import Foundation

/// Stops a small model that has fallen into a loop.
///
/// A ~3B model asked something whimsical ("can I be a rabbit?") will happily
/// emit the same sentence until it hits its token limit — one reader saw an
/// answer repeat itself six times. The guard is fed the answer as it grows
/// and reports the first point at which a sentence is repeating: everything
/// before that point is worth showing, nothing after it is.
///
/// Sentence-level and order-insensitive to punctuation and case, so "I'm
/// sorry, I can't help." and "i'm sorry i can't help" count as the same
/// sentence. Two consecutive repeats of one sentence, or any sentence
/// appearing a third time, is a loop; a sentence legitimately restated once
/// is not.
public struct RepetitionGuard: Sendable {

    /// The verdict for a cumulative answer text.
    public enum Verdict: Equatable, Sendable {
        /// Keep streaming.
        case fine
        /// Stop; `keep` is the prefix of the text worth keeping — up to the
        /// end of the last sentence before the repetition began.
        case looping(keep: String)
    }

    /// How many times a sentence may appear before the answer is a loop.
    public var maximumOccurrences: Int

    /// Normalised sentences shorter than this are never counted.
    public static let minimumSentenceLength = 12

    public init(maximumOccurrences: Int = 2) {
        self.maximumOccurrences = max(2, maximumOccurrences)
    }

    /// Only completed sentences are judged (the trailing fragment may still be
    /// growing), so the verdict cannot flip once given.
    public func verdict(for text: String) -> Verdict {
        let sentences = Self.completedSentences(in: text)
        var seen: [String: Int] = [:]
        var previous: String?
        for sentence in sentences {
            let key = Self.normalized(sentence.text)
            // "Yes." / "Not sure." / "One line" repeat legitimately; a loop is
            // made of full sentences.
            guard key.count >= Self.minimumSentenceLength else { previous = key; continue }
            seen[key, default: 0] += 1
            if seen[key]! > maximumOccurrences || (previous == key && seen[key]! >= 2) {
                return .looping(keep: String(text[..<sentence.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            previous = key
        }
        return .fine
    }

    /// The text up to the end of its last completed sentence — what a
    /// streaming caller may release now, holding back the fragment that might
    /// still become a repeat.
    public static func settledPrefix(of text: String) -> String {
        guard let last = completedSentences(in: text).last else { return "" }
        return String(text[..<last.range.upperBound])
    }

    struct Sentence { var text: Substring; var range: Range<String.Index> }

    /// Sentences that have ended — a terminator followed by whitespace, or a
    /// line break. The trailing fragment is excluded.
    static func completedSentences(in text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let ends: Bool
            if character == "\n" {
                ends = true
            } else if ".!?".contains(character) {
                ends = next == text.endIndex ? false : text[next].isWhitespace
            } else {
                ends = false
            }
            if ends {
                let range = start..<next
                let slice = text[range]
                if slice.contains(where: { !$0.isWhitespace }) {
                    sentences.append(Sentence(text: slice, range: range))
                }
                start = next
            }
            index = next
        }
        return sentences
    }

    static func normalized(_ sentence: Substring) -> String {
        String(sentence.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
