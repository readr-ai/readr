import XCTest
@testable import ReadrKit

/// "Recap what I've read so far, no spoilers" is only honest if Ask cannot
/// see past the reader's position. The frontier is that boundary: everything
/// before it is fair game, everything after it does not exist to the model —
/// on the whole-book tier, on the retrieval tier, and in the prompt.
final class ReadingFrontierTests: XCTestCase {

    private func makeBook(tokenCount: Int = 1_000) -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book", authors: ["A. Author"]),
            chapters: [
                Chapter(title: "One", order: 0, text: "Alpha alpha alpha."),
                Chapter(title: "Two", order: 1, text: "Bravo bravo bravo."),
                Chapter(title: "Three", order: 2, text: "Charlie charlie charlie."),
            ],
            estimatedTokenCount: tokenCount
        )
    }

    private func provider(budget: Int = 200_000, isLocal: Bool = false) -> ProviderInfo {
        ProviderInfo(
            kind: isLocal ? .local : .anthropic, modelID: "test",
            contextBudget: budget, supportsPromptCaching: !isLocal, isLocal: isLocal
        )
    }

    private func systemText(_ ctx: AssembledContext) -> String {
        ctx.request.messages.first(where: { $0.role == .system })?.content ?? ""
    }

    private func userText(_ ctx: AssembledContext) -> String {
        ctx.request.messages.last?.content ?? ""
    }

    // MARK: - What "read so far" means

    func testTextReadIncludesEarlierChaptersInFullAndTheCurrentOneUpToTheOffset() {
        let book = makeBook()
        let read = book.textRead(upTo: ReadingFrontier(chapterIndex: 1, characterOffset: 5))
        XCTAssertTrue(read.contains("Alpha alpha alpha."))
        XCTAssertTrue(read.hasSuffix("Bravo"))
        XCTAssertFalse(read.contains("bravo bravo."))
        XCTAssertFalse(read.contains("Charlie"))
    }

    func testTextReadAtTheVeryStartIsEmpty() {
        XCTAssertEqual(makeBook().textRead(upTo: ReadingFrontier(chapterIndex: 0, characterOffset: 0)), "")
    }

    func testTextReadClampsAnOffsetPastTheChapterEnd() {
        let read = makeBook().textRead(upTo: ReadingFrontier(chapterIndex: 0, characterOffset: 10_000))
        XCTAssertEqual(read, "Alpha alpha alpha.")
    }

    func testTextReadPastTheLastChapterIsTheWholeBook() {
        let book = makeBook()
        let read = book.textRead(upTo: ReadingFrontier(chapterIndex: 99, characterOffset: 0))
        XCTAssertEqual(read, book.fullText)
    }

    /// Chapters are ordered by `order`, not by array position — the frontier
    /// index is a reading-order index, same as everywhere else in the app.
    func testTextReadFollowsReadingOrderNotArrayOrder() {
        let book = Book(
            metadata: BookMetadata(title: "Shuffled"),
            chapters: [
                Chapter(title: "Second", order: 1, text: "SECOND"),
                Chapter(title: "First", order: 0, text: "FIRST"),
            ],
            estimatedTokenCount: 10
        )
        XCTAssertEqual(book.textRead(upTo: ReadingFrontier(chapterIndex: 0, characterOffset: 99)), "FIRST")
    }

    // MARK: - Whole-book tier

    func testWholeBookTierSendsOnlyTheTextReadSoFar() async throws {
        let strategy = AdaptiveContextStrategy(index: StubFrontierIndex())
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0),
            provider: provider()
        )
        XCTAssertEqual(ctx.tier, .wholeBook)
        let prefix = try XCTUnwrap(ctx.request.cacheableSystemPrefix)
        XCTAssertTrue(prefix.contains("Alpha"))
        XCTAssertFalse(prefix.contains("Bravo"), "text after the frontier must not be sent")
        XCTAssertFalse(prefix.contains("Charlie"))
    }

    /// The budget decision looks at what will actually be sent. A long book
    /// the reader has only started can ride whole on the first tier.
    func testFrontierBudgetsTheTextReadNotTheWholeBook() async throws {
        let strategy = AdaptiveContextStrategy(index: StubFrontierIndex())
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 5),
            provider: provider()
        )
        XCTAssertEqual(ctx.tier, .wholeBook)
    }

    // MARK: - Retrieval tier

    func testRetrievalTierDropsPassagesPastTheFrontier() async throws {
        let index = StubFrontierIndex(passages: [
            RetrievedPassage(text: "early", locator: "Ch. 1", score: 0.9, chapterIndex: 0),
            RetrievedPassage(text: "current chapter", locator: "Ch. 2", score: 0.8, chapterIndex: 1),
            RetrievedPassage(text: "later", locator: "Ch. 3", score: 0.7, chapterIndex: 2),
            RetrievedPassage(text: "unknown", locator: "?", score: 0.6, chapterIndex: nil),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 3),
            provider: provider(isLocal: true)
        )
        XCTAssertEqual(ctx.tier, .retrieval)
        XCTAssertEqual(ctx.citations.map(\.locator), ["Ch. 1"])
        let user = userText(ctx)
        XCTAssertTrue(user.contains("early"))
        XCTAssertFalse(user.contains("later"), "a passage after the frontier leaked into the prompt")
        XCTAssertFalse(user.contains("current chapter"), "the unfinished chapter is only partly read; its passages are withheld")
        XCTAssertFalse(user.contains("unknown"), "a passage of unknown position is withheld, not assumed safe")
    }

    func testRetrievalTierKeepsTheCurrentChapterOnceItIsFinished() async throws {
        let index = StubFrontierIndex(passages: [
            RetrievedPassage(text: "current chapter", locator: "Ch. 2", score: 0.8, chapterIndex: 1),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 1, characterOffset: "Bravo bravo bravo.".count),
            provider: provider(isLocal: true)
        )
        XCTAssertEqual(ctx.citations.map(\.locator), ["Ch. 2"])
    }

    // MARK: - The prompt

    func testPromptCarriesTheNoSpoilerRuleOnlyWhenAFrontierIsSet() async throws {
        let strategy = AdaptiveContextStrategy(index: StubFrontierIndex())
        let with = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0), provider: provider()
        )
        let without = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [], frontier: nil, provider: provider()
        )
        XCTAssertTrue(systemText(with).lowercased().contains("spoil"))
        XCTAssertFalse(systemText(without).lowercased().contains("spoil"))
        XCTAssertEqual(systemText(without), AdaptiveContextStrategy.systemPrompt)
    }

    func testAnchorTellsTheModelWhereTheReaderStopped() async throws {
        let strategy = AdaptiveContextStrategy(index: StubFrontierIndex())
        let ctx = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [],
            frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0), provider: provider()
        )
        let user = userText(ctx)
        XCTAssertTrue(user.contains("Two"), "the anchor names the chapter the reader is in")
        XCTAssertTrue(user.lowercased().contains("not read past"), "the anchor states the boundary")
    }

    /// The rule must cover what the model knows about the book, not just the
    /// text it was given — a famous ending is a spoiler from either source.
    func testNoSpoilerRuleCoversWorldKnowledgeToo() {
        let rule = AdaptiveContextStrategy.spoilerGuard.lowercased()
        XCTAssertTrue(rule.contains("what you know"))
        XCTAssertTrue(rule.contains("recap") || rule.contains("summar"))
    }
}

private struct StubFrontierIndex: RAGIndex {
    var passages: [RetrievedPassage] = [
        RetrievedPassage(text: "stub passage", locator: "Ch.1", score: 1.0, chapterIndex: 0)
    ]
    func build(for book: Book, embeddings: EmbeddingProvider) async throws {}
    func retrieve(query: String, bookID: UUID, limit: Int) async throws -> [RetrievedPassage] { passages }
    func isBuilt(bookID: UUID) async -> Bool { true }
}
