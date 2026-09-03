import XCTest
@testable import ReadrKit

/// A PDF with no text layer — a scanned book, or screenshots exported as a
/// PDF — used to be rejected at import as "damaged". It isn't: PDFKit renders
/// its pages fine, only the text features have nothing to work with. The
/// page-to-chapter assembly lives in ReadrKit so this rule is tested on CI,
/// away from PDFKit; `PDFKitBookParser` feeds it one `page.string` per page.
final class ImageOnlyPDFTests: XCTestCase {

    // MARK: - Page chaptering

    func testEveryPageBecomesAChapterEvenWhenItHasNoText() {
        let result = PDFPageChapters.build(fromPageTexts: [nil, nil, nil])

        XCTAssertEqual(result.chapters.count, 3)
        XCTAssertEqual(result.chapters.map(\.title), ["Page 1", "Page 2", "Page 3"])
        XCTAssertEqual(result.chapters.map(\.order), [0, 1, 2])
        XCTAssertTrue(result.chapters.allSatisfy { $0.text.isEmpty })
    }

    func testAllPagesWithoutTextFlagsTheBookImageOnly() {
        XCTAssertTrue(PDFPageChapters.build(fromPageTexts: [nil, nil]).isImageOnly)
        // Whitespace is not a text layer: PDFKit can hand back a stray
        // newline for a page that carries nothing but an image.
        XCTAssertTrue(PDFPageChapters.build(fromPageTexts: ["", " \n", nil]).isImageOnly)
    }

    func testAnyPageWithTextMeansTheBookHasATextLayer() {
        let result = PDFPageChapters.build(fromPageTexts: [nil, "Chapter One", nil])
        XCTAssertFalse(result.isImageOnly)
    }

    func testPageNumberingSurvivesTextlessPagesInTheMiddle() {
        // Skipping textless pages (the old behaviour) shifted every later
        // "Page N" title off by one per skipped page.
        let result = PDFPageChapters.build(fromPageTexts: ["one", nil, "three"])

        XCTAssertEqual(result.chapters.count, 3)
        XCTAssertEqual(result.chapters[1].title, "Page 2")
        XCTAssertEqual(result.chapters[1].text, "")
        XCTAssertEqual(result.chapters[2].title, "Page 3")
        XCTAssertEqual(result.chapters[2].text, "three")
    }

    func testWhitespaceOnlyPageIsStoredEmptySoTheFlagAndTheChapterAgree() {
        let result = PDFPageChapters.build(fromPageTexts: [" \n", "\u{00A0}"])
        XCTAssertTrue(result.isImageOnly)
        XCTAssertTrue(result.chapters.allSatisfy { $0.text.isEmpty })
        XCTAssertFalse(result.chapters.contains(where: \.hasText))
    }

    func testChapterHasTextIgnoresWhitespace() {
        XCTAssertFalse(Chapter(title: nil, order: 0, text: "").hasText)
        XCTAssertFalse(Chapter(title: nil, order: 0, text: " \n\t").hasText)
        XCTAssertTrue(Chapter(title: nil, order: 0, text: " a ").hasText)
    }

    func testNoPagesIsNeitherImageOnlyNorReadable() {
        let result = PDFPageChapters.build(fromPageTexts: [])
        XCTAssertTrue(result.chapters.isEmpty)
        XCTAssertFalse(result.isImageOnly, "an empty document is a different failure, not a scan")
    }

    func testReadingLengthsKeepZeroTextPagesWithoutInventingProgress() {
        let pages = PDFPageChapters.build(fromPageTexts: [nil, " \n", nil])
        let book = Book(
            metadata: BookMetadata(title: "Scan", isImageOnly: true),
            chapters: pages.chapters,
            estimatedTokenCount: 0
        )

        let lengths = ReadingLengthTable(book: book)
        XCTAssertEqual(lengths.chapterCount, 3)
        XCTAssertEqual(lengths.entries.map(\.characters), [0, 0, 0])
        XCTAssertEqual(lengths.entries.map(\.words), [0, 0, 0])
        XCTAssertEqual(lengths.totalLinearCharacters, 0)
        XCTAssertEqual(
            lengths.charactersRead(upTo: ReadingFrontier(chapterIndex: 2, characterOffset: 99)),
            0
        )
    }

    // MARK: - Metadata flag, Codable back-compat

    func testMetadataJSONWithoutImageOnlyKeyStillDecodes() throws {
        let json = """
        {"title": "Old Book", "authors": ["A"], "tableOfContents": []}
        """
        let metadata = try JSONDecoder().decode(BookMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.isImageOnly)
    }

    func testNilImageOnlyFlagEncodesWithoutTheKey() throws {
        let metadata = BookMetadata(title: "Text Book")
        let raw = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(raw.contains("isImageOnly"))
    }

    func testImageOnlyFlagRoundTripsThroughCodable() throws {
        let book = Book(
            metadata: BookMetadata(title: "Scan", isImageOnly: true),
            chapters: [Chapter(title: "Page 1", order: 0, text: "")],
            estimatedTokenCount: 0
        )
        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded.metadata.isImageOnly, true)
        XCTAssertEqual(decoded.chapters.count, 1)
    }
}
