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
        let words = Self.wordCount(in: text)
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / wordsPerMinute).rounded(.up)))
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
