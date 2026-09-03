import XCTest
@testable import ReadrKit

/// "Recap what I've read so far, no spoilers" is only honest if Ask cannot
/// see past the reader's position. The frontier is that boundary: everything
/// before it is fair game, everything after it does not exist to the model —
/// on the whole-book tier, on the retrieval tier, and in the prompt. The
/// scope that carries it is a named choice at every call site.
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

    // MARK: - The scope is a named choice

    func testScopeExposesItsFrontier() {
        let frontier = ReadingFrontier(chapterIndex: 2, characterOffset: 9)
        XCTAssertEqual(ReadingScope.upTo(frontier).frontier, frontier)
        XCTAssertTrue(ReadingScope.upTo(frontier).isScoped)
        XCTAssertNil(ReadingScope.wholeBook.frontier)
        XCTAssertFalse(ReadingScope.wholeBook.isScoped)
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

    /// A negative chapter index is "before the start": it clamps to the
    /// first chapter rather than trapping on a negative prefix.
    func testTextReadClampsANegativeChapterIndexToTheFirstChapter() {
        let book = makeBook()
        XCTAssertEqual(book.textRead(upTo: ReadingFrontier(chapterIndex: -3, characterOffset: 0)), "")
        XCTAssertEqual(book.textRead(upTo: ReadingFrontier(chapterIndex: -3, characterOffset: 5)), "Alpha")
        XCTAssertFalse(book.hasFinishedChapter(at: ReadingFrontier(chapterIndex: -1, characterOffset: 0)))
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

    // MARK: - The tail of what was read

    func testTailOfTextReadIsTheEndOfWhatWasRead() {
        let book = makeBook()
        let frontier = ReadingFrontier(chapterIndex: 1, characterOffset: 5)
        XCTAssertEqual(book.textRead(upTo: frontier, lastCharacters: 3), "avo")
        XCTAssertEqual(
            book.textRead(upTo: frontier, lastCharacters: 12),
            " alpha.\n\nBravo",
            "the tail crosses back into the previous chapter with the same join"
        )
        XCTAssertEqual(
            book.textRead(upTo: frontier, lastCharacters: 10_000),
            book.textRead(upTo: frontier),
            "a tail longer than the text read is all of it"
        )
        XCTAssertEqual(book.textRead(upTo: frontier, lastCharacters: 0), "")
    }

    // MARK: - A selection is in front of the reader

    func testExtendingTheFrontierToASelectionNeverMovesItBackwards() {
        let frontier = ReadingFrontier(chapterIndex: 3, characterOffset: 100)
        let ahead = frontier.extended(toInclude: 150..<180)
        XCTAssertEqual(ahead, ReadingFrontier(chapterIndex: 3, characterOffset: 180),
                       "a selection below the page top pulls the frontier to its end")
        let behind = frontier.extended(toInclude: 20..<60)
        XCTAssertEqual(behind, frontier, "a selection above the page top leaves the frontier alone")
        let straddling = frontier.extended(toInclude: 90..<110)
        XCTAssertEqual(straddling.characterOffset, 110)
    }

    // MARK: - Whole-book tier

    func testWholeBookTierSendsOnlyTheTextReadSoFar() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 1, characterOffset: 0)),
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
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 5)),
            provider: provider()
        )
        XCTAssertEqual(ctx.tier, .wholeBook)
    }

    /// The estimate comes from the chapter lengths, not from building the
    /// text: a book read up to the budget's edge routes the same way whether
    /// it is measured or assembled.
    func testFrontierBudgetIsDecidedFromChapterLengths() async throws {
        let long = String(repeating: "x", count: 4_000)
        let book = Book(
            metadata: BookMetadata(title: "Long"),
            chapters: [Chapter(title: "One", order: 0, text: long), Chapter(title: "Two", order: 1, text: long)],
            estimatedTokenCount: 2_000
        )
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        // Budget: 1_000 tokens × 0.6 = 600 tokens ≈ 2_400 characters.
        let fits = try await strategy.assembleContext(
            for: "q", in: book, selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 2_000)),
            provider: provider(budget: 1_000)
        )
        XCTAssertEqual(fits.tier, .wholeBook)
        let spills = try await strategy.assembleContext(
            for: "q", in: book, selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 3_000)),
            provider: provider(budget: 1_000)
        )
        XCTAssertEqual(spills.tier, .retrieval)
    }

    // MARK: - Nothing read yet

    /// A frontier at the very start must not send an empty book: no cacheable
    /// prefix at all, and a system line saying the reader hasn't started.
    func testFrontierAtTheStartSendsNoBookTextAndSaysSo() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        for isLocal in [false, true] {
            let ctx = try await strategy.assembleContext(
                for: "Recap so far", in: makeBook(), selection: nil, history: [],
                scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 0)),
                provider: provider(isLocal: isLocal)
            )
            XCTAssertNil(ctx.request.cacheableSystemPrefix, "no empty prefix (local: \(isLocal))")
            XCTAssertTrue(ctx.citations.isEmpty)
            XCTAssertTrue(systemText(ctx).contains("has not started the book yet"))
            XCTAssertTrue(systemText(ctx).lowercased().contains("nothing to recap"))
            XCTAssertFalse(userText(ctx).contains("Alpha"), "no book text may ride along")
            XCTAssertFalse(userText(ctx).contains("Relevant passages"), "no empty passage block either")
        }
    }

    // MARK: - Retrieval tier

    func testRetrievalTierDropsPassagesPastTheFrontier() async throws {
        let index = LeakyIndex(passages: [
            RetrievedPassage(text: "early", locator: "Ch. 1", score: 0.9, chapterIndex: 0),
            RetrievedPassage(text: "current chapter", locator: "Ch. 2", score: 0.8, chapterIndex: 1),
            RetrievedPassage(text: "later", locator: "Ch. 3", score: 0.7, chapterIndex: 2),
            RetrievedPassage(text: "unknown", locator: "?", score: 0.6, chapterIndex: nil),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 1, characterOffset: 3)),
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
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: "current chapter", locator: "Ch. 2", score: 0.8, chapterIndex: 1),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "Recap so far", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 1, characterOffset: "Bravo bravo bravo.".count)),
            provider: provider(isLocal: true)
        )
        XCTAssertEqual(ctx.citations.map(\.locator), ["Ch. 2"])
        XCTAssertEqual(index.lastMaxChapterIndex, .some(1), "a finished chapter is inside the ceiling")
    }

    /// The scope reaches the index, and reaches it before the limit: with
    /// eight later passages outranking the earlier ones, a strategy that
    /// filtered after `prefix(8)` would come back with nothing.
    func testScopeIsPushedIntoTheIndexBeforeTheLimit() async throws {
        var passages = (0..<8).map {
            RetrievedPassage(text: "later \($0)", locator: "Ch. 3 ¶\($0)", score: 0.9, chapterIndex: 2)
        }
        passages += (0..<8).map {
            RetrievedPassage(text: "early \($0)", locator: "Ch. 1 ¶\($0)", score: 0.5, chapterIndex: 0)
        }
        let index = StubRAGIndex(passages: passages)
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "q", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 1, characterOffset: 3)),
            provider: provider(isLocal: true)
        )
        XCTAssertEqual(index.lastMaxChapterIndex, .some(0), "an unfinished chapter 2 caps the index at chapter 1")
        XCTAssertEqual(ctx.citations.count, 8, "all eight usable passages come back")
        XCTAssertTrue(ctx.citations.allSatisfy { $0.locator.hasPrefix("Ch. 1") })

        let whole = try await strategy.assembleContext(
            for: "q", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .wholeBook, provider: provider(isLocal: true)
        )
        XCTAssertEqual(index.lastMaxChapterIndex, .some(nil), "the whole book asks for no ceiling")
        XCTAssertEqual(whole.citations.count, 8)
    }

    /// Partway through the first chapter, no whole chapter is finished and no
    /// indexed passage survives — but the reader HAS read something, and the
    /// passage block must carry it rather than go out empty.
    func testRetrievalFallsBackToTheTailOfWhatWasReadWhenNoPassageSurvives() async throws {
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: "current chapter", locator: "Ch. 1", score: 0.8, chapterIndex: 0),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let ctx = try await strategy.assembleContext(
            for: "q", in: makeBook(tokenCount: 5_000_000), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 11)),
            provider: provider(isLocal: true)
        )
        XCTAssertEqual(ctx.tier, .retrieval)
        XCTAssertEqual(ctx.citations.map(\.locator), [AdaptiveContextStrategy.readSoFarLocator])
        let user = userText(ctx)
        XCTAssertTrue(user.contains("[Read so far] Alpha alpha"), "the tail of the text read is the passage")
        XCTAssertFalse(user.contains("alpha."), "and it stops at the frontier")
    }

    // MARK: - The prompt

    func testPromptCarriesTheNoSpoilerRuleOnlyWhenScoped() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let with = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [],
            scope: .upTo(ReadingFrontier(chapterIndex: 1, characterOffset: 0)), provider: provider()
        )
        let without = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [], scope: .wholeBook, provider: provider()
        )
        XCTAssertTrue(systemText(with).lowercased().contains("spoil"))
        XCTAssertFalse(systemText(without).lowercased().contains("spoil"))
        XCTAssertEqual(systemText(without), AdaptiveContextStrategy.systemPrompt)
    }

    /// The anchor's "read so far" line is the panel's own summary — the same
    /// title, the same "Chapter N of M" — so the model and the reader are
    /// told the same place.
    func testAnchorTellsTheModelWhereTheReaderStoppedInThePanelsWords() async throws {
        let book = makeBook()
        let frontier = ReadingFrontier(chapterIndex: 1, characterOffset: 0)
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let ctx = try await strategy.assembleContext(
            for: "q", in: book, selection: nil, history: [],
            scope: .upTo(frontier), provider: provider()
        )
        let user = userText(ctx)
        let summary = try XCTUnwrap(ReadingPositionSummary(book: book, frontier: frontier))
        XCTAssertTrue(user.contains("through \"\(summary.chapterTitle)\""), "the anchor names the chapter the reader is in")
        XCTAssertTrue(user.contains("(\(summary.chapterLine), \(summary.percent)%)"), "with the panel's own count")
        XCTAssertTrue(user.lowercased().contains("not read past"), "the anchor states the boundary")
    }

    func testWholeBookAnchorHasNoReadSoFarLine() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let ctx = try await strategy.assembleContext(
            for: "q", in: makeBook(), selection: nil, history: [], scope: .wholeBook, provider: provider()
        )
        XCTAssertFalse(userText(ctx).contains("Read so far"))
    }

    /// The rule must cover what the model knows about the book, not just the
    /// text it was given — a famous ending is a spoiler from either source.
    func testNoSpoilerRuleCoversWorldKnowledgeToo() {
        let rule = AdaptiveContextStrategy.spoilerGuard.lowercased()
        XCTAssertTrue(rule.contains("what you know"))
        XCTAssertTrue(rule.contains("recap") || rule.contains("summar"))
    }

    // MARK: - The service names its scope too

    func testAskServicePassesTheScopeThrough() async throws {
        let strategy = RecordingStrategy()
        let provider = MockLLMProvider(
            info: .fixture(kind: .anthropic, contextBudget: 200_000, supportsPromptCaching: true),
            scriptedChunks: ["ok"]
        )
        let service = AskService(strategy: strategy, provider: provider)
        let frontier = ReadingFrontier(chapterIndex: 1, characterOffset: 4)
        for try await _ in service.ask("q", about: makeBook(), selection: nil, scope: .upTo(frontier)) {}
        XCTAssertEqual(strategy.scopes, [.upTo(frontier)])
        for try await _ in service.ask("q", about: makeBook(), selection: nil, scope: .wholeBook) {}
        XCTAssertEqual(strategy.scopes, [.upTo(frontier), .wholeBook])
    }
}

/// An index that ignores the chapter ceiling and hands back everything —
/// so the strategy's own guard is the only thing standing between a later
/// passage and the prompt.
private struct LeakyIndex: RAGIndex {
    var passages: [RetrievedPassage]
    func build(for book: Book, embeddings: EmbeddingProvider) async throws {}
    func retrieve(
        query: String, bookID: UUID, limit: Int, maxChapterIndex: Int?
    ) async throws -> [RetrievedPassage] { passages }
    func isBuilt(bookID: UUID) async -> Bool { true }
}

/// Records the scope of every assembly and returns an empty request.
private final class RecordingStrategy: ContextStrategy, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scopes: [ReadingScope] = []

    func assembleContext(
        for question: String, in book: Book, selection: Selection?,
        history: [ConversationTurn], scope: ReadingScope, provider: ProviderInfo
    ) async throws -> AssembledContext {
        lock.lock(); scopes.append(scope); lock.unlock()
        return AssembledContext(
            tier: .wholeBook,
            request: ChatRequest(messages: [ChatMessage(role: .user, content: question)], maxOutputTokens: 8)
        )
    }
}
