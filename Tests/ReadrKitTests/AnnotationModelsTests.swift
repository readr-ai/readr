import XCTest
@testable import ReadrKit

/// v2 annotation model types — Codable round-trips and `BookState.isFinished`.
final class AnnotationModelsTests: XCTestCase {

    /// Encode → decode → must equal the original.
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testPDFRectRoundTrips() throws {
        try roundTrip(PDFRect(x: 72.5, y: 640.25, width: 451, height: 13.2))
    }

    func testPDFHighlightRoundTrips() throws {
        try roundTrip(PDFHighlight(
            bookID: UUID(),
            pageIndex: 11,
            lineRects: [
                PDFRect(x: 72, y: 640, width: 451, height: 13),
                PDFRect(x: 72, y: 626, width: 210, height: 13),
            ],
            quotedText: "two lines\nof text",
            color: .purple,
            note: "see also ch. 3",
            createdAt: Date(timeIntervalSince1970: 1_000)
        ))
    }

    func testPDFHighlightWithoutNoteRoundTrips() throws {
        try roundTrip(PDFHighlight(
            bookID: UUID(),
            pageIndex: 0,
            lineRects: [],
            quotedText: "bare",
            createdAt: Date(timeIntervalSince1970: 0)
        ))
    }

    func testBookmarkRoundTrips() throws {
        try roundTrip(Bookmark(
            bookID: UUID(),
            chapterIndex: 3,
            characterOffset: 128,
            pdfPageIndex: 12,
            snippet: "Page 13 — 'It was a…'",
            createdAt: Date(timeIntervalSince1970: 2_000)
        ))
    }

    func testTextBookmarkWithoutPDFPageRoundTrips() throws {
        let bookmark = Bookmark(
            bookID: UUID(),
            chapterIndex: 1,
            characterOffset: 42,
            snippet: "hello",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try roundTrip(bookmark)

        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(Bookmark.self, from: data)
        XCTAssertNil(decoded.pdfPageIndex)
    }

    func testBookStateRoundTrips() throws {
        try roundTrip(BookState(
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200)
        ))
        try roundTrip(BookState()) // all-nil state also survives
    }

    func testBookStateIsFinished() {
        XCTAssertFalse(BookState().isFinished)
        XCTAssertFalse(
            BookState(
                addedAt: Date(timeIntervalSince1970: 0),
                lastOpenedAt: Date(timeIntervalSince1970: 50)
            ).isFinished
        )
        XCTAssertTrue(
            BookState(finishedAt: Date(timeIntervalSince1970: 100)).isFinished
        )
    }

    func testHighlightWithColorRoundTrips() throws {
        try roundTrip(Highlight(
            bookID: UUID(),
            chapterID: UUID(),
            range: 10..<25,
            quotedText: "quoted",
            note: "a note",
            createdAt: Date(timeIntervalSince1970: 0),
            color: .green
        ))
    }
}
