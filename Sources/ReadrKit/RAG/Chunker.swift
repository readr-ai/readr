import Foundation

/// A contiguous span of text from a single chapter, ready to embed and index.
public struct Chunk: Sendable, Hashable {
    /// The raw chunk text (no situating prefix).
    public var text: String
    /// Human-readable position, e.g. `Ch. 3 (Chapter Title)`.
    public var locator: String
    /// Zero-based index into `Book.chapters` (sorted by reading order).
    public var chapterIndex: Int

    public init(text: String, locator: String, chapterIndex: Int) {
        self.text = text
        self.locator = locator
        self.chapterIndex = chapterIndex
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
            let pieces = splitChapter(chapter.text)
            for piece in pieces {
                result.append(Chunk(text: piece, locator: locator, chapterIndex: chapterIndex))
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

    /// Split a single chapter's text into overlapping windows, preferring
    /// paragraph then sentence then word boundaries, never cutting mid-word.
    func splitChapter(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let chars = Array(trimmed)
        let n = chars.count
        if n <= targetCharacters {
            return [trimmed]
        }

        var chunks: [String] = []
        var start = 0

        while start < n {
            let hardEnd = min(start + targetCharacters, n)

            // If we've reached the end of the text, emit the remainder.
            if hardEnd >= n {
                let piece = String(chars[start..<n]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { chunks.append(piece) }
                break
            }

            // Find the best boundary at or before hardEnd, but not so early that
            // the chunk becomes trivially small.
            let minEnd = start + max(1, targetCharacters / 2)
            let end = bestBoundary(in: chars, from: start, lowerBound: minEnd, upperBound: hardEnd)

            let piece = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }

            // Advance with overlap, guaranteeing forward progress.
            let nextStart = end - overlapCharacters
            start = nextStart > start ? nextStart : end
        }

        return chunks
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
