import XCTest
@testable import Readr

final class AskPreferencesTests: XCTestCase {
    func testAnswerFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(
            AskPreferences.clampedAnswerFontSize(AskPreferences.minimumAnswerFontSize - 10),
            AskPreferences.minimumAnswerFontSize
        )
        XCTAssertEqual(AskPreferences.clampedAnswerFontSize(17), 17)
        XCTAssertEqual(
            AskPreferences.clampedAnswerFontSize(AskPreferences.maximumAnswerFontSize + 10),
            AskPreferences.maximumAnswerFontSize
        )
    }

    func testContextRangeRawValuesAreStableForPersistence() {
        XCTAssertEqual(AskContextRange.nearby.rawValue, "nearby")
        XCTAssertEqual(AskContextRange.readSoFar.rawValue, "readSoFar")
        XCTAssertEqual(AskContextRange.wholeBook.rawValue, "wholeBook")
    }

    func testKnowledgeSearchFindsRelevantSavedNoteInsteadOfMatchingBookAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readr-knowledge-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KnowledgeBaseStore(root: root)

        let relevant = try store.save(
            question: "先验综合判断为什么可能？",
            answer: "康德认为数学判断扩展知识，同时具有先天必然性。",
            quote: nil,
            bookTitle: "纯粹理性批判",
            author: "康德",
            chapter: nil,
            model: nil
        )
        _ = try store.save(
            question: "目录有几章？",
            answer: "这本书的目录分为若干部分。",
            quote: nil,
            bookTitle: "纯粹理性批判",
            author: "康德",
            chapter: nil,
            model: nil
        )

        let matches = store.relevantEntries(
            for: "数学知识为什么有必然性？",
            selection: "先验综合判断",
            bookTitle: "纯粹理性批判"
        )

        XCTAssertEqual(matches.first?.path, relevant.path)
        XCTAssertFalse(matches.contains { $0.question == "目录有几章？" })
    }
}
