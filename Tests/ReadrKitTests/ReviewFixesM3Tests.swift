import XCTest
@testable import ReadrKit

/// Regression tests for issues found reviewing the M3 (ask-the-book) code.
final class ReviewFixesM3Tests: XCTestCase {

    // MARK: Chunker — chapterIndex follows reading order, not array order

    func testChapterIndexFollowsReadingOrderWhenChaptersAreStoredOutOfOrder() {
        let beta = Chapter(title: "Beta", order: 1, text: String(repeating: "beta ", count: 10))
        let alpha = Chapter(title: "Alpha", order: 0, text: String(repeating: "alpha ", count: 10))
        // Stored out of reading order on purpose.
        let book = Book(
            metadata: BookMetadata(title: "T"),
            chapters: [beta, alpha],
            estimatedTokenCount: 0
        )

        let chunks = Chunker().chunk(book)
        let alphaChunk = chunks.first { $0.text.contains("alpha") }
        let betaChunk = chunks.first { $0.text.contains("beta") }

        XCTAssertEqual(alphaChunk?.chapterIndex, 0)
        XCTAssertEqual(alphaChunk?.locator, "Ch. 1 (Alpha)")
        XCTAssertEqual(betaChunk?.chapterIndex, 1)
        XCTAssertEqual(betaChunk?.locator, "Ch. 2 (Beta)")
    }

    // MARK: HybridRAGIndex — isBuilt is presence-based

    func testIsBuiltIsTrueForBookThatYieldsNoChunks() async throws {
        let book = Book(
            metadata: BookMetadata(title: "Empty"),
            chapters: [Chapter(title: nil, order: 0, text: "")],
            estimatedTokenCount: 0
        )
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        // Built, even though there are no chunks (so it isn't rebuilt every ask).
        let built = await index.isBuilt(bookID: book.id)
        XCTAssertTrue(built)

        let results = try await index.retrieve(query: "anything", bookID: book.id, limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: HybridRAGIndex.minMaxNormalize — sole/tied candidates

    func testMinMaxNormalizePresentSignalAllEqualBecomesOne() {
        XCTAssertEqual(HybridRAGIndex.minMaxNormalize([5, 5, 5]), [1, 1, 1])
        XCTAssertEqual(HybridRAGIndex.minMaxNormalize([0.3]), [1])
    }

    func testMinMaxNormalizeAbsentSignalStaysZero() {
        XCTAssertEqual(HybridRAGIndex.minMaxNormalize([0, 0, 0]), [0, 0, 0])
    }

    func testMinMaxNormalizeNormalRange() {
        XCTAssertEqual(HybridRAGIndex.minMaxNormalize([0, 5, 10]), [0, 0.5, 1])
    }

    func testSingleChunkBookGivesNonZeroScore() async throws {
        let book = Book(
            metadata: BookMetadata(title: "Tiny"),
            chapters: [Chapter(title: "One", order: 0, text: "Puppies love to play fetch.")],
            estimatedTokenCount: 0
        )
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())
        let results = try await index.retrieve(query: "puppies", bookID: book.id, limit: 1)
        let top = try XCTUnwrap(results.first)
        XCTAssertGreaterThan(top.score, 0, "A sole matching chunk should not score 0")
    }
}
