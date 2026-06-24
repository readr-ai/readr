import XCTest
@testable import ReadrKit

final class ContextStrategyTests: XCTestCase {

    private func makeBook(tokenCount: Int) -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book", authors: ["A. Author"]),
            chapters: [Chapter(title: "One", order: 0, text: "Hello world.")],
            estimatedTokenCount: tokenCount
        )
    }

    private func provider(budget: Int, isLocal: Bool) -> ProviderInfo {
        ProviderInfo(
            kind: isLocal ? .local : .anthropic,
            modelID: "test",
            contextBudget: budget,
            supportsPromptCaching: !isLocal,
            isLocal: isLocal
        )
    }

    func testSmallBookUsesWholeBookTier() async throws {
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 1_000),
            selection: nil,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .wholeBook)
    }

    func testLargeBookUsesRetrievalTier() async throws {
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .retrieval)
    }

    func testRetrievalTierPopulatesCitationsFromPassages() async throws {
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: "First relevant passage.", locator: "Ch. 2 ¶3", score: 0.9),
            RetrievedPassage(text: "Second relevant passage.", locator: "Ch. 5 ¶1", score: 0.8),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .retrieval)
        XCTAssertEqual(result.citations.map(\.locator), ["Ch. 2 ¶3", "Ch. 5 ¶1"])
        XCTAssertEqual(result.citations.first?.quotedText, "First relevant passage.")
    }

    func testWholeBookTierHasNoCitations() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 1_000),
            selection: nil,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .wholeBook)
        XCTAssertTrue(result.citations.isEmpty)
    }

    func testCitationSnippetTrimsLongText() async throws {
        let long = String(repeating: "word ", count: 100)
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: long, locator: "Ch. 1 ¶1", score: 1.0),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            provider: provider(budget: 200_000, isLocal: false)
        )
        let snippet = try XCTUnwrap(result.citations.first?.quotedText)
        XCTAssertLessThanOrEqual(snippet.count, 161) // up to maxLength + ellipsis
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testLocalProviderAlwaysUsesRetrieval() async throws {
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 10),
            selection: nil,
            provider: provider(budget: 8_000, isLocal: true)
        )
        XCTAssertEqual(result.tier, .retrieval)
    }

    func testTokenEstimate() {
        XCTAssertEqual(estimateTokens(String(repeating: "a", count: 400)), 100)
    }
}

/// Minimal in-memory index for routing tests.
private struct StubIndex: RAGIndex {
    func build(for book: Book, embeddings: EmbeddingProvider) async throws {}
    func retrieve(query: String, bookID: UUID, limit: Int) async throws -> [RetrievedPassage] {
        [RetrievedPassage(text: "stub passage", locator: "Ch.1", score: 1.0)]
    }
    func isBuilt(bookID: UUID) async -> Bool { true }
}
