import XCTest
@testable import ReadrKit

final class ChatGPTSubscriptionProviderTests: XCTestCase {

    // MARK: - Fixtures

    /// Build an unsigned JWT whose payload is the given JSON object —
    /// enough for claim extraction, which never verifies signatures.
    private func makeJWT(payload: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let body = try JSONSerialization.data(withJSONObject: payload).base64URLEncodedString()
        return "\(header).\(body).sig"
    }

    private func makeCredentials(accountID: String? = "acc-123") throws -> Credentials {
        let payload: [String: Any] = accountID.map { ["chatgpt_account_id": $0] } ?? ["sub": "u"]
        return .oauth(
            accessToken: try makeJWT(payload: payload), refreshToken: "rt", expiresAt: nil
        )
    }

    private func makeRequest() -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "Hi")], maxOutputTokens: 64)
    }

    // MARK: - JWT account-id extraction

    func testAccountIDExtractedFromTopLevelClaim() throws {
        let token = try makeJWT(payload: ["chatgpt_account_id": "acc-top"])
        XCTAssertEqual(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: token), "acc-top")
    }

    func testAccountIDExtractedFromNestedAuthClaim() throws {
        let token = try makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-nested"]
        ])
        XCTAssertEqual(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: token), "acc-nested")
    }

    func testAccountIDNilForGarbageToken() {
        XCTAssertNil(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: "not-a-jwt"))
        XCTAssertNil(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: "a.!!!.c"))
        XCTAssertNil(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: ""))
    }

    func testAccountIDNilWhenClaimMissing() throws {
        let token = try makeJWT(payload: ["sub": "user-1"])
        XCTAssertNil(ChatGPTSubscriptionProvider.chatGPTAccountID(fromAccessToken: token))
    }

    // MARK: - Request body

    func testEncodeBodyFoldsSystemContentIntoInstructions() throws {
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .system, content: "Be terse."),
                ChatMessage(role: .user, content: "Q1"),
            ],
            cacheableSystemPrefix: "BOOK CONTEXT",
            maxOutputTokens: 32
        )
        let body = try ChatGPTSubscriptionProvider.encodeBody(request, model: "gpt-5.4-mini")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertEqual(object["instructions"] as? String, "BOOK CONTEXT\n\nBe terse.")

        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "Q1")
    }

    func testEncodeBodyMapsAssistantTurnsToOutputText() throws {
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .user, content: "Q1"),
                ChatMessage(role: .assistant, content: "A1"),
                ChatMessage(role: .user, content: "Q2"),
            ],
            maxOutputTokens: 32
        )
        let body = try ChatGPTSubscriptionProvider.encodeBody(request, model: "gpt-5.4-mini")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        let assistantContent = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.first?["type"] as? String, "output_text")
        // No instructions key when there is no system content.
        XCTAssertNil(object["instructions"])
    }

    // MARK: - Streaming

    func testStreamSendsWhamRequestAndYieldsDeltas() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"type":"response.output_text.delta","delta":"Hel"}"#.utf8),
            Data(#"data: {"type":"response.output_text.delta","delta":"lo"}"#.utf8),
            Data(#"data: {"type":"response.completed"}"#.utf8),
        ]
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini", http: mock
        )
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hello")

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(
            recorded.url.absoluteString, "https://chatgpt.com/backend-api/wham/responses"
        )
        XCTAssertEqual(recorded.method, .post)
        XCTAssertEqual(recorded.headers["ChatGPT-Account-Id"], "acc-123")
        XCTAssertEqual(recorded.headers["authorization"]?.hasPrefix("Bearer "), true)
    }

    func testStreamIgnoresUnrelatedEvents() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"type":"response.created"}"#.utf8),
            Data(#"data: {"type":"response.output_item.added","item":{}}"#.utf8),
            Data(#"data: {"type":"response.output_text.delta","delta":"Hi"}"#.utf8),
            Data("data: [DONE]".utf8),
        ]
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini", http: mock
        )
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hi")
    }

    func testStreamThrowsOnFailureEvent() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"type":"response.failed","response":{"error":{"message":"quota hit"}}}"#.utf8),
        ]
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini", http: mock
        )
        do {
            _ = try await collectStream(provider.stream(makeRequest()))
            XCTFail("expected the failure event to throw")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("quota hit"), "\(error)")
        }
    }

    func testStreamCompletesAtEndWithoutDoneSentinel() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"type":"response.output_text.delta","delta":"End"}"#.utf8)
        ]
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini", http: mock
        )
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "End")
    }

    func testStreamFailsBeforeNetworkWhenAccountIDMissing() async throws {
        let mock = MockHTTPClient()
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(accountID: nil), model: "gpt-5.4-mini", http: mock
        )
        do {
            _ = try await collectStream(provider.stream(makeRequest()))
            XCTFail("expected missing account id to fail the stream")
        } catch {
            XCTAssertTrue(mock.requests.isEmpty, "no request should have been sent")
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("sign in"),
                error.localizedDescription
            )
        }
    }

    // MARK: - Validation

    func testValidateCredentialRejectsUnusableTokenWithoutNetwork() async {
        let mock = MockHTTPClient()
        let provider = ChatGPTSubscriptionProvider(
            credentials: .oauth(accessToken: "garbage", refreshToken: nil, expiresAt: nil),
            model: "gpt-5.4-mini",
            http: mock
        )
        do {
            try await provider.validateCredential()
            XCTFail("expected an unusable token to throw")
        } catch let HTTPError.status(code, _) {
            // 401 so ProviderManager classifies it .invalid (re-auth), not .unavailable.
            XCTAssertEqual(code, 401)
            XCTAssertTrue(mock.requests.isEmpty, "pre-check must not touch the network")
        } catch {
            XCTFail("expected a synthetic 401, got \(error)")
        }
    }

    func testValidateCredentialSurfacesBackendRejection() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acc-123")
            return HTTPResponse(status: 401, body: Data())
        }
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini", http: mock
        )
        do {
            try await provider.validateCredential()
            XCTFail("expected a 401 to throw")
        } catch let HTTPError.status(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Metadata

    func testInfoMetadata() throws {
        let provider = ChatGPTSubscriptionProvider(
            credentials: try makeCredentials(), model: "gpt-5.4-mini"
        )
        XCTAssertEqual(provider.info.kind, .chatGPT)
        XCTAssertEqual(provider.info.modelID, "gpt-5.4-mini")
        XCTAssertFalse(provider.info.supportsPromptCaching)
        XCTAssertFalse(provider.info.isLocal)
    }
}

private extension Data {
    /// Base64url without padding — the JWT segment encoding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
