import XCTest
@testable import ReadrKit

/// The unit narration is built out of. Every playback control below depends on
/// these being sentence-shaped and on the range/text invariant holding.
final class SpeechSegmenterTests: XCTestCase {

    private let segmenter = SpeechSegmenter()

    // MARK: - Sentence splitting

    func testSplitsOnSentenceTerminators() {
        let segments = segmenter.segments(
            ofChapterText: "It was a bright day. The clocks struck thirteen! Did they?"
        )
        XCTAssertEqual(segments.map(\.text), [
            "It was a bright day.",
            "The clocks struck thirteen!",
            "Did they?",
        ])
    }

    func testTerminatorRunsAndClosingQuotesStayWithTheirSentence() {
        let segments = segmenter.segments(
            ofChapterText: "\u{201C}Who goes there?!\u{201D} he called. Nobody answered."
        )
        XCTAssertEqual(segments.map(\.text), [
            "\u{201C}Who goes there?!\u{201D}",
            "he called.",
            "Nobody answered.",
        ])
    }

    func testEllipsisEndsASentence() {
        let segments = segmenter.segments(ofChapterText: "He hesitated\u{2026} Then he spoke.")
        XCTAssertEqual(segments.map(\.text), ["He hesitated\u{2026}", "Then he spoke."])
    }

    func testLineBreaksAlwaysEndASegment() {
        // A heading and a verse line carry no terminator, but each is its own
        // utterance — otherwise the voice runs a title into the prose below it.
        let segments = segmenter.segments(
            ofChapterText: "Chapter One\n\nThe road was long\nand the light was going"
        )
        XCTAssertEqual(segments.map(\.text), [
            "Chapter One",
            "The road was long",
            "and the light was going",
        ])
    }

    // MARK: - False sentence ends

    func testDoesNotSplitOnAbbreviations() {
        let segments = segmenter.segments(
            ofChapterText: "Mr. Smith met Dr. Watson at St. Pancras. They talked."
        )
        XCTAssertEqual(segments.map(\.text), [
            "Mr. Smith met Dr. Watson at St. Pancras.",
            "They talked.",
        ])
    }

    func testDoesNotSplitOnInitials() {
        let segments = segmenter.segments(ofChapterText: "It was J. R. R. Tolkien. He wrote.")
        XCTAssertEqual(segments.map(\.text), ["It was J. R. R. Tolkien.", "He wrote."])
    }

    func testDoesNotSplitInsideDecimalsOrDottedAbbreviations() {
        let segments = segmenter.segments(ofChapterText: "It cost 3.50, i.e. too much. Fine.")
        XCTAssertEqual(segments.map(\.text), ["It cost 3.50, i.e. too much.", "Fine."])
    }

    func testDoesNotSplitWhenTheNextWordContinuesInLowercase() {
        let segments = segmenter.segments(ofChapterText: "Bread, cheese, etc. and some wine. Good.")
        XCTAssertEqual(segments.map(\.text), ["Bread, cheese, etc. and some wine.", "Good."])
    }

    // MARK: - What never reaches the voice

    func testDropsSegmentsWithNothingToSay() {
        // An inline-image placeholder and a scene-break rule would otherwise
        // become silent segments the reader has to skip past by hand.
        let segments = segmenter.segments(
            ofChapterText: "First line.\n\n\u{FFFC}\n\n* * *\n\n\u{2014}\u{2014}\u{2014}\n\nLast line."
        )
        XCTAssertEqual(segments.map(\.text), ["First line.", "Last line."])
    }

    func testEmptyChapterYieldsNoSegments() {
        XCTAssertTrue(segmenter.segments(ofChapterText: "").isEmpty)
        XCTAssertTrue(segmenter.segments(ofChapterText: "   \n\n  ").isEmpty)
    }

    // MARK: - Ranges

    func testRangesAddressTheChapterTextExactly() {
        let text = "It was a bright day.\n\nThe clocks struck thirteen. Winston went in."
        let characters = Array(text)
        let segments = segmenter.segments(ofChapterText: text)
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            // The invariant every spoken-word → chapter-offset mapping rests on.
            XCTAssertEqual(String(characters[segment.range]), segment.text)
        }
    }

    func testRangesAreAscendingAndNonOverlapping() {
        let text = "One. Two. Three.\n\nFour. Five."
        let segments = segmenter.segments(ofChapterText: text)
        XCTAssertEqual(segments.count, 5)
        for (previous, next) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.range.upperBound, next.range.lowerBound)
        }
    }

    func testSegmentsCarryTheirChapterIndex() {
        let segments = segmenter.segments(ofChapterText: "One. Two.", chapterIndex: 4)
        XCTAssertEqual(segments.map(\.chapterIndex), [4, 4])
    }

    func testSegmentsOfChapterUseTheChapterText() {
        let chapter = Chapter(title: "One", order: 0, text: "A sentence. Another one.")
        let segments = segmenter.segments(of: chapter, chapterIndex: 2)
        XCTAssertEqual(segments.map(\.text), ["A sentence.", "Another one."])
        XCTAssertEqual(segments.map(\.chapterIndex), [2, 2])
    }

    // MARK: - Run-on sentences

    func testLongSentencesAreBrokenAtClauseBoundaries() {
        let clause = "and the road went on past the mill, "
        let sentence = "It was a long way, " + String(repeating: clause, count: 12) + "and then it ended."
        let segmenter = SpeechSegmenter(maximumSegmentLength: 120)
        let segments = segmenter.segments(ofChapterText: sentence)

        XCTAssertGreaterThan(segments.count, 1, "A run-on sentence should be broken up")
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.text.count, 120)
        }
        // No text is lost: the pieces reassemble into the original sentence.
        XCTAssertEqual(
            segments.map(\.text).joined(separator: " "),
            sentence.trimmingCharacters(in: .whitespaces)
        )
        // Pieces break after punctuation, not mid-clause.
        XCTAssertTrue(segments[0].text.hasSuffix(","))
    }

    func testAnUnbrokenRunIsHardWrappedRatherThanDropped() {
        let text = String(repeating: "a", count: 250)
        let segmenter = SpeechSegmenter(maximumSegmentLength: 100)
        let segments = segmenter.segments(ofChapterText: text)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.text).joined(), text)
    }

    func testMaximumSegmentLengthIsNeverZero() {
        // A zero capacity would make the splitter unable to advance.
        let segmenter = SpeechSegmenter(maximumSegmentLength: 0)
        XCTAssertEqual(segmenter.maximumSegmentLength, 1)
        XCTAssertEqual(segmenter.segments(ofChapterText: "ab").count, 2)
    }
}
