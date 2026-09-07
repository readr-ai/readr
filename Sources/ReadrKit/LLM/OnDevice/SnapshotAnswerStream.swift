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
/// Judged by count, so each step costs the new text and not the answer.
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
            // repetition is final: release it and take no more. `keep` is
            // already settled, so it is settled whole rather than trimmed
            // back to its last sentence boundary again.
            isFinished = true
            var output = settle(keep)
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
    private mutating func settle(_ settled: String) -> Output {
        let count = settled.count
        guard count > judgedCount else { return .nothing }
        var output = Output.nothing
        var offset = 0
        for sentence in Self.sentences(ofSettled: settled) {
            let start = offset
            offset += sentence.count
            guard start >= judgedCount else { continue }
            if !source.isEmpty, RepetitionGuard.isCopied(String(sentence), from: source) {
                output.droppedCopiedSentences += 1
                continue
            }
            output.delta += sentence
        }
        judgedCount = count
        return output
    }

    /// The sentences of a string that is settled all the way to its end.
    ///
    /// `RepetitionGuard` calls a sentence over only once whitespace follows
    /// its full stop — mid-stream, "3." may still become "3.5". Settled text
    /// ends exactly ON that full stop, so its last sentence is not among the
    /// completed ones and would be judged twice, or never. Here the whole
    /// string is settled by construction, so the remainder is a sentence too.
    private static func sentences(ofSettled text: String) -> [Substring] {
        var pieces: [Substring] = []
        var cursor = text.startIndex
        for sentence in RepetitionGuard.completedSentences(in: text) {
            pieces.append(sentence.text)
            cursor = sentence.range.upperBound
        }
        let remainder = text[cursor...]
        if remainder.contains(where: { !$0.isWhitespace }) { pieces.append(remainder) }
        return pieces
    }
}
