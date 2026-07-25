import XCTest
@testable import ReadrKit

final class OpenAIProviderTests: XCTestCase {

    private func makeRequest() -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "Hi")], maxOutputTokens: 64)
    }

    func testStreamsConcatenatedText() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#.utf8),
            Data(#"data: {"choices":[{"delta":{"content":"lo"}}]}"#.utf8),
            Data("data: [DONE]".utf8),
        ]
        let provider = OpenAIProvider(credentials: .apiKey("sk-test"), http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hello")
    }

    func testIgnoresEmptyDeltas() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#.utf8),
            Data(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#.utf8),
            Data("data: [DONE]".utf8),
        ]
        let provider = OpenAIProvider(credentials: .apiKey("sk-test"), http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hi")
    }

    func testRequestUsesCompletionsEndpointAndBearerAuth() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data("data: [DONE]".utf8)]
        let provider = OpenAIProvider(credentials: .apiKey("sk-abc"), http: mock)
        _ = try await collectStream(provider.stream(makeRequest()))

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(recorded.method, .post)
        XCTAssertEqual(recorded.headers["authorization"], "Bearer sk-abc")

        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"stream\":true"), "body was: \(json)")
    }

    func testOAuthAccessTokenUsedAsBearer() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data("data: [DONE]".utf8)]
        let provider = OpenAIProvider(
            credentials: .oauth(accessToken: "tok-9", refreshToken: nil, expiresAt: nil),
            http: mock
        )
        _ = try await collectStream(provider.stream(makeRequest()))
        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.headers["authorization"], "Bearer tok-9")
    }

    func testSystemMessageSentInline() async throws {
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .system, content: "Sys"),
                ChatMessage(role: .user, content: "Q"),
            ],
            maxOutputTokens: 32
        )
        let body = try OpenAIProvider.encodeBody(request, model: "gpt-4.1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "Sys")
    }

    func testInfoMetadata() {
        let provider = OpenAIProvider(credentials: .apiKey("k"))
        XCTAssertEqual(provider.info.kind, .openAI)
        XCTAssertFalse(provider.info.supportsPromptCaching)
        XCTAssertFalse(provider.info.isLocal)
    }

    // MARK: - OpenRouter endpoints preset

    func testOpenRouterPresetStreamsAgainstOpenRouterEndpoint() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#.utf8),
            Data("data: [DONE]".utf8),
        ]
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-or-abc"),
            model: "openai/gpt-4.1",
            http: mock,
            endpoints: .openRouter
        )
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hi")

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(recorded.headers["authorization"], "Bearer sk-or-abc")
    }

    func testOpenRouterPresetReportsOpenRouterKind() {
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-or-abc"), model: "openai/gpt-4.1", endpoints: .openRouter
        )
        XCTAssertEqual(provider.info.kind, .openRouter)
        XCTAssertFalse(provider.info.isLocal)
    }

    func testOpenRouterValidationSurfacesRejection() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            XCTAssertEqual(request.headers["authorization"], "Bearer sk-or-bad")
            return HTTPResponse(status: 401, body: Data())
        }
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-or-bad"), model: "openai/gpt-5.6", http: mock, endpoints: .openRouter
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

    // MARK: - Validation exercises generation

    /// A metadata GET would pass for a key with no quota and then fail every
    /// real question; the probe posts a 1-token completion instead.
    func testValidationPostsMinimalCompletionToChatEndpoint() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/chat/completions")
            XCTAssertEqual(request.method, .post)
            let body = try XCTUnwrap(request.body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            // OpenAI's current output-cap field.
            XCTAssertEqual(object["max_completion_tokens"] as? Int, 1)
            XCTAssertNil(object["max_tokens"], "the deprecated field is rejected by newer models")
            XCTAssertEqual(object["model"] as? String, "gpt-5.6-terra")
            return HTTPResponse(status: 200, body: Data())
        }
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-abc"), model: "gpt-5.6-terra", http: mock
        )
        try await provider.validateCredential()
        XCTAssertEqual(mock.requests.count, 1)
    }

    /// OpenRouter normalizes the older field name, so the preset sends that.
    func testOpenRouterValidationUsesMaxTokensField() async throws {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            let body = try XCTUnwrap(request.body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["max_tokens"] as? Int, 1)
            return HTTPResponse(status: 200, body: Data())
        }
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-or"), model: "openai/gpt-5.6", http: mock, endpoints: .openRouter
        )
        try await provider.validateCredential()
    }

    /// The exhausted-quota case the metadata probe used to miss entirely.
    func testValidationSurfacesQuotaExhaustion() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { _ in
            HTTPResponse(
                status: 429,
                body: Data(#"{"error":{"type":"insufficient_quota"}}"#.utf8)
            )
        }
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-nocredit"), model: "gpt-5.6-terra", http: mock
        )
        do {
            try await provider.validateCredential()
            XCTFail("expected the quota error to throw")
        } catch let HTTPError.status(code, body) {
            XCTAssertEqual(code, 429)
            XCTAssertTrue(HTTPError.indicatesQuotaExhausted(body))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The default init is byte-for-byte the pre-endpoints behavior: same URL,
    /// same kind — guards against the parameterization changing the OpenAI path.
    func testDefaultEndpointsUnchanged() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data("data: [DONE]".utf8)]
        let provider = OpenAIProvider(credentials: .apiKey("sk-abc"), http: mock)
        _ = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(
            mock.requests.first?.url.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(provider.info.kind, .openAI)
    }
}
