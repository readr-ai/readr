import Foundation

/// A contiguous span of text from a single chapter, ready to embed and index.
public struct Chunk: Sendable, Hashable {
    /// The raw chunk text (no situating prefix).
    public var text: String
    /// Human-readable position, e.g. `Ch. 3 (Chapter Title)`.
    public var locator: String
    /// Zero-based index into `Book.chapters` (sorted by reading order).
    public var chapterIndex: Int
    /// Where this chunk starts in `Chapter.text`, as a character offset — the
    /// splitter knows where it cut, and a citation that can't be pointed at
    /// is only prose. Optional so a chunk assembled by hand (a test, a
    /// synthetic passage) need not invent one.
    public var characterOffset: Int?

    public init(text: String, locator: String, chapterIndex: Int, characterOffset: Int? = nil) {
        self.text = text
        self.locator = locator
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }
}

/// Splits a `Book` into chapter-aware, overlapping chunks suitable for
/// Anthropic-style Contextual Retrieval.
public struct Chunker {
    /// Approximate target size of each chunk in characters.
    public let targetCharacters: Int
    /// Number of characters of overlap carried between adjacent chunks.
    public let overlapCharacters: Int

    public init(targetCharacters: Int = 1200, overlapCharacters: Int = 200) {
        // Defensive clamping: overlap must be smaller than the window so we
        // always make forward progress.
        self.targetCharacters = max(1, targetCharacters)
        self.overlapCharacters = max(0, min(overlapCharacters, max(0, targetCharacters - 1)))
    }

    /// Chunk every chapter independently — chunks never span chapter boundaries.
    public func chunk(_ book: Book) -> [Chunk] {
        var result: [Chunk] = []
        // Enumerate AFTER sorting so `chapterIndex` is the reading-order position,
        // matching the doc, even when `book.chapters` is stored out of order.
        let ordered = book.chapters.sorted { $0.order < $1.order }

        for (chapterIndex, chapter) in ordered.enumerated() {
            let locator = Self.locator(for: chapter)
            for piece in splitChapter(chapter.text) {
                result.append(
                    Chunk(
                        text: piece.text, locator: locator, chapterIndex: chapterIndex,
                        characterOffset: piece.offset
                    )
                )
            }
        }
        return result
    }

    /// The text actually embedded/indexed: a short situating prefix followed by
    /// the raw chunk text (contextual embeddings).
    public func contextualText(for chunk: Chunk, in book: Book) -> String {
        "From \"\(book.metadata.title)\", \(chunk.locator):\n\(chunk.text)"
    }

    // MARK: - Locator

    static func locator(for chapter: Chapter) -> String {
        let number = chapter.order + 1
        if let title = chapter.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Ch. \(number) (\(title))"
        }
        return "Ch. \(number)"
    }

    // MARK: - Splitting

    /// One window of a chapter, and where it begins in that chapter's text.
    struct Piece: Equatable {
        var text: String
        var offset: Int
    }

    /// Split a single chapter's text into overlapping windows, preferring
    /// paragraph then sentence then word boundaries, never cutting mid-word.
    ///
    /// The window walks the chapter's own text in place rather than a trimmed
    /// copy of it, so every piece can report the offset it was cut at — the
    /// offset a citation is pointed at later.
    func splitChapter(_ text: String) -> [Piece] {
        let chars = Array(text)
        // Whitespace at either end belongs to no chunk.
        var start = 0
        var n = chars.count
        while start < n, chars[start].isWhitespace { start += 1 }
        while n > start, chars[n - 1].isWhitespace { n -= 1 }
        guard start < n else { return [] }

        var chunks: [Piece] = []

        while start < n {
            let hardEnd = min(start + targetCharacters, n)

            // If we've reached the end of the text, emit the remainder.
            if hardEnd >= n {
                if let piece = Self.piece(in: chars, from: start, to: n) { chunks.append(piece) }
                break
            }

            // Find the best boundary at or before hardEnd, but not so early that
            // the chunk becomes trivially small.
            let minEnd = start + max(1, targetCharacters / 2)
            let end = bestBoundary(in: chars, from: start, lowerBound: minEnd, upperBound: hardEnd)

            if let piece = Self.piece(in: chars, from: start, to: end) { chunks.append(piece) }

            // Advance with overlap, guaranteeing forward progress.
            let nextStart = end - overlapCharacters
            start = nextStart > start ? nextStart : end
        }

        return chunks
    }

    /// The window `from..<to` with its own surrounding whitespace dropped, and
    /// the offset that trim leaves it at. Nil when the window is all
    /// whitespace — a blank line between paragraphs is not a chunk.
    private static func piece(in chars: [Character], from: Int, to: Int) -> Piece? {
        var lower = from
        var upper = to
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
        guard lower < upper else { return nil }
        return Piece(text: String(chars[lower..<upper]), offset: lower)
    }

    /// Pick the highest-quality boundary index (exclusive end) in
    /// `lowerBound...upperBound`, preferring paragraph breaks, then sentence
    /// terminators, then whitespace. Falls back to `upperBound` (a hard cut at a
    /// window edge, which by construction never lands mid-word unless the window
    /// itself contains no whitespace).
    private func bestBoundary(in chars: [Character], from start: Int, lowerBound: Int, upperBound: Int) -> Int {
        let lo = max(start + 1, min(lowerBound, upperBound))
        let hi = upperBound

        // 1) Paragraph break: a newline (often a blank line) — scan backwards.
        var i = hi - 1
        while i >= lo {
            if chars[i] == "\n" {
                return i + 1
            }
            i -= 1
        }

        // 2) Sentence terminator followed by whitespace.
        i = hi - 1
        while i >= lo {
            if Self.isSentenceTerminator(chars[i]) {
                // Include any trailing closing quotes/brackets and whitespace.
                var j = i + 1
                while j < hi, Self.isSentenceTrailing(chars[j]) {
                    j += 1
                }
                return j
            }
            i -= 1
        }

        // 3) Whitespace (word boundary).
        i = hi - 1
        while i >= lo {
            if chars[i].isWhitespace {
                return i + 1
            }
            i -= 1
        }

        // 4) No boundary found — hard cut at the window edge.
        return hi
    }

    private static func isSentenceTerminator(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?"
    }

    private static func isSentenceTrailing(_ c: Character) -> Bool {
        c == "\"" || c == "'" || c == ")" || c == "]" || c == "”" || c == "’" || c.isWhitespace
    }
}
