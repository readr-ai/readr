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

    func testOpenRouterValidationHitsKeyEndpointAndSurfacesRejection() async {
        let mock = MockHTTPClient()
        mock.sendHandler = { request in
            XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/key")
            XCTAssertEqual(request.headers["authorization"], "Bearer sk-or-bad")
            return HTTPResponse(status: 401, body: Data())
        }
        let provider = OpenAIProvider(
            credentials: .apiKey("sk-or-bad"), model: "openai/gpt-4.1", http: mock, endpoints: .openRouter
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
