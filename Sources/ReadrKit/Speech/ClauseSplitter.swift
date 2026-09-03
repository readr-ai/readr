import Foundation

/// Cuts a sentence that is too long for a synthesizer into clause-sized
/// pieces. Kokoro accepts at most 510 phonemes per call; the segmenter's
/// 320-character cap keeps nearly every sentence under that, and this is
/// the guard for the rest — cut at a clause and synthesize in pieces rather
/// than refuse the sentence.
public enum ClauseSplitter {

    /// How far from the target a clause break may be and still win over a
    /// better-placed space, as a fraction of the target. Without a window,
    /// "Well, " followed by four hundred unbroken characters cut after the
    /// comma — a one-word head and a tail that recursed, when the nearest
    /// space would have made two balanced halves.
    static let clauseWindow = 0.4

    /// Punctuation a listener already hears as a pause; the split lands
    /// after it so the mark stays with its clause.
    private static let clauseBreaks: Set<Character> = [
        ",", ";", ":", "\u{2014}", "\u{2013}",
    ]

    /// Pieces of `text` no longer than `maxLength` characters, each trimmed
    /// and non-empty. Preference order for the cut: the clause break nearest
    /// the middle (or as near as the limit allows) if one lies within
    /// `clauseWindow` of the target, then the nearest whitespace, then a
    /// hard cut. Joining the pieces with single spaces reproduces every word.
    public static func split(_ text: String, maxLength: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(maxLength, 1)
        guard trimmed.count > limit else { return [trimmed] }

        let characters = Array(trimmed)
        // Cut as close to the middle as the limit allows: two balanced
        // halves keep prosody better than a full head and a stub tail.
        let target = min(limit, (characters.count + 1) / 2)
        let cut = bestCut(in: characters, limit: limit, target: target)
        let head = String(characters[..<cut])
        let tail = String(characters[cut...])
        return split(head, maxLength: limit) + split(tail, maxLength: limit)
    }

    /// The index the head ends at (exclusive).
    private static func bestCut(in characters: [Character], limit: Int, target: Int) -> Int {
        // Candidate cuts: just after a clause break, or at whitespace (the
        // head then ends before the space, which trimming removes anyway).
        var clauseCuts: [Int] = []
        var spaceCuts: [Int] = []
        for index in 0..<min(limit, characters.count) {
            let character = characters[index]
            if clauseBreaks.contains(character), index + 1 <= limit {
                clauseCuts.append(index + 1)
            } else if character.isWhitespace, index > 0 {
                spaceCuts.append(index)
            }
        }
        let window = Int((Double(target) * clauseWindow).rounded(.down))
        if let cut = nearest(to: target, in: clauseCuts), abs(cut - target) <= window {
            return cut
        }
        if let cut = nearest(to: target, in: spaceCuts) { return cut }
        return limit
    }

    private static func nearest(to target: Int, in candidates: [Int]) -> Int? {
        candidates.min { abs($0 - target) < abs($1 - target) }
    }
}
