import XCTest
@testable import ReadrKit

/// A fresh install must never be a dead end. Apple's App Review rejected 3.2.1
/// under guideline 2.1(a) on 2026-09-01 for exactly that: the reviewer opened
/// Readr on an iPad, met "Your library is empty", and had no file on the device
/// to import. These tests pin the two things that make seeding safe — it
/// happens once, and it never fights the user for control of their library.
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
        XCTAssertTrue(SampleBookSeeder.shouldSeed(hasSeededBefore: false, existingBookCount: 0))
    }

    /// The user deleted the sample. That is an answer, and re-seeding would
    /// override it — the sample would reappear every launch.
    func testDoesNotSeedAgainAfterTheUserDeletesTheSample() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(hasSeededBefore: true, existingBookCount: 0))
    }

    /// Someone upgrading with books already imported is not stuck, so seeding
    /// would just be clutter in a library they have already made their own.
    func testDoesNotSeedIntoALibraryThatAlreadyHasBooks() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(hasSeededBefore: false, existingBookCount: 1))
    }

    func testDoesNotSeedWhenBothConditionsRuleItOut() {
        XCTAssertFalse(SampleBookSeeder.shouldSeed(hasSeededBefore: true, existingBookCount: 4))
    }

    // MARK: The effect

    func testSeedingAddsExactlyOneBookAndReturnsIt() throws {
        let store = InMemoryLibraryStore()
        let seeded = try SampleBookSeeder.seedIfNeeded(
            into: store, hasSeededBefore: false, makeBook: { self.makeBook() }
        )
        XCTAssertNotNil(seeded)
        XCTAssertEqual(store.allBooks().count, 1)
        XCTAssertEqual(store.allBooks().first?.metadata.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(store.book(id: try XCTUnwrap(seeded).id)?.id, seeded?.id)
    }

    func testSecondCallDoesNotDuplicateTheSample() throws {
        let store = InMemoryLibraryStore()
        _ = try SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false, makeBook: { self.makeBook() })
        let again = try SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: true, makeBook: { self.makeBook() })
        XCTAssertNil(again)
        XCTAssertEqual(store.allBooks().count, 1)
    }

    /// Parsing the bundled EPUB costs real time on a cold launch. When we are
    /// not going to seed, that work must not happen at all.
    func testDoesNotBuildTheBookWhenItWillNotSeed() throws {
        let store = InMemoryLibraryStore()
        try store.add(makeBook(title: "The user's own book"))
        var built = false
        let seeded = try SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) {
            built = true
            return self.makeBook()
        }
        XCTAssertNil(seeded)
        XCTAssertFalse(built, "the bundled book was parsed even though seeding was skipped")
        XCTAssertEqual(store.allBooks().count, 1)
    }

    /// A corrupt or missing bundled file must not take the app down with it —
    /// an empty library is a far better outcome than a launch crash.
    func testAFailingBuildPropagatesRatherThanCorruptingTheLibrary() {
        struct Boom: Error {}
        let store = InMemoryLibraryStore()
        XCTAssertThrowsError(
            try SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: false) { throw Boom() }
        )
        XCTAssertTrue(store.allBooks().isEmpty)
    }
}
