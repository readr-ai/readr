import Foundation
import ReadrKit

/// Memoizes the paged reader's pagination.
///
/// Re-paginating is the most expensive thing the reading surface does, so a
/// miss is not merely slow — on a novel-sized chapter it is seconds of blocked
/// main thread. It holds SEVERAL entries on purpose: a single slot looks
/// sufficient (one chapter is on screen at a time) but thrashes, because
/// tapping the page toggles the reader's chrome, which hides the nav/bottom/
/// status bars and changes the surface's height — a different key. With one
/// slot the two chrome states evicted each other and EVERY tap re-paginated
/// the whole chapter.
///
/// Reference type on purpose: mutating it during a `body` evaluation must not
/// invalidate the view.
final class PaginationCache {
    struct Entry {
        let pages: [Page]
        /// Words from the start of each page to the chapter's end, index-
        /// aligned with `pages`, so the page bar never re-scans the chapter.
        let remainingWords: [Int]
    }

    private struct Key: Hashable {
        let chapterID: UUID
        let signature: String
    }

    /// Entries live at the same geometry/style for a chapter, so the working
    /// set is tiny: the two chrome states, plus headroom for a rotation or a
    /// font-size step mid-read. Bounded because the key space is not — every
    /// text size, orientation and chapter mints a new one, and a novel's worth
    /// of retained paginations is real memory.
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    /// Least-recently-used first.
    private var order: [Key] = []

    /// The most recently read or written entry — the pagination `body` is
    /// currently rendering, which the page bar reads its word counts from.
    private(set) var current: Entry?

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    func entry(chapterID: UUID, key: String) -> Entry? {
        let key = Key(chapterID: chapterID, signature: key)
        guard let hit = entries[key] else { return nil }
        touch(key)
        current = hit
        return hit
    }

    func store(chapterID: UUID, key: String, pages: [Page], remainingWords: [Int]) {
        let key = Key(chapterID: chapterID, signature: key)
        let entry = Entry(pages: pages, remainingWords: remainingWords)
        entries[key] = entry
        touch(key)
        current = entry
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    private func touch(_ key: Key) {
        if let existing = order.firstIndex(of: key) { order.remove(at: existing) }
        order.append(key)
    }
}
