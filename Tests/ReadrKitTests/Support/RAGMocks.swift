import Foundation
@testable import ReadrKit

/// Shared M3 test doubles for retrieval-dependent suites.

/// A `RAGIndex` that returns canned passages and records which books were built.
final class StubRAGIndex: RAGIndex, @unchecked Sendable {
    var passages: [RetrievedPassage]
    private let lock = NSLock()
    private var built: Set<UUID> = []
    private(set) var retrieveCallCount = 0
    /// The chapter ceiling of the most recent `retrieve`, so a test can
    /// assert the strategy pushed its scope into the index.
    private(set) var lastMaxChapterIndex: Int??

    init(passages: [RetrievedPassage] = [RetrievedPassage(text: "a relevant passage", locator: "Ch. 1", score: 1.0)]) {
        self.passages = passages
    }

    func build(for book: Book, embeddings: EmbeddingProvider) async throws {
        lock.lock(); built.insert(book.id); lock.unlock()
    }

    /// Filters by the ceiling BEFORE the limit, the way a real index must.
    func retrieve(
        query: String, bookID: UUID, limit: Int, maxChapterIndex: Int?
    ) async throws -> [RetrievedPassage] {
        lock.lock()
        retrieveCallCount += 1
        lastMaxChapterIndex = .some(maxChapterIndex)
        lock.unlock()
        let candidates = passages.filter { passage in
            guard let maxChapterIndex else { return true }
            guard let chapter = passage.chapterIndex else { return false }
            return chapter <= maxChapterIndex
        }
        return Array(candidates.prefix(limit))
    }

    func isBuilt(bookID: UUID) async -> Bool {
        lock.lock(); defer { lock.unlock() }; return built.contains(bookID)
    }
}

/// Deterministic local embedding (no network) for index tests.
final class DeterministicEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let dimensions: Int
    let isLocal = true

    init(dimensions: Int = 16) { self.dimensions = dimensions }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let bucket = abs(token.hashValue) % dimensions
                vector[bucket] += 1
            }
            return vector
        }
    }
}
