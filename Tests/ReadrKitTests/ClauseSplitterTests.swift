import XCTest
@testable import ReadrKit

/// Kokoro takes at most 510 phonemes per call. The segmenter's 320-character
/// cap keeps nearly every sentence under that, but "nearly" is not a
/// guarantee (stress marks add phonemes), so an over-long sentence is cut
/// at a clause and synthesized in pieces rather than refused.
final class ClauseSplitterTests: XCTestCase {

    func testAShortTextIsReturnedWhole() {
        XCTAssertEqual(
            ClauseSplitter.split("A short one, really.", maxLength: 40),
            ["A short one, really."]
        )
    }

    func testEmptyAndBlankTextProduceNoPieces() {
        XCTAssertEqual(ClauseSplitter.split("", maxLength: 10), [])
        XCTAssertEqual(ClauseSplitter.split("   \n ", maxLength: 10), [])
    }

    func testSplitsAtTheClauseBreakNearestTheMiddle() {
        let text = "One, two, three, four, five, six, seven, eight"
        let pieces = ClauseSplitter.split(text, maxLength: 40)
        XCTAssertEqual(pieces, ["One, two, three, four,", "five, six, seven, eight"])
    }

    func testThePunctuationStaysWithTheHeadAndWhitespaceIsTrimmed() {
        let pieces = ClauseSplitter.split("Alpha beta;   gamma delta", maxLength: 14)
        XCTAssertEqual(pieces, ["Alpha beta;", "gamma delta"])
    }

    func testDashesAndColonsAreClauseBreaks() {
        XCTAssertEqual(
            ClauseSplitter.split("Head \u{2014} tail here", maxLength: 10),
            ["Head \u{2014}", "tail here"]
        )
        XCTAssertEqual(
            ClauseSplitter.split("Head: tail here", maxLength: 10),
            ["Head:", "tail here"]
        )
    }

    func testFallsBackToWhitespaceWhenThereIsNoClauseBreak() {
        let pieces = ClauseSplitter.split("the quick brown fox jumps over", maxLength: 16)
        XCTAssertEqual(pieces, ["the quick brown", "fox jumps over"])
    }

    func testHardCutsAnUnbrokenRunAsALastResort() {
        let pieces = ClauseSplitter.split(String(repeating: "x", count: 25), maxLength: 10)
        XCTAssertEqual(pieces, [
            String(repeating: "x", count: 10),
            String(repeating: "x", count: 10),
            String(repeating: "x", count: 5),
        ])
    }

    func testEveryPieceFitsAndNoWordIsLost() {
        let words = (1...80).map { "word\($0)" + ($0 % 7 == 0 ? "," : "") }
        let text = words.joined(separator: " ")
        let pieces = ClauseSplitter.split(text, maxLength: 60)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 60, piece)
            XCTAssertEqual(piece, piece.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(piece.isEmpty)
        }
        XCTAssertEqual(
            pieces.joined(separator: " ").split(separator: " ").map(String.init), words
        )
    }
}
