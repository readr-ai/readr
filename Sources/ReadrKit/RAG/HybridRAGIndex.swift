import Foundation

/// In-memory hybrid (vector + BM25) retrieval index implementing
/// Anthropic-style Contextual Retrieval.
///
/// SQLite/`sqlite-vec` persistence is a later milestone; this implementation
/// keeps everything in memory, guarded by an `NSLock` for thread safety.
public final class HybridRAGIndex: RAGIndex, @unchecked Sendable {

    /// Everything stored for a single book.
    private struct BookIndex {
        var chunks: [Chunk]
        /// Contextual embedding vector per chunk (parallel to `chunks`).
        var vectors: [[Float]]
        /// Per-chunk term-frequency multiset over the contextual text.
        var termCounts: [[String: Int]]
        /// Per-chunk token length (sum of term frequencies).
        var docLengths: [Int]
        /// Document frequency: number of chunks containing each term.
        var documentFrequency: [String: Int]
        /// Average document length across all chunks.
        var averageDocLength: Double
        /// The provider used to embed this book — reused to embed its queries so
        /// build-time and query-time embeddings always share a vector space.
        var provider: EmbeddingProvider
    }

    private let chunker: Chunker
    private let lock = NSLock()
    private var indexes: [UUID: BookIndex] = [:]

    // BM25 parameters.
    private let k1: Double = 1.5
    private let b: Double = 0.75

    public init(chunker: Chunker = Chunker()) {
        self.chunker = chunker
    }

    // MARK: - RAGIndex

    public func build(for book: Book, embeddings: EmbeddingProvider) async throws {
        let chunks = chunker.chunk(book)

        // Embed the *contextual* text of each chunk (situating prefix included).
        let contextualTexts = chunks.map { chunker.contextualText(for: $0, in: book) }
        let vectors = chunks.isEmpty ? [] : try await embeddings.embed(contextualTexts)

        // Lexical bookkeeping is also over the contextual text so prefixes
        // (book title / chapter) contribute to BM25 just like vector search.
        var termCounts: [[String: Int]] = []
        var docLengths: [Int] = []
        var documentFrequency: [String: Int] = [:]

        for contextual in contextualTexts {
            let tokens = LocalEmbeddingProvider.tokenize(contextual)
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            termCounts.append(counts)
            docLengths.append(tokens.count)
            for term in counts.keys { documentFrequency[term, default: 0] += 1 }
        }

        let totalLength = docLengths.reduce(0, +)
        let averageDocLength = chunks.isEmpty ? 0 : Double(totalLength) / Double(chunks.count)

        let entry = BookIndex(
            chunks: chunks,
            vectors: vectors,
            termCounts: termCounts,
            docLengths: docLengths,
            documentFrequency: documentFrequency,
            averageDocLength: averageDocLength,
            provider: embeddings
        )

        lock.lock()
        indexes[book.id] = entry  // Idempotent: rebuild replaces prior state.
        lock.unlock()
    }

    public func retrieve(query: String, bookID: UUID, limit: Int) async throws -> [RetrievedPassage] {
        lock.lock()
        let entry = indexes[bookID]
        lock.unlock()

        guard let entry, !entry.chunks.isEmpty, limit > 0 else { return [] }

        // Vector score: cosine of query embedding vs each chunk embedding, using
        // the same provider that built this book (matching vector spaces).
        let queryVectors = try await entry.provider.embed([query])
        let queryVector = queryVectors.first ?? []

        let count = entry.chunks.count
        var vectorScores = [Double](repeating: 0, count: count)
        for idx in 0..<count {
            let sim = LocalEmbeddingProvider.cosineSimilarity(queryVector, entry.vectors[idx])
            vectorScores[idx] = Double(sim)
        }

        // BM25 lexical score over query terms.
        let queryTerms = LocalEmbeddingProvider.tokenize(query)
        var bm25Scores = [Double](repeating: 0, count: count)
        let n = Double(count)
        for term in Set(queryTerms) {
            let df = Double(entry.documentFrequency[term] ?? 0)
            guard df > 0 else { continue }
            let idf = log((n - df + 0.5) / (df + 0.5) + 1)
            for idx in 0..<count {
                let tf = Double(entry.termCounts[idx][term] ?? 0)
                guard tf > 0 else { continue }
                let denom = tf + k1 * (1 - b + b * Double(entry.docLengths[idx]) / max(entry.averageDocLength, 1e-9))
                bm25Scores[idx] += idf * (tf * (k1 + 1)) / denom
            }
        }

        // Min-max normalize each signal across candidates, then fuse 50/50.
        let normVector = Self.minMaxNormalize(vectorScores)
        let normBM25 = Self.minMaxNormalize(bm25Scores)

        var ranked: [(index: Int, score: Double)] = []
        ranked.reserveCapacity(count)
        for idx in 0..<count {
            let combined = 0.5 * normVector[idx] + 0.5 * normBM25[idx]
            ranked.append((idx, combined))
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index  // Stable tie-break for determinism.
        }

        return ranked.prefix(limit).map { item in
            let chunk = entry.chunks[item.index]
            return RetrievedPassage(text: chunk.text, locator: chunk.locator, score: item.score)
        }
    }

    /// Whether the book was built. Presence-based (not chunk-count based) so a
    /// book that legitimately yields zero chunks isn't rebuilt on every query.
    public func isBuilt(bookID: UUID) async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexes[bookID] != nil
    }

    // MARK: - Internals

    static func minMaxNormalize(_ values: [Double]) -> [Double] {
        guard let minValue = values.min(), let maxValue = values.max() else {
            return values
        }
        let range = maxValue - minValue
        guard range > 0 else {
            // All equal: a present signal (non-zero) is uniformly relevant (1);
            // an absent signal (all zero) contributes nothing (0). Avoids zeroing
            // the score of a sole/tied perfect match.
            let value = maxValue > 0 ? 1.0 : 0.0
            return [Double](repeating: value, count: values.count)
        }
        return values.map { ($0 - minValue) / range }
    }
}
