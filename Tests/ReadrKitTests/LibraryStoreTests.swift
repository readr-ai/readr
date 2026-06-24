import XCTest
@testable import ReadrKit

/// J1/J2/J3 — library persistence: books, reading position, highlights.
final class LibraryStoreTests: XCTestCase {

    private func makeBook(title: String = "Book") -> Book {
        Book(
            metadata: BookMetadata(title: title),
            chapters: [Chapter(title: "One", order: 0, text: "hello world")],
            estimatedTokenCount: 3
        )
    }

    func testAddedBooksAppearInOrder() throws {
        let store = InMemoryLibraryStore()
        let a = makeBook(title: "A"), b = makeBook(title: "B")
        try store.add(a)
        try store.add(b)
        XCTAssertEqual(store.allBooks().map(\.metadata.title), ["A", "B"])
        XCTAssertEqual(store.book(id: a.id)?.metadata.title, "A")
    }

    func testReadingPositionRoundTrips() throws {
        let store = InMemoryLibraryStore()
        let book = makeBook()
        try store.add(book)
        XCTAssertNil(store.position(for: book.id))

        let pos = ReadingPosition(chapterIndex: 3, characterOffset: 128)
        try store.savePosition(pos, for: book.id)
        XCTAssertEqual(store.position(for: book.id), pos)
    }

    func testHighlightsPersistAndRemove() throws {
        let store = InMemoryLibraryStore()
        let book = makeBook()
        try store.add(book)
        let chapterID = book.chapters[0].id

        let highlight = Highlight(
            bookID: book.id,
            chapterID: chapterID,
            range: 0..<5,
            quotedText: "hello",
            note: "greeting",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try store.addHighlight(highlight)
        XCTAssertEqual(store.highlights(for: book.id).count, 1)
        XCTAssertEqual(store.highlights(for: book.id).first?.note, "greeting")

        try store.removeHighlight(id: highlight.id)
        XCTAssertTrue(store.highlights(for: book.id).isEmpty)
    }
}
