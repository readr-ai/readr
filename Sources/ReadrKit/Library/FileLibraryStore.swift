import Foundation

/// A `LibraryStore` that persists to a single JSON file, so the library,
/// reading positions, and highlights survive app relaunches. Cross-platform and
/// unit-testable (point it at a temp file). A SwiftData/GRDB store with iCloud
/// sync can replace it later behind the same protocol.
public final class FileLibraryStore: LibraryStore, @unchecked Sendable {
    private struct State: Codable {
        var order: [UUID] = []
        var books: [UUID: Book] = [:]
        var positions: [UUID: ReadingPosition] = [:]
        var highlights: [UUID: [Highlight]] = [:]
        // v2 additions — optional so pre-v2 library.json files decode.
        var bookmarks: [UUID: [Bookmark]]? = [:]
        var pdfHighlights: [UUID: [PDFHighlight]]? = [:]
        var bookStates: [UUID: BookState]? = [:]
    }

    private let url: URL
    private let lock = NSLock()
    private var state: State

    /// Loads existing state from `fileURL` if present; otherwise starts empty.
    public init(fileURL: URL) {
        self.url = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            self.state = State()
            return
        }
        if let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            // The file exists but can't be decoded (truncated write, schema
            // change, ...). Don't start empty and overwrite it on the next
            // mutation — set it aside so the user's data is recoverable.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            self.state = State()
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    public func add(_ book: Book) throws {
        lock.lock(); defer { lock.unlock() }
        if state.books[book.id] == nil { state.order.append(book.id) }
        state.books[book.id] = book
        try persist()
    }

    public func allBooks() -> [Book] {
        lock.lock(); defer { lock.unlock() }
        return state.order.compactMap { state.books[$0] }
    }

    public func book(id: UUID) -> Book? {
        lock.lock(); defer { lock.unlock() }
        return state.books[id]
    }

    public func savePosition(_ position: ReadingPosition, for bookID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        state.positions[bookID] = position
        try persist()
    }

    public func position(for bookID: UUID) -> ReadingPosition? {
        lock.lock(); defer { lock.unlock() }
        return state.positions[bookID]
    }

    public func addHighlight(_ highlight: Highlight) throws {
        lock.lock(); defer { lock.unlock() }
        state.highlights[highlight.bookID, default: []].append(highlight)
        try persist()
    }

    public func highlights(for bookID: UUID) -> [Highlight] {
        lock.lock(); defer { lock.unlock() }
        return state.highlights[bookID] ?? []
    }

    public func removeHighlight(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for (bookID, list) in state.highlights {
            state.highlights[bookID] = list.filter { $0.id != id }
        }
        try persist()
    }

    public func removeBook(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        state.books[id] = nil
        state.order.removeAll { $0 == id }
        state.positions[id] = nil
        state.highlights[id] = nil
        state.bookmarks?[id] = nil
        state.pdfHighlights?[id] = nil
        state.bookStates?[id] = nil
        try persist()
    }

    public func updateHighlight(_ highlight: Highlight) throws {
        lock.lock(); defer { lock.unlock() }
        guard var list = state.highlights[highlight.bookID],
              let index = list.firstIndex(where: { $0.id == highlight.id }) else { return }
        list[index] = highlight
        state.highlights[highlight.bookID] = list
        try persist()
    }

    public func bookmarks(for bookID: UUID) -> [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        return state.bookmarks?[bookID] ?? []
    }

    public func addBookmark(_ bookmark: Bookmark) throws {
        lock.lock(); defer { lock.unlock() }
        var all = state.bookmarks ?? [:]
        all[bookmark.bookID, default: []].append(bookmark)
        state.bookmarks = all
        try persist()
    }

    public func removeBookmark(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var all = state.bookmarks else { return }
        for (bookID, list) in all {
            all[bookID] = list.filter { $0.id != id }
        }
        state.bookmarks = all
        try persist()
    }

    public func pdfHighlights(for bookID: UUID) -> [PDFHighlight] {
        lock.lock(); defer { lock.unlock() }
        return state.pdfHighlights?[bookID] ?? []
    }

    public func addPDFHighlight(_ highlight: PDFHighlight) throws {
        lock.lock(); defer { lock.unlock() }
        var all = state.pdfHighlights ?? [:]
        all[highlight.bookID, default: []].append(highlight)
        state.pdfHighlights = all
        try persist()
    }

    public func updatePDFHighlight(_ highlight: PDFHighlight) throws {
        lock.lock(); defer { lock.unlock() }
        guard var all = state.pdfHighlights,
              var list = all[highlight.bookID],
              let index = list.firstIndex(where: { $0.id == highlight.id }) else { return }
        list[index] = highlight
        all[highlight.bookID] = list
        state.pdfHighlights = all
        try persist()
    }

    public func removePDFHighlight(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var all = state.pdfHighlights else { return }
        for (bookID, list) in all {
            all[bookID] = list.filter { $0.id != id }
        }
        state.pdfHighlights = all
        try persist()
    }

    public func bookState(for bookID: UUID) -> BookState? {
        lock.lock(); defer { lock.unlock() }
        return state.bookStates?[bookID]
    }

    public func saveBookState(_ bookState: BookState, for bookID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = state.bookStates ?? [:]
        all[bookID] = bookState
        state.bookStates = all
        try persist()
    }
}

extension FileLibraryStore {
    /// Default library file under Application Support (created if needed).
    public static func defaultURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Readr", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }
}
