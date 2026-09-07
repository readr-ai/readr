import XCTest
@testable import ReadrKit

/// An on-device model hands back the whole answer so far on every step. This
/// is what turns that into the deltas a reader sees — and what it refuses to
/// pass on.
final class SnapshotAnswerStreamTests: XCTestCase {

    /// Run a sequence of cumulative snapshots and collect everything shown.
    private func play(
        _ snapshots: [String], source: String = ""
    ) -> (shown: String, dropped: Int, loopedAfter: Int?) {
        var stream = SnapshotAnswerStream(source: source)
        var shown = ""
        var dropped = 0
        var loopedAfter: Int?
        for (step, snapshot) in snapshots.enumerated() {
            let output = stream.advance(to: snapshot)
            shown += output.delta
            dropped += output.droppedCopiedSentences
            if output.isLooping, loopedAfter == nil { loopedAfter = step }
        }
        let last = stream.finish()
        shown += last.delta
        dropped += last.droppedCopiedSentences
        return (shown, dropped, loopedAfter)
    }

    /// The whole answer arrives, in order, with nothing said twice.
    func testGrowingSnapshotsBecomeTheAnswerExactlyOnce() {
        let result = play([
            "The",
            "The rabbit",
            "The rabbit ran past her.",
            "The rabbit ran past her. She followed",
            "The rabbit ran past her. She followed him down.",
        ])

        XCTAssertEqual(result.shown, "The rabbit ran past her. She followed him down.")
        XCTAssertEqual(result.dropped, 0)
        XCTAssertNil(result.loopedAfter)
    }

    /// A sentence is held back until it has ended: a delta must never be a
    /// half-sentence the guards have not judged yet.
    func testNothingIsShownUntilASentenceHasEnded() {
        var stream = SnapshotAnswerStream(source: "")

        XCTAssertEqual(stream.advance(to: "The rabbit ran").delta, "")
        XCTAssertEqual(stream.advance(to: "The rabbit ran past her.").delta, "")
        // The whitespace after the full stop belongs to the sentence that
        // follows it, so it arrives with the next delta.
        XCTAssertEqual(
            stream.advance(to: "The rabbit ran past her. She").delta,
            "The rabbit ran past her."
        )
    }

    /// The trailing fragment has no whitespace after it to mark it complete,
    /// so a clean stream releases it at the end or it is never shown at all.
    func testTheTailIsFlushedWhenTheStreamEndsCleanly() {
        var stream = SnapshotAnswerStream(source: "")
        _ = stream.advance(to: "One. Two")

        XCTAssertEqual(stream.finish().delta, " Two")
        XCTAssertEqual(stream.finish().delta, "", "finishing twice repeats nothing")
    }

    /// A ~3B model asked something whimsical will emit the same sentence until
    /// it runs out of tokens. The reader sees it once, and the stream stops.
    func testALoopingModelIsCutAtItsFirstRepeat() {
        let sentence = "I'm sorry, I can't help with that."
        let result = play([
            sentence,
            sentence + " I'm sorry, I",
            sentence + " " + sentence + " ",
            sentence + " " + sentence + " " + sentence + " ",
        ])

        XCTAssertEqual(result.shown, sentence)
        XCTAssertEqual(result.loopedAfter, 2, "the loop is called on the step it appears")
    }

    /// Once it has looped nothing more is shown — later snapshots are all
    /// repeat, and `finish` has nothing to add.
    func testNothingIsShownAfterALoop() {
        let sentence = "I'm sorry, I can't help with that."
        var stream = SnapshotAnswerStream(source: "")
        _ = stream.advance(to: sentence + " I'm")
        let loop = stream.advance(to: sentence + " " + sentence + " ")

        XCTAssertTrue(loop.isLooping)
        XCTAssertEqual(stream.advance(to: sentence + " " + sentence + " " + sentence).delta, "")
        XCTAssertEqual(stream.finish().delta, "")
    }

    // MARK: - Newlines (the offset drift)

    /// The reproduction. Offsets used to be rebuilt by summing sentence
    /// lengths, and a whitespace-only slice — the `\n` between two sentences
    /// — is not a sentence, so the sum fell a character behind the text at
    /// the first newline and never caught up: every sentence after it looked
    /// already judged and was silently dropped.
    func testSentencesAfterANewlineStillReachTheReader() {
        let answer = """
            Alice follows the rabbit out of curiosity.
            She falls down the hole for a while. Then she lands in a hall. \
            The hall has many doors here.
            """

        let result = play(growing(answer))

        XCTAssertEqual(result.shown, answer)
        XCTAssertNil(result.loopedAfter)
    }

    /// A small model answering "what are the four rules?" writes a list, and
    /// every item ends in a line break. Under the old arithmetic the reader
    /// saw the first bullet and nothing else.
    func testEveryItemOfABulletedListArrives() {
        let answer = """
            The passages give four rules:
            - Alice must not eat the cake yet.
            - She must follow the rabbit down.
            - She must not cry into the pool.
            - She must remember which door she came through.
            """

        let result = play(growing(answer))

        XCTAssertEqual(result.shown, answer)
        for bullet in ["- Alice must not", "- She must follow", "- She must not cry", "- She must remember"] {
            XCTAssertTrue(result.shown.contains(bullet), "\(bullet) never reached the reader")
        }
    }

    /// A blank line between paragraphs is two whitespace-only slices in a
    /// row, and it is the model's own layout — it survives verbatim.
    func testATwoParagraphAnswerKeepsItsBlankLine() {
        let answer = """
            Alice follows the rabbit because she is curious. It runs past her \
            with a watch.

            Later she lands in a long hall. Every door there is locked.
            """

        let result = play(growing(answer))

        XCTAssertEqual(result.shown, answer)
        XCTAssertTrue(result.shown.contains("\n\n"), "the paragraph break is part of the answer")
    }

    /// Growing snapshots, a word at a time — the shape a real runtime hands
    /// back, and the one the offsets have to survive.
    private func growing(_ answer: String) -> [String] {
        var snapshots: [String] = []
        var soFar = ""
        for piece in answer.split(separator: " ", omittingEmptySubsequences: false) {
            soFar += (soFar.isEmpty ? "" : " ") + piece
            snapshots.append(soFar)
        }
        return snapshots
    }

    // MARK: - The phrase loop's dangling clause

    /// A phrase loop is caught mid-sentence and the guard backs its cut up to
    /// the clause boundary before the repeat — a comma. What the reader is
    /// shown must still end where a sentence ends.
    func testAPhraseLoopIsShownCutBackToItsLastWholeSentence() {
        let loop = "or a queen of clubs, or a queen of spades, "
        let answer = "The Queen is angry. She might be a queen of hearts, "
            + String(repeating: loop, count: 4)

        let result = play(growing(answer))

        XCTAssertEqual(result.shown, "The Queen is angry.")
        XCTAssertNotNil(result.loopedAfter, "the card-suit loop is a loop")
        XCTAssertFalse(result.shown.hasSuffix(","), "a dangling clause is not an answer")
    }

    /// The sentence loop's cut already lands on a sentence end, and trimming
    /// it back again would cost the reader the last thing the model said.
    func testASentenceLoopStillShowsItsLastWholeSentence() {
        let first = "Alice follows the rabbit because she is curious about it."
        let repeated = "I'm sorry, I can't help with that."
        let result = play([
            first + " " + repeated,
            first + " " + repeated + " " + repeated + " ",
        ])

        XCTAssertEqual(result.shown, first + " " + repeated)
    }

    /// A small model handed eight passages pastes them out instead of
    /// answering. A whole sentence lifted from the prompt is not an answer, so
    /// it never reaches the reader — and the caller is told, for the log.
    func testASentenceCopiedFromThePassagesIsDropped() {
        let copied = "There was nothing so very remarkable in that, nor did Alice think it much out of the way."
        let source = AdaptiveContextStrategy.passagesHeader + "[Ch. 1] " + copied

        let result = play(
            [copied + " ", copied + " She followed him. "],
            source: source
        )

        XCTAssertEqual(result.shown, " She followed him. ")
        XCTAssertEqual(result.dropped, 1)
    }

    /// With no passages behind the answer — a general question, an article —
    /// there is nothing to copy from, and the check is off.
    func testWithNoSourceNothingIsTreatedAsCopied() {
        let line = "There was nothing so very remarkable in that, nor did Alice think it much out of the way."

        XCTAssertEqual(play([line + " "]).shown, line + " ")
    }

    /// A short phrase quoted from the book is fine — the guard is about a
    /// model pasting whole sentences, not about quotation.
    func testAShortQuotedPhraseSurvives() {
        let source = "[Ch. 1] Off with their heads, said the Queen, and everyone fell silent at once."

        let result = play(["The Queen says \"off with their heads\". "], source: source)

        XCTAssertEqual(result.shown, "The Queen says \"off with their heads\". ")
        XCTAssertEqual(result.dropped, 0)
    }
}
