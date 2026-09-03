import XCTest
@testable import ReadrKit

/// One answer to "what is this chapter called", shared by the reader header,
/// the Contents list, the "where am I" caption and the prompt anchor.
final class ChapterTitleTests: XCTestCase {

    private func makeBook(toc: [TOCEntry] = []) -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book", tableOfContents: toc),
            chapters: [
                Chapter(title: "Loomings", order: 0, text: "a"),
                Chapter(title: "  ", order: 1, text: "b"),
                Chapter(title: nil, order: 2, text: "c"),
                Chapter(title: nil, order: 3, text: "d"),
            ],
            estimatedTokenCount: 4
        )
    }

    func testOwnTitleWins() {
        XCTAssertEqual(makeBook().chapterTitle(forChapterIndex: 0), "Loomings")
        XCTAssertEqual(makeBook().chapterDisplayTitle(0), "Loomings")
    }

    func testBlankOwnTitleIsNoTitle() {
        let book = makeBook(toc: [TOCEntry(title: "Part One", chapterIndex: 0)])
        XCTAssertEqual(book.chapterTitle(forChapterIndex: 1), "Part One")
    }

    func testFallsBackToTheNearestTOCTitleAtOrBefore() {
        let book = makeBook(toc: [
            TOCEntry(title: "Part One", chapterIndex: 0, children: [
                TOCEntry(title: "The Carpet-Bag", chapterIndex: 2),
            ]),
            TOCEntry(title: "Part Two", chapterIndex: 3),
        ])
        XCTAssertEqual(book.tocTitle(forChapterIndex: 1), "Part One")
        XCTAssertEqual(book.tocTitle(forChapterIndex: 2), "The Carpet-Bag", "the deepest entry that precedes the chapter wins")
        XCTAssertEqual(book.tocTitle(forChapterIndex: 3), "Part Two")
        XCTAssertNil(book.tocTitle(forChapterIndex: -1))
    }

    func testBlankTOCTitlesAreSkipped() {
        let book = makeBook(toc: [
            TOCEntry(title: "Part One", chapterIndex: 0),
            TOCEntry(title: "   ", chapterIndex: 2),
        ])
        XCTAssertEqual(book.tocTitle(forChapterIndex: 3), "Part One")
    }

    /// The one fallback wording, everywhere: "Chapter N", N from one.
    func testTheFallbackIsChapterN() {
        let book = makeBook()
        XCTAssertNil(book.chapterTitle(forChapterIndex: 2))
        XCTAssertEqual(book.chapterDisplayTitle(2), "Chapter 3")
        XCTAssertEqual(book.chapterDisplayTitle(3), "Chapter 4")
        XCTAssertEqual(book.chapterDisplayTitle(42), "Chapter 43", "an index outside the book still gets a name")
        XCTAssertEqual(Book.fallbackChapterTitle(number: 7), "Chapter 7")
    }

    /// The index is a reading-order index, like the frontier's.
    func testIndexesChaptersInReadingOrder() {
        let book = Book(
            metadata: BookMetadata(title: "Shuffled"),
            chapters: [
                Chapter(title: "Second", order: 1, text: "b"),
                Chapter(title: "First", order: 0, text: "a"),
            ],
            estimatedTokenCount: 2
        )
        XCTAssertEqual(book.chapterDisplayTitle(0), "First")
        XCTAssertEqual(book.chapterDisplayTitle(1), "Second")
    }

    /// The summary's title is this lookup, so the caption and the header
    /// can never name the same chapter differently.
    func testTheSummaryUsesTheSameLookup() {
        let book = makeBook(toc: [TOCEntry(title: "Part One", chapterIndex: 0)])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 0))
        XCTAssertEqual(summary?.chapterTitle, book.chapterDisplayTitle(2))
        XCTAssertEqual(summary?.titleIsFallback, false)
    }
}
