import Foundation

/// Where the reader last left off in a book.
public struct ReadingPosition: Sendable, Hashable, Codable {
    public var chapterIndex: Int
    public var characterOffset: Int
    /// Last viewed page in native PDF mode (zero-based), if any.
    public var pdfPageIndex: Int?

    public init(chapterIndex: Int, characterOffset: Int = 0, pdfPageIndex: Int? = nil) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.pdfPageIndex = pdfPageIndex
    }
}

/// Persistence for the library: books, reading positions, annotations
/// (highlights, PDF highlights, bookmarks), and per-book lifecycle state.
///
/// `InMemoryLibraryStore` is the test/bootstrap implementation. A SwiftData- or
/// GRDB-backed store (with iCloud sync) replaces it later without touching the
/// UI, which depends only on this protocol.
public protocol LibraryStore: Sendable {
    func add(_ book: Book) throws
    func allBooks() -> [Book]
    func book(id: UUID) -> Book?
    /// Removes the book and all of its positions, annotations, and state.
    func removeBook(id: UUID) throws

    func savePosition(_ position: ReadingPosition, for bookID: UUID) throws
    func position(for bookID: UUID) -> ReadingPosition?

    func addHighlight(_ highlight: Highlight) throws
    func highlights(for bookID: UUID) -> [Highlight]
    /// Replaces the stored highlight with the same `id` (note/color edits).
    func updateHighlight(_ highlight: Highlight) throws
    func removeHighlight(id: UUID) throws

    func bookmarks(for bookID: UUID) -> [Bookmark]
    func addBookmark(_ bookmark: Bookmark) throws
    func removeBookmark(id: UUID) throws

    func pdfHighlights(for bookID: UUID) -> [PDFHighlight]
    func addPDFHighlight(_ highlight: PDFHighlight) throws
    /// Replaces the stored PDF highlight with the same `id`.
    func updatePDFHighlight(_ highlight: PDFHighlight) throws
    func removePDFHighlight(id: UUID) throws

    func bookState(for bookID: UUID) -> BookState?
    func saveBookState(_ state: BookState, for bookID: UUID) throws
}

/// In-memory `LibraryStore` for tests and the initial app bootstrap.
public final class InMemoryLibraryStore: LibraryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var books: [UUID: Book] = [:]
    private var order: [UUID] = []
    private var positions: [UUID: ReadingPosition] = [:]
    private var highlightsByBook: [UUID: [Highlight]] = [:]
    private var bookmarksByBook: [UUID: [Bookmark]] = [:]
    private var pdfHighlightsByBook: [UUID: [PDFHighlight]] = [:]
    private var states: [UUID: BookState] = [:]

    public init() {}

    public func add(_ book: Book) throws {
        lock.lock(); defer { lock.unlock() }
        if books[book.id] == nil { order.append(book.id) }
        books[book.id] = book
    }

    public func allBooks() -> [Book] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { books[$0] }
    }

    public func book(id: UUID) -> Book? {
        lock.lock(); defer { lock.unlock() }
        return books[id]
    }

    public func removeBook(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        books[id] = nil
        order.removeAll { $0 == id }
        positions[id] = nil
        highlightsByBook[id] = nil
        bookmarksByBook[id] = nil
        pdfHighlightsByBook[id] = nil
        states[id] = nil
    }

    public func savePosition(_ position: ReadingPosition, for bookID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        positions[bookID] = position
    }

    public func position(for bookID: UUID) -> ReadingPosition? {
        lock.lock(); defer { lock.unlock() }
        return positions[bookID]
    }

    public func addHighlight(_ highlight: Highlight) throws {
        lock.lock(); defer { lock.unlock() }
        highlightsByBook[highlight.bookID, default: []].append(highlight)
    }

    public func highlights(for bookID: UUID) -> [Highlight] {
        lock.lock(); defer { lock.unlock() }
        return highlightsByBook[bookID] ?? []
    }

    public func updateHighlight(_ highlight: Highlight) throws {
        lock.lock(); defer { lock.unlock() }
        guard var list = highlightsByBook[highlight.bookID],
              let index = list.firstIndex(where: { $0.id == highlight.id }) else { return }
        list[index] = highlight
        highlightsByBook[highlight.bookID] = list
    }

    public func removeHighlight(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for (bookID, list) in highlightsByBook {
            highlightsByBook[bookID] = list.filter { $0.id != id }
        }
    }

    public func bookmarks(for bookID: UUID) -> [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        return bookmarksByBook[bookID] ?? []
    }

    public func addBookmark(_ bookmark: Bookmark) throws {
        lock.lock(); defer { lock.unlock() }
        bookmarksByBook[bookmark.bookID, default: []].append(bookmark)
    }

    public func removeBookmark(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for (bookID, list) in bookmarksByBook {
            bookmarksByBook[bookID] = list.filter { $0.id != id }
        }
    }

    public func pdfHighlights(for bookID: UUID) -> [PDFHighlight] {
        lock.lock(); defer { lock.unlock() }
        return pdfHighlightsByBook[bookID] ?? []
    }

    public func addPDFHighlight(_ highlight: PDFHighlight) throws {
        lock.lock(); defer { lock.unlock() }
        pdfHighlightsByBook[highlight.bookID, default: []].append(highlight)
    }

    public func updatePDFHighlight(_ highlight: PDFHighlight) throws {
        lock.lock(); defer { lock.unlock() }
        guard var list = pdfHighlightsByBook[highlight.bookID],
              let index = list.firstIndex(where: { $0.id == highlight.id }) else { return }
        list[index] = highlight
        pdfHighlightsByBook[highlight.bookID] = list
    }

    public func removePDFHighlight(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for (bookID, list) in pdfHighlightsByBook {
            pdfHighlightsByBook[bookID] = list.filter { $0.id != id }
        }
    }

    public func bookState(for bookID: UUID) -> BookState? {
        lock.lock(); defer { lock.unlock() }
        return states[bookID]
    }

    public func saveBookState(_ state: BookState, for bookID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        states[bookID] = state
    }
}
