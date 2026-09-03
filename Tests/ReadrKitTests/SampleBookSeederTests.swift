import XCTest
@testable import ReadrKit

/// A fresh install must never be a dead end. Apple's App Review rejected 3.2.1
/// under guideline 2.1(a) on 2026-09-01 for exactly that: the reviewer opened
/// Readr on an iPad, met "Your library is empty", and had no file on the device
/// to import. These tests pin the two things that make seeding safe — it
/// happens once, into a library that has never been used, and it never fights
/// the user for control of their library.
final class SampleBookSeederTests: XCTestCase {

    private func makeBook(title: String = "Alice's Adventures in Wonderland") -> Book {
        Book(
            metadata: BookMetadata(title: title, authors: ["Lewis Carroll"]),
            chapters: [Chapter(title: "Down the Rabbit-Hole", order: 0, text: "Alice was beginning")],
            estimatedTokenCount: 3
        )
    }

    // MARK: The decision

    func testSeedsIntoAFreshEmptyLibrary() {
        XCTAssertTrue(SampleBookSeeder.shouldSeed(
            hasSeededBefore: false, hasPersistedLibrary: false, existingBookCount: 0
        ))
    }

    /// The user deleted the sample. That is an answer, and re-seeding would
    /// override it — the sample would reappear every launch.
    func testDoesNotSeedAgainAfterTheUserDeletesTheSample() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(
            hasSeededBefore: true, hasPersistedLibrary: false, existingBookCount: 0
        ))
    }

    /// A library that has been written to disk has been used, even when it is
    /// empty now — the user imported and then deleted, or the seeded flag was
    /// lost with the app's defaults. Either way it is theirs, not a blank shelf.
    func testDoesNotSeedIntoAnEmptiedLibraryThatWasPersisted() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(
            hasSeededBefore: false, hasPersistedLibrary: true, existingBookCount: 0
        ))
    }

    /// Someone upgrading with books already imported is not stuck, so seeding
    /// would just be clutter in a library they have already made their own.
    func testDoesNotSeedIntoALibraryThatAlreadyHasBooks() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(
            hasSeededBefore: false, hasPersistedLibrary: false, existingBookCount: 1
        ))
    }

    func testDoesNotSeedWhenEveryConditionRulesItOut() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(
            hasSeededBefore: true, hasPersistedLibrary: true, existingBookCount: 4
        ))
    }

    // MARK: The effect

    func testSeedingRunsTheImportOnceAndReturnsItsBook() async throws {
        let store = InMemoryLibraryStore()
        var imports = 0
        let seeded = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) {
            imports += 1
            let book = self.makeBook()
            try store.add(book)
            return book
        }
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(store.allBooks().count, 1)
        XCTAssertEqual(store.allBooks().first?.metadata.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(store.book(id: try XCTUnwrap(seeded).id)?.id, seeded?.id)
    }

    func testSecondCallDoesNotImportAgain() async throws {
        let store = InMemoryLibraryStore()
        _ = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) {
            let book = self.makeBook()
            try store.add(book)
            return book
        }
        let again = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: true) {
            XCTFail("the import ran a second time")
            return self.makeBook()
        }
        XCTAssertNil(again)
        XCTAssertEqual(store.allBooks().count, 1)
    }

    /// Parsing the bundled EPUB costs real time on a cold launch. When we are
    /// not going to seed, that work must not happen at all.
    func testDoesNotRunTheImportWhenItWillNotSeed() async throws {
        let store = InMemoryLibraryStore()
        try store.add(makeBook(title: "The user's own book"))
        var imported = false
        let seeded = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) {
            imported = true
            return self.makeBook()
        }
        XCTAssertNil(seeded)
        XCTAssertFalse(imported, "the bundled book was parsed even though seeding was skipped")
        XCTAssertEqual(store.allBooks().count, 1)
    }

    /// The store's own word on whether it has been used is what the gate
    /// reads — a persisted, empty library is left alone.
    func testAPersistedEmptyLibraryIsLeftAlone() async throws {
        let store = PersistedEmptyStore()
        let seeded = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) {
            XCTFail("seeded into a library the user had already used")
            return self.makeBook()
        }
        XCTAssertNil(seeded)
    }

    /// A corrupt or missing bundled file must not take the app down with it —
    /// an empty library is a far better outcome than a launch crash.
    func testAFailingImportPropagatesRatherThanCorruptingTheLibrary() async {
        struct Boom: Error {}
        let store = InMemoryLibraryStore()
        do {
            _ = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) { throw Boom() }
            XCTFail("the import's error was swallowed")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertTrue(store.allBooks().isEmpty)
    }
}

/// An empty store that reports it has been written before.
private final class PersistedEmptyStore: LibraryStore, @unchecked Sendable {
    private let inner = InMemoryLibraryStore()
    var hasPersistedLibrary: Bool { true }
    func add(_ book: Book) throws { try inner.add(book) }
    func allBooks() -> [Book] { inner.allBooks() }
    func book(id: UUID) -> Book? { inner.book(id: id) }
    func removeBook(id: UUID) throws { try inner.removeBook(id: id) }
    func savePosition(_ position: ReadingPosition, for bookID: UUID) throws { try inner.savePosition(position, for: bookID) }
    func position(for bookID: UUID) -> ReadingPosition? { inner.position(for: bookID) }
    func addHighlight(_ highlight: Highlight) throws { try inner.addHighlight(highlight) }
    func highlights(for bookID: UUID) -> [Highlight] { inner.highlights(for: bookID) }
    func updateHighlight(_ highlight: Highlight) throws { try inner.updateHighlight(highlight) }
    func removeHighlight(id: UUID) throws { try inner.removeHighlight(id: id) }
    func bookmarks(for bookID: UUID) -> [Bookmark] { inner.bookmarks(for: bookID) }
    func addBookmark(_ bookmark: Bookmark) throws { try inner.addBookmark(bookmark) }
    func removeBookmark(id: UUID) throws { try inner.removeBookmark(id: id) }
    func pdfHighlights(for bookID: UUID) -> [PDFHighlight] { inner.pdfHighlights(for: bookID) }
    func addPDFHighlight(_ highlight: PDFHighlight) throws { try inner.addPDFHighlight(highlight) }
    func updatePDFHighlight(_ highlight: PDFHighlight) throws { try inner.updatePDFHighlight(highlight) }
    func removePDFHighlight(id: UUID) throws { try inner.removePDFHighlight(id: id) }
    func bookState(for bookID: UUID) -> BookState? { inner.bookState(for: bookID) }
    func saveBookState(_ state: BookState, for bookID: UUID) throws { try inner.saveBookState(state, for: bookID) }
}
