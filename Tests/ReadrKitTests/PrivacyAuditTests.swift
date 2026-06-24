import XCTest
@testable import ReadrKit

/// Zero-egress / privacy audit (J7).
///
/// These tests prove Readr's privacy posture *structurally*: the on-device
/// retrieval pipeline takes no `HTTPClient` (so it physically cannot egress),
/// the local LLM provider only ever contacts loopback, and telemetry is off.
final class PrivacyAuditTests: XCTestCase {

    // MARK: - Helpers

    /// A small, fully on-device 2-chapter book for the retrieval pipeline test.
    private func makeBook() -> Book {
        let ch1 = Chapter(
            title: "Dogs",
            order: 0,
            text: """
            The puppy ran across the yard chasing a ball. Dogs love to play \
            fetch with their owners. A loyal puppy will follow you everywhere, \
            wagging its tail.
            """
        )
        let ch2 = Chapter(
            title: "Space",
            order: 1,
            text: """
            The planets orbit the sun through space. Astronomers study distant \
            galaxies with powerful telescopes. Mars and Jupiter are planets in \
            our solar system.
            """
        )
        return Book(
            metadata: BookMetadata(title: "Animals and the Cosmos"),
            chapters: [ch1, ch2],
            estimatedTokenCount: 0
        )
    }

    /// Drain a `ChatChunk` stream into the concatenated text. The caller wraps
    /// this in do/catch because the `NetworkSentinel` throws on every call.
    private func collect(_ provider: LLMProvider, _ request: ChatRequest) async throws -> String {
        var text = ""
        for try await chunk in provider.stream(request) {
            text += chunk.textDelta
        }
        return text
    }

    // MARK: - Tests

    func testNoTelemetryByDefault() {
        XCTAssertFalse(Telemetry.isEnabled)
    }

    func testOnDeviceRetrievalPipelineNeedsNoNetwork() async throws {
        // The whole retrieval path is structurally offline: `HybridRAGIndex`,
        // `LocalEmbeddingProvider`, and `Chunker` take NO `HTTPClient`, so there
        // is no place to inject network access and nothing to egress. No network
        // sentinel is needed because the pipeline literally can't make requests.
        let book = makeBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let results = try await index.retrieve(query: "puppy", bookID: book.id, limit: 2)
        XCTAssertFalse(results.isEmpty)
    }

    func testLocalProviderOnlyContactsLoopback() async throws {
        // Hold a reference to the sentinel so we can inspect attempts afterward.
        let sentinel = NetworkSentinel()
        let provider = LocalLLMProvider(http: sentinel)

        let request = ChatRequest(
            messages: [.init(role: .user, content: "hi")],
            maxOutputTokens: 16
        )

        do {
            _ = try await collect(provider, request)
        } catch {
            // Expected: the sentinel throws on every network call.
        }

        // The provider must have attempted a request...
        XCTAssertFalse(sentinel.attemptedURLs.isEmpty)

        // ...and every attempt must target loopback only — never an external API.
        for url in sentinel.attemptedURLs {
            XCTAssertEqual(url.host, "127.0.0.1", "Local mode reached non-loopback host: \(url)")
            XCTAssertNotEqual(url.host, "api.openai.com")
            XCTAssertNotEqual(url.host, "api.anthropic.com")
        }
    }

    func testLocalProviderInfoIsLocal() {
        let info = LocalLLMProvider().info
        XCTAssertTrue(info.isLocal)
        XCTAssertEqual(info.kind, .local)
    }
}
