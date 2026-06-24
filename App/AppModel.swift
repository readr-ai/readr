import Foundation
import ReadrKit

/// App-level state for M1: the library, import, reading position, and
/// highlights. AI features (ask, article) attach to this in later milestones.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var highlightsByBook: [UUID: [Highlight]] = [:]
    @Published var importError: String?

    private let store: any LibraryStore
    private let parsers: BookParserRegistry
    private let highlightService = HighlightService()

    init(store: (any LibraryStore)? = nil, parsers: BookParserRegistry? = nil) {
        if store == nil, ProcessInfo.processInfo.arguments.contains("-uiTestSeed") {
            let seeded = InMemoryLibraryStore()
            try? seeded.add(Self.sampleBook)
            self.store = seeded
        } else {
            self.store = store ?? Self.makeDefaultStore()
        }
        self.parsers = parsers ?? Self.makeDefaultRegistry()
        self.books = self.store.allBooks()
    }

    /// Deterministic fixture for UI tests (seeded via the `-uiTestSeed` arg).
    static let sampleBook = Book(
        metadata: BookMetadata(title: "Sample Book", authors: ["Test Author"]),
        chapters: [
            Chapter(title: "Chapter One", order: 0, text: "It was a bright cold day in April."),
            Chapter(title: "Chapter Two", order: 1, text: "The clocks were striking thirteen."),
        ],
        estimatedTokenCount: 16
    )

    // MARK: Defaults

    private static func makeDefaultStore() -> any LibraryStore {
        if let url = try? FileLibraryStore.defaultURL() {
            return FileLibraryStore(fileURL: url)
        }
        return InMemoryLibraryStore()
    }

    private static func makeDefaultRegistry() -> BookParserRegistry {
        var parsers: [any BookParser] = [PlainTextBookParser()]
        #if canImport(PDFKit)
        parsers.append(PDFKitBookParser())
        #endif
        #if canImport(ZIPFoundation)
        parsers.append(EPUBFileParser())
        #endif
        return BookParserRegistry(parsers: parsers)
    }

    // MARK: Import

    func importBook(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let book = try await parsers.parse(url)
            try store.add(book)
            books = store.allBooks()
        } catch let error as BookParserError {
            importError = Self.message(for: error)
        } catch {
            importError = "Couldn't import this file: \(error.localizedDescription)"
        }
    }

    // MARK: Reading position

    func position(for book: Book) -> ReadingPosition? {
        store.position(for: book.id)
    }

    func savePosition(_ position: ReadingPosition, for book: Book) {
        try? store.savePosition(position, for: book.id)
    }

    // MARK: Highlights

    func highlights(for book: Book) -> [Highlight] {
        if let cached = highlightsByBook[book.id] { return cached }
        let loaded = store.highlights(for: book.id)
        highlightsByBook[book.id] = loaded
        return loaded
    }

    func addHighlight(in book: Book, chapter: Chapter, range: Range<Int>, note: String? = nil) {
        do {
            let highlight = try highlightService.makeHighlight(
                in: book, chapter: chapter, range: range, note: note, createdAt: Date()
            )
            try store.addHighlight(highlight)
            highlightsByBook[book.id] = store.highlights(for: book.id)
        } catch {
            // Empty selection or persistence error — nothing to add.
        }
    }

    func removeHighlight(_ highlight: Highlight, in book: Book) {
        try? store.removeHighlight(id: highlight.id)
        highlightsByBook[book.id] = store.highlights(for: book.id)
    }

    private static func message(for error: BookParserError) -> String {
        switch error {
        case .drmProtected:
            return "This book is DRM-protected. Readr only supports DRM-free books you own."
        case .unsupportedFormat:
            return "Unsupported file type. Readr reads EPUB, PDF, and plain-text/Markdown."
        case .corrupted(let why):
            return "This file couldn't be read (\(why))."
        }
    }
}
