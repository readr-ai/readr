import Foundation

/// Estimates reading time ("~N min left in chapter") from word counts. Uses a
/// fixed default speed until Readr measures the reader's own pace (ROADMAP).
public struct ReadingTimeEstimator: Sendable {
    /// Average adult silent-reading speed.
    public static let defaultWordsPerMinute = 240.0

    public var wordsPerMinute: Double

    public init(wordsPerMinute: Double = ReadingTimeEstimator.defaultWordsPerMinute) {
        self.wordsPerMinute = max(1, wordsPerMinute)
    }

    /// Number of whitespace-separated words in `text`.
    public static func wordCount(in text: some StringProtocol) -> Int {
        var count = 0
        var inWord = false
        for character in text.unicodeScalars {
            if character.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Whole minutes (rounded up, minimum 1 for non-empty text) to read `text`.
    public func minutes(for text: some StringProtocol) -> Int {
        minutes(forWords: Self.wordCount(in: text))
    }

    /// Whole minutes (rounded up, minimum 1 for any words) to read `words`.
    public func minutes(forWords words: Int) -> Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / wordsPerMinute).rounded(.up)))
    }

    /// Minutes left in the frontier's chapter, from counts measured once:
    /// the words still ahead are taken as the chapter's words in proportion
    /// to the characters still ahead. An estimate of an estimate, and the
    /// difference from counting the remaining words is well inside the
    /// "~" — but it costs nothing per card instead of a pass over the text.
    public func minutesLeft(in lengths: ReadingLengthTable, at frontier: ReadingFrontier) -> Int {
        guard !lengths.entries.isEmpty else { return 0 }
        let index = min(max(0, frontier.chapterIndex), lengths.entries.count - 1)
        let entry = lengths.entries[index]
        guard entry.characters > 0, entry.words > 0 else { return 0 }
        let ahead = entry.characters - lengths.offset(at: frontier)
        guard ahead > 0 else { return 0 }
        let words = Int((Double(entry.words) * Double(ahead) / Double(entry.characters)).rounded())
        return minutes(forWords: words)
    }

    /// Minutes left in a chapter from a character offset into its text.
    /// Offsets outside the text are clamped.
    public func minutesLeft(inChapterText text: String, fromCharacterOffset offset: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clamped = min(max(0, offset), text.count)
        guard let start = text.index(text.startIndex, offsetBy: clamped, limitedBy: text.endIndex)
        else { return 0 }
        return minutes(for: text[start...])
    }
}
