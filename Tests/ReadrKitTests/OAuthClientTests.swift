import XCTest
@testable import ReadrKit

final class OAuthClientTests: XCTestCase {

    private let config = OAuthProviderConfig.openAI

    /// Parse the query items of a URL into a `[name: value]` dictionary.
    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    // MARK: - authorizationURL

    func testAuthorizationURLContainsRequiredQueryItems() {
        let client = OAuthClient(config: config, http: MockHTTPClient())
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = client.authorizationURL(pkce: pkce, state: "xyz-state")

        let items = queryItems(url)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], config.clientID)
        XCTAssertEqual(items["redirect_uri"], config.redirectURI)
        XCTAssertEqual(items["scope"], "openid profile email offline_access")
        XCTAssertEqual(items["code_challenge"], pkce.codeChallenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "xyz-state")
    }

    // MARK: - handleCallback

    func testHandleCallbackReturnsCodeOnMatchingState() throws {
        let client = OAuthClient(config: config, http: MockHTTPClient())
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=the-code&state=expected")!
        let code = try client.handleCallback(url: url, expectedState: "expected")
        XCTAssertEqual(code, "the-code")
    }

    func testHandleCallbackThrowsOnStateMismatch() {
        let client = OAuthClient(config: config, http: MockHTTPClient())
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?code=the-code&state=wrong")!
        XCTAssertThrowsError(try client.handleCallback(url: url, expectedState: "expected")) { error in
            XCTAssertEqual(error as? AuthError, AuthError.stateMismatch)
        }
    }

    func testHandleCallbackThrowsWhenCodeMissing() {
        let client = OAuthClient(config: config, http: MockHTTPClient())
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?state=expected")!
        XCTAssertThrowsError(try client.handleCallback(url: url, expectedState: "expected")) { error in
            guard case AuthError.tokenExchangeFailed = error else {
                return XCTFail("expected tokenExchangeFailed, got \(error)")
            }
        }
    }

    // MARK: - exchangeCode

    func testExchangeCodeReturnsOAuthCredentials() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#
            return HTTPResponse(status: 200, body: Data(json.utf8))
        }
        let client = OAuthClient(config: config, http: mock, now: { fixedNow })
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        let credentials = try await client.exchangeCode("the-code", pkce: pkce)

        guard case let .oauth(accessToken, refreshToken, expiresAt) = credentials else {
            return XCTFail("expected .oauth credentials, got \(credentials)")
        }
        XCTAssertEqual(accessToken, "at")
        XCTAssertEqual(refreshToken, "rt")
        XCTAssertEqual(expiresAt, fixedNow.addingTimeInterval(3600))

        // Verify the POST body carried the grant type and PKCE verifier.
        let body = try XCTUnwrap(mock.requests.first?.body)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("grant_type=authorization_code"), bodyString)
        XCTAssertTrue(bodyString.contains("code_verifier="), bodyString)
    }

    func testExchangeCodeThrowsOnNonSuccess() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            HTTPResponse(status: 400, body: Data("bad".utf8))
        }
        let client = OAuthClient(config: config, http: mock)
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        do {
            _ = try await client.exchangeCode("the-code", pkce: pkce)
            XCTFail("expected tokenExchangeFailed")
        } catch let AuthError.tokenExchangeFailed(message) {
            XCTAssertEqual(message, "bad")
        } catch {
            XCTFail("expected tokenExchangeFailed, got \(error)")
        }
    }

    // MARK: - refresh

    func testRefreshWithoutRefreshTokenThrows() async {
        let client = OAuthClient(config: config, http: MockHTTPClient())
        let credentials = Credentials.oauth(accessToken: "at", refreshToken: nil, expiresAt: nil)

        do {
            _ = try await client.refresh(credentials)
            XCTFail("expected refreshFailed")
        } catch {
            XCTAssertEqual(error as? AuthError, AuthError.refreshFailed)
        }
    }

    func testRefreshPreservesOldRefreshTokenWhenOmitted() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            // Response omits refresh_token — the client should keep the old one.
            let json = #"{"access_token":"new-at","expires_in":7200}"#
            return HTTPResponse(status: 200, body: Data(json.utf8))
        }
        let client = OAuthClient(config: config, http: mock, now: { fixedNow })
        let credentials = Credentials.oauth(accessToken: "old-at", refreshToken: "keep-me", expiresAt: nil)

        let refreshed = try await client.refresh(credentials)

        guard case let .oauth(accessToken, refreshToken, expiresAt) = refreshed else {
            return XCTFail("expected .oauth credentials, got \(refreshed)")
        }
        XCTAssertEqual(accessToken, "new-at")
        XCTAssertEqual(refreshToken, "keep-me")
        XCTAssertEqual(expiresAt, fixedNow.addingTimeInterval(7200))

        let body = try XCTUnwrap(mock.requests.first?.body)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("grant_type=refresh_token"), bodyString)
    }

    // MARK: - Extra authorize params (ChatGPT / Codex flow)

    func testOpenAIAuthorizeURLCarriesCodexFlowParams() {
        let client = OAuthClient(config: .openAI, http: MockHTTPClient())
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let items = queryItems(client.authorizationURL(pkce: pkce, state: "s"))

        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(items["id_token_add_organizations"], "true")
        XCTAssertNotNil(items["originator"])
    }

    // MARK: - Key-exchange flow (OpenRouter)

    private let openRouter = OAuthProviderConfig.openRouter

    func testKeyExchangeAuthorizeURLUsesCallbackURLShape() {
        let client = OAuthClient(config: openRouter, http: MockHTTPClient())
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = client.authorizationURL(pkce: pkce, state: "xyz-state")
        let items = queryItems(url)

        XCTAssertEqual(url.host, "openrouter.ai")
        XCTAssertEqual(items["callback_url"], openRouter.redirectURI)
        XCTAssertEqual(items["code_challenge"], pkce.codeChallenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "xyz-state")
        // The key-exchange style has no OAuth client registration.
        XCTAssertNil(items["client_id"])
        XCTAssertNil(items["redirect_uri"])
        XCTAssertNil(items["response_type"])
        XCTAssertNil(items["scope"])
    }

    func testKeyExchangeReturnsAPIKeyCredentials() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
            XCTAssertEqual(request.headers["Content-Type"], "application/json")
            let body = try XCTUnwrap(request.body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["code"], "the-code")
            XCTAssertEqual(object["code_verifier"], "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            XCTAssertEqual(object["code_challenge_method"], "S256")
            return HTTPResponse(status: 200, body: Data(#"{"key":"sk-or-v1-abc"}"#.utf8))
        }
        let client = OAuthClient(config: openRouter, http: mock)
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        let credentials = try await client.exchangeCode("the-code", pkce: pkce)
        XCTAssertEqual(credentials, .apiKey("sk-or-v1-abc"))
    }

    func testKeyExchangeThrowsOnNonSuccess() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 403, body: Data("denied".utf8)) }
        let client = OAuthClient(config: openRouter, http: mock)
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        do {
            _ = try await client.exchangeCode("the-code", pkce: pkce)
            XCTFail("expected tokenExchangeFailed")
        } catch let AuthError.tokenExchangeFailed(message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("expected tokenExchangeFailed, got \(error)")
        }
    }

    func testKeyExchangeThrowsWhenKeyFieldMissing() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in HTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        let client = OAuthClient(config: openRouter, http: mock)
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        do {
            _ = try await client.exchangeCode("the-code", pkce: pkce)
            XCTFail("expected tokenExchangeFailed")
        } catch AuthError.tokenExchangeFailed {
            // expected
        } catch {
            XCTFail("expected tokenExchangeFailed, got \(error)")
        }
    }

    /// OpenRouter may not echo `state` back on the callback; the PKCE verifier
    /// still binds the exchange, so a missing state is tolerated for the
    /// key-exchange style — but an explicitly different state never is.
    func testKeyExchangeCallbackToleratesMissingStateButNotMismatch() throws {
        let client = OAuthClient(config: openRouter, http: MockHTTPClient())

        let missing = URL(string: "http://127.0.0.1:1456/callback?code=c1")!
        XCTAssertEqual(try client.handleCallback(url: missing, expectedState: "expected"), "c1")

        let mismatched = URL(string: "http://127.0.0.1:1456/callback?code=c1&state=wrong")!
        XCTAssertThrowsError(try client.handleCallback(url: mismatched, expectedState: "expected")) {
            XCTAssertEqual($0 as? AuthError, AuthError.stateMismatch)
        }
    }

    /// The token-style flow must NOT inherit that tolerance: a missing state
    /// on the standard flow stays a hard mismatch.
    func testTokenFlowCallbackStillRequiresState() {
        let client = OAuthClient(config: .openAI, http: MockHTTPClient())
        let url = URL(string: "http://localhost:1455/auth/callback?code=c1")!
        XCTAssertThrowsError(try client.handleCallback(url: url, expectedState: "expected")) {
            XCTAssertEqual($0 as? AuthError, AuthError.stateMismatch)
        }
    }

    // MARK: - Kind → config mapping

    func testConfigForKindMapsSignInKindsOnly() {
        XCTAssertEqual(OAuthProviderConfig.config(for: .chatGPT), .openAI)
        XCTAssertEqual(OAuthProviderConfig.config(for: .openRouter), .openRouter)
        XCTAssertNil(OAuthProviderConfig.config(for: .anthropic), "prohibited by ToS — docs/AUTH.md")
        XCTAssertNil(OAuthProviderConfig.config(for: .openAI), "API-key path by design")
        XCTAssertNil(OAuthProviderConfig.config(for: .local))
    }

    func testRefreshThrowsForKeyExchangeStyle() async {
        let client = OAuthClient(config: openRouter, http: MockHTTPClient())
        let credentials = Credentials.oauth(accessToken: "at", refreshToken: "rt", expiresAt: nil)
        do {
            _ = try await client.refresh(credentials)
            XCTFail("expected refreshFailed")
        } catch {
            XCTAssertEqual(error as? AuthError, AuthError.refreshFailed)
        }
    }
}
