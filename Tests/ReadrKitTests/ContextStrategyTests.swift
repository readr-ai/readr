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

    // MARK: - Where a citation points

    /// "Ch. 2 ¶3" is for the reader to read, not for the app to act on. The
    /// chapter and offset the index knew about ride along, so a source can be
    /// opened at the passage rather than at the top of a chapter.
    func testRetrievalCitationsCarryTheirPositionInTheBook() async throws {
        let index = StubRAGIndex(passages: [
            RetrievedPassage(
                text: "First relevant passage.", locator: "Ch. 2 ¶3", score: 0.9,
                chapterIndex: 1, characterOffset: 480
            ),
            RetrievedPassage(
                text: "Second relevant passage.", locator: "Ch. 5 ¶1", score: 0.8,
                chapterIndex: 4, characterOffset: 12
            ),
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
        XCTAssertEqual(result.citations.map(\.chapterIndex), [1, 4])
        XCTAssertEqual(result.citations.map(\.characterOffset), [480, 12])
    }

    /// An index that knows no position says so, rather than the strategy
    /// inventing one.
    func testACitationFromAPositionlessPassageStaysPositionless() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex(passages: [
            RetrievedPassage(text: "somewhere", locator: "Ch. 1", score: 1),
        ]))

        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            scope: .wholeBook,
            provider: provider(budget: 200_000, isLocal: false)
        )

        XCTAssertNil(result.citations.first?.chapterIndex)
        XCTAssertNil(result.citations.first?.characterOffset)
    }

    /// The fallback passage — the end of what has been read, when nothing
    /// indexed sits before the frontier — points at itself too: it is the
    /// tail of the frontier chapter, so its offset is where that tail starts.
    func testTheReadSoFarPassagePointsAtWhereItStarts() async throws {
        let chapter = Chapter(
            title: "One", order: 0, text: String(repeating: "read text. ", count: 400)
        )
        let book = Book(
            metadata: BookMetadata(title: "Test Book", authors: ["A. Author"]),
            chapters: [chapter],
            estimatedTokenCount: 5_000_000
        )
        // Nothing indexed before the frontier, so the tail is all there is.
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex(passages: []))

        let result = try await strategy.assembleContext(
            for: "Recap what I've read.",
            in: book,
            selection: nil,
            scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: chapter.text.count)),
            provider: provider(budget: 200, isLocal: true)
        )

        let citation = try XCTUnwrap(result.citations.first)
        XCTAssertEqual(citation.locator, "Read so far")
        XCTAssertEqual(citation.chapterIndex, 0)
        // The tail is the last four characters per token of the whole-book
        // budget — 60% of the provider's, as the strategy computes it.
        XCTAssertEqual(citation.characterOffset, chapter.text.count - Int(200 * 0.6) * 4)
    }

    /// The same passage on a real book: a reader fifty characters into the
    /// third chapter, with a tail long enough to reach back into the second,
    /// is cited in the SECOND — at an offset the second chapter's own text
    /// answers to. The frontier's chapter with the frontier's arithmetic gave
    /// a negative offset in a chapter the passage does not start in.
    func testTheReadSoFarPassageCitesTheChapterTheTailBeginsIn() async throws {
        let chapters = (0..<3).map { index in
            Chapter(
                title: "Chapter \(index + 1)", order: index,
                text: String(repeating: "Chapter \(index + 1) sentence. ", count: 200)
            )
        }
        let book = Book(
            metadata: BookMetadata(title: "Test Book", authors: ["A. Author"]),
            chapters: chapters,
            estimatedTokenCount: 5_000_000
        )
        // 834 * 0.6 = 500 tokens of whole-book budget, and the tail is four
        // characters a token: 2,000 characters, against 50 read in chapter 3.
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex(passages: []))

        let result = try await strategy.assembleContext(
            for: "Recap what I've read.",
            in: book,
            selection: nil,
            scope: .upTo(ReadingFrontier(chapterIndex: 2, characterOffset: 50)),
            provider: provider(budget: 834, isLocal: true)
        )

        let citation = try XCTUnwrap(result.citations.first)
        XCTAssertEqual(citation.locator, "Read so far")
        XCTAssertEqual(citation.chapterIndex, 1, "the tail opens in the second chapter")
        let second = chapters[1].text
        XCTAssertEqual(citation.characterOffset, second.count - (2_000 - 50))
        let quoted = try XCTUnwrap(citation.quotedText)
        let offset = try XCTUnwrap(citation.characterOffset)
        XCTAssertTrue(
            second.dropFirst(offset).hasPrefix(quoted.dropLast()),
            "the quoted text is found at the offset the citation gives"
        )
    }

    // MARK: - The routing predicate

    /// A book with real chapter text, so a scoped question has something to
    /// measure. `estimatedTokenCount` is the whole book's; what a scoped
    /// question sends is derived from the chapter lengths.
    private func makeChapteredBook(tokenCount: Int) -> Book {
        Book(
            metadata: BookMetadata(title: "Chaptered", authors: ["A. Author"]),
            chapters: [
                Chapter(title: "One", order: 0, text: String(repeating: "x", count: 4_000)),
                Chapter(title: "Two", order: 1, text: String(repeating: "y", count: 4_000)),
            ],
            estimatedTokenCount: tokenCount
        )
    }

    /// Every routing case the router has, as (book, scope, provider). Both
    /// the predicate and `assembleContext` are asked each one, and they must
    /// answer the same — that is the whole point of factoring the rule out.
    private var routingCases: [(name: String, book: Book, scope: ReadingScope, provider: ProviderInfo)] {
        let short = makeChapteredBook(tokenCount: 1_000)
        let long = makeChapteredBook(tokenCount: 5_000_000)
        // Budget: 1_000 tokens × 0.6 = 600 tokens ≈ 2_400 characters read.
        let tight = provider(budget: 1_000, isLocal: false)
        let roomy = provider(budget: 200_000, isLocal: false)
        let local = provider(budget: 200_000, isLocal: true)
        let start = ReadingScope.upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 0))
        let underBudget = ReadingScope.upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 2_000))
        let overBudget = ReadingScope.upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 3_000))
        return [
            ("a short book, whole", short, .wholeBook, roomy),
            ("a long book, whole", long, .wholeBook, roomy),
            ("a long book, barely started", long, underBudget, roomy),
            ("scoped just inside the budget", short, underBudget, tight),
            ("scoped just past the budget", short, overBudget, tight),
            ("a local model, whole book", short, .wholeBook, local),
            ("a local model, scoped past the start", short, underBudget, local),
            ("a local model, nothing read", short, start, local),
            ("nothing read", short, start, roomy),
            ("nothing read, long book", long, start, roomy),
        ]
    }

    /// The predicate and the tier `assembleContext` actually picks must agree
    /// on every case — a caller that plans work on the predicate (skipping an
    /// index build for a question that will never retrieve) is wrong the
    /// moment they diverge.
    func testTheRoutingPredicateAgreesWithTheTierAssembleContextPicks() async throws {
        for testCase in routingCases {
            let lengths = ReadingLengthCache()
            let strategy = AdaptiveContextStrategy(index: StubIndex(), lengths: lengths)
            let assembled = try await strategy.assembleContext(
                for: "What happens?", in: testCase.book, selection: nil,
                scope: testCase.scope, provider: testCase.provider
            )
            let predicted = strategy.routesWholeBook(
                book: testCase.book, scope: testCase.scope, provider: testCase.provider
            )
            XCTAssertEqual(
                predicted, assembled.tier == .wholeBook,
                "\(testCase.name): the predicate and the router disagree"
            )
            XCTAssertEqual(
                AdaptiveContextStrategy.routesWholeBook(
                    book: testCase.book, scope: testCase.scope,
                    provider: testCase.provider, lengths: lengths
                ),
                predicted,
                "\(testCase.name): the static and the instance must answer alike"
            )
        }
    }

    /// The cases above are only worth running if they cover both answers.
    func testTheRoutingCasesCoverBothTiers() async throws {
        var tiers: Set<AssembledContext.Tier> = []
        for testCase in routingCases {
            let strategy = AdaptiveContextStrategy(index: StubIndex())
            tiers.insert(
                try await strategy.assembleContext(
                    for: "What happens?", in: testCase.book, selection: nil,
                    scope: testCase.scope, provider: testCase.provider
                ).tier
            )
        }
        XCTAssertEqual(tiers, [.wholeBook, .retrieval])
    }

    /// A local model never rides the whole-book tier — except when the reader
    /// has read nothing, where there is no book text to send and every
    /// provider takes the same empty first tier.
    func testALocalModelRoutesWholeBookOnlyWhenNothingHasBeenRead() {
        let book = makeChapteredBook(tokenCount: 1_000)
        let local = provider(budget: 200_000, isLocal: true)
        let lengths = ReadingLengthCache()
        XCTAssertFalse(
            AdaptiveContextStrategy.routesWholeBook(
                book: book, scope: .wholeBook, provider: local, lengths: lengths
            )
        )
        XCTAssertFalse(
            AdaptiveContextStrategy.routesWholeBook(
                book: book,
                scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 2_000)),
                provider: local, lengths: lengths
            )
        )
        XCTAssertTrue(
            AdaptiveContextStrategy.routesWholeBook(
                book: book,
                scope: .upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 0)),
                provider: local, lengths: lengths
            ),
            "nothing read is the empty whole-book tier, whatever the provider"
        )
    }

    /// The budget fraction lives in one place: a strategy built with a
    /// different one routes by it, and so does the predicate that reads it.
    func testThePredicateFollowsTheStrategysOwnBudgetFraction() async throws {
        let book = makeChapteredBook(tokenCount: 1_000)
        // 2_000 characters read ≈ 500 tokens. At 0.6 of a 1_000-token budget
        // (600) that fits; at 0.4 (400) it does not.
        let scope = ReadingScope.upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 2_000))
        let info = provider(budget: 1_000, isLocal: false)
        for (fraction, expected) in [(0.6, true), (0.4, false)] {
            let strategy = AdaptiveContextStrategy(
                index: StubIndex(), wholeBookBudgetFraction: fraction
            )
            XCTAssertEqual(
                strategy.routesWholeBook(book: book, scope: scope, provider: info), expected,
                "fraction \(fraction)"
            )
            let assembled = try await strategy.assembleContext(
                for: "q", in: book, selection: nil, scope: scope, provider: info
            )
            XCTAssertEqual(assembled.tier == .wholeBook, expected, "fraction \(fraction)")
        }
    }

    /// The default the strategy uses is the one it publishes, so a caller
    /// that must predict the tier without a strategy in hand (deciding
    /// whether to build a retrieval index at all) names the same number
    /// rather than keeping a copy of it.
    func testTheStaticPredicateDefaultsToTheStrategysBudgetFraction() {
        XCTAssertEqual(AdaptiveContextStrategy.defaultWholeBookBudgetFraction, 0.6)
        let book = makeChapteredBook(tokenCount: 1_000)
        let scope = ReadingScope.upTo(ReadingFrontier(chapterIndex: 0, characterOffset: 2_000))
        let info = provider(budget: 1_000, isLocal: false)
        XCTAssertEqual(
            AdaptiveContextStrategy.routesWholeBook(
                book: book, scope: scope, provider: info, lengths: ReadingLengthCache()
            ),
            AdaptiveContextStrategy(index: StubIndex())
                .routesWholeBook(book: book, scope: scope, provider: info)
        )
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
