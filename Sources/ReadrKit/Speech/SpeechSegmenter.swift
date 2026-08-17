import Foundation

/// Splits chapter text into sentence-sized `SpeechSegment`s for narration.
///
/// Pure and deterministic so it is unit-testable on CI: no platform tokenizer
/// is involved (`NSLinguisticTagger`/`NLTokenizer` are unavailable on Linux and
/// untestable without a device), and the same text always yields the same
/// segments — which the reader relies on, since a segment's range is what makes
/// "resume where I stopped listening" land on the right sentence.
///
/// Sentences (rather than paragraphs or whole chapters) are the unit because
/// every playback control is expressed in them: skip forward/back, the
/// follow-along page turn, and re-speaking the remainder after a speed change
/// all need a granularity a reader can perceive.
public struct SpeechSegmenter: Sendable {
    /// Longest segment handed to the engine before it is broken at a clause
    /// boundary. A run-on sentence — common in 19th-century prose — otherwise
    /// becomes one multi-minute utterance, which makes "skip back one sentence"
    /// useless and leaves the page frozen while the voice reads on.
    public let maximumSegmentLength: Int

    public init(maximumSegmentLength: Int = 320) {
        self.maximumSegmentLength = max(1, maximumSegmentLength)
    }

    /// Segments of a chapter's text, in reading order.
    public func segments(ofChapterText text: String, chapterIndex: Int = 0) -> [SpeechSegment] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }

        var result: [SpeechSegment] = []
        var start = 0
        var index = 0
        while index < chars.count {
            let character = chars[index]
            var boundary = index + 1
            var isBoundary = false

            if character.isNewline {
                // A line break always ends a segment: paragraphs, headings and
                // verse lines each deserve their own utterance (and their own
                // beat of silence). Consume the whole run so a blank line
                // doesn't produce an empty slice.
                while boundary < chars.count, chars[boundary].isNewline { boundary += 1 }
                isBoundary = true
            } else if Self.terminators.contains(character) {
                // Terminator runs ("?!", "...") and the closing punctuation
                // after them ride with the sentence they end.
                var end = index + 1
                while end < chars.count, Self.terminators.contains(chars[end]) { end += 1 }
                while end < chars.count, Self.closers.contains(chars[end]) { end += 1 }
                // Whitespace (or the chapter's end) after the terminator is
                // what makes it a sentence end rather than a decimal point or
                // an initial mid-name — "3.14" and "e.g." never reach here.
                let followedByBreak = end >= chars.count || chars[end].isWhitespace
                if followedByBreak, !suppressesBreak(chars, terminator: index, next: end) {
                    boundary = end
                    isBoundary = true
                }
            }

            if isBoundary {
                append(start..<boundary, of: chars, chapterIndex: chapterIndex, to: &result)
                start = boundary
                index = boundary
            } else {
                index += 1
            }
        }
        if start < chars.count {
            append(start..<chars.count, of: chars, chapterIndex: chapterIndex, to: &result)
        }
        return result
    }

    /// Convenience over a `Chapter`.
    public func segments(of chapter: Chapter, chapterIndex: Int) -> [SpeechSegment] {
        segments(ofChapterText: chapter.text, chapterIndex: chapterIndex)
    }

    // MARK: - Boundary rules

    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
    /// Quotes and brackets that close *after* a terminator.
    private static let closers: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", ")", "]", "\u{00BB}",
    ]
    /// Where an over-long segment may be cut instead of mid-clause.
    private static let clauseBreaks: Set<Character> = [",", ";", ":", "\u{2014}", "\u{2013}"]

    /// Titles and honorifics: a period after one of these is never a sentence
    /// end, and what follows is a capitalised name, so no other signal can
    /// tell us. Suppressed unconditionally.
    private static let titles: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "rev", "hon",
        "gen", "col", "capt", "lt", "sgt", "messrs",
    ]

    /// Abbreviations that are also ordinary words — "No.", "Co.", "Ed.",
    /// "Vol." — so their period *can* end a sentence: "Did he agree? No. He
    /// refused." Suppressed only when what follows continues the phrase
    /// rather than starting a sentence (see `suppressesBreak`), which is what
    /// keeps "No. 5" and "Fig. 3" together without swallowing the "No." above.
    private static let phraseAbbreviations: Set<String> = [
        "vs", "etc", "al", "approx", "dept", "est", "fig", "figs", "no",
        "nos", "vol", "vols", "ch", "chap", "ed", "eds", "pp", "cf", "ca",
        "viz", "inc", "ltd", "co", "corp", "univ", "jan", "feb", "mar",
        "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// Whether a period at `terminator` continues the sentence rather than
    /// ending it. Only periods are ambiguous — "!" and "?" end a sentence
    /// wherever they appear.
    private func suppressesBreak(_ chars: [Character], terminator: Int, next: Int) -> Bool {
        guard chars[terminator] == "." else { return false }

        // The word the period is attached to.
        var scan = terminator - 1
        var reversed: [Character] = []
        while scan >= 0, chars[scan].isLetter {
            reversed.append(chars[scan])
            scan -= 1
        }
        let word = reversed.isEmpty ? "" : String(reversed.reversed()).lowercased()

        // A lone initial ("J. R. R. Tolkien") or a title ("Mr. Smith") always
        // carries on — nothing about what follows could tell us otherwise.
        if word.count == 1 { return true }
        if Self.titles.contains(word) { return true }

        // Otherwise the word that FOLLOWS decides. A lowercase start is a
        // continuation whatever the period was ("...etc. and so on"); a
        // sentence starts with a capital, a digit, or an opening quote.
        var forward = next
        while forward < chars.count, chars[forward].isWhitespace { forward += 1 }
        guard forward < chars.count else { return false }
        if chars[forward].isLowercase { return true }
        // A number after an abbreviation that takes one ("No. 5", "Fig. 3",
        // "pp. 41") belongs to it. Without this test the same word ends a
        // sentence, which is the point: "Did he agree? No. He refused."
        if chars[forward].isNumber, Self.phraseAbbreviations.contains(word) { return true }
        return false
    }

    // MARK: - Segment construction

    /// Trims `raw`, drops it if nothing in it can be spoken, and splits it if
    /// it runs past `maximumSegmentLength`.
    private func append(
        _ raw: Range<Int>, of chars: [Character], chapterIndex: Int,
        to result: inout [SpeechSegment]
    ) {
        guard let trimmed = Self.trimming(raw, in: chars),
              Self.isSpeakable(chars, trimmed) else { return }

        guard trimmed.count > maximumSegmentLength else {
            result.append(Self.segment(trimmed, of: chars, chapterIndex: chapterIndex))
            return
        }

        var start = trimmed.lowerBound
        while start < trimmed.upperBound {
            let limit = min(start + maximumSegmentLength, trimmed.upperBound)
            // `lastBreak` never returns `start` itself, and `limit` is always
            // past it, so the cursor advances on every pass.
            let cut = limit < trimmed.upperBound
                ? (Self.lastBreak(in: chars, after: start, before: limit) ?? limit)
                : limit
            if let piece = Self.trimming(start..<cut, in: chars), Self.isSpeakable(chars, piece) {
                result.append(Self.segment(piece, of: chars, chapterIndex: chapterIndex))
            }
            start = cut
        }
    }

    private static func segment(
        _ range: Range<Int>, of chars: [Character], chapterIndex: Int
    ) -> SpeechSegment {
        SpeechSegment(
            chapterIndex: chapterIndex, range: range, text: String(chars[range])
        )
    }

    /// `range` without leading/trailing whitespace, or nil if nothing is left.
    private static func trimming(_ range: Range<Int>, in chars: [Character]) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    /// Whether a range holds anything a voice can pronounce. Drops the
    /// leftovers of extraction — a lone U+FFFC image placeholder, a "* * *"
    /// scene break, a rule of em dashes — which would otherwise become silent
    /// segments the reader has to skip past by hand.
    private static func isSpeakable(_ chars: [Character], _ range: Range<Int>) -> Bool {
        for index in range where chars[index].isLetter || chars[index].isNumber {
            return true
        }
        return false
    }

    /// Best cut point strictly inside `(after, before)`: after the last clause
    /// punctuation if there is one, else at the last whitespace. Nil when the
    /// window holds neither (one unbroken word), leaving the caller to cut at
    /// the hard limit.
    private static func lastBreak(
        in chars: [Character], after lower: Int, before upper: Int
    ) -> Int? {
        var space: Int?
        var index = upper - 1
        while index > lower {
            if chars[index].isWhitespace {
                if space == nil { space = index }
                if Self.clauseBreaks.contains(chars[index - 1]) { return index }
            }
            index -= 1
        }
        return space
    }
}
