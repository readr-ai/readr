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
}
