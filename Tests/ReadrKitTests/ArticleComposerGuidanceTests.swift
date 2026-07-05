import XCTest
@testable import ReadrKit

/// The reader's optional guidance must reach the model as its own labeled
/// instruction section — never disguised as one of the quoted highlights.
final class ArticleComposerGuidanceTests: XCTestCase {

    private let composer = LLMArticleComposer()
    private let guidanceLabel = "Reader's guidance for this article (instructions, not book content):"

    private func makeBook() -> Book {
        Book(
            metadata: BookMetadata(title: "1984", authors: ["George Orwell"]),
            chapters: [
                Chapter(id: UUID(), title: "One", order: 0, text: String(repeating: "a", count: 100)),
            ],
            estimatedTokenCount: 50
        )
    }

    private func highlight(chapter: Chapter, quoted: String) -> Highlight {
        Highlight(
            bookID: UUID(),
            chapterID: chapter.id,
            range: 0..<quoted.count,
            quotedText: quoted,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Prompt rendering

    func testGuidanceRendersInItsOwnLabeledSectionAfterHighlights() throws {
        let book = makeBook()
        let highlights = [highlight(chapter: book.chapters[0], quoted: "bright cold day")]
        let prompt = LLMArticleComposer.buildPrompt(
            highlights: highlights, book: book, guidance: "Focus on surveillance themes"
        )

        let labelIdx = try XCTUnwrap(prompt.range(of: guidanceLabel)).lowerBound
        let bulletIdx = try XCTUnwrap(prompt.range(of: "- \"bright cold day\"")).lowerBound
        XCTAssertLessThan(bulletIdx, labelIdx, "guidance section follows the highlights list")
        XCTAssertTrue(prompt.contains("Focus on surveillance themes"))
    }

    func testGuidanceNeverAppearsAsAHighlightBullet() {
        let book = makeBook()
        let highlights = [highlight(chapter: book.chapters[0], quoted: "bright cold day")]
        let prompt = LLMArticleComposer.buildPrompt(
            highlights: highlights, book: book, guidance: "Focus on surveillance themes"
        )

        // Exactly the real highlight becomes a bullet; guidance does not.
        let bulletLines = prompt.split(separator: "\n").filter { $0.hasPrefix("- ") }.map(String.init)
        XCTAssertEqual(bulletLines, ["- \"bright cold day\""])
        XCTAssertFalse(prompt.contains("- \"\""), "no synthetic empty-quote bullet")
        XCTAssertFalse(prompt.contains("\"Focus on surveillance themes\""),
                       "guidance must not be quoted like book content")
    }

    func testNilGuidanceOmitsTheSection() {
        let book = makeBook()
        let highlights = [highlight(chapter: book.chapters[0], quoted: "x")]
        let withNil = LLMArticleComposer.buildPrompt(highlights: highlights, book: book, guidance: nil)
        let withDefault = LLMArticleComposer.buildPrompt(highlights: highlights, book: book)
        XCTAssertFalse(withNil.contains(guidanceLabel))
        XCTAssertEqual(withNil, withDefault, "defaulted parameter behaves like nil")
    }

    func testEmptyOrWhitespaceGuidanceOmitsTheSection() {
        let book = makeBook()
        let highlights = [highlight(chapter: book.chapters[0], quoted: "x")]
        for guidance in ["", "   ", " \n\t "] {
            let prompt = LLMArticleComposer.buildPrompt(
                highlights: highlights, book: book, guidance: guidance
            )
            XCTAssertFalse(prompt.contains(guidanceLabel), "guidance \(guidance.debugDescription)")
        }
    }

    func testGuidanceIsTrimmedInThePrompt() {
        let book = makeBook()
        let highlights = [highlight(chapter: book.chapters[0], quoted: "x")]
        let prompt = LLMArticleComposer.buildPrompt(
            highlights: highlights, book: book, guidance: "  Keep it short.\n"
        )
        XCTAssertTrue(prompt.contains("\(guidanceLabel)\nKeep it short."))
        XCTAssertTrue(prompt.hasSuffix("Keep it short."))
    }

    // MARK: - Through the streaming pipeline

    func testComposeStreamingSendsGuidanceSectionToTheProvider() async throws {
        let book = makeBook()
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: ["ok"])
        let highlights = [highlight(chapter: book.chapters[0], quoted: "x")]

        for try await _ in composer.composeStreaming(
            from: highlights, in: book, guidance: "Make it lyrical", provider: provider
        ) {}

        let sent = try XCTUnwrap(provider.receivedRequests.first?.messages.first?.content)
        XCTAssertTrue(sent.contains(guidanceLabel))
        XCTAssertTrue(sent.contains("Make it lyrical"))
    }

    func testComposeStreamingWithoutGuidanceSendsNoGuidanceSection() async throws {
        let book = makeBook()
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: ["ok"])
        let highlights = [highlight(chapter: book.chapters[0], quoted: "x")]

        for try await _ in composer.composeStreaming(
            from: highlights, in: book, provider: provider
        ) {}

        let sent = try XCTUnwrap(provider.receivedRequests.first?.messages.first?.content)
        XCTAssertFalse(sent.contains(guidanceLabel))
    }
}
