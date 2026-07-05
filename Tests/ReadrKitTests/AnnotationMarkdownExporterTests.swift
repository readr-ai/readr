import XCTest
@testable import ReadrKit

/// Annotations → portable Markdown: chapter/page grouping in reading order,
/// blockquote formatting, color labels, and notes.
final class AnnotationMarkdownExporterTests: XCTestCase {

    private let exporter = AnnotationMarkdownExporter()

    private func makeTwoChapterBook() -> Book {
        Book(
            metadata: BookMetadata(title: "Walden", authors: ["Henry David Thoreau"]),
            chapters: [
                Chapter(title: "Economy", order: 0, text: String(repeating: "a", count: 200)),
                Chapter(title: "Sounds", order: 1, text: String(repeating: "b", count: 200)),
            ],
            estimatedTokenCount: 100
        )
    }

    private func makeHighlight(
        in book: Book,
        chapter: Int,
        range: Range<Int>,
        quote: String,
        note: String? = nil,
        color: HighlightColor? = nil
    ) -> Highlight {
        Highlight(
            bookID: book.id,
            chapterID: book.chapters[chapter].id,
            range: range,
            quotedText: quote,
            note: note,
            createdAt: Date(timeIntervalSince1970: 0),
            color: color
        )
    }

    // MARK: Empty input

    func testNilWhenThereAreNoAnnotations() {
        XCTAssertNil(exporter.markdown(book: makeTwoChapterBook(), highlights: [], pdfHighlights: []))
    }

    // MARK: Header

    func testHeaderContainsTitleAndAuthors() throws {
        let book = makeTwoChapterBook()
        let highlight = makeHighlight(in: book, chapter: 0, range: 0..<5, quote: "aaaaa")
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: [highlight]))

        XCTAssertTrue(markdown.hasPrefix("# Highlights — Walden"))
        XCTAssertTrue(markdown.contains("by Henry David Thoreau"))
    }

    func testHeaderOmitsAuthorLineWhenBookHasNoAuthors() throws {
        var book = makeTwoChapterBook()
        book.metadata.authors = []
        let highlight = makeHighlight(in: book, chapter: 0, range: 0..<5, quote: "aaaaa")
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: [highlight]))

        XCTAssertFalse(markdown.contains("\nby "))
    }

    // MARK: Chapter grouping & ordering

    func testChaptersAppearInReadingOrderAndHighlightsSortByRange() throws {
        let book = makeTwoChapterBook()
        // Deliberately added out of order: chapter 2 first, then chapter 1's
        // later highlight before its earlier one.
        let highlights = [
            makeHighlight(in: book, chapter: 1, range: 40..<50, quote: "second chapter"),
            makeHighlight(in: book, chapter: 0, range: 100..<110, quote: "later in first"),
            makeHighlight(in: book, chapter: 0, range: 5..<15, quote: "early in first"),
        ]
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: highlights))

        let economy = try XCTUnwrap(markdown.range(of: "## Economy"))
        let sounds = try XCTUnwrap(markdown.range(of: "## Sounds"))
        XCTAssertLessThan(economy.lowerBound, sounds.lowerBound)

        let early = try XCTUnwrap(markdown.range(of: "> early in first"))
        let later = try XCTUnwrap(markdown.range(of: "> later in first"))
        XCTAssertLessThan(economy.lowerBound, early.lowerBound)
        XCTAssertLessThan(early.lowerBound, later.lowerBound)
        XCTAssertLessThan(later.lowerBound, sounds.lowerBound)
        XCTAssertLessThan(
            sounds.lowerBound,
            try XCTUnwrap(markdown.range(of: "> second chapter")).lowerBound
        )
    }

    // MARK: Blockquote formatting

    func testMultiLineQuotePrefixesEveryLine() throws {
        let book = makeTwoChapterBook()
        let highlight = makeHighlight(
            in: book,
            chapter: 0,
            range: 0..<30,
            quote: "first line\nsecond line\nthird line"
        )
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: [highlight]))

        XCTAssertTrue(markdown.contains("> first line\n> second line\n> third line"))
        XCTAssertFalse(markdown.contains("\nsecond line")) // never unprefixed
    }

    func testNoteAndColorLabelRendering() throws {
        let book = makeTwoChapterBook()
        let highlight = makeHighlight(
            in: book,
            chapter: 0,
            range: 0..<5,
            quote: "aaaaa",
            note: "revisit this",
            color: .blue
        )
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: [highlight]))

        XCTAssertTrue(markdown.contains("> — *Blue* · Note: revisit this"))
    }

    func testHighlightWithoutColorRendersYellowLabelAndNoNote() throws {
        let book = makeTwoChapterBook()
        let highlight = makeHighlight(in: book, chapter: 0, range: 0..<5, quote: "aaaaa")
        let markdown = try XCTUnwrap(exporter.markdown(book: book, highlights: [highlight]))

        XCTAssertTrue(markdown.contains("> — *Yellow*"))
        XCTAssertFalse(markdown.contains("Note:"))
    }

    // MARK: PDF highlights

    func testPDFHighlightsGroupUnderOneBasedPagesSortedByPage() throws {
        let book = makeTwoChapterBook()
        let pageTwo = PDFHighlight(
            bookID: book.id,
            pageIndex: 2,
            lineRects: [PDFRect(x: 0, y: 0, width: 1, height: 1)],
            quotedText: "from page three",
            color: .purple,
            createdAt: Date(timeIntervalSince1970: 60)
        )
        let pageZero = PDFHighlight(
            bookID: book.id,
            pageIndex: 0,
            lineRects: [PDFRect(x: 0, y: 0, width: 1, height: 1)],
            quotedText: "from page one",
            color: .green,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let markdown = try XCTUnwrap(exporter.markdown(
            book: book,
            highlights: [],
            pdfHighlights: [pageTwo, pageZero] // out of page order
        ))

        // Zero-based page indexes render as 1-based headings…
        let pageOne = try XCTUnwrap(markdown.range(of: "## Page 1"))
        let pageThree = try XCTUnwrap(markdown.range(of: "## Page 3"))
        XCTAssertFalse(markdown.contains("## Page 0"))
        // …sorted by page regardless of input order.
        XCTAssertLessThan(pageOne.lowerBound, pageThree.lowerBound)
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "> from page one")).lowerBound,
            try XCTUnwrap(markdown.range(of: "> from page three")).lowerBound
        )
    }

    func testBookWithOnlyPDFHighlightsExports() throws {
        let book = Book(
            metadata: BookMetadata(title: "Scanned Paper"),
            chapters: [Chapter(title: nil, order: 0, text: "")],
            estimatedTokenCount: 0
        )
        let highlight = PDFHighlight(
            bookID: book.id,
            pageIndex: 4,
            lineRects: [PDFRect(x: 10, y: 20, width: 30, height: 12)],
            quotedText: "pdf only",
            color: .pink,
            note: "figure 2",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let markdown = try XCTUnwrap(exporter.markdown(
            book: book,
            highlights: [],
            pdfHighlights: [highlight]
        ))

        XCTAssertTrue(markdown.hasPrefix("# Highlights — Scanned Paper"))
        XCTAssertTrue(markdown.contains("## Page 5"))
        XCTAssertTrue(markdown.contains("> pdf only"))
        XCTAssertTrue(markdown.contains("> — *Pink* · Note: figure 2"))
    }
}
