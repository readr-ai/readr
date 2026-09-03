import Foundation

/// Where the reader is, in the words a reader would use:
/// "Chapter 7 of 24 · 31% · The Whale".
///
/// The line under a Recap. A recap that stops "where you stopped" should say
/// where that is, so the reader can tell at a glance that the answer covers
/// the right stretch of the book — and the Continue Reading card can say the
/// same thing before the book is even open. The context router puts the same
/// line in front of the model, so the panel and the prompt never disagree.
///
/// Chapters are counted in reading order and linear chapters only: a notes
/// file the reader follows a link into is not a chapter they are "on", and
/// its text is not part of the book's length. Progress is measured in
/// characters, the unit the frontier is in, from a `ReadingLengthTable` so
/// the text is not walked again for every card.
public struct ReadingPositionSummary: Sendable, Hashable {
    /// The chapter's own title, else the nearest table-of-contents title at
    /// or before it, else "Chapter N" (see `titleIsFallback`). The same
    /// lookup the reader header and Contents use — `Book.chapterTitle`.
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

    /// Measures the book now. Prefer the `lengths:` form with a cached table
    /// when the summary is built more than once for the same book.
    public init?(book: Book, frontier: ReadingFrontier) {
        self.init(book: book, frontier: frontier, lengths: book.readingLengths)
    }

    /// Nil for a book with no linear chapters: there is nothing to be
    /// partway through. `lengths` must be the table for `book`.
    public init?(book: Book, frontier: ReadingFrontier, lengths: ReadingLengthTable) {
        let entries = lengths.entries
        guard !entries.isEmpty, entries.contains(where: \.isLinear) else { return nil }

        // Clamp the frontier into the book. Past the last chapter means the
        // book is finished — every character of the last chapter is behind
        // the reader, whatever the offset says.
        let lastIndex = entries.count - 1
        let pastTheEnd = frontier.chapterIndex > lastIndex
        let index = min(max(frontier.chapterIndex, 0), lastIndex)
        let current = entries[index]

        // The chapter the reader is "on": the current one when it is linear,
        // otherwise the last linear chapter before it — they followed a link
        // out of that chapter and will come back to it. Standing in a notes
        // file before any linear chapter counts as being on the first.
        let namedIndex: Int
        if current.isLinear {
            namedIndex = index
        } else if let before = entries[..<index].lastIndex(where: \.isLinear) {
            namedIndex = before
        } else {
            namedIndex = entries.firstIndex(where: \.isLinear) ?? 0
        }
        chapterNumber = entries[...namedIndex].reduce(0) { $0 + ($1.isLinear ? 1 : 0) }
        chapterCount = lengths.linearChapterCount

        if let title = book.chapterTitle(forChapterIndex: namedIndex) {
            chapterTitle = title
            titleIsFallback = false
        } else {
            chapterTitle = Book.fallbackChapterTitle(number: chapterNumber)
            titleIsFallback = true
        }

        let totalCharacters = lengths.totalLinearCharacters
        let fraction: Double
        if totalCharacters > 0 {
            let read = lengths.linearCharactersRead(upTo: frontier)
            fraction = Double(read) / Double(totalCharacters)
        } else if pastTheEnd {
            fraction = 1
        } else {
            // A book with no text at all (a picture book): whole chapters are
            // the only thing there is to count.
            let behind = entries[..<index].reduce(0) { $0 + ($1.isLinear ? 1 : 0) }
            fraction = Double(behind) / Double(chapterCount)
        }
        percent = min(100, max(0, Int((fraction * 100).rounded())))
    }

    /// The saved position is the frontier by definition.
    public init?(book: Book, position: ReadingPosition) {
        self.init(book: book, frontier: ReadingFrontier(position))
    }

    /// The saved position, measured from a cached table.
    public init?(book: Book, position: ReadingPosition, lengths: ReadingLengthTable) {
        self.init(book: book, frontier: ReadingFrontier(position), lengths: lengths)
    }
}
