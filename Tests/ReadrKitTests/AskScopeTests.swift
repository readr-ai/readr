import XCTest
@testable import ReadrKit

/// The book is the *context* for an answer, not its ceiling (#54).
///
/// Readers ask things the book cannot answer on its own — "how has the science
/// moved on since this was written?", "who directed the film adaptation?" — and
/// the marketing promises real answers to them. The earlier prompt told the
/// model to answer "using the provided book context" and to say so when the
/// answer wasn't in the book, which read as permission to decline.
///
/// What must stay true is narrower: the model may never invent *what the book
/// says*. These pin that split — answer freely, attribute carefully — so a
/// later prompt edit can't quietly reintroduce the refusal.
final class AskScopeTests: XCTestCase {

    private var prompt: String { AdaptiveContextStrategy.systemPrompt }
    private var lowered: String { prompt.lowercased() }

    // MARK: - Answering past the book

    /// The prompt must state outright that the book bounds the context, not the
    /// answer. Without this the model treats "not in the book" as a stop sign.
    func testPromptSaysTheBookIsContextNotLimit() {
        XCTAssertTrue(
            lowered.contains("not your limit") || lowered.contains("not a limit"),
            "the prompt must say the book is context, not a limit:\n\(prompt)"
        )
    }

    /// Questions reaching past the book get answered from world knowledge.
    func testPromptInvitesAnswersFromGeneralKnowledge() {
        XCTAssertTrue(
            lowered.contains("past the book") || lowered.contains("beyond the book"),
            "the prompt must name the beyond-the-book case:\n\(prompt)"
        )
        XCTAssertTrue(
            lowered.contains("from what you know"),
            "the prompt must license answering from world knowledge:\n\(prompt)"
        )
    }

    /// The failure mode this issue was filed for: the model declining rather
    /// than answering. The prompt has to name declining as the wrong move.
    func testPromptForbidsDecliningAnOutOfBookQuestion() {
        XCTAssertTrue(
            lowered.contains("rather than declining") || lowered.contains("don't decline"),
            "the prompt must rule out declining out-of-book questions:\n\(prompt)"
        )
    }

    // MARK: - What the guarantee still covers

    /// The anti-hallucination guarantee survives, scoped to the book's content.
    func testPromptStillForbidsInventingWhatTheBookSays() {
        XCTAssertTrue(
            lowered.contains("never invent what the book says"),
            "the accuracy guarantee about the book itself must survive:\n\(prompt)"
        )
        XCTAssertTrue(
            lowered.contains("attribute"),
            "the prompt must forbid attributing outside claims to the book:\n\(prompt)"
        )
    }

    /// Blended answers have to signal which half is which, or the reader can't
    /// tell the book's claim from the model's.
    func testPromptAsksToDistinguishBookFromWorldKnowledge() {
        XCTAssertTrue(
            lowered.contains("which is which"),
            "the prompt must ask the model to mark book vs. beyond:\n\(prompt)"
        )
    }

    /// Signalling the source must stay a few words inline. An earlier draft's
    /// "say so in one line before answering" produced a disclaimer paragraph
    /// on top of every answer, which is exactly the verbosity the panel fights.
    func testSourceSignallingStaysInlineNotADisclaimer() {
        XCTAssertTrue(
            lowered.contains("don't label every sentence")
                || lowered.contains("no disclaimer"),
            "signalling must not become a per-sentence or preamble ritual:\n\(prompt)"
        )
    }

    // MARK: - Regressions against the old wording

    /// The exact instructions that caused the refusal must not come back.
    func testPromptDoesNotReinstateTheBookOnlyInstruction() {
        XCTAssertFalse(
            lowered.contains("only from the book"),
            "book-only answering is the bug:\n\(prompt)"
        )
        XCTAssertFalse(
            lowered.contains("say so rather than"),
            "'say so rather than answering' is the refusal wording:\n\(prompt)"
        )
    }

    // MARK: - The prompt still ships on every request

    /// The scope rules are worthless if they don't ride along with the ask.
    func testSystemPromptIsSentOnBothTiers() async throws {
        let book = Book(
            metadata: BookMetadata(title: "T", authors: ["A"]),
            chapters: [Chapter(title: "One", order: 0, text: "Body.")],
            estimatedTokenCount: 100
        )
        let strategy = AdaptiveContextStrategy(index: StubRAGIndex())

        let small = try await strategy.assembleContext(
            for: "Q", in: book, selection: nil,
            provider: ProviderInfo(
                kind: .anthropic, modelID: "m",
                contextBudget: 100_000, supportsPromptCaching: true, isLocal: false
            )
        )
        XCTAssertEqual(small.tier, AssembledContext.Tier.wholeBook)
        XCTAssertEqual(small.request.messages.first?.content, prompt)

        let large = try await strategy.assembleContext(
            for: "Q", in: book, selection: nil,
            provider: ProviderInfo(
                kind: .local, modelID: "m",
                contextBudget: 8_000, supportsPromptCaching: false, isLocal: true
            )
        )
        XCTAssertEqual(large.tier, AssembledContext.Tier.retrieval)
        XCTAssertEqual(large.request.messages.first?.content, prompt)
    }
}
