import Foundation
import ReadrKit

/// App-level state for M1: the library and book import. AI features (ask,
/// article) attach to this in later milestones.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var importError: String?

    private let store: any LibraryStore
    private let parsers: BookParserRegistry

    init(
        store: any LibraryStore = InMemoryLibraryStore(),
        parsers: BookParserRegistry = .standard
    ) {
        self.store = store
        self.parsers = parsers
        self.books = store.allBooks()
    }

    func importBook(at url: URL) async {
        // Security-scoped access is needed for files chosen via the importer.
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

    func position(for book: Book) -> ReadingPosition? {
        store.position(for: book.id)
    }

    func savePosition(_ position: ReadingPosition, for book: Book) {
        try? store.savePosition(position, for: book.id)
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
