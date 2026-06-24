import XCTest
@testable import ReadrKit

final class AnthropicProviderTests: XCTestCase {

    private func deltaLine(_ text: String) -> Data {
        Data(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(text)"}}"#.utf8)
    }

    private func makeRequest() -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "Hi")], maxOutputTokens: 64)
    }

    func testStreamsConcatenatedText() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            deltaLine("Hel"),
            deltaLine("lo"),
            Data("data: [DONE]".utf8),
        ]
        let provider = AnthropicProvider(credentials: .apiKey("sk-test"), http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hello")
    }

    func testIgnoresNonDeltaEvents() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"data: {"type":"message_start"}"#.utf8),
            deltaLine("Hi"),
            Data(#"data: {"type":"content_block_stop"}"#.utf8),
            Data("data: [DONE]".utf8),
        ]
        let provider = AnthropicProvider(credentials: .apiKey("sk-test"), http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hi")
    }

    func testRequestUsesMessagesEndpointAndAPIKeyHeader() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data("data: [DONE]".utf8)]
        let provider = AnthropicProvider(credentials: .apiKey("sk-abc"), http: mock)
        _ = try await collectStream(provider.stream(makeRequest()))

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.method, .post)
        XCTAssertEqual(recorded.headers["x-api-key"], "sk-abc")
        XCTAssertEqual(recorded.headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(recorded.headers["authorization"])

        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"stream\":true"), "body was: \(json)")
    }

    func testOAuthCredentialsUseBearerAuthorization() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data("data: [DONE]".utf8)]
        let provider = AnthropicProvider(
            credentials: .oauth(accessToken: "tok-123", refreshToken: nil, expiresAt: nil),
            http: mock
        )
        _ = try await collectStream(provider.stream(makeRequest()))

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.headers["authorization"], "Bearer tok-123")
        XCTAssertNil(recorded.headers["x-api-key"])
        XCTAssertEqual(recorded.headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testCacheableSystemPrefixIsEphemeralBlock() async throws {
        let request = ChatRequest(
            messages: [ChatMessage(role: .user, content: "Q")],
            cacheableSystemPrefix: "BOOK",
            maxOutputTokens: 32
        )
        let body = try AnthropicProvider.encodeBody(request, model: "claude-opus-4-8")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let system = try XCTUnwrap(object["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["type"] as? String, "text")
        XCTAssertEqual(system.first?["text"] as? String, "BOOK")
        let cacheControl = try XCTUnwrap(system.first?["cache_control"] as? [String: Any])
        XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
    }

    func testSystemMessageIsHoisted() async throws {
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .system, content: "You are a tutor."),
                ChatMessage(role: .user, content: "Q"),
            ],
            maxOutputTokens: 32
        )
        let body = try AnthropicProvider.encodeBody(request, model: "claude-opus-4-8")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        // `system` is always an array of text blocks (consistent shape).
        let system = try XCTUnwrap(object["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system.first?["text"] as? String, "You are a tutor.")
        XCTAssertNil(system.first?["cache_control"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testInfoMetadata() {
        let provider = AnthropicProvider(credentials: .apiKey("k"))
        XCTAssertEqual(provider.info.kind, .anthropic)
        XCTAssertTrue(provider.info.supportsPromptCaching)
        XCTAssertFalse(provider.info.isLocal)
    }

    func testCountTokens() throws {
        let provider = AnthropicProvider(credentials: .apiKey("k"))
        XCTAssertEqual(try provider.countTokens("12345678"), 2)
    }
}
