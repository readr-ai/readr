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
    func retrieve(query: String, bookID: UUID, limit: Int) async throws -> [RetrievedPassage]

    /// Whether an index already exists for this book.
    func isBuilt(bookID: UUID) async -> Bool
}

/// Produces embeddings — hosted or on-device (MLX) for the privacy mode.
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var isLocal: Bool { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
