import Foundation

/// Where the reader is, in the words a reader would use:
/// "Chapter 7 of 24 · 31% · The Whale".
///
/// The line under a Recap. A recap that stops "where you stopped" should say
/// where that is, so the reader can tell at a glance that the answer covers
/// the right stretch of the book — and the Continue Reading card can say the
/// same thing before the book is even open.
///
/// Chapters are counted in reading order and linear chapters only: a notes
/// file the reader follows a link into is not a chapter they are "on", and
/// its text is not part of the book's length. Progress is measured in
/// characters, the unit the frontier is in.
public struct ReadingPositionSummary: Sendable, Hashable {
    /// The chapter's own title, else the nearest table-of-contents title at
    /// or before it, else "Chapter N" (see `titleIsFallback`).
    public var chapterTitle: String
    /// 1-based, among linear chapters.
    public var chapterNumber: Int
    /// Linear chapters in the book.
    public var chapterCount: Int
    /// Characters read over the book's characters, 0–100.
    public var percent: Int
    /// True when `chapterTitle` is the synthetic "Chapter N" — the caption
    /// leaves it out then, rather than saying "Chapter 2 of 4 · Chapter 2".
    public var titleIsFallback: Bool

    /// "Chapter 7 of 24".
    public var chapterLine: String {
        "Chapter \(chapterNumber) of \(chapterCount)"
    }

    /// "Chapter 7 of 24 · 31% · The Whale" — without the title when the
    /// title would only repeat the chapter number.
    public var caption: String {
        var parts = [chapterLine, "\(percent)%"]
        if !titleIsFallback { parts.append(chapterTitle) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Nil for a book with no linear chapters: there is nothing to be
    /// partway through.
    public init?(book: Book, frontier: ReadingFrontier) {
        let ordered = book.chaptersInReadingOrder
        let linear = ordered.filter(Self.isLinear)
        guard !ordered.isEmpty, !linear.isEmpty else { return nil }

        // Clamp the frontier into the book. Past the last chapter means the
        // book is finished — every character of the last chapter is behind
        // the reader, whatever the offset says.
        let lastIndex = ordered.count - 1
        let pastTheEnd = frontier.chapterIndex > lastIndex
        let index = min(max(frontier.chapterIndex, 0), lastIndex)
        let current = ordered[index]
        let currentLength = current.text.count
        let offset = pastTheEnd
            ? currentLength
            : min(max(frontier.characterOffset, 0), currentLength)

        // The chapter the reader is "on": the current one when it is linear,
        // otherwise the last linear chapter before it — they followed a link
        // out of that chapter and will come back to it. Standing in a notes
        // file before any linear chapter counts as being on the first.
        let namedIndex = Self.isLinear(current)
            ? index
            : (ordered.prefix(index).lastIndex(where: Self.isLinear) ?? ordered.firstIndex(where: Self.isLinear)!)
        let named = ordered[namedIndex]
        chapterNumber = ordered.prefix(namedIndex + 1).filter(Self.isLinear).count
        chapterCount = linear.count

        let ownTitle = named.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ownTitle.isEmpty {
            chapterTitle = ownTitle
            titleIsFallback = false
        } else if let tocTitle = Self.tocTitle(in: book, atOrBefore: namedIndex) {
            chapterTitle = tocTitle
            titleIsFallback = false
        } else {
            chapterTitle = "Chapter \(chapterNumber)"
            titleIsFallback = true
        }

        let totalCharacters = linear.reduce(0) { $0 + $1.text.count }
        let fraction: Double
        if totalCharacters > 0 {
            var read = ordered.prefix(index).filter(Self.isLinear).reduce(0) { $0 + $1.text.count }
            if Self.isLinear(current) { read += offset }
            fraction = Double(read) / Double(totalCharacters)
        } else if pastTheEnd {
            fraction = 1
        } else {
            // A book with no text at all (a picture book): whole chapters are
            // the only thing there is to count.
            let behind = ordered.prefix(index).filter(Self.isLinear).count
            fraction = Double(behind) / Double(linear.count)
        }
        percent = min(100, max(0, Int((fraction * 100).rounded())))
    }

    /// The saved position is the frontier by definition.
    public init?(book: Book, position: ReadingPosition) {
        self.init(book: book, frontier: ReadingFrontier(position))
    }

    private static func isLinear(_ chapter: Chapter) -> Bool {
        chapter.isLinear != false
    }

    /// The nearest table-of-contents title at or before a reading-order
    /// chapter index — a spine document without a title of its own belongs
    /// to the section that precedes it. Entries are walked in document
    /// order, children after their parent, so the deepest entry that still
    /// precedes the chapter wins.
    private static func tocTitle(in book: Book, atOrBefore index: Int) -> String? {
        var best: String?
        func walk(_ entries: [TOCEntry]) {
            for entry in entries {
                if entry.chapterIndex <= index {
                    let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { best = title }
                }
                walk(entry.children)
            }
        }
        walk(book.metadata.tableOfContents)
        return best
    }
}
