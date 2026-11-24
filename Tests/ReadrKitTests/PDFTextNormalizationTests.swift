import XCTest
@testable import ReadrKit

final class PDFTextNormalizationTests: XCTestCase {
    func testWrappedWordsAreJoinedForNarrationWithoutLosingParagraphs() {
        let result = PDFPageChapters.build(fromPageTexts: ["A won-\nderful story\ncontinues here.\n\nA new paragraph."])
        XCTAssertEqual(result.chapters[0].text, "A wonderful story continues here.\n\nA new paragraph.")
    }
    func testRealHyphensAndPoetryPunctuationSurvive() {
        let result = PDFPageChapters.build(fromPageTexts: ["A well-known story.\r\nNext line.\u{00ad}"])
        XCTAssertEqual(result.chapters[0].text, "A well-known story. Next line.")
    }
    func testSelectionOffsetsStillReachTheSameWordsAfterPDFCleanup() throws {
        let raw = "  A won-\nderful story\ncontinues.\n\nEmoji 🐇 next."
        let normalized = PDFPageChapters.normalizedText(raw)
        for word in ["wonderful", "story", "continues", "Emoji", "🐇", "next"] {
            let sourceWord = word == "wonderful" ? "won-" : word
            let source = try XCTUnwrap(raw.range(of: sourceWord))
            let originalOffset = raw.distance(from: raw.startIndex, to: source.lowerBound)
            let mapped = PDFPageChapters.normalizedOffset(ofCharacter: originalOffset, in: raw)
            XCTAssertTrue(String(normalized.dropFirst(mapped)).hasPrefix(word), word)
        }
    }

}
