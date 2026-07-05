import XCTest
@testable import ReadrKit

/// "~N min left in chapter" — word counting and minute math.
final class ReadingTimeEstimatorTests: XCTestCase {

    /// `count` copies of "word" separated by single spaces.
    private func words(_ count: Int) -> String {
        Array(repeating: "word", count: count).joined(separator: " ")
    }

    // MARK: wordCount

    func testWordCountOfEmptyStringIsZero() {
        XCTAssertEqual(ReadingTimeEstimator.wordCount(in: ""), 0)
    }

    func testWordCountOfWhitespaceOnlyIsZero() {
        XCTAssertEqual(ReadingTimeEstimator.wordCount(in: "   \t  \n  "), 0)
    }

    func testWordCountCollapsesRunsOfSpaces() {
        XCTAssertEqual(ReadingTimeEstimator.wordCount(in: "one   two     three"), 3)
    }

    func testWordCountTreatsNewlinesAsSeparators() {
        XCTAssertEqual(ReadingTimeEstimator.wordCount(in: "one\ntwo\n\nthree\nfour"), 4)
    }

    // MARK: minutes

    func testMinutesForEmptyTextIsZero() {
        XCTAssertEqual(ReadingTimeEstimator().minutes(for: ""), 0)
    }

    func testMinutesHasOneMinuteFloorForShortText() {
        XCTAssertEqual(ReadingTimeEstimator().minutes(for: "hi"), 1)
    }

    func testMinutesRoundsUp() {
        // 241 words at 240 wpm is just over a minute — must round up to 2.
        XCTAssertEqual(ReadingTimeEstimator().minutes(for: words(241)), 2)
    }

    func testFourEightyWordsAtDefaultSpeedIsTwoMinutes() {
        XCTAssertEqual(ReadingTimeEstimator().minutes(for: words(480)), 2)
    }

    // MARK: minutesLeft

    func testMinutesLeftFromOffsetZeroEqualsWholeChapter() {
        let estimator = ReadingTimeEstimator()
        let text = words(480)
        XCTAssertEqual(
            estimator.minutesLeft(inChapterText: text, fromCharacterOffset: 0),
            estimator.minutes(for: text)
        )
    }

    func testMinutesLeftBeyondEndIsZero() {
        let text = words(480)
        XCTAssertEqual(
            ReadingTimeEstimator().minutesLeft(
                inChapterText: text, fromCharacterOffset: text.count + 100
            ),
            0
        )
    }

    func testMinutesLeftNegativeOffsetClampsToStart() {
        let estimator = ReadingTimeEstimator()
        let text = words(480)
        XCTAssertEqual(
            estimator.minutesLeft(inChapterText: text, fromCharacterOffset: -50),
            estimator.minutes(for: text)
        )
    }

    func testMinutesLeftMidChapterIsLessThanFullEstimate() {
        let estimator = ReadingTimeEstimator()
        let text = words(480) // 2 minutes total.
        // "word " is 5 characters, so offset 240 * 5 lands at word 241:
        // 240 words remain — 1 minute.
        let midOffset = 240 * 5
        let left = estimator.minutesLeft(inChapterText: text, fromCharacterOffset: midOffset)
        XCTAssertEqual(left, 1)
        XCTAssertLessThan(left, estimator.minutes(for: text))
    }

    func testMinutesLeftInEmptyChapterIsZero() {
        XCTAssertEqual(
            ReadingTimeEstimator().minutesLeft(inChapterText: "", fromCharacterOffset: 0),
            0
        )
    }
}
