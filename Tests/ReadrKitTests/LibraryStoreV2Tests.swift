import XCTest
@testable import ReadrKit

/// v2 `LibraryStore` additions — updateHighlight, bookmarks, PDF highlights,
/// book state, and cascading removeBook. Every test runs against BOTH
/// `InMemoryLibraryStore` and `FileLibraryStore` (on a temp file) so the two
/// implementations can't drift apart.
final class LibraryStoreV2Tests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs = []
    }

    /// Runs `body` once per store implementation.
    private func withEachStore(_ body: (LibraryStore) throws -> Void) throws {
        try body(InMemoryLibraryStore())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-v2-\(UUID().uuidString).json")
        tempURLs.append(url)
        try body(FileLibraryStore(fileURL: url))
    }

    private func makeBook(title: String = "Book") -> Book {
        Book(
            metadata: BookMetadata(title: title),
            chapters: [Chapter(title: "One", order: 0, text: "hello world")],
            estimatedTokenCount: 3
        )
    }

    // MARK: updateHighlight

    func testUpdateHighlightReplacesNoteAndColorByID() throws {
        try withEachStore { store in
            let book = makeBook()
            try store.add(book)
            let original = Highlight(
                bookID: book.id,
                chapterID: book.chapters[0].id,
                range: 0..<5,
                quotedText: "hello",
                note: "old note",
                createdAt: Date(timeIntervalSince1970: 0),
                color: .yellow
            )
            try store.addHighlight(original)

            var edited = original
            edited.note = "new note"
            edited.color = .blue
            try store.updateHighlight(edited)

            let stored = store.highlights(for: book.id)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.first?.id, original.id)
            XCTAssertEqual(stored.first?.note, "new note")
            XCTAssertEqual(stored.first?.color, .blue)
        }
    }

    func testUpdateHighlightIgnoresUnknownID() throws {
        try withEachStore { store in
            let book = makeBook()
            try store.add(book)
            let existing = Highlight(
                bookID: book.id,
                chapterID: book.chapters[0].id,
                range: 0..<5,
                quotedText: "hello",
                createdAt: Date(timeIntervalSince1970: 0)
            )
            try store.addHighlight(existing)

            // Same book, id the store has never seen — must be a no-op.
            let stranger = Highlight(
                bookID: book.id,
                chapterID: book.chapters[0].id,
                range: 6..<11,
                quotedText: "world",
                note: "should not appear",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertNoThrow(try store.updateHighlight(stranger))
            XCTAssertEqual(store.highlights(for: book.id), [existing])

            // Book the store has never seen — also a no-op.
            let unknownBook = Highlight(
                bookID: UUID(),
                chapterID: UUID(),
                range: 0..<1,
                quotedText: "x",
                createdAt: Date(timeIntervalSince1970: 2)
            )
            XCTAssertNoThrow(try store.updateHighlight(unknownBook))
            XCTAssertTrue(store.highlights(for: unknownBook.bookID).isEmpty)
        }
    }

    // MARK: Bookmarks

    func testAddAndRemoveBookmarks() throws {
        try withEachStore { store in
            let book = makeBook()
            try store.add(book)
            XCTAssertTrue(store.bookmarks(for: book.id).isEmpty)

            let first = Bookmark(
                bookID: book.id,
                chapterIndex: 0,
                characterOffset: 0,
                snippet: "hello",
                createdAt: Date(timeIntervalSince1970: 0)
            )
            let second = Bookmark(
                bookID: book.id,
                pdfPageIndex: 4,
                snippet: "page five",
                createdAt: Date(timeIntervalSince1970: 60)
            )
            try store.addBookmark(first)
            try store.addBookmark(second)
            XCTAssertEqual(store.bookmarks(for: book.id), [first, second])

            try store.removeBookmark(id: first.id)
            XCTAssertEqual(store.bookmarks(for: book.id), [second])
        }
    }

    // MARK: PDF highlights

    func testAddUpdateAndRemovePDFHighlights() throws {
        try withEachStore { store in
            let book = makeBook()
            try store.add(book)
            XCTAssertTrue(store.pdfHighlights(for: book.id).isEmpty)

            let original = PDFHighlight(
                bookID: book.id,
                pageIndex: 2,
                lineRects: [PDFRect(x: 10, y: 700, width: 200, height: 14)],
                quotedText: "a line of pdf text",
                color: .yellow,
                createdAt: Date(timeIntervalSince1970: 0)
            )
            try store.addPDFHighlight(original)
            XCTAssertEqual(store.pdfHighlights(for: book.id), [original])

            var edited = original
            edited.color = .pink
            edited.note = "important"
            try store.updatePDFHighlight(edited)
            let stored = store.pdfHighlights(for: book.id)
            XCTAssertEqual(stored.count, 1)
            XCTAssertEqual(stored.first?.color, .pink)
            XCTAssertEqual(stored.first?.note, "important")

            // Unknown id is ignored gracefully.
            let stranger = PDFHighlight(
                bookID: book.id,
                pageIndex: 9,
                lineRects: [],
                quotedText: "never added",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertNoThrow(try store.updatePDFHighlight(stranger))
            XCTAssertEqual(store.pdfHighlights(for: book.id).count, 1)

            try store.removePDFHighlight(id: original.id)
            XCTAssertTrue(store.pdfHighlights(for: book.id).isEmpty)
        }
    }

    // MARK: Book state

    func testBookStateSaveAndLoad() throws {
        try withEachStore { store in
            let book = makeBook()
            try store.add(book)
            XCTAssertNil(store.bookState(for: book.id))

            let opened = BookState(
                addedAt: Date(timeIntervalSince1970: 0),
                lastOpenedAt: Date(timeIntervalSince1970: 100)
            )
            try store.saveBookState(opened, for: book.id)
            XCTAssertEqual(store.bookState(for: book.id), opened)
            XCTAssertEqual(store.bookState(for: book.id)?.isFinished, false)

            var finished = opened
            finished.finishedAt = Date(timeIntervalSince1970: 200)
            try store.saveBookState(finished, for: book.id)
            XCTAssertEqual(store.bookState(for: book.id), finished)
            XCTAssertEqual(store.bookState(for: book.id)?.isFinished, true)
        }
    }

    // MARK: removeBook cascade

    func testRemoveBookCascadesAndLeavesOtherBooksUntouched() throws {
        try withEachStore { store in
            let doomed = makeBook(title: "Doomed")
            let keeper = makeBook(title: "Keeper")
            try store.add(doomed)
            try store.add(keeper)

            for book in [doomed, keeper] {
                try store.savePosition(
                    ReadingPosition(chapterIndex: 0, characterOffset: 3), for: book.id
                )
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
                    lineRects: [PDFRect(x: 0, y: 0, width: 1, height: 1)],
                    quotedText: "hello",
                    createdAt: Date(timeIntervalSince1970: 0)
                ))
                try store.saveBookState(
                    BookState(addedAt: Date(timeIntervalSince1970: 0)), for: book.id
                )
            }

            try store.removeBook(id: doomed.id)

            // Everything about the removed book is gone.
            XCTAssertNil(store.book(id: doomed.id))
            XCTAssertNil(store.position(for: doomed.id))
            XCTAssertTrue(store.highlights(for: doomed.id).isEmpty)
            XCTAssertTrue(store.bookmarks(for: doomed.id).isEmpty)
            XCTAssertTrue(store.pdfHighlights(for: doomed.id).isEmpty)
            XCTAssertNil(store.bookState(for: doomed.id))

            // Order shrank; the other book keeps all of its data.
            XCTAssertEqual(store.allBooks().map(\.metadata.title), ["Keeper"])
            XCTAssertNotNil(store.book(id: keeper.id))
            XCTAssertNotNil(store.position(for: keeper.id))
            XCTAssertEqual(store.highlights(for: keeper.id).count, 1)
            XCTAssertEqual(store.bookmarks(for: keeper.id).count, 1)
            XCTAssertEqual(store.pdfHighlights(for: keeper.id).count, 1)
            XCTAssertNotNil(store.bookState(for: keeper.id))
        }
    }
}
