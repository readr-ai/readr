import XCTest
@testable import ReadrKit

/// v2 backward compatibility — pre-v2 models and `library.json` files (no
/// `color`, no `pdfPageIndex`, no bookmarks/pdfHighlights/bookStates keys)
/// keep decoding, and v2 writes don't lose pre-v2 data.
final class V2BackwardCompatibilityTests: XCTestCase {

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

    // MARK: Model-level decoding

    func testHighlightWithoutColorKeyDecodesAsNilColorAndYellowMarker() throws {
        // Exactly what a pre-v2 JSONEncoder wrote: no `color` key.
        let json = """
        {
            "id": "99999999-8888-7777-6666-555555555555",
            "bookID": "11111111-2222-3333-4444-555555555555",
            "chapterID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "range": [0, 5],
            "quotedText": "hello",
            "note": "greeting",
            "createdAt": 0
        }
        """
        let highlight = try JSONDecoder().decode(Highlight.self, from: Data(json.utf8))
        XCTAssertNil(highlight.color)
        XCTAssertEqual(highlight.markerColor, .yellow)
        XCTAssertEqual(highlight.range, 0..<5)
        XCTAssertEqual(highlight.quotedText, "hello")
    }

    func testReadingPositionWithoutPDFPageIndexDecodes() throws {
        let json = """
        {"chapterIndex": 2, "characterOffset": 7}
        """
        let position = try JSONDecoder().decode(ReadingPosition.self, from: Data(json.utf8))
        XCTAssertEqual(position.chapterIndex, 2)
        XCTAssertEqual(position.characterOffset, 7)
        XCTAssertNil(position.pdfPageIndex)
    }

    // MARK: Pre-v2 library.json

    private let legacyBookID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let legacyChapterID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let legacyHighlightID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    /// Exactly the shape pre-v2 `FileLibraryStore.State` had — no bookmarks/
    /// pdfHighlights/bookStates keys. Encoded with JSONEncoder so the fixture
    /// is byte-compatible with what the old store actually wrote (notably:
    /// Swift encodes `[UUID: T]` as a flat [key, value, …] ARRAY, not a
    /// string-keyed object, and synthesized Codable omits nil optionals, so a
    /// v2 `Highlight` with `color == nil` encodes exactly like a pre-v2 one).
    private struct LegacyState: Codable {
        var order: [UUID] = []
        var books: [UUID: Book] = [:]
        var positions: [UUID: ReadingPosition] = [:]
        var highlights: [UUID: [Highlight]] = [:]
    }

    private func writeLegacyLibraryFile() throws {
        let book = Book(
            id: legacyBookID,
            metadata: BookMetadata(title: "Legacy Book", authors: ["Ada Lovelace"]),
            chapters: [
                Chapter(id: legacyChapterID, title: "One", order: 0, text: "hello world")
            ],
            estimatedTokenCount: 3
        )
        let highlight = Highlight(
            id: legacyHighlightID,
            bookID: legacyBookID,
            chapterID: legacyChapterID,
            range: 0..<5,
            quotedText: "hello",
            note: "greeting",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        var state = LegacyState()
        state.order = [legacyBookID]
        state.books = [legacyBookID: book]
        state.positions = [legacyBookID: ReadingPosition(chapterIndex: 1, characterOffset: 42)]
        state.highlights = [legacyBookID: [highlight]]
        try JSONEncoder().encode(state).write(to: fileURL)

        // The fixture must not contain any v2 keys — that's the whole point.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("bookmarks"))
        XCTAssertFalse(raw.contains("pdfHighlights"))
        XCTAssertFalse(raw.contains("bookStates"))
        XCTAssertFalse(raw.contains("color"))
    }

    func testPreV2LibraryFileLoadsIntoFileLibraryStore() throws {
        try writeLegacyLibraryFile()

        let store = FileLibraryStore(fileURL: fileURL)

        // Old data is all there…
        XCTAssertEqual(store.allBooks().map(\.metadata.title), ["Legacy Book"])
        XCTAssertEqual(
            store.position(for: legacyBookID),
            ReadingPosition(chapterIndex: 1, characterOffset: 42)
        )
        let highlights = store.highlights(for: legacyBookID)
        XCTAssertEqual(highlights.map(\.id), [legacyHighlightID])
        XCTAssertNil(highlights.first?.color)
        XCTAssertEqual(highlights.first?.markerColor, .yellow)

        // …and the file was NOT set aside as corrupt.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileURL.appendingPathExtension("corrupt").path
            )
        )

        // v2 surfaces are empty/nil rather than crashing.
        XCTAssertTrue(store.bookmarks(for: legacyBookID).isEmpty)
        XCTAssertTrue(store.pdfHighlights(for: legacyBookID).isEmpty)
        XCTAssertNil(store.bookState(for: legacyBookID))
    }

    func testAddingBookmarkToPreV2FileKeepsOldHighlightsAfterReload() throws {
        try writeLegacyLibraryFile()

        let bookmark = Bookmark(
            bookID: legacyBookID,
            chapterIndex: 0,
            characterOffset: 6,
            snippet: "world",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        do {
            let store = FileLibraryStore(fileURL: fileURL)
            try store.addBookmark(bookmark)
        }

        // Fresh instance reads the upgraded file: old + new data coexist.
        let reopened = FileLibraryStore(fileURL: fileURL)
        XCTAssertEqual(reopened.allBooks().map(\.metadata.title), ["Legacy Book"])
        XCTAssertEqual(reopened.highlights(for: legacyBookID).map(\.id), [legacyHighlightID])
        XCTAssertEqual(reopened.bookmarks(for: legacyBookID), [bookmark])
        XCTAssertEqual(
            reopened.position(for: legacyBookID),
            ReadingPosition(chapterIndex: 1, characterOffset: 42)
        )
    }
}
