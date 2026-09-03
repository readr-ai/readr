import XCTest
@testable import ReadrKit

/// J1/J2/J3 — persistence survives across store instances (i.e. relaunch).
final class FileLibraryStoreTests: XCTestCase {

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

    // MARK: hasPersistedLibrary

    /// The first-run seed reads this: a store pointed at a file that does not
    /// exist yet has never been used; the moment anything is written, it has.
    func testHasPersistedLibraryFollowsTheFileOnDisk() throws {
        let store = FileLibraryStore(fileURL: fileURL)
        XCTAssertFalse(store.hasPersistedLibrary, "no file yet")
        try store.add(makeBook())
        XCTAssertTrue(store.hasPersistedLibrary)
        try store.removeBook(id: store.allBooks()[0].id)
        XCTAssertTrue(store.allBooks().isEmpty)
        XCTAssertTrue(store.hasPersistedLibrary, "an emptied library was still used")
        XCTAssertTrue(FileLibraryStore(fileURL: fileURL).hasPersistedLibrary, "and a relaunch sees the same")
    }

    /// A library we had to set aside as corrupt was a library the user
    /// filled: seeding a sample over it would bury their recovery.
    func testACorruptFileSetAsideStillCountsAsPersisted() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = FileLibraryStore(fileURL: fileURL)
        XCTAssertTrue(store.allBooks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the corrupt file was moved aside")
        XCTAssertTrue(store.hasPersistedLibrary)
    }

    func testBooksPositionsAndHighlightsSurviveReload() throws {
        let book = makeBook(title: "Persisted")
        let chapterID = book.chapters[0].id

        // First "launch": write everything.
        do {
            let store = FileLibraryStore(fileURL: fileURL)
            try store.add(book)
            try store.savePosition(ReadingPosition(chapterIndex: 2, characterOffset: 40), for: book.id)
            try store.addHighlight(
                Highlight(
                    bookID: book.id,
                    chapterID: chapterID,
                    range: 0..<5,
                    quotedText: "hello",
                    note: "hi",
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            )
        }

        // Second "launch": a fresh instance reads from disk.
        let reopened = FileLibraryStore(fileURL: fileURL)
        XCTAssertEqual(reopened.allBooks().map(\.metadata.title), ["Persisted"])
        XCTAssertEqual(reopened.position(for: book.id), ReadingPosition(chapterIndex: 2, characterOffset: 40))
        XCTAssertEqual(reopened.highlights(for: book.id).first?.quotedText, "hello")
        XCTAssertEqual(reopened.highlights(for: book.id).first?.note, "hi")
    }

    func testRemoveHighlightPersists() throws {
        let store = FileLibraryStore(fileURL: fileURL)
        let book = makeBook()
        try store.add(book)
        let highlight = Highlight(
            bookID: book.id,
            chapterID: book.chapters[0].id,
            range: 0..<5,
            quotedText: "hello",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try store.addHighlight(highlight)
        try store.removeHighlight(id: highlight.id)

        XCTAssertTrue(FileLibraryStore(fileURL: fileURL).highlights(for: book.id).isEmpty)
    }
}
