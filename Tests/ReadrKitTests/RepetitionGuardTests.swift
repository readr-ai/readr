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
