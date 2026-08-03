import XCTest
@testable import ReadrKit

/// Follow-up questions must carry the conversation with them.
///
/// The Ask panel could only ever hold one exchange: asking again replaced the
/// answer, and the model was re-prompted from scratch — so "but roads are
/// technically 3D" arrived with nothing to object to (user-reported). These
/// pin the prompt assembly the multi-turn panel depends on.
final class ConversationHistoryTests: XCTestCase {

    private func makeBook(tokenCount: Int = 1_000) -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book", authors: ["A. Author"]),
            chapters: [Chapter(title: "One", order: 0, text: "Hello world.")],
            estimatedTokenCount: tokenCount
        )
    }

    private func provider(budget: Int = 200_000, isLocal: Bool = false) -> ProviderInfo {
        ProviderInfo(
            kind: isLocal ? .local : .anthropic,
            modelID: "test",
            contextBudget: budget,
            supportsPromptCaching: !isLocal,
            isLocal: isLocal
        )
    }

    private func turn(_ question: String, _ answer: String?) -> ConversationTurn {
        ConversationTurn(
            question: question,
            answer: answer.map { Answer(text: $0, tier: .wholeBook) }
        )
    }

    // MARK: - historyMessages

    func testAnsweredTurnsBecomeAlternatingMessages() {
        let messages = AdaptiveContextStrategy.historyMessages(from: [
            turn("Why 2D?", "Because roads are laid out on the surface."),
            turn("And tunnels?", "Tunnels add vertical layers."),
        ])

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(messages.map(\.content), [
            "Why 2D?",
            "Because roads are laid out on the surface.",
            "And tunnels?",
            "Tunnels add vertical layers.",
        ])
    }

    /// A turn still streaming (or one that failed) has no answer. Replaying
    /// the bare question would invite the model to answer it a second time.
    func testUnansweredTurnsAreSkipped() {
        let messages = AdaptiveContextStrategy.historyMessages(from: [
            turn("Answered.", "Yes."),
            turn("Still streaming…", nil),
        ])
        XCTAssertEqual(messages.map(\.content), ["Answered.", "Yes."])
    }

    func testEmptyHistoryProducesNoMessages() {
        XCTAssertTrue(AdaptiveContextStrategy.historyMessages(from: []).isEmpty)
    }

    /// The book is the point; a long chat must not crowd it out.
    func testOnlyTheMostRecentTurnsRideAlong() {
        let history = (1...10).map { turn("Q\($0)", "A\($0)") }
        let messages = AdaptiveContextStrategy.historyMessages(from: history)

        XCTAssertEqual(messages.count, AdaptiveContextStrategy.maxHistoryTurns * 2)
        // The most recent turns, in order, ending at the newest.
        XCTAssertEqual(messages.first?.content, "Q5")
        XCTAssertEqual(messages.last?.content, "A10")
    }

    func testLongEarlierAnswersAreAbridged() throws {
        let long = String(repeating: "word ", count: 500)
        let messages = AdaptiveContextStrategy.historyMessages(from: [turn("Q", long)])

        let replayed = try XCTUnwrap(messages.last?.content)
        XCTAssertLessThanOrEqual(
            replayed.count,
            AdaptiveContextStrategy.maxHistoryAnswerCharacters + 1,
            "an abridged answer plus its ellipsis"
        )
        XCTAssertTrue(replayed.hasSuffix("\u{2026}"))
    }

    func testShortEarlierAnswersRideAlongVerbatim() {
        let messages = AdaptiveContextStrategy.historyMessages(from: [turn("Q", "Short answer.")])
        XCTAssertEqual(messages.last?.content, "Short answer.")
    }

    // MARK: - Assembly, whole-book tier

    func testHistorySitsBetweenTheSystemPromptAndTheNewQuestion() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let result = try await strategy.assembleContext(
            for: "but roads are technically 3D",
            in: makeBook(),
            selection: nil,
            history: [turn("Why are roads 2D?", "Because they are laid out on the surface.")],
            provider: provider()
        )

        let messages = result.request.messages
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(messages[1].content, "Why are roads 2D?")
        XCTAssertTrue(
            messages.last?.content.hasSuffix("Question: but roads are technically 3D") == true,
            "the new question must come last: \(messages.last?.content ?? "")"
        )
    }

    /// The no-history call still assembles exactly two messages — the
    /// convenience overload must not smuggle anything in.
    func testNoHistoryLeavesTheRequestUnchanged() async throws {
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())
        let result = try await strategy.assembleContext(
            for: "What happens?",
            in: makeBook(),
            selection: nil,
            provider: provider()
        )
        XCTAssertEqual(result.request.messages.map(\.role), [.system, .user])
    }

    // MARK: - Assembly, retrieval tier

    func testRetrievalTierAlsoCarriesHistory() async throws {
        let index = StubRAGIndex(passages: [
            RetrievedPassage(text: "A passage.", locator: "Ch. 1 ¶1", score: 0.9),
        ])
        let strategy = AdaptiveContextStrategy(index: index)
        let result = try await strategy.assembleContext(
            for: "and after that?",
            in: makeBook(tokenCount: 5_000_000),
            selection: nil,
            history: [turn("What happens first?", "The tunnel is dug.")],
            provider: provider()
        )

        XCTAssertEqual(result.tier, .retrieval)
        XCTAssertEqual(result.request.messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(result.request.messages[2].content, "The tunnel is dug.")
    }

    // MARK: - The prompt itself

    /// The answers were "a little too verbose" and arrived as raw Markdown
    /// punctuation. The prompt has to ask for both fixes, so pin that it says
    /// something about each.
    func testSystemPromptAsksForBrevityAndMarkdown() {
        let prompt = AdaptiveContextStrategy.systemPrompt.lowercased()
        XCTAssertTrue(prompt.contains("brief"), "the prompt must ask for brevity")
        XCTAssertTrue(prompt.contains("markdown"), "the prompt must name the output format")
        XCTAssertTrue(
            prompt.contains("no headings"),
            "headings in a chat bubble read as a report, not an answer"
        )
    }
}
