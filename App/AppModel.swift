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

    /// Credential storage + the active-LLM selector (used by Settings and, from
    /// M3, by "ask the book").
    let credentialStore: any CredentialStore
    let providerManager: ProviderManager

    init(store: (any LibraryStore)? = nil, parsers: BookParserRegistry? = nil) {
        if store == nil, ProcessInfo.processInfo.arguments.contains("-uiTestSeed") {
            let seeded = InMemoryLibraryStore()
            for book in Self.sampleBooks { try? seeded.add(book) }
            self.store = seeded
        } else {
            self.store = store ?? Self.makeDefaultStore()
        }
        self.parsers = parsers ?? Self.makeDefaultRegistry()
        self.books = self.store.allBooks()

        let credentials = Self.makeCredentialStore()
        self.credentialStore = credentials
        self.providerManager = ProviderManager(
            store: credentials,
            factory: DefaultProviderFactory.factory()
        )
    }

    private static func makeCredentialStore() -> any CredentialStore {
        #if canImport(Security)
        return KeychainCredentialStore()
        #else
        return InMemoryCredentialStore()
        #endif
    }

    /// Deterministic fixtures for UI tests and screenshots (seeded via the
    /// `-uiTestSeed` arg). The first book keeps the titles the UI tests assert
    /// on; the extra books fill the shelf so screenshots look like a library.
    static let sampleBooks: [Book] = {
        let paragraph = """
        It was a bright cold day in April, and the clocks were striking \
        thirteen. Winston Smith, his chin nuzzled into his breast in an effort \
        to escape the vile wind, slipped quickly through the glass doors of \
        Victory Mansions, though not quickly enough to prevent a swirl of \
        gritty dust from entering along with him.
        """
        let chapterOne = (0..<6).map { _ in paragraph }.joined(separator: "\n\n")
        let sample = Book(
            metadata: BookMetadata(title: "Sample Book", authors: ["Test Author"]),
            chapters: [
                Chapter(title: "Chapter One", order: 0, text: chapterOne),
                Chapter(title: "Chapter Two", order: 1, text: "The clocks were striking thirteen.\n\n" + paragraph),
            ],
            estimatedTokenCount: 500
        )
        let voyage = Book(
            metadata: BookMetadata(title: "A Voyage North", authors: ["I. Larsen"]),
            chapters: [Chapter(title: "Departure", order: 0, text: paragraph)],
            estimatedTokenCount: 90
        )
        let letters = Book(
            metadata: BookMetadata(title: "Letters on Design", authors: ["M. Ortiz"]),
            chapters: [Chapter(title: "On Type", order: 0, text: paragraph)],
            estimatedTokenCount: 90
        )
        return [sample, voyage, letters]
    }()

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
            var book = try await parsers.parse(url)
            let bookID = book.id
            let needsCover = book.coverImageData == nil
            // File copy + PDF thumbnail rendering happen OFF the main actor —
            // large books would otherwise freeze the UI right after import.
            // The security scope is still held: we await before returning.
            let assets = await Task.detached(priority: .userInitiated) {
                let retained = try? Self.retainSource(url, for: bookID)
                let cover = needsCover ? Self.pdfCoverThumbnail(for: url) : nil
                return (retained, cover)
            }.value
            book.sourceFilename = assets.0
            if let cover = assets.1 { book.coverImageData = cover }

            // Covers live as files, not inside library.json: the store rewrites
            // its whole JSON on every position save, so embedded image data
            // would make each page turn re-serialize megabytes.
            if let cover = book.coverImageData {
                try? Self.saveCoverFile(cover, for: book.id)
                book.coverImageData = nil
            }
            try store.add(book)
            books = store.allBooks()
        } catch let error as BookParserError {
            importError = Self.message(for: error)
        } catch {
            importError = "Couldn't import this file: \(error.localizedDescription)"
        }
    }

    // MARK: Covers

    private let coverCache = NSCache<NSUUID, PlatformImage>()

    nonisolated static func coversDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Readr/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func saveCoverFile(_ data: Data, for bookID: UUID) throws {
        let url = try coversDirectory().appendingPathComponent("\(bookID.uuidString).img")
        try data.write(to: url, options: .atomic)
    }

    /// Decoded cover artwork, cached so shelf scrolling doesn't re-decode PNGs
    /// on every cell render. Sources: in-memory data (seeded books) or the
    /// cover file written at import.
    func coverImage(for book: Book) -> PlatformImage? {
        if let cached = coverCache.object(forKey: book.id as NSUUID) { return cached }
        var data = book.coverImageData
        if data == nil,
           let url = try? Self.coversDirectory()
               .appendingPathComponent("\(book.id.uuidString).img"),
           FileManager.default.fileExists(atPath: url.path) {
            data = try? Data(contentsOf: url)
        }
        guard let data, let image = PlatformImage(data: data) else { return nil }
        coverCache.setObject(image, forKey: book.id as NSUUID)
        return image
    }

    /// Copy the imported file into the app's Books directory as `<id>.<ext>`.
    nonisolated static func retainSource(_ url: URL, for bookID: UUID) throws -> String {
        let dir = try booksDirectory()
        let filename = "\(bookID.uuidString).\(url.pathExtension.lowercased())"
        let destination = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return filename
    }

    nonisolated static func booksDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Readr/Books", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute URL of a book's retained source file, if any.
    func sourceURL(for book: Book) -> URL? {
        guard let filename = book.sourceFilename,
              let dir = try? Self.booksDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// First-page thumbnail for PDFs (nil for other formats).
    nonisolated private static func pdfCoverThumbnail(for url: URL) -> Data? {
        #if canImport(PDFKit)
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        return PDFCoverRenderer.firstPageThumbnail(url: url)
        #else
        return nil
        #endif
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

    // MARK: Ask the book (M3)

    private let ragIndex = HybridRAGIndex()
    private let embeddings = LocalEmbeddingProvider()

    /// An `AskService` bound to the active provider, or nil if none is configured.
    func makeAskService() -> AskService? {
        guard let provider = activeProvider() else { return nil }
        return AskService(strategy: AdaptiveContextStrategy(index: ragIndex), provider: provider)
    }

    /// The active LLM provider, or nil if none is configured.
    func activeProvider() -> LLMProvider? {
        try? providerManager.activeProvider()
    }

    /// Build the retrieval index for a book if it hasn't been built yet. Cheap to
    /// call repeatedly; the index is reused across questions.
    func ensureIndexed(_ book: Book) async {
        if await ragIndex.isBuilt(bookID: book.id) { return }
        try? await ragIndex.build(for: book, embeddings: embeddings)
    }

    /// Build a `Selection` (quote + surrounding context) from a character range.
    func makeSelection(in chapter: Chapter, range: Range<Int>) -> Selection {
        let characters = Array(chapter.text)
        let lower = max(0, range.lowerBound)
        let upper = min(characters.count, range.upperBound)
        let quoted = lower < upper ? String(characters[lower..<upper]) : ""
        let contextLower = max(0, lower - 240)
        let contextUpper = min(characters.count, upper + 240)
        let surrounding = String(characters[contextLower..<contextUpper])
        return Selection(
            chapterID: chapter.id,
            quotedText: quoted,
            surroundingText: surrounding,
            chapterTitle: chapter.title
        )
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
