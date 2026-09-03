import Foundation

/// A retrievable passage from the book's hybrid index.
public struct RetrievedPassage: Sendable, Hashable {
    public var text: String
    /// Human-readable position, e.g. "Ch. 4 ¶12".
    public var locator: String
    public var score: Double
    /// Reading-order chapter the passage came from, when the index knows it.
    /// Lets `ReadingFrontier` keep passages the reader hasn't reached out of
    /// the prompt. Nil is treated as unknown — and withheld — when a frontier
    /// is in force.
    public var chapterIndex: Int?

    public init(text: String, locator: String, score: Double, chapterIndex: Int? = nil) {
        self.text = text
        self.locator = locator
        self.score = score
        self.chapterIndex = chapterIndex
    }
}

/// Builds and queries the on-device contextual-retrieval index for a book.
///
/// Default implementation (forthcoming) uses SQLite with `sqlite-vec` for
/// vector search and FTS5 for BM25, fuses the two, and reranks — i.e.
/// Anthropic-style Contextual Retrieval. See docs/CONTEXT-STRATEGY.md.
public protocol RAGIndex: Sendable {
    /// Chunk, contextualize, embed, and persist the book. Idempotent per book.
    func build(for book: Book, embeddings: EmbeddingProvider) async throws

    /// Hybrid (vector + BM25) retrieval with reranking.
    ///
    /// - Parameter maxChapterIndex: when set, only passages from reading-order
    ///   chapters at or before it are candidates, and passages whose chapter
    ///   is unknown are left out. Applied BEFORE `limit`, so a question scoped
    ///   to what the reader has read still comes back with `limit` usable
    ///   passages rather than a handful of survivors. Nil means the whole book.
    ///   This is the spoiler boundary on the retrieval tier: the context
    ///   strategy does not filter again, so a conforming index must honor it.
    func retrieve(
        query: String, bookID: UUID, limit: Int, maxChapterIndex: Int?
    ) async throws -> [RetrievedPassage]

    /// Whether an index already exists for this book.
    func isBuilt(bookID: UUID) async -> Bool
}

public extension RAGIndex {
    /// Whole-book retrieval: no chapter ceiling.
    func retrieve(query: String, bookID: UUID, limit: Int) async throws -> [RetrievedPassage] {
        try await retrieve(query: query, bookID: bookID, limit: limit, maxChapterIndex: nil)
    }
}

/// Produces embeddings — hosted or on-device (MLX) for the privacy mode.
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var isLocal: Bool { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
