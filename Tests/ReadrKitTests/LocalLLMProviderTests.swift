import XCTest
@testable import ReadrKit

final class LocalLLMProviderTests: XCTestCase {

    private func makeRequest() -> ChatRequest {
        ChatRequest(messages: [ChatMessage(role: .user, content: "Hi")], maxOutputTokens: 64)
    }

    func testStreamsConcatenatedTextFromNDJSON() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"{"message":{"content":"Hel"},"done":false}"#.utf8),
            Data(#"{"message":{"content":"lo"},"done":true}"#.utf8),
        ]
        let provider = LocalLLMProvider(http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "Hello")
    }

    func testRequestTargetsLocalChatEndpoint() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [Data(#"{"message":{"content":"x"},"done":true}"#.utf8)]
        let provider = LocalLLMProvider(http: mock)
        _ = try await collectStream(provider.stream(makeRequest()))

        let recorded = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(recorded.url.host, "127.0.0.1")
        XCTAssertEqual(recorded.url.port, 11434)
        XCTAssertEqual(recorded.url.path, "/api/chat")
        XCTAssertEqual(recorded.method, .post)

        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("\"stream\":true"), "body was: \(json)")
    }

    func testFinishesOnDoneFlag() async throws {
        let mock = MockHTTPClient()
        mock.streamChunks = [
            Data(#"{"message":{"content":"A"},"done":false}"#.utf8),
            Data(#"{"message":{"content":"B"},"done":true}"#.utf8),
            // Trailing line after done must be ignored.
            Data(#"{"message":{"content":"C"},"done":false}"#.utf8),
        ]
        let provider = LocalLLMProvider(http: mock)
        let text = try await collectStream(provider.stream(makeRequest()))
        XCTAssertEqual(text, "AB")
    }

    func testInfoMetadata() {
        let provider = LocalLLMProvider()
        XCTAssertEqual(provider.info.kind, .local)
        XCTAssertTrue(provider.info.isLocal)
        XCTAssertFalse(provider.info.supportsPromptCaching)
        XCTAssertEqual(provider.info.modelID, "llama3")
    }

    func testCountTokensMinimumOne() throws {
        let provider = LocalLLMProvider()
        XCTAssertEqual(try provider.countTokens(""), 1)
    }
}
