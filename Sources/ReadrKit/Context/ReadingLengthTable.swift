import Foundation

/// Per-chapter character and word counts, in reading order, measured once.
///
/// Three places need to know how long the chapters are — the "Chapter 7 of
/// 24 · 31%" summary, the "~N min left" estimate, and the context router's
/// token estimate for what the reader has read — and each used to walk the
/// text again. `String.count` is a full pass over the text, so a Home screen
/// with a few cards was re-measuring whole books on every refresh. This
/// table is the single pass; the app keeps one per book (`ReadingLengthCache`).
public struct ReadingLengthTable: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// `Chapter.text.count`.
        public var characters: Int
        /// Whitespace-separated words, the unit reading time is estimated in.
        public var words: Int
        /// `Chapter.isLinear != false`.
        public var isLinear: Bool

        public init(characters: Int, words: Int, isLinear: Bool) {
            self.characters = characters
            self.words = words
            self.isLinear = isLinear
        }
    }

    /// One entry per chapter, in reading order.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(book: Book) {
        entries = book.chaptersInReadingOrder.map { chapter in
            Entry(
                characters: chapter.text.count,
                words: ReadingTimeEstimator.wordCount(in: chapter.text),
                isLinear: chapter.isLinear != false
            )
        }
    }

    public var chapterCount: Int { entries.count }

    public var linearChapterCount: Int {
        entries.reduce(0) { $0 + ($1.isLinear ? 1 : 0) }
    }

    /// Characters in linear chapters — the book's length as a reader
    /// experiences it. A notes file reached by a link is not part of it.
    public var totalLinearCharacters: Int {
        entries.reduce(0) { $0 + ($1.isLinear ? $1.characters : 0) }
    }

    /// The reading-order index the frontier resolves to, clamped into the
    /// book, or nil for a book with no chapters.
    private func clampedIndex(_ frontier: ReadingFrontier) -> Int? {
        guard !entries.isEmpty else { return nil }
        return min(max(0, frontier.chapterIndex), entries.count - 1)
    }

    /// Characters into the frontier's chapter, clamped; the whole chapter
    /// when the frontier is past the end of the book.
    public func offset(at frontier: ReadingFrontier) -> Int {
        guard let index = clampedIndex(frontier) else { return 0 }
        let length = entries[index].characters
        if frontier.chapterIndex >= entries.count { return length }
        return min(max(0, frontier.characterOffset), length)
    }

    /// Characters of `textRead(upTo:)`, less the joins: every chapter before
    /// the frontier's, plus the offset into it.
    public func charactersRead(upTo frontier: ReadingFrontier) -> Int {
        guard let index = clampedIndex(frontier) else { return 0 }
        let earlier = entries.prefix(index).reduce(0) { $0 + $1.characters }
        return earlier + offset(at: frontier)
    }

    /// Linear characters behind the reader, for the percent line.
    public func linearCharactersRead(upTo frontier: ReadingFrontier) -> Int {
        guard let index = clampedIndex(frontier) else { return 0 }
        let earlier = entries.prefix(index).reduce(0) { $0 + ($1.isLinear ? $1.characters : 0) }
        return earlier + (entries[index].isLinear ? offset(at: frontier) : 0)
    }
}

public extension Book {
    /// The chapter lengths, measured now. Prefer a `ReadingLengthCache` for
    /// anything that asks more than once.
    var readingLengths: ReadingLengthTable { ReadingLengthTable(book: self) }
}

/// One `ReadingLengthTable` per book, measured on first request and kept.
/// A book's chapters never change after import, so the table is good for
/// the life of the book; `invalidate` is for when the book leaves the library.
public final class ReadingLengthCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [UUID: ReadingLengthTable] = [:]

    public init() {}

    public func table(for book: Book) -> ReadingLengthTable {
        lock.lock()
        let cached = tables[book.id]
        lock.unlock()
        if let cached { return cached }
        let table = ReadingLengthTable(book: book)
        lock.lock()
        tables[book.id] = table
        lock.unlock()
        return table
    }

    public func invalidate(bookID: UUID) {
        lock.lock()
        tables[bookID] = nil
        lock.unlock()
    }
}
