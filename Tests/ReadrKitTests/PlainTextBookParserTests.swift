import XCTest
@testable import ReadrKit

/// J1 — Add a book to the library (parsing side).
final class PlainTextBookParserTests: XCTestCase {

    private let parser = PlainTextBookParser()

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesChaptersAndTOCFromHeadings() throws {
        let book = try parser.parse(
            data: data("""
            # Chapter One
            It was a bright cold day in April.

            # Chapter Two
            The clocks were striking thirteen.
            """),
            title: "1984"
        )
        XCTAssertEqual(book.metadata.title, "1984")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters.first?.title, "Chapter One")
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertTrue(book.chapters[1].text.contains("striking thirteen"))
    }

    func testHeadinglessTextBecomesSingleChapter() throws {
        let book = try parser.parse(data: data("Just one block of prose."), title: "Note")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertNil(book.chapters[0].title)
    }

    func testComputesTokenEstimate() throws {
        let book = try parser.parse(data: data(String(repeating: "a", count: 400)), title: "T")
        XCTAssertEqual(book.estimatedTokenCount, 100) // ~4 chars/token
    }

    func testEmptyFileIsCorrupted() {
        XCTAssertThrowsError(try parser.parse(data: Data(), title: "Empty")) { error in
            guard case BookParserError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    func testNonUTF8IsCorrupted() {
        let invalid = Data([0xFF, 0xFE, 0xFF])
        XCTAssertThrowsError(try parser.parse(data: invalid, title: "Bad")) { error in
            guard case BookParserError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    func testCanParseByExtension() {
        XCTAssertTrue(parser.canParse(URL(fileURLWithPath: "/x/book.md")))
        XCTAssertTrue(parser.canParse(URL(fileURLWithPath: "/x/book.TXT")))
        XCTAssertFalse(parser.canParse(URL(fileURLWithPath: "/x/book.epub")))
    }
}
