import XCTest
@testable import ReadrKit

final class PDFTextNormalizationTests: XCTestCase {
    func testLargeHyphenatedPageNormalizesWithinImportBudget() {
        let raw = String(repeating: "a-\na ", count: 100_000)
        let completed = expectation(description: "normalize a valid large page within ten seconds")
        DispatchQueue.global().async {
            XCTAssertEqual(PDFPageChapters.normalizedText(raw), String(repeating: "aa ", count: 100_000).trimmingCharacters(in: .whitespaces))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
    }

    func testLongHorizontalWhitespaceDoesNotTriggerRegexBacktracking() {
        let raw = "a" + String(repeating: " ", count: 100_000) + "\nb"
        let completed = expectation(description: "normalize a whitespace-heavy page within ten seconds")
        DispatchQueue.global().async {
            XCTAssertEqual(PDFPageChapters.normalizedText(raw), "a b")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
    }

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
