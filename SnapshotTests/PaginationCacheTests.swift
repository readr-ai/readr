import XCTest
import ReadrKit
@testable import Readr

/// The paged reader memoizes its pagination, because re-paginating a chapter
/// is the single most expensive thing the reading surface does. These tests
/// pin the cache's retention contract.
@MainActor
final class PaginationCacheTests: XCTestCase {

    private let chapter = UUID()
    private let other = UUID()

    private func page(_ text: String) -> ReadrKit.Page {
        ReadrKit.Page(text: text, range: 0..<text.count)
    }

    func testStoredPaginationIsReturnedForTheSameKey() {
        let cache = PaginationCache()
        cache.store(chapterID: chapter, key: "a", pages: [page("one")], remainingWords: [1])
        let hit = cache.entry(chapterID: chapter, key: "a")
        XCTAssertEqual(hit?.pages.map(\.text), ["one"])
        XCTAssertEqual(hit?.remainingWords, [1])
    }

    func testMissOnDifferentKeyOrChapter() {
        let cache = PaginationCache()
        cache.store(chapterID: chapter, key: "a", pages: [page("one")], remainingWords: [1])
        XCTAssertNil(cache.entry(chapterID: chapter, key: "b"))
        XCTAssertNil(cache.entry(chapterID: other, key: "a"))
    }

    /// THE regression. Tapping the page toggles the reader's chrome, which
    /// hides the nav/bottom/status bars and so changes the reading surface's
    /// height — a different pagination key. A single-slot cache made the two
    /// chrome states evict each other, so EVERY tap re-paginated the whole
    /// chapter: measured at 3.8 s and 4.7 s alternating, on the main thread,
    /// on a 306 KB chapter. Both states must stay resident.
    func testBothChromeStatesStayCached() {
        let cache = PaginationCache()
        let chromeShown = "354x598|18.0|newYork|normal|true|singlePage|false|[]|0"
        let chromeHidden = "354x704|18.0|newYork|normal|true|singlePage|false|[]|0"

        cache.store(chapterID: chapter, key: chromeShown, pages: [page("shown")], remainingWords: [1])
        cache.store(chapterID: chapter, key: chromeHidden, pages: [page("hidden")], remainingWords: [1])

        // Toggle back and forth: neither state may ever miss again.
        for _ in 0..<10 {
            XCTAssertEqual(
                cache.entry(chapterID: chapter, key: chromeShown)?.pages.map(\.text), ["shown"],
                "Chrome-shown pagination was evicted — every page tap re-paginates"
            )
            XCTAssertEqual(
                cache.entry(chapterID: chapter, key: chromeHidden)?.pages.map(\.text), ["hidden"],
                "Chrome-hidden pagination was evicted — every page tap re-paginates"
            )
        }
    }

    /// The cache is unbounded-input (every font size, every rotation, every
    /// chapter) so it must not grow without limit — a novel's worth of
    /// paginations is real memory. Oldest-used entries go first.
    func testCacheEvictsLeastRecentlyUsedBeyondCapacity() {
        let cache = PaginationCache(capacity: 2)
        cache.store(chapterID: chapter, key: "a", pages: [page("a")], remainingWords: [1])
        cache.store(chapterID: chapter, key: "b", pages: [page("b")], remainingWords: [1])
        _ = cache.entry(chapterID: chapter, key: "a") // "a" is now most recent
        cache.store(chapterID: chapter, key: "c", pages: [page("c")], remainingWords: [1])

        XCTAssertNotNil(cache.entry(chapterID: chapter, key: "a"), "recently used survives")
        XCTAssertNotNil(cache.entry(chapterID: chapter, key: "c"), "newest survives")
        XCTAssertNil(cache.entry(chapterID: chapter, key: "b"), "least recently used is evicted")
    }
}
