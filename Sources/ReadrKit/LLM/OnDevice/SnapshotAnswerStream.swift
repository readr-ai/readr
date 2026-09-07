import Foundation

/// Turns an on-device model's cumulative snapshots into the deltas the kit's
/// `ChatChunk` stream is made of — and decides what of them a reader sees.
///
/// On-device runtimes hand back the whole answer so far on every step, not
/// the new piece. Converting that to deltas is only half the job: text is
/// released a completed sentence at a time, held back just long enough for
/// `RepetitionGuard` to judge it, so a loop ends before its first repeat is
/// shown and the reader never sees the same sentence six times. Sentences
/// lifted verbatim out of the passages are dropped on the way past — a whole
/// copied sentence answers nothing.
///
/// What a step costs: releasing is incremental — only the text a snapshot
/// ADDS is read. Judging is not, and cannot be: `RepetitionGuard.verdict`
/// re-reads the whole answer each step, because a loop is a relation between
/// sentences rather than a property of the last one. An answer is capped at a
/// few hundred tokens, so that re-read is bounded and cheap; the line that
/// used to stand here — "each step costs the new text and not the answer" —
/// was only ever true of the releasing half.
///
/// Lifted out of the app's Foundation Models provider, where it re-derived
/// sentence boundaries from each batch of settled text and so dropped the
/// last sentence of every batch — a multi-sentence answer reached the reader
/// as its final fragment alone. `SnapshotAnswerStreamTests` pins the fix.
public struct SnapshotAnswerStream: Sendable {

    /// What one step produced.
    public struct Output: Equatable, Sendable {
        /// New text to show the reader; empty when nothing settled yet.
        public var delta: String
        /// Sentences dropped for being copied out of the passages — a count,
        /// so the caller can log it without this type knowing how.
        public var droppedCopiedSentences: Int
        /// True on the step where the model began repeating itself. Stop
        /// reading snapshots: nothing after this point is worth showing.
        public var isLooping: Bool

        static let nothing = Output(delta: "", droppedCopiedSentences: 0, isLooping: false)
    }

    /// The prompt the model was given, for the copied-sentence check. Empty
    /// when there are no passages to copy from (a general question, an
    /// article), which turns that check off.
    private let source: String
    private let repetition: RepetitionGuard
    /// Characters of the answer already settled and judged. Snapshots are
    /// cumulative, so this is also where the next step's fresh text starts.
    private var judgedCount = 0
    private var latest = ""
    private var isFinished = false

    public init(source: String, repetition: RepetitionGuard = RepetitionGuard()) {
        self.source = source
        self.repetition = repetition
    }

    /// Take the next cumulative snapshot.
    public mutating func advance(to snapshot: String) -> Output {
        guard !isFinished else { return .nothing }
        switch repetition.verdict(for: snapshot) {
        case let .looping(keep):
            // The verdict cannot flip once given, so everything before the
            // repetition is final: release it and take no more.
            isFinished = true
            var output = settle(Self.wholeSentences(of: keep))
            output.isLooping = true
            return output
        case .fine:
            latest = snapshot
            return settle(RepetitionGuard.settledPrefix(of: snapshot))
        }
    }

    /// The trailing fragment at the end of a clean stream — the last sentence
    /// has no whitespace after it to mark it complete, so it is released here
    /// instead. A no-op once the stream stopped for a loop.
    public mutating func finish() -> Output {
        guard !isFinished else { return .nothing }
        isFinished = true
        var output = settle(RepetitionGuard.settledPrefix(of: latest))
        let count = latest.count
        guard count > judgedCount else { return output }
        let tail = String(latest.suffix(count - judgedCount))
        judgedCount = count
        if source.isEmpty || !RepetitionGuard.isCopied(tail, from: source) {
            output.delta += tail
        }
        return output
    }

    /// Judge the settled text past what was already judged, and keep the
    /// sentences that are the model's own.
    ///
    /// Only the fresh suffix is scanned. The sentence scanner carries no
    /// state across a sentence boundary and everything judged so far ends on
    /// one, so the suffix's sentences are the answer's sentences past that
    /// point — no sentence is judged twice, and none is walked past twice.
    ///
    /// The whitespace BETWEEN sentences is passed through rather than
    /// counted. Counting was the old bug: a blank line is not a sentence, so
    /// `RepetitionGuard` discards it, and rebuilding offsets by summing
    /// sentence lengths therefore fell one character behind the text at every
    /// `\n` — past the first newline every later sentence looked already
    /// judged, and no reader ever saw it.
    private mutating func settle(_ settled: String) -> Output {
        let count = settled.count
        guard count > judgedCount else { return .nothing }
        let fresh = String(settled.suffix(count - judgedCount))
        judgedCount = count

        var output = Output.nothing
        var cursor = fresh.startIndex
        for sentence in Self.sentenceRanges(ofSettled: fresh) {
            output.delta += fresh[cursor..<sentence.lowerBound]
            cursor = sentence.upperBound
            if !source.isEmpty, RepetitionGuard.isCopied(String(fresh[sentence]), from: source) {
                output.droppedCopiedSentences += 1
                continue
            }
            output.delta += fresh[sentence]
        }
        output.delta += fresh[cursor...]
        return output
    }

    /// The sentence ranges of a string that is settled all the way to its end.
    ///
    /// `RepetitionGuard` calls a sentence over only once whitespace follows
    /// its full stop — mid-stream, "3." may still become "3.5". Settled text
    /// ends exactly ON that full stop, so its last sentence is not among the
    /// completed ones and would be judged twice, or never. Here the whole
    /// string is settled by construction, so the remainder is a sentence too.
    private static func sentenceRanges(ofSettled text: String) -> [Range<String.Index>] {
        var ranges = RepetitionGuard.completedSentences(in: text).map(\.range)
        let remainder = (ranges.last?.upperBound ?? text.startIndex)..<text.endIndex
        if text[remainder].contains(where: { !$0.isWhitespace }) { ranges.append(remainder) }
        return ranges
    }

    /// What a loop verdict kept, cut back to the end of its last whole
    /// sentence.
    ///
    /// A sentence loop is caught on a sentence boundary and comes back whole.
    /// A phrase loop is not: it is caught mid-sentence, and the guard backs
    /// its cut up to the clause boundary before the repeat — usually a comma
    /// — so what it hands back can end on a dangling clause ("The Queen is
    /// angry, or a queen of clubs,"). Showing that is worse than showing one
    /// sentence less.
    ///
    /// The trailing space is what lets one rule serve both: a full stop only
    /// ends a sentence once whitespace follows it, so text already ending on
    /// one comes back untouched and a dangling clause loses itself.
    private static func wholeSentences(of keep: String) -> String {
        RepetitionGuard.settledPrefix(of: keep + " ")
    }
}
