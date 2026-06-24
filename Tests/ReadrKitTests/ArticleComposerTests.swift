import XCTest
@testable import ReadrKit

final class ArticleComposerTests: XCTestCase {

    private let composer = LLMArticleComposer()

    private func makeBook() -> Book {
        Book(
            metadata: BookMetadata(title: "1984", authors: ["George Orwell"]),
            chapters: [
                Chapter(id: UUID(), title: "One", order: 0, text: String(repeating: "a", count: 100)),
                Chapter(id: UUID(), title: "Two", order: 1, text: String(repeating: "b", count: 100)),
            ],
            estimatedTokenCount: 50
        )
    }

    private func highlight(
        chapter: Chapter, lower: Int, quoted: String, note: String? = nil, at seconds: TimeInterval
    ) -> Highlight {
        Highlight(
            bookID: UUID(),
            chapterID: chapter.id,
            range: lower..<(lower + quoted.count),
            quotedText: quoted,
            note: note,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    // MARK: J6 — zero highlights

    func testZeroHighlightsThrowsAndDoesNotCallProvider() async {
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: ["should not run"])
        do {
            _ = try await composer.compose(from: [], in: makeBook(), provider: provider)
            XCTFail("expected noHighlights")
        } catch {
            XCTAssertEqual(error as? ArticleComposerError, .noHighlights)
        }
        XCTAssertTrue(provider.receivedRequests.isEmpty, "no LLM call should be made")
    }

    // MARK: J6 — reading order + quotes preserved

    func testHighlightsAreOrderedByReadingPosition() {
        let book = makeBook()
        let ch1 = book.chapters[0], ch2 = book.chapters[1]
        // Deliberately out of reading order and out of capture order.
        let secondChapter = highlight(chapter: ch2, lower: 0, quoted: "second", at: 1)
        let firstChapterLate = highlight(chapter: ch1, lower: 40, quoted: "first-late", at: 0)
        let firstChapterEarly = highlight(chapter: ch1, lower: 0, quoted: "first-early", at: 5)

        let ordered = LLMArticleComposer.orderedHighlights(
            [secondChapter, firstChapterLate, firstChapterEarly], in: book
        )
        XCTAssertEqual(ordered.map(\.quotedText), ["first-early", "first-late", "second"])
    }

    func testBuildPromptKeepsQuotesAndNotesInReadingOrder() {
        let book = makeBook()
        let ch1 = book.chapters[0], ch2 = book.chapters[1]
        let highlights = [
            highlight(chapter: ch2, lower: 0, quoted: "the clocks", at: 1),
            highlight(chapter: ch1, lower: 0, quoted: "bright cold day", note: "opening line", at: 2),
        ]
        let prompt = LLMArticleComposer.buildPrompt(highlights: highlights, book: book)

        // Reading order: chapter 1's quote precedes chapter 2's.
        let firstIdx = try! XCTUnwrap(prompt.range(of: "bright cold day")).lowerBound
        let secondIdx = try! XCTUnwrap(prompt.range(of: "the clocks")).lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
        XCTAssertTrue(prompt.contains("note: opening line"))
        XCTAssertTrue(prompt.contains("\"1984\" by George Orwell"))
    }

    func testMultiLineQuoteStaysASingleBullet() {
        let book = makeBook()
        let highlights = [
            highlight(chapter: book.chapters[0], lower: 0, quoted: "the clocks\nwere striking thirteen", at: 0),
        ]
        let prompt = LLMArticleComposer.buildPrompt(highlights: highlights, book: book)
        XCTAssertTrue(prompt.contains("\"the clocks were striking thirteen\""))
        XCTAssertFalse(prompt.contains("the clocks\nwere striking"), "internal newline must be collapsed")
    }

    // MARK: J6 — compose returns the streamed markdown

    func testComposeReturnsStreamedMarkdownArticle() async throws {
        let book = makeBook()
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: ["# Notes\n", "Body text."])
        let highlights = [highlight(chapter: book.chapters[0], lower: 0, quoted: "x", at: 0)]

        let article = try await composer.compose(from: highlights, in: book, provider: provider)
        XCTAssertEqual(article.markdown, "# Notes\nBody text.")
        XCTAssertEqual(article.title, "Notes on 1984")
        XCTAssertEqual(provider.receivedRequests.count, 1)
    }

    // MARK: J6 — streaming composition

    func testComposeStreamingYieldsScriptedDeltasInOrder() async throws {
        let book = makeBook()
        let scripted = ["# Notes\n", "First paragraph. ", "Second paragraph."]
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: scripted)
        let highlights = [highlight(chapter: book.chapters[0], lower: 0, quoted: "x", at: 0)]

        var collected = ""
        var deltas: [String] = []
        for try await delta in composer.composeStreaming(from: highlights, in: book, provider: provider) {
            deltas.append(delta)
            collected += delta
        }

        XCTAssertEqual(deltas, scripted, "deltas should arrive in scripted order")
        XCTAssertEqual(collected, scripted.joined())
        XCTAssertEqual(provider.receivedRequests.count, 1)
    }

    func testComposeStreamingEmptyHighlightsThrowsNoHighlights() async {
        let provider = MockLLMProvider(info: .fixture(), scriptedChunks: ["should not run"])
        do {
            for try await _ in composer.composeStreaming(from: [], in: makeBook(), provider: provider) {
                XCTFail("empty highlights should not yield any deltas")
            }
            XCTFail("expected noHighlights to be thrown")
        } catch {
            XCTAssertEqual(error as? ArticleComposerError, .noHighlights)
        }
        XCTAssertTrue(provider.receivedRequests.isEmpty, "no LLM call should be made")
    }
}
