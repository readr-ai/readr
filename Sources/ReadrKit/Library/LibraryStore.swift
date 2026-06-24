import Foundation

/// Where the reader last left off in a book.
public struct ReadingPosition: Sendable, Hashable {
    public var chapterIndex: Int
    public var characterOffset: Int

    public init(chapterIndex: Int, characterOffset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }
}

/// Persistence for the library: books, reading positions, and highlights.
///
/// `InMemoryLibraryStore` is the test/bootstrap implementation. A SwiftData- or
/// GRDB-backed store (with iCloud sync) replaces it later without touching the
/// UI, which depends only on this protocol.
public protocol LibraryStore: Sendable {
    func add(_ book: Book) throws
    func allBooks() -> [Book]
    func book(id: UUID) -> Book?

    func savePosition(_ position: ReadingPosition, for bookID: UUID) throws
    func position(for bookID: UUID) -> ReadingPosition?

    func addHighlight(_ highlight: Highlight) throws
    func highlights(for bookID: UUID) -> [Highlight]
    func removeHighlight(id: UUID) throws
}

/// In-memory `LibraryStore` for tests and the initial app bootstrap.
public final class InMemoryLibraryStore: LibraryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var books: [UUID: Book] = [:]
    private var order: [UUID] = []
    private var positions: [UUID: ReadingPosition] = [:]
    private var highlightsByBook: [UUID: [Highlight]] = [:]

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

    public func removeHighlight(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for (bookID, list) in highlightsByBook {
            highlightsByBook[bookID] = list.filter { $0.id != id }
        }
    }
}
