import Foundation

/// One in-book search match, addressable as chapter + character offset so the
/// reader can jump straight to it (the paged anchor lands on the match).
public struct BookSearchResult: Identifiable, Hashable, Sendable {
    /// Position in the result list — stable for a single search, which is all
    /// a results UI needs.
    public let id: Int
    public let chapterIndex: Int
    public let chapterTitle: String?
    /// Character offset of the match within the chapter's text.
    public let characterOffset: Int
    public let snippet: String

    public init(
        id: Int,
        chapterIndex: Int,
        chapterTitle: String?,
        characterOffset: Int,
        snippet: String
    ) {
        self.id = id
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.characterOffset = characterOffset
        self.snippet = snippet
    }
}

/// Case-insensitive full-book text search. Pure so it stays trivially
/// testable; capped because 100 hits is already more than anyone scans in a
/// popover list.
public enum BookSearcher {
    public static let resultCap = 100

    /// All matches in reading order, capped at `limit`.
    ///
    /// Checks `Task.isCancelled` between chapters, so a caller running the
    /// scan inside a task that gets cancelled (e.g. a restarted search
    /// debounce) stops early; such callers must discard the partial results.
    public static func search(_ query: String, in book: Book, limit: Int = resultCap) -> [BookSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var results: [BookSearchResult] = []
        outer: for (chapterIndex, chapter) in book.chapters.enumerated() {
            if Task.isCancelled { break }
            let text = chapter.text
            var searchFrom = text.startIndex
            // Character offset of `searchFrom`, maintained incrementally so
            // each match only measures the gap since the previous one —
            // measuring from `startIndex` every time would rescan the whole
            // chapter per match (quadratic in pathological cases).
            var searchFromOffset = 0
            while searchFrom < text.endIndex,
                  let match = text.range(
                      of: needle, options: [.caseInsensitive], range: searchFrom..<text.endIndex
                  ) {
                let matchOffset = searchFromOffset
                    + text.distance(from: searchFrom, to: match.lowerBound)
                results.append(BookSearchResult(
                    id: results.count,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapter.title,
                    characterOffset: matchOffset,
                    snippet: snippet(around: match, in: text)
                ))
                if results.count >= limit { break outer }
                // The matched range can differ in length from the needle
                // (case-insensitive matching), so measure the match itself.
                searchFromOffset = matchOffset
                    + text.distance(from: match.lowerBound, to: match.upperBound)
                searchFrom = match.upperBound
            }
        }
        return results
    }

    /// A single-line excerpt with a little context on both sides of the match.
    static func snippet(
        around match: Range<String.Index>, in text: String, context: Int = 36
    ) -> String {
        let start = text.index(match.lowerBound, offsetBy: -context, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: context, limitedBy: text.endIndex)
            ?? text.endIndex
        let excerpt = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "")
            + excerpt
            + (end < text.endIndex ? "…" : "")
    }
}
