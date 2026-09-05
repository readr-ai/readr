import XCTest
@testable import ReadrKit

/// The backstop that shortens a retrieval prompt for a hard-windowed model.
/// The bug this pins: an earlier version split passages on blank lines (book
/// prose has them) and, once down to its placeholder, kept returning the
/// same prompt — so the caller's fitting loop never ended.
final class RetrievalPromptTrimmerTests: XCTestCase {

    private func prompt(passages: [String], anchor: String = "Selected text: here") -> String {
        anchor
            + AdaptiveContextStrategy.passagesHeader
            + passages.joined(separator: AdaptiveContextStrategy.passageSeparator)
            + AdaptiveContextStrategy.questionPrefix + "Why?"
    }

    func testDropsWholePassagesFromTheEndKeepingBlankLinesInsideThem() {
        let first = "[Ch. 1] A paragraph.\n\nA second paragraph of the same passage."
        let second = "[Ch. 2] Another passage."
        let once = RetrievalPromptTrimmer.droppingLastPassage(from: prompt(passages: [first, second]))
        XCTAssertEqual(once, prompt(passages: [first]))
        let twice = RetrievalPromptTrimmer.droppingLastPassage(from: once!)
        XCTAssertEqual(twice, prompt(passages: [RetrievalPromptTrimmer.omittedPlaceholder]))
        XCTAssertNil(
            RetrievalPromptTrimmer.droppingLastPassage(from: twice!),
            "nothing left to drop — a loop on this must end"
        )
    }

    func testAPromptWithoutAPassageBlockIsLeftAlone() {
        let article = "Highlights:\n- one\n- two\n\nWrite an article."
        XCTAssertNil(RetrievalPromptTrimmer.droppingLastPassage(from: article))
        XCTAssertEqual(RetrievalPromptTrimmer.fit(article, budget: 1) { $0.count }, article)
    }

    func testFitStopsAtTheBudgetOrAtThePlaceholder() {
        let passages = (1...5).map { "[Ch. \($0)] " + String(repeating: "words ", count: 20) }
        let full = prompt(passages: passages)
        let fitted = RetrievalPromptTrimmer.fit(full, budget: full.count - 150) { $0.count }
        XCTAssertLessThanOrEqual(fitted.count, full.count - 150)
        XCTAssertTrue(fitted.contains("[Ch. 1]"))
        XCTAssertFalse(fitted.contains("[Ch. 5]"))

        let impossible = RetrievalPromptTrimmer.fit(full, budget: 10) { $0.count }
        XCTAssertTrue(impossible.contains(RetrievalPromptTrimmer.omittedPlaceholder))
        XCTAssertTrue(impossible.hasSuffix(AdaptiveContextStrategy.questionPrefix + "Why?"))
    }

    func testTheReadSoFarFallbackIsOnePassageNotManyParagraphs() {
        let tail = "[Read so far] Para one.\n\nPara two.\n\nPara three."
        XCTAssertEqual(RetrievalPromptTrimmer.passages(in: tail), [tail])
    }
}
