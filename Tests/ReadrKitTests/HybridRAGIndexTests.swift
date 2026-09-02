import XCTest
@testable import ReadrKit

final class HybridRAGIndexTests: XCTestCase {

    private func makeDogsAndSpaceBook() -> Book {
        let dogText = """
        The puppy ran across the yard chasing a ball. Dogs love to play fetch \
        with their owners. A loyal puppy will follow you everywhere, wagging its \
        tail. Puppies need training, walks on a leash, and plenty of belly rubs. \
        Many breeds of dog are friendly companions for families.
        """
        let spaceText = """
        The planets orbit the sun in elliptical paths through space. Astronomers \
        study distant galaxies and nebulae with powerful telescopes. A comet's \
        tail points away from the sun. Mars and Jupiter are planets in our solar \
        system, surrounded by the vast emptiness of outer space.
        """
        let ch1 = Chapter(title: "Dogs", order: 0, text: dogText)
        let ch2 = Chapter(title: "Space", order: 1, text: spaceText)
        return Book(
            metadata: BookMetadata(title: "Animals and the Cosmos"),
            chapters: [ch1, ch2],
            estimatedTokenCount: 0
        )
    }

    func testRetrieveRanksRelevantChapterFirst() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let results = try await index.retrieve(query: "puppy", bookID: book.id, limit: 2)
        XCTAssertFalse(results.isEmpty)

        let top = try XCTUnwrap(results.first)
        XCTAssertTrue(
            top.locator.contains("Dogs"),
            "A puppy query should rank the dogs chapter first, got: \(top.locator)"
        )
    }

    func testRetrieveSpaceQueryRanksSpaceChapterFirst() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let results = try await index.retrieve(query: "planets orbiting the sun", bookID: book.id, limit: 2)
        let top = try XCTUnwrap(results.first)
        XCTAssertTrue(top.locator.contains("Space"), "Got: \(top.locator)")
    }

    func testRetrieveOnUnbuiltBookReturnsEmpty() async throws {
        let index = HybridRAGIndex()
        let results = try await index.retrieve(query: "anything", bookID: UUID(), limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testIsBuiltReflectsBuild() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()

        let before = await index.isBuilt(bookID: book.id)
        XCTAssertFalse(before)

        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let after = await index.isBuilt(bookID: book.id)
        XCTAssertTrue(after)

        let other = await index.isBuilt(bookID: UUID())
        XCTAssertFalse(other)
    }

    func testRetrieveRespectsLimit() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let results = try await index.retrieve(query: "puppy dog space planet", bookID: book.id, limit: 1)
        XCTAssertEqual(results.count, 1)
    }

    func testBuildIsIdempotent() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())
        let first = try await index.retrieve(query: "puppy", bookID: book.id, limit: 2)

        // Rebuild; results should remain consistent and not duplicate.
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())
        let second = try await index.retrieve(query: "puppy", bookID: book.id, limit: 2)

        XCTAssertEqual(first.map(\.locator), second.map(\.locator))
    }

    /// The frontier filter in `AdaptiveContextStrategy` can only withhold a
    /// passage it can place. The index must say which chapter each one came
    /// from, in reading order.
    func testRetrievedPassagesCarryTheirChapterIndex() async throws {
        let book = makeDogsAndSpaceBook()
        let index = HybridRAGIndex()
        try await index.build(for: book, embeddings: LocalEmbeddingProvider())

        let dogResults = try await index.retrieve(query: "puppy", bookID: book.id, limit: 1)
        let spaceResults = try await index.retrieve(query: "planets", bookID: book.id, limit: 1)
        let dogs = try XCTUnwrap(dogResults.first)
        let space = try XCTUnwrap(spaceResults.first)
        XCTAssertEqual(dogs.chapterIndex, 0)
        XCTAssertEqual(space.chapterIndex, 1)
    }
}
