import Foundation

/// Static configuration for one provider's OAuth 2.0 + PKCE flow.
public struct OAuthProviderConfig: Sendable, Equatable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String]
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// OpenAI / Codex CLI public client configuration.
    public static let openAI = OAuthProviderConfig(
        authorizationEndpoint: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        redirectURI: "http://127.0.0.1:1455/auth/callback",
        scopes: ["openid", "profile", "email", "offline_access"]
    )

    /// Anthropic does NOT offer a supported subscription-OAuth path for Readr:
    /// Anthropic's Consumer Terms prohibit using Free/Pro/Max OAuth tokens in any
    /// third-party product. Connect Anthropic with an **API key** instead. This
    /// config is intentionally left unwired (see SettingsModel.oauthConfig) and
    /// kept only as a marker; do not enable it. (docs/AUTH.md)
    public static let anthropicUnsupported = OAuthProviderConfig(
        authorizationEndpoint: URL(string: "https://claude.ai/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        clientID: "UNSUPPORTED_ANTHROPIC_OAUTH_PROHIBITED_BY_TOS",
        redirectURI: "http://127.0.0.1:1456/auth/callback",
        scopes: []
    )
}

/// Drives the OAuth 2.0 Authorization Code + PKCE flow for a single provider.
///
/// The flow has four steps that map to the methods below:
/// 1. `authorizationURL(pkce:state:)` — URL to open in the browser.
/// 2. `handleCallback(url:expectedState:)` — extract the `code` from the redirect.
/// 3. `exchangeCode(_:pkce:)` — swap the code for tokens.
/// 4. `refresh(_:)` — renew an access token using the refresh token.
public struct OAuthClient: Sendable {
    private let config: OAuthProviderConfig
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(
        config: OAuthProviderConfig,
        http: HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.http = http
        self.now = now
    }

    // MARK: - Authorization

    /// Build the browser authorization URL with the PKCE challenge and CSRF state.
    public func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Parse the redirect URL, validate `state`, and return the authorization `code`.
    ///
    /// - Throws: `AuthError.stateMismatch` if the returned state does not match,
    ///   `AuthError.tokenExchangeFailed("missing code")` if no code is present.
    public func handleCallback(url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let returnedState = items.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw AuthError.stateMismatch
        }
        // The provider may redirect with an error (e.g. the user denied consent)
        // while still echoing a valid state — surface that, don't report "missing code".
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" { throw AuthError.userCancelled }
            let description = items.first(where: { $0.name == "error_description" })?.value
            throw AuthError.tokenExchangeFailed(description ?? error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.tokenExchangeFailed("missing code")
        }
        return code
    }

    // MARK: - Token exchange

    /// Exchange an authorization code for OAuth credentials.
    public func exchangeCode(_ code: String, pkce: PKCE) async throws -> Credentials {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientID,
            "code_verifier": pkce.codeVerifier,
        ]
        return try await postTokenRequest(form: form, existingRefreshToken: nil)
    }

    /// Renew credentials using the stored refresh token.
    ///
    /// - Throws: `AuthError.refreshFailed` if the credentials are not an
    ///   `.oauth` value carrying a refresh token.
    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard case let .oauth(_, refreshToken?, _) = credentials else {
            throw AuthError.refreshFailed
        }
        let form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        return try await postTokenRequest(form: form, existingRefreshToken: refreshToken)
    }

    // MARK: - Internals

    /// JSON token endpoint response. Fields beyond these are ignored.
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    /// POST a form-urlencoded body to the token endpoint and decode credentials.
    ///
    /// - Parameter existingRefreshToken: preserved when the response omits a new
    ///   refresh token (common for refresh-token grants).
    private func postTokenRequest(
        form: [String: String],
        existingRefreshToken: String?
    ) async throws -> Credentials {
        let request = HTTPRequest(
            url: config.tokenEndpoint,
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(OAuthClient.formURLEncode(form).utf8)
        )

        let response = try await http.send(request)
        guard response.isSuccess else {
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw AuthError.tokenExchangeFailed(body)
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw AuthError.tokenExchangeFailed("invalid token response")
        }

        let expiresAt = token.expires_in.map { now().addingTimeInterval($0) }
        return .oauth(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? existingRefreshToken,
            expiresAt: expiresAt
        )
    }

    /// Encode a dictionary as an `application/x-www-form-urlencoded` body.
    ///
    /// Keys are sorted for deterministic output; values are percent-encoded.
    private static func formURLEncode(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    /// Percent-encode a form component. The unreserved set is left untouched and
    /// everything else (including `+`, `&`, `=`, space) is escaped.
    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
