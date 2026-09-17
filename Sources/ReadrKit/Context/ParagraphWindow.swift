import Foundation

/// The text around a passage, expanded to the paragraphs it sits among.
///
/// This is the local half of the context Readr sends, and it is meant to be
/// what a reader still has in mind when they ask about a sentence: the
/// paragraph they are in, a few before it, the one after. Working memory
/// research puts what we hold at once at a handful of chunks (Cowan's ~4, down
/// from the older 7±2), and reading studies describe the rest of comprehension
/// as a model built over the text plus *going back to look something up* — the
/// reinstatement that retrieval stands in for here. So: a window of paragraphs,
/// plus retrieved passages, and no whole book in the prompt.
///
/// Measured in characters, and on `Character` boundaries, because that is the
/// currency the reader's selection arrives in (`AppModel.makeSelection`).
public enum ParagraphWindow {

    /// Paragraphs of run-up: what the reader has just read, and is still
    /// holding. Three is deliberately modest — this is billed on every
    /// question, and the retrieved passages cover the long-range lookups.
    public static let defaultBefore = 3
    /// Paragraphs of follow-on: one. Enough to know what the passage is
    /// leading into, not enough to be a spoiler on its own — and a scoped
    /// question withholds anything past the reader's place separately.
    public static let defaultAfter = 1
    /// A ceiling on the window, in characters.
    ///
    /// Not every text has paragraphs: a PDF page's extracted string, or a
    /// plain-text book, can be one run of single newlines — and there a
    /// "paragraph" is the whole chapter, which would quietly put the entire
    /// chapter into every question, exactly what this window exists to avoid.
    /// When the paragraphs around the selection are bigger than this, the
    /// window is trimmed to this many characters centred on the selection.
    /// 2,000 characters ≈ 500 tokens of English, ≈ 1,300–2,000 of CJK.
    public static let defaultMaxCharacters = 2_000

    /// The text of the paragraphs around `range`: `before` paragraphs before
    /// the one the range starts in, the paragraphs it touches, and `after`
    /// after the one it ends in — trimmed to `maxCharacters`, centred on the
    /// selection, when those paragraphs are enormous.
    ///
    /// `range` is in the same character coordinates as `text`; it is clamped,
    /// so a range past the end yields the tail rather than a crash.
    public static func text(
        in text: String,
        around range: Range<Int>,
        before: Int = defaultBefore,
        after: Int = defaultAfter,
        maxCharacters: Int = defaultMaxCharacters
    ) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }

        let lower = min(max(0, range.lowerBound), characters.count)
        let upper = min(max(lower, range.upperBound), characters.count)

        let paragraphs = paragraphBounds(in: characters)
        guard !paragraphs.isEmpty else {
            return bounded(characters, from: 0, to: characters.count,
                           lower: lower, upper: upper, maxCharacters: maxCharacters)
        }

        // The paragraph the range starts in, and the one it ends in — the
        // paragraph before when the offset lands in the blank line between
        // two of them, which is the paragraph the reader was in.
        let startIndex = paragraphs.lastIndex { $0.lowerBound <= lower } ?? 0
        let endProbe = upper > lower ? upper - 1 : lower
        let endIndex = paragraphs.lastIndex { $0.lowerBound <= endProbe } ?? startIndex

        let first = max(0, min(startIndex, endIndex) - max(0, before))
        let last = min(paragraphs.count - 1, max(startIndex, endIndex) + max(0, after))

        return bounded(
            characters,
            from: paragraphs[first].lowerBound,
            to: paragraphs[last].upperBound,
            lower: lower, upper: upper, maxCharacters: maxCharacters
        )
    }

    /// A slice of `characters` between two offsets, trimmed to `maxCharacters`
    /// around the selection if it has to be: `maxCharacters` starting half a
    /// window before the selection, slid back inside the slice when that runs
    /// off its end.
    private static func bounded(
        _ characters: [Character], from: Int, to: Int,
        lower: Int, upper: Int, maxCharacters: Int
    ) -> String {
        let start = max(0, min(from, characters.count))
        let end = max(start, min(to, characters.count))
        guard end - start > maxCharacters, maxCharacters > 0 else {
            return String(characters[start..<end])
        }
        var window = max(start, lower - maxCharacters / 2)
        var windowEnd = min(end, window + maxCharacters)
        if windowEnd - window < maxCharacters {
            window = max(start, windowEnd - maxCharacters)
            windowEnd = min(end, window + maxCharacters)
        }
        return String(characters[window..<windowEnd])
    }

    /// Paragraph boundaries as character ranges, in order. A paragraph is a
    /// run of lines that are not all whitespace; the blank line between two
    /// paragraphs belongs to neither, so the text between them is dropped
    /// rather than glued to one side.
    public static func paragraphBounds(in characters: [Character]) -> [Range<Int>] {
        var bounds: [Range<Int>] = []
        var paragraphStart: Int?
        var index = 0

        func closeParagraph(at end: Int) {
            if let start = paragraphStart, start < end {
                bounds.append(start..<end)
            }
            paragraphStart = nil
        }

        while index <= characters.count {
            var lineEnd = index
            while lineEnd < characters.count, characters[lineEnd] != "\n" {
                lineEnd += 1
            }
            let isBlank = characters[index..<lineEnd].allSatisfy {
                $0 == " " || $0 == "\t" || $0 == "\r"
            }
            if isBlank {
                closeParagraph(at: index)
            } else if paragraphStart == nil {
                paragraphStart = index
            }
            index = lineEnd + 1
        }
        closeParagraph(at: characters.count)
        return bounds
    }
}
