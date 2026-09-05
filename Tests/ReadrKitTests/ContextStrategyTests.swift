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

    private func provider(budget: Int, isLocal: Bool, caching: Bool? = nil) -> ProviderInfo {
        ProviderInfo(
            kind: isLocal ? .local : .anthropic,
            modelID: "test",
            contextBudget: budget,
            supportsPromptCaching: caching ?? !isLocal,
            isLocal: isLocal
        )
    }

    func testSmallBookUsesWholeBookTier() async throws {
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 1_000),
            selection: nil,
            scope: .wholeBook,
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
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .retrieval)
    }

    /// A small-window model (the on-device one: 4,096 tokens including the
    /// answer) gets as many passages as its budget holds — decided here, where
    /// the passages are still a list, so the citations shown to the reader
    /// are exactly the passages the model was sent. Nothing downstream has
    /// to parse the prompt to shorten it.
    func testRetrievalTierTrimsPassagesToTheProviderBudgetAndCitesOnlyThose() async throws {
        let passages = (1...8).map { index in
            RetrievedPassage(
                text: String(repeating: "passage \(index) words and words. ", count: 40),
                locator: "Ch. \(index)", score: 1.0 - Double(index) / 10
            )
        }
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex(passages: passages))
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 1_200, isLocal: true)
        )
        XCTAssertEqual(result.tier, .retrieval)
        XCTAssertLessThan(result.citations.count, 8, "eight passages cannot fit 1,200 tokens")
        XCTAssertGreaterThan(result.citations.count, 0, "the best passage always rides along")
        // The strongest matches are the ones kept, in order.
        XCTAssertEqual(result.citations.map(\.locator), (1...result.citations.count).map { "Ch. \($0)" })
        let prompt = result.request.messages.last?.content ?? ""
        XCTAssertTrue(prompt.contains("[Ch. 1]"))
        XCTAssertFalse(prompt.contains("[Ch. 8]"), "a dropped passage is not in the prompt either")
        XCTAssertLessThanOrEqual(
            TokenCounter.estimate(result.request.messages.map(\.content).joined()), 1_200
        )
    }

    func testAGenerousBudgetKeepsEveryPassage() async throws {
        let passages = (1...8).map {
            RetrievedPassage(text: "passage \($0).", locator: "Ch. \($0)", score: 0.5)
        }
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex(passages: passages))
        let result = try await strategy.assembleContext(
            for: "What happens?", in: makeBook(tokenCount: 5_000_000), selection: nil,
            scope: .wholeBook, provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.citations.count, 8)
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
            scope: .wholeBook,
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
            scope: .wholeBook,
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
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false)
        )
        let snippet = try XCTUnwrap(result.citations.first?.quotedText)
        XCTAssertLessThanOrEqual(snippet.count, 161) // up to maxLength + ellipsis
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    /// The whole-book tier must carry the full text for EVERY remote provider —
    /// prompt caching is an optimization, not a precondition. A non-caching
    /// provider that received no book text would answer ungrounded (and
    /// hallucinate) while still reporting the whole-book tier.
    func testWholeBookTierCarriesFullTextWithoutPromptCaching() async throws {
        let book = makeBook(tokenCount: 1_000)
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: book,
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false, caching: false)
        )
        XCTAssertEqual(result.tier, .wholeBook)
        XCTAssertEqual(result.request.cacheableSystemPrefix, book.fullText)
    }

    func testWholeBookTierCarriesFullTextWithPromptCaching() async throws {
        let book = makeBook(tokenCount: 1_000)
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: book,
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false, caching: true)
        )
        XCTAssertEqual(result.tier, .wholeBook)
        XCTAssertEqual(result.request.cacheableSystemPrefix, book.fullText)
    }

    func testLocalProviderAlwaysUsesRetrieval() async throws {
        let strategy = AdaptiveContextStrategy(index: StubIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 10),
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 8_000, isLocal: true)
        )
        XCTAssertEqual(result.tier, .retrieval)
    }

    func testTokenEstimate() {
        XCTAssertEqual(estimateTokens(String(repeating: "a", count: 400)), 100)
    }

    // MARK: - Tier citation signal (A4)

    func testWholeBookTierDoesNotPromiseCitations() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 1_000),
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .wholeBook)
        XCTAssertFalse(result.providesCitations)
        XCTAssertFalse(result.tier.providesCitations)
    }

    func testRetrievalTierPromisesCitations() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false)
        )
        XCTAssertEqual(result.tier, .retrieval)
        XCTAssertTrue(result.providesCitations)
        XCTAssertTrue(result.tier.providesCitations)
    }

    func testProvidesCitationsIsPurelyTierDerived() {
        XCTAssertFalse(AssembledContext.Tier.wholeBook.providesCitations)
        XCTAssertTrue(AssembledContext.Tier.retrieval.providesCitations)
    }
}

/// Minimal in-memory index for routing tests.
private struct StubIndex: RAGIndex {
    func build(for book: Book, embeddings: EmbeddingProvider) async throws {}
    func retrieve(
        query: String, bookID: UUID, limit: Int, maxChapterIndex: Int?
    ) async throws -> [RetrievedPassage] {
        [RetrievedPassage(text: "stub passage", locator: "Ch.1", score: 1.0)]
    }
    func isBuilt(bookID: UUID) async -> Bool { true }
}
