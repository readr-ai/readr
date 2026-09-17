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
    /// question sends is derived from the chapter lengths, so the two can
    /// disagree — deliberately, in the cases that need a long chapter.
    private func makeChapteredBook(tokenCount: Int, chapterCharacters: Int = 4_000) -> Book {
        Book(
            metadata: BookMetadata(title: "Chaptered", authors: ["A. Author"]),
            chapters: [
                Chapter(title: "One", order: 0, text: String(repeating: "x", count: chapterCharacters)),
                Chapter(title: "Two", order: 1, text: String(repeating: "y", count: chapterCharacters)),
            ],
            estimatedTokenCount: tokenCount
        )
    }

    /// One routing case: everything the router reads.
    private struct RoutingCase {
        let name: String
        let book: Book
        let scope: ReadingScope
        let provider: ProviderInfo
    }

    /// Every routing case the router has. Both the predicate and
    /// `assembleContext` are asked each one, and they must answer the same —
    /// that is the whole point of factoring the rule out.
    ///
    /// The rule this set pins: the scope says how much text the reader asked
    /// for, and the router takes it at its word. `.window` sends extracts,
    /// never the book, except while the read-so-far is still small
    /// (`defaultSmallBookTokenCap` ≈ 6,000 tokens). `.upTo` and `.wholeBook`
    /// send the text up to what the model can hold. Every way in and every
    /// way out is covered below.
    private var routingCases: [RoutingCase] {
        let short = makeChapteredBook(tokenCount: 1_000)
        let long = makeChapteredBook(tokenCount: 5_000_000)
        // Long chapters, so a frontier can read past the small-read cap while
        // still sitting inside one chapter; and a whole book (100,000 tokens)
        // that fits a 200k budget — the case the old "60% of the budget" rule
        // sent whole on every question.
        let mid = makeChapteredBook(tokenCount: 100_000, chapterCharacters: 100_000)
        // Budget: 1_000 tokens × 0.6 = 600 tokens ≈ 2,400 characters read.
        let tight = provider(budget: 1_000, isLocal: false)
        let roomy = provider(budget: 200_000, isLocal: false)
        let local = provider(budget: 200_000, isLocal: true)
        let start = ReadingFrontier(chapterIndex: 0, characterOffset: 0)
        let underBudget = ReadingFrontier(chapterIndex: 0, characterOffset: 2_000)
        let overBudget = ReadingFrontier(chapterIndex: 0, characterOffset: 3_000)
        // 40,000 characters = 10,000 tokens: past the small-read cap, so this
        // is the rung where retrieval takes over in the nearby scope.
        let pastSmallCap = ReadingFrontier(chapterIndex: 0, characterOffset: 40_000)
        // 20,000 characters = 5,000 tokens: inside the small-read cap.
        let insideSmallCap = ReadingFrontier(chapterIndex: 0, characterOffset: 20_000)
        return [
            // The nearby scope: extracts, never the book.
            RoutingCase(name: "nearby, read past the small cap", book: mid, scope: .window(pastSmallCap), provider: roomy),
            RoutingCase(name: "nearby, a huge book barely started", book: long, scope: .window(insideSmallCap), provider: roomy),
            RoutingCase(name: "nearby, a small read rides along", book: mid, scope: .window(insideSmallCap), provider: roomy),
            RoutingCase(name: "nearby, nothing read", book: short, scope: .window(start), provider: roomy),
            RoutingCase(name: "nearby, a local model", book: short, scope: .window(pastSmallCap), provider: local),
            // No reading position at all — a native PDF page.
            RoutingCase(name: "nearby, no frontier, short document", book: short, scope: .window(nil), provider: roomy),
            RoutingCase(name: "nearby, no frontier, vast document", book: long, scope: .window(nil), provider: roomy),
            // The text scopes: what the reader asked for, up to what fits.
            RoutingCase(name: "a short book, whole", book: short, scope: .wholeBook, provider: roomy),
            RoutingCase(name: "a long book, whole and far too big", book: long, scope: .wholeBook, provider: roomy),
            RoutingCase(name: "a mid book, whole and it fits", book: mid, scope: .wholeBook, provider: roomy),
            RoutingCase(name: "a long book, read so far", book: long, scope: .upTo(insideSmallCap), provider: roomy),
            RoutingCase(
                name: "a mid book, read past the small cap",
                book: mid, scope: .upTo(pastSmallCap), provider: roomy
            ),
            RoutingCase(name: "scoped just inside the budget", book: short, scope: .upTo(underBudget), provider: tight),
            RoutingCase(name: "scoped just past the budget", book: short, scope: .upTo(overBudget), provider: tight),
            RoutingCase(name: "a local model, whole book", book: short, scope: .wholeBook, provider: local),
            RoutingCase(name: "a local model, scoped past the start", book: short, scope: .upTo(underBudget), provider: local),
            RoutingCase(name: "a local model, nothing read", book: short, scope: .upTo(start), provider: local),
            RoutingCase(name: "nothing read", book: short, scope: .upTo(start), provider: roomy),
            RoutingCase(name: "nothing read, long book", book: long, scope: .upTo(start), provider: roomy),
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

    /// The fraction governs the two text scopes: "Read so far" and "Whole
    /// book" are asked to hold what was asked for, up to this share of the
    /// budget. A strategy built with a different fraction routes by it, and so
    /// does the predicate that reads it — while the nearby scope is unaffected
    /// by it either way.
    func testThePredicateFollowsTheStrategysOwnBudgetFractionForTextScopes() async throws {
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
                "fraction \(fraction), read so far"
            )
            let assembled = try await strategy.assembleContext(
                for: "q", in: book, selection: nil, scope: scope, provider: info
            )
            XCTAssertEqual(assembled.tier == .wholeBook, expected, "fraction \(fraction)")
        }
    }

    /// The small-read cap is what the nearby scope consults, and it is the
    /// whole point of the change: read a little and the text rides along
    /// (cheaper and more accurate than retrieving from a text this size); read
    /// past it and the answer comes from the neighborhood plus retrieval,
    /// however big the budget is. The text scopes are not capped by it —
    /// asking for the text is asking for the text.
    func testNearbySendsTheTextOnlyWhileTheReadIsSmall() async throws {
        let book = makeChapteredBook(tokenCount: 100_000, chapterCharacters: 100_000)
        let roomy = provider(budget: 200_000, isLocal: false)
        // 20,000 characters = 5,000 tokens: inside the 6,000-token cap.
        let smallRead = ReadingFrontier(chapterIndex: 0, characterOffset: 20_000)
        // 40,000 characters = 10,000 tokens: past it. A 200k budget either way.
        let bigRead = ReadingFrontier(chapterIndex: 0, characterOffset: 40_000)

        XCTAssertEqual(
            try await AdaptiveContextStrategy(index: StubIndex()).assembleContext(
                for: "q", in: book, selection: nil, scope: .window(smallRead), provider: roomy
            ).tier,
            .wholeBook,
            "nearby, a small read still rides along whole"
        )
        XCTAssertEqual(
            try await AdaptiveContextStrategy(index: StubIndex()).assembleContext(
                for: "q", in: book, selection: nil, scope: .window(bigRead), provider: roomy
            ).tier,
            .retrieval,
            "nearby, a big budget does not buy a whole-book prompt"
        )
        XCTAssertEqual(
            try await AdaptiveContextStrategy(index: StubIndex()).assembleContext(
                for: "q", in: book, selection: nil, scope: .upTo(bigRead), provider: roomy
            ).tier,
            .wholeBook,
            "read so far: the same text, because that is what was asked for"
        )
        XCTAssertEqual(
            try await AdaptiveContextStrategy(index: StubIndex()).assembleContext(
                for: "q", in: book, selection: nil, scope: .window(nil), provider: roomy
            ).tier,
            .retrieval,
            "nearby with no reading position is still extracts, not the document"
        )
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
