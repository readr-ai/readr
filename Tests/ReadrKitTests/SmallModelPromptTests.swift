import XCTest
@testable import ReadrKit

/// The rules for asking a ~3B on-device model about a book.
///
/// Every string here exists because a small model did something a reader
/// complained about, so they are pinned verbatim: changing one is a decision,
/// not a refactor. The parsers are checked against prompts
/// `AdaptiveContextStrategy` actually builds, not hand-written ones — that
/// coupling is the thing most likely to break silently.
final class SmallModelPromptTests: XCTestCase {

    // MARK: - The strings

    func testTheQuestionStyleTellsASmallModelTheThreeThingsItGetsWrong() {
        XCTAssertEqual(
            SmallModelPrompt.questionStyle,
            """
            Answer style: reply in your own words in two to five sentences. Do not \
            copy the passages out — refer to what happens in them, and quote at \
            most a short phrase. Only state things the passages support; if they \
            don't answer the question, say the book doesn't say, then mention what \
            in the passages comes closest. Never repeat a sentence you have already \
            written.
            """
        )
    }

    func testTheAnswerCueIsRestatedAfterTheQuestion() {
        XCTAssertEqual(
            SmallModelPrompt.answerCue,
            "\nAnswer, in your own words, using only the passages (say if they don't tell):"
        )
    }

    func testTheGeneralInstructionsAnswerPlainlyAndTieBackToTheBook() {
        XCTAssertEqual(
            SmallModelPrompt.generalInstructions,
            """
            You are a reading companion inside an ebook app. The reader asked \
            something that is not about the book. Answer it plainly and kindly in \
            your own words in one to three sentences — if it is impossible or \
            whimsical, say so with a light touch — then add one sentence about \
            what in the book they are reading comes closest to it. Never copy text \
            from the book. Never repeat a sentence.
            """
        )
    }

    /// The examples are the whole point of the classifier: a 3B model sorts by
    /// keyword, and "can I be a rabbit?" went BOOK on the strength of "rabbit"
    /// in Alice until they were added.
    func testTheClassifierInstructionsKeepTheirExamples() {
        XCTAssertEqual(
            SmallModelPrompt.classifierInstructions,
            """
            You sort a reader's questions. Reply with exactly one word.
            BOOK: the question asks what the book says — its story, characters, events, places, themes, or wording.
            GENERAL: the question is about the reader themself (I, me, my, can I, should I), the real world, advice, or anything the book would not answer — even if it mentions something from the book.
            Examples:
            "Why does Alice follow the White Rabbit?" → BOOK
            "Who shouts off with their heads?" → BOOK
            "Can I be a rabbit?" → GENERAL
            "Can I shrink if I drink from a bottle?" → GENERAL
            "What should I read next?" → GENERAL
            "Is the Cheshire Cat real?" → GENERAL
            "What does the Cheshire Cat say about which way to go?" → BOOK
            """
        )
    }

    func testTheClassifierPromptAsksForOneWord() {
        XCTAssertEqual(
            SmallModelPrompt.classifierPrompt(question: "Can I be a rabbit?"),
            "The reader's question: \"Can I be a rabbit?\"\nOne word, BOOK or GENERAL:"
        )
    }

    /// The model is asked for one word and answers with a sentence often
    /// enough; unsure means "about the book", the path with citations.
    func testTheClassifierReplyIsReadCaseInsensitivelyAndUnsureIsNil() {
        XCTAssertEqual(SmallModelPrompt.classification(from: "BOOK"), true)
        XCTAssertEqual(SmallModelPrompt.classification(from: "book\n"), true)
        XCTAssertEqual(SmallModelPrompt.classification(from: "GENERAL"), false)
        XCTAssertEqual(SmallModelPrompt.classification(from: "General."), false)
        XCTAssertNil(SmallModelPrompt.classification(from: "I'm not sure."))
        XCTAssertNil(SmallModelPrompt.classification(from: ""))
    }

    func testTheGeneralPromptLeadsWithTheBookLineWhenThereIsOne() {
        XCTAssertEqual(
            SmallModelPrompt.generalPrompt(
                question: "Can I be a rabbit?", bookAnchor: "Book: \"Alice\" by Lewis Carroll"
            ),
            "Book: \"Alice\" by Lewis Carroll\n\nThe reader asks: Can I be a rabbit?\nAnswer:"
        )
        XCTAssertEqual(
            SmallModelPrompt.generalPrompt(question: "Can I be a rabbit?", bookAnchor: ""),
            "The reader asks: Can I be a rabbit?\nAnswer:"
        )
    }

    // MARK: - split

    func testSplitSendsSystemContentToInstructionsAndTheQuestionToThePrompt() {
        let request = ChatRequest(messages: [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "What happens in chapter two?"),
        ])

        let (instructions, prompt) = SmallModelPrompt.split(request)

        XCTAssertEqual(instructions, "Be brief.")
        XCTAssertEqual(prompt, "What happens in chapter two?")
    }

    /// The whole-book tier hands the book down as a cacheable prefix. There is
    /// no cache on a small model, so it becomes the leading instruction —
    /// ahead of the system prompt, the way the strategy ordered them.
    func testSplitOnAWholeBookRequestPutsTheBookFirstInTheInstructions() async throws {
        let book = Book(
            metadata: BookMetadata(title: "Alice", authors: ["Lewis Carroll"]),
            chapters: [Chapter(title: "Down the Rabbit-Hole", order: 0, text: "Alice was beginning.")],
            estimatedTokenCount: 100
        )
        let assembled = try await AdaptiveContextStrategy(index: EmptyIndex()).assembleContext(
            for: "Who is Alice?", in: book, selection: nil, scope: .wholeBook,
            provider: ProviderInfo(
                kind: .anthropic, modelID: "test", contextBudget: 200_000,
                supportsPromptCaching: true, isLocal: false
            )
        )
        XCTAssertEqual(assembled.tier, .wholeBook)

        let (instructions, prompt) = SmallModelPrompt.split(assembled.request)

        XCTAssertTrue(instructions.hasPrefix("Alice was beginning."))
        XCTAssertTrue(instructions.contains("You are a reading companion"))
        XCTAssertTrue(prompt.contains("Question: Who is Alice?"))
        XCTAssertFalse(
            SmallModelPrompt.isRetrievalTier(prompt),
            "no passage block, so no question-style rules and no answer cue"
        )
    }

    func testSplitOnARetrievalRequestKeepsThePassageBlockInThePrompt() async throws {
        let assembled = try await retrievalContext(question: "Why does she follow him?")

        let (instructions, prompt) = SmallModelPrompt.split(assembled.request)

        XCTAssertFalse(instructions.isEmpty)
        XCTAssertTrue(SmallModelPrompt.isRetrievalTier(prompt))
        XCTAssertTrue(prompt.contains("[Ch. 1] The rabbit ran past her."))
        XCTAssertEqual(SmallModelPrompt.question(in: prompt), "Why does she follow him?")
    }

    /// Earlier turns are labelled so the model can tell them from the question
    /// it has to answer now.
    func testSplitLabelsEarlierTurns() {
        let request = ChatRequest(messages: [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Who is Alice?"),
            ChatMessage(role: .assistant, content: "A girl."),
            ChatMessage(role: .user, content: "And the rabbit?"),
        ])

        let (_, prompt) = SmallModelPrompt.split(request)

        XCTAssertEqual(
            prompt,
            "Earlier in this conversation:\nWho is Alice?\n\n(Your earlier answer:) A girl."
                + "\n\n---\n\nAnd the rabbit?"
        )
    }

    // MARK: - Reading a real prompt back

    func testQuestionAndAnchorAreReadOffTheStrategysOwnPrompt() async throws {
        let assembled = try await retrievalContext(question: "Why does she follow him?")
        let (_, prompt) = SmallModelPrompt.split(assembled.request)

        XCTAssertEqual(SmallModelPrompt.question(in: prompt), "Why does she follow him?")
        XCTAssertEqual(SmallModelPrompt.anchor(in: prompt), "Book: \"Alice\" by Lewis Carroll")
    }

    /// The anchor is the title line and nothing else. A small model asked a
    /// general question with the selected passage in front of it recited the
    /// passage instead of answering.
    func testTheAnchorDropsTheSelectionAndItsSurroundings() async throws {
        let assembled = try await retrievalContext(
            question: "Can I be a rabbit?",
            selection: Selection(
                chapterID: UUID(),
                quotedText: "a White Rabbit with pink eyes ran close by her",
                surroundingText: "There was nothing so very remarkable in that.",
                chapterTitle: "Down the Rabbit-Hole"
            )
        )
        let (_, prompt) = SmallModelPrompt.split(assembled.request)

        let anchor = SmallModelPrompt.anchor(in: prompt)
        XCTAssertEqual(anchor, "Book: \"Alice\" by Lewis Carroll")
        XCTAssertFalse(anchor.contains("pink eyes"))
        XCTAssertFalse(anchor.contains("Down the Rabbit-Hole"))
    }

    func testAPromptWithNoQuestionHasNone() {
        XCTAssertNil(SmallModelPrompt.question(in: "Book: \"Alice\" by Lewis Carroll"))
        XCTAssertNil(SmallModelPrompt.question(in: "Some passages.\n\nQuestion: "))
        XCTAssertEqual(SmallModelPrompt.anchor(in: "no passages here"), "")
    }

    // MARK: - Fitting the window

    /// Four characters a token, so the arithmetic below is readable.
    private func measure(_ text: String) -> Int { TokenCounter.estimate(text) }

    func testAPromptThatAlreadyFitsIsLeftAloneAndReportsItsRoom() throws {
        let prompt = String(repeating: "a", count: 400)  // 100 tokens

        let fitted = try SmallModelPrompt.fit(
            rawPrompt: prompt, window: 1_000, fixedTokens: 200,
            minimumAnswerTokens: 150, measure: measure
        )

        XCTAssertEqual(fitted.prompt, prompt)
        XCTAssertEqual(fitted.answerTokens, 700)
    }

    /// Right on the line: exactly `minimumAnswerTokens` left is enough.
    func testAPromptLeavingExactlyTheMinimumFits() throws {
        let prompt = String(repeating: "a", count: 400)  // 100 tokens

        let fitted = try SmallModelPrompt.fit(
            rawPrompt: prompt, window: 350, fixedTokens: 100,
            minimumAnswerTokens: 150, measure: measure
        )

        XCTAssertEqual(fitted.answerTokens, 150)
    }

    /// One token past the line, with no passage block to shed, is the honest
    /// failure: an answer cut off mid-thought helps nobody.
    func testAPromptOneTokenTooLongThrows() {
        let prompt = String(repeating: "a", count: 404)  // 101 tokens

        XCTAssertThrowsError(
            try SmallModelPrompt.fit(
                rawPrompt: prompt, window: 350, fixedTokens: 100,
                minimumAnswerTokens: 150, measure: measure
            )
        ) { XCTAssertTrue($0 is SmallModelPrompt.DoesNotFit) }
    }

    /// The backstop doing its job: whole passages go, worst-ranked first,
    /// until an answer fits. Prose is never cut.
    func testAnOversizedRetrievalPromptShedsPassagesUntilItFits() throws {
        let passages = (1...4).map { index in
            "[Ch. \(index)] " + String(repeating: "word ", count: 100)
        }
        let prompt = "Book: \"Alice\" by Lewis Carroll"
            + AdaptiveContextStrategy.passagesHeader
            + passages.joined(separator: AdaptiveContextStrategy.passageSeparator)
            + AdaptiveContextStrategy.questionPrefix + "Why?"

        let fitted = try SmallModelPrompt.fit(
            rawPrompt: prompt, window: 500, fixedTokens: 50,
            minimumAnswerTokens: 150, measure: measure
        )

        XCTAssertTrue(fitted.prompt.contains("[Ch. 1]"), "the best match always rides along")
        XCTAssertFalse(fitted.prompt.contains("[Ch. 4]"), "the worst-ranked passage goes first")
        XCTAssertTrue(fitted.prompt.hasSuffix("Question: Why?"))
        XCTAssertGreaterThanOrEqual(fitted.answerTokens, 150)
    }

    // MARK: - Helpers

    private func retrievalContext(
        question: String, selection: Selection? = nil
    ) async throws -> AssembledContext {
        let book = Book(
            metadata: BookMetadata(title: "Alice", authors: ["Lewis Carroll"]),
            chapters: [Chapter(title: "Down the Rabbit-Hole", order: 0, text: "Alice was beginning.")],
            estimatedTokenCount: 5_000_000
        )
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: "The rabbit ran past her.", locator: "Ch. 1", score: 1),
        ])
        return try await AdaptiveContextStrategy(index: index).assembleContext(
            for: question, in: book, selection: selection, scope: .wholeBook,
            provider: ProviderInfo(
                kind: .appleIntelligence, modelID: "apple-on-device", contextBudget: 2_200,
                supportsPromptCaching: false, isLocal: true
            )
        )
    }
}

/// An index with nothing in it, for the whole-book routing case.
private struct EmptyIndex: RAGIndex {
    func build(for book: Book, embeddings: EmbeddingProvider) async throws {}
    func retrieve(
        query: String, bookID: UUID, limit: Int, maxChapterIndex: Int?
    ) async throws -> [RetrievedPassage] { [] }
    func isBuilt(bookID: UUID) async -> Bool { true }
}
