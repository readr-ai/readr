import Foundation
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

    func testApplyingGeneratedMetadataPreservesEditsMadeAfterSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readr-knowledge-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KnowledgeBaseStore(root: root)
        let saved = try store.save(
            question: "What changed?",
            answer: "The answer that generated the initial title.",
            quote: nil,
            bookTitle: "Editable Book",
            author: nil,
            chapter: nil,
            model: "local"
        )

        var edited = try String(contentsOfFile: saved.path, encoding: .utf8)
        edited = KnowledgeBaseStore.updatingFrontMatter(
            in: edited,
            replacements: [
                ("title", "\"Reader title\""),
                ("tags", "[manual-tag]"),
            ]
        )
        edited = edited.replacingOccurrences(
            of: "status: seedling",
            with: "status: seedling\ncustom-field: keep-me"
        )
        edited = edited.replacingOccurrences(
            of: "## 我的批注\n\n\n## 相关",
            with: "## 我的批注\n\nKeep this reader annotation.\n\n## Custom section\n\nKeep custom prose.\n\n## 相关"
        )
        try edited.write(toFile: saved.path, atomically: true, encoding: .utf8)

        let renamed = try store.applyMetadata(
            title: "Generated title",
            tags: ["generated-tag", "manual-tag"],
            links: ["New concept"],
            to: saved.path
        )
        let result = try String(contentsOfFile: renamed.path, encoding: .utf8)
        let front = KnowledgeBaseStore.frontMatter(of: result)

        XCTAssertTrue(front.scalars["title"]?.contains("Reader title") == true)
        XCTAssertEqual(front.scalars["custom-field"], "keep-me")
        XCTAssertEqual(front.arrays["tags"], ["manual-tag", "generated-tag"])
        XCTAssertTrue(result.contains("Keep this reader annotation."))
        XCTAssertTrue(result.contains("## Custom section\n\nKeep custom prose."))
        XCTAssertTrue(result.contains("[[New concept]]"))
    }

    func testApplyingMetadataPreservesObsidianBlockTagsAndLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readr-knowledge-block-yaml-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KnowledgeBaseStore(root: root)
        let saved = try store.save(
            question: "Question", answer: "Answer", quote: nil,
            bookTitle: "Book", author: nil, chapter: nil, model: "local"
        )
        var edited = try String(contentsOfFile: saved.path, encoding: .utf8)
        edited = edited.replacingOccurrences(
            of: "tags: []\nlinks: [\"[[Book]]\"]",
            with: "tags:\n  - manual-tag\nlinks:\n  - \"[[Manual concept]]\"\n  - \"[[Book]]\""
        )
        try edited.write(toFile: saved.path, atomically: true, encoding: .utf8)

        let renamed = try store.applyMetadata(
            title: nil,
            tags: ["generated-tag"],
            links: ["Generated concept"],
            to: saved.path
        )
        let result = try String(contentsOfFile: renamed.path, encoding: .utf8)
        let front = KnowledgeBaseStore.frontMatter(of: result)

        XCTAssertEqual(front.arrays["tags"], ["manual-tag", "generated-tag"])
        XCTAssertEqual(
            front.arrays["links"],
            ["Manual concept", "Book", "Generated concept"]
        )
        XCTAssertFalse(result.contains("\n  - manual-tag"))
        XCTAssertFalse(result.contains("\n  - \"[[Manual concept]]\""))
    }
}
