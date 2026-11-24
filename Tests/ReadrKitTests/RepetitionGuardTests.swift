import XCTest
@testable import ReadrKit

/// A reader asked the on-device model "can I be a rabbit?" and the answer
/// repeated itself six times. The guard ends that.
final class RepetitionGuardTests: XCTestCase {

    private let guardian = RepetitionGuard()

    func testAnAnswerThatRepeatsASentenceIsCutBeforeTheRepeat() {
        let sentence = "You can't literally become a rabbit, but you can imagine one. "
        let looping = String(repeating: sentence, count: 6)
        guard case let .looping(keep) = guardian.verdict(for: looping) else {
            return XCTFail("six copies of one sentence is a loop")
        }
        XCTAssertEqual(keep, sentence.trimmingCharacters(in: .whitespaces))
    }

    func testARestatementIsNotALoopButAThirdOccurrenceIs() {
        let text = "Alice follows the rabbit. She is curious. Alice follows the rabbit. "
        XCTAssertEqual(guardian.verdict(for: text), .fine, "saying it twice, apart, is emphasis")
        let third = text + "The hole is deep. Alice follows the rabbit. "
        guard case let .looping(keep) = guardian.verdict(for: third) else {
            return XCTFail("a third time is a loop")
        }
        XCTAssertTrue(keep.hasSuffix("The hole is deep."), keep)
    }

    /// The real thing, verbatim from the simulator: three sentences ending in
    /// quoted speech, then the same three again. Each ends `!"` — the quote
    /// after the terminator hid the sentence boundary, so the guard saw one
    /// endless sentence and let the loop through.
    func testASentenceEndingInAClosingQuoteStillEnds() {
        let block = "She meets the Queen of Hearts, who is very angry and says, \"Off with their heads!\" "
            + "Alice then meets the Mad Hatter, who is very confused and says, \"Why is it so late?\" "
            + "Alice then meets the Caterpillar, who is very slow and says, \"Eat, eat, eat!\" "
        XCTAssertEqual(RepetitionGuard.completedSentences(in: block).count, 3)
        XCTAssertEqual(guardian.verdict(for: block), .fine)
        guard case let .looping(keep) = guardian.verdict(for: block + block) else {
            return XCTFail("the same three quoted sentences again is a loop")
        }
        XCTAssertEqual(keep, block.trimmingCharacters(in: .whitespaces))
        // Curly quotes and a bracket close the same way.
        let curly = "He said, \u{201C}Off with their heads!\u{201D} Then he left (for good). And that was all. "
        XCTAssertEqual(RepetitionGuard.completedSentences(in: curly).count, 3)
    }

    func testPunctuationAndCaseDoNotHideARepeat() {
        let text = "I'm sorry, I can't help with that. i'm sorry i cant help with that! "
        guard case let .looping(keep) = guardian.verdict(for: text) else {
            return XCTFail("the same sentence in different dress is still a repeat")
        }
        XCTAssertEqual(keep, "I'm sorry, I can't help with that.")
    }

    func testShortAnswersAndTrailingFragmentsAreFine() {
        XCTAssertEqual(guardian.verdict(for: "Yes. Yes. Yes. "), .fine, "tiny sentences repeat legitimately")
        XCTAssertEqual(guardian.verdict(for: "Alice follows the rabbit. Alice follows the rab"), .fine)
        XCTAssertEqual(guardian.verdict(for: ""), .fine)
        XCTAssertEqual(guardian.verdict(for: "One line\nOne line\n"), .fine, "under the sentence-length floor")
    }

    func testTheSettledPrefixStopsAtTheLastCompletedSentence() {
        XCTAssertEqual(RepetitionGuard.settledPrefix(of: "One. Two. Thr"), "One. Two.")
        XCTAssertEqual(RepetitionGuard.settledPrefix(of: "No boundary yet"), "")
        XCTAssertEqual(RepetitionGuard.settledPrefix(of: "Line one\nline two"), "Line one\n")
    }

    /// The second loop a reader hit: a list that never ends, so no sentence
    /// ever completes for the sentence rule to judge.
    func testAPhraseRepeatingInsideOneSentenceIsALoop() {
        let lead = "You cannot become a rabbit, though Alice wonders whether the cards are a king or a queen of hearts, "
        let cycle = "or a queen of diamonds, or a queen of clubs, or a queen of spades, or a queen of hearts, "
        let text = lead + cycle + cycle + cycle + "or a queen of dia"
        guard case let .looping(keep) = guardian.verdict(for: text) else {
            return XCTFail("three turns of the same phrase is a loop")
        }
        XCTAssertEqual(keep, lead.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(guardian.verdict(for: lead + cycle + cycle), .fine, "twice could still be a list")
    }

    func testEmphasisAndOrdinaryProseAreNotPhraseLoops() {
        XCTAssertEqual(guardian.verdict(for: "It was a very, very, very long fall, and Alice had time to look about her as she went down"), .fine)
        XCTAssertEqual(guardian.verdict(for: "Down, down, down. Would the fall never come to an end? Down, down, down."), .fine)
    }

    func testASentenceLiftedFromThePassagesIsCopiedAShortQuoteIsNot() {
        let passage = "\"Hush! Hush!\" said the Rabbit in a low, hurried tone. He looked anxiously over his shoulder as he spoke, and then raised himself upon tiptoe."
        XCTAssertTrue(RepetitionGuard.isCopied(
            " He looked anxiously over his shoulder as he spoke, and then raised himself upon tiptoe.", from: passage
        ))
        XCTAssertFalse(RepetitionGuard.isCopied("\"Hush! Hush!\" said the Rabbit.", from: passage), "short quotes are fine")
        XCTAssertFalse(RepetitionGuard.isCopied(
            "The Rabbit is nervous and keeps looking over his shoulder as he speaks to Alice here.", from: passage
        ), "a paraphrase is the model's own")
    }

    func testTheVerdictIsStableAsTheTextGrows() {
        let sentence = "The rabbit is late for a very important date. "
        let looping = sentence + sentence + sentence
        guard case let .looping(keep) = guardian.verdict(for: looping) else { return XCTFail() }
        // More text after the loop began changes nothing about where to cut.
        guard case let .looping(later) = guardian.verdict(for: looping + "And then some more words here. ") else {
            return XCTFail()
        }
        XCTAssertEqual(keep, later)
    }
}
