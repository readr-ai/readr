import XCTest
@testable import ReadrKit

/// v2 persistence — bookmarks, PDF highlights, and book states written by one
/// `FileLibraryStore` instance are visible to a fresh instance on the same URL
/// (i.e. survive relaunch), alongside the pre-existing v1 data.
final class FileLibraryStoreV2Tests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeBook(title: String = "Book") -> Book {
        Book(
            metadata: BookMetadata(title: title),
            chapters: [Chapter(title: "One", order: 0, text: "hello world")],
            estimatedTokenCount: 3
        )
    }

    func testBookmarksPDFHighlightsAndStatesSurviveReload() throws {
        let book = makeBook(title: "Persisted")
        let bookmark = Bookmark(
            bookID: book.id,
            chapterIndex: 1,
            characterOffset: 23,
            pdfPageIndex: 7,
            snippet: "It was a…",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let pdfHighlight = PDFHighlight(
            bookID: book.id,
            pageIndex: 11,
            lineRects: [
                PDFRect(x: 72, y: 640.5, width: 451, height: 13.2),
                PDFRect(x: 72, y: 626, width: 210, height: 13.2),
            ],
            quotedText: "two lines of pdf text",
            color: .green,
            note: "wow",
            createdAt: Date(timeIntervalSince1970: 60)
        )
        let state = BookState(
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: Date(timeIntervalSince1970: 120),
            finishedAt: Date(timeIntervalSince1970: 240)
        )

        // First "launch": write everything.
        do {
            let store = FileLibraryStore(fileURL: fileURL)
            try store.add(book)
            try store.addBookmark(bookmark)
            try store.addPDFHighlight(pdfHighlight)
            try store.saveBookState(state, for: book.id)
        }

        // Second "launch": a fresh instance reads from disk.
        let reopened = FileLibraryStore(fileURL: fileURL)
        XCTAssertEqual(reopened.bookmarks(for: book.id), [bookmark])
        XCTAssertEqual(reopened.pdfHighlights(for: book.id), [pdfHighlight])
        XCTAssertEqual(reopened.bookState(for: book.id), state)
        XCTAssertEqual(reopened.bookState(for: book.id)?.isFinished, true)
    }

    func testRemovalsPersistAcrossReload() throws {
        let book = makeBook()
        let bookmark = Bookmark(
            bookID: book.id,
            snippet: "hello",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let pdfHighlight = PDFHighlight(
            bookID: book.id,
            pageIndex: 0,
            lineRects: [PDFRect(x: 0, y: 0, width: 1, height: 1)],
            quotedText: "hello",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        do {
            let store = FileLibraryStore(fileURL: fileURL)
            try store.add(book)
            try store.addBookmark(bookmark)
            try store.addPDFHighlight(pdfHighlight)
            try store.removeBookmark(id: bookmark.id)
            try store.removePDFHighlight(id: pdfHighlight.id)
        }

        let reopened = FileLibraryStore(fileURL: fileURL)
        XCTAssertTrue(reopened.bookmarks(for: book.id).isEmpty)
        XCTAssertTrue(reopened.pdfHighlights(for: book.id).isEmpty)
    }

    func testRemoveBookCascadePersistsAcrossReload() throws {
        let book = makeBook(title: "Removed")
        do {
            let store = FileLibraryStore(fileURL: fileURL)
            try store.add(book)
            try store.savePosition(ReadingPosition(chapterIndex: 0), for: book.id)
            try store.addHighlight(Highlight(
                bookID: book.id,
                chapterID: book.chapters[0].id,
                range: 0..<5,
                quotedText: "hello",
                createdAt: Date(timeIntervalSince1970: 0)
            ))
            try store.addBookmark(Bookmark(
                bookID: book.id,
                snippet: "hello",
                createdAt: Date(timeIntervalSince1970: 0)
            ))
            try store.addPDFHighlight(PDFHighlight(
                bookID: book.id,
                pageIndex: 0,
                lineRects: [],
                quotedText: "hello",
                createdAt: Date(timeIntervalSince1970: 0)
            ))
            try store.saveBookState(BookState(addedAt: Date(timeIntervalSince1970: 0)), for: book.id)
            try store.removeBook(id: book.id)
        }

        let reopened = FileLibraryStore(fileURL: fileURL)
        XCTAssertTrue(reopened.allBooks().isEmpty)
        XCTAssertNil(reopened.position(for: book.id))
        XCTAssertTrue(reopened.highlights(for: book.id).isEmpty)
        XCTAssertTrue(reopened.bookmarks(for: book.id).isEmpty)
        XCTAssertTrue(reopened.pdfHighlights(for: book.id).isEmpty)
        XCTAssertNil(reopened.bookState(for: book.id))
    }
}
