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

    /// Two kinds of loop are caught: a sentence coming round again (only
    /// completed sentences are judged, so the verdict cannot flip once given),
    /// and a phrase repeating inside one — "or a queen of clubs, or a queen
    /// of spades, or a queen of clubs, …" never reaches a full stop, so it
    /// is judged on the text's tail instead.
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
        if let start = Self.phraseLoopStart(in: text) {
            return .looping(keep: String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .fine
    }

    /// The shortest phrase treated as a loop when it repeats back to back.
    /// "very, very, very" is emphasis; a dozen characters three times over is
    /// a model going round.
    public static let minimumPhraseLength = 12
    static let phraseRepeats = 3
    /// How much of the tail is examined — a loop shows up at the end.
    static let phraseWindow = 300

    /// Where a back-to-back phrase repeat begins in `text`'s tail, or nil.
    static func phraseLoopStart(in text: String) -> String.Index? {
        let tail = Array(text.suffix(phraseWindow))
        guard tail.count >= minimumPhraseLength * phraseRepeats else { return nil }
        for period in minimumPhraseLength...(tail.count / phraseRepeats) {
            let block = tail[(tail.count - period)...]
            var repeats = 1
            var end = tail.count - period
            while end - period >= 0, tail[(end - period)..<end].elementsEqual(block) {
                repeats += 1
                end -= period
            }
            if repeats >= phraseRepeats {
                // `end` is where the run of repeats begins in the tail. The
                // block was aligned to the text's end, so the run may start
                // mid-phrase; back up to the clause boundary before it (within
                // one period) so the kept text ends cleanly.
                var start = text.index(text.endIndex, offsetBy: -(tail.count - end))
                let floor = text.index(start, offsetBy: -period, limitedBy: text.startIndex) ?? text.startIndex
                var cursor = start
                while cursor > floor {
                    let previous = text.index(before: cursor)
                    if ",;.!?\n".contains(text[previous]) {
                        start = cursor
                        break
                    }
                    cursor = previous
                }
                return start
            }
        }
        return nil
    }

    /// Whether a completed sentence of the answer is lifted verbatim from the
    /// source text — a small model given eight passages will paste them out
    /// instead of answering. Short sentences and phrases are allowed (a brief
    /// quotation is fine); a whole copied sentence is not.
    public static func isCopied(_ sentence: String, from source: String, minimumLength: Int = 60) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return false }
        return source.contains(trimmed)
    }

    /// The text up to the end of its last completed sentence — what a
    /// streaming caller may release now, holding back the fragment that might
    /// still become a repeat.
    public static func settledPrefix(of text: String) -> String {
        guard let last = completedSentences(in: text).last else { return "" }
        return String(text[..<last.range.upperBound])
    }

    public struct Sentence: Sendable { public var text: Substring; public var range: Range<String.Index> }

    /// Sentences that have ended — a terminator followed by whitespace, or a
    /// line break. The trailing fragment is excluded.
    public static func completedSentences(in text: String) -> [Sentence] {
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
