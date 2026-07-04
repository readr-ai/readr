import Foundation

/// A single rendered page of a chapter.
public struct Page: Sendable, Hashable {
    /// The page's text (never cut mid-word).
    public var text: String
    /// Character range within the chapter's text that this page covers.
    public var range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

/// How pages are laid out in the reader.
public enum PageLayout: String, Sendable, CaseIterable, Codable {
    /// Continuous scrolling (no pagination).
    case scroll
    /// One page at a time.
    case singlePage
    /// Two facing pages, like an open book.
    case doublePage

    /// Pages advanced per "page turn".
    public var pagesPerSpread: Int {
        self == .doublePage ? 2 : 1
    }
}

/// Splits chapter text into fixed-capacity pages on word boundaries.
///
/// Pure and deterministic so it is unit-testable on CI: the view measures its
/// geometry, derives a character capacity, and asks the paginator for pages.
public struct Paginator: Sendable {
    /// Maximum characters per page. The view derives this from font metrics and
    /// available size; the paginator only guarantees no page exceeds it.
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Split `text` into pages. Pages never exceed `capacity` characters and
    /// never cut mid-word (unless a single word exceeds the capacity, in which
    /// case it is hard-wrapped). Ranges are contiguous, ascending, and cover the
    /// whole text.
    public func paginate(_ text: String) -> [Page] {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return [] }
        guard n > capacity else { return [Page(text: text, range: 0..<n)] }

        var pages: [Page] = []
        var start = 0
        var rangeStart = 0 // page range start, covering any folded whitespace
        while start < n {
            // Skip whitespace so every page's text starts on a word; the
            // skipped run stays covered by this page's range (contiguity).
            while start < n, chars[start].isWhitespace { start += 1 }
            if start >= n {
                // Only trailing whitespace remained — fold it into the last page.
                if var last = pages.last {
                    last.range = last.range.lowerBound..<n
                    pages[pages.count - 1] = last
                }
                break
            }

            let hardEnd = min(start + capacity, n)
            var end = hardEnd
            if hardEnd < n && !chars[hardEnd].isWhitespace {
                // Back up to the last whitespace so we don't cut mid-word.
                var i = hardEnd - 1
                while i > start, !chars[i].isWhitespace { i -= 1 }
                // Break after that whitespace; if the whole window is one giant
                // word (no whitespace found), hard-wrap at capacity.
                end = chars[i].isWhitespace ? i + 1 : hardEnd
            }
            pages.append(Page(text: String(chars[start..<end]), range: rangeStart..<end))
            start = end
            rangeStart = end
        }
        return pages
    }

    /// Index of the page containing `offset` (character offset into the chapter
    /// text). Clamps to the last page for out-of-range offsets.
    public static func pageIndex(containing offset: Int, in pages: [Page]) -> Int {
        guard !pages.isEmpty else { return 0 }
        for (index, page) in pages.enumerated() where page.range.contains(offset) {
            return index
        }
        return offset < pages[0].range.lowerBound ? 0 : pages.count - 1
    }

    /// The first page index of the spread containing `pageIndex` for `layout`
    /// (for double-page layout, spreads start on even indices).
    public static func spreadStart(for pageIndex: Int, layout: PageLayout) -> Int {
        guard layout == .doublePage else { return pageIndex }
        return pageIndex - (pageIndex % 2)
    }
}
