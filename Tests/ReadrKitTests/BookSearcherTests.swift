import XCTest
@testable import ReadrKit

final class BookSearcherTests: XCTestCase {

    /// Book from (title, text) chapter pairs, in order.
    private func makeBook(_ chapters: [(title: String?, text: String)]) -> Book {
        Book(
            metadata: BookMetadata(title: "Searchable"),
            chapters: chapters.enumerated().map { index, chapter in
                Chapter(title: chapter.title, order: index, text: chapter.text)
            },
            estimatedTokenCount: 10
        )
    }

    // MARK: - Empty / no-match

    func testEmptyAndWhitespaceQueriesReturnNothing() {
        let book = makeBook([("One", "some text here")])
        XCTAssertEqual(BookSearcher.search("", in: book), [])
        XCTAssertEqual(BookSearcher.search("   \n\t", in: book), [])
    }

    func testNoMatchReturnsEmpty() {
        let book = makeBook([("One", "some text here")])
        XCTAssertEqual(BookSearcher.search("zebra", in: book), [])
    }

    // MARK: - Offsets

    func testOffsetsMatchManualCharacterCounts() {
        //           0123456789012345678901234
        let text = "The cat sat. A cat! CAT."
        let book = makeBook([("One", text)])
        let results = BookSearcher.search("cat", in: book)
        XCTAssertEqual(results.map(\.characterOffset), [4, 15, 20])
        XCTAssertEqual(results.map(\.id), [0, 1, 2])
    }

    func testOffsetsCountCharactersNotBytesAroundEmojiAndAccents() {
        // Characters: é(0) 😀(1) ␣(2) c(3)a(4)f(5)é(6) ␣(7) —(8) ␣(9) c(10)...
        let text = "é😀 café — café"
        let book = makeBook([(nil, text)])
        let results = BookSearcher.search("café", in: book)
        XCTAssertEqual(results.map(\.characterOffset), [3, 10])

        // Each offset must round-trip: advancing by it lands on the match.
        for result in results {
            let start = text.index(text.startIndex, offsetBy: result.characterOffset)
            XCTAssertTrue(text[start...].hasPrefix("café"))
        }
    }

    func testOffsetsStayCorrectAcrossManyMatchesInOneChapter() {
        // "ha ha ha ..." — the incremental offset bookkeeping must not drift.
        let text = String(repeating: "ha ", count: 20)
        let book = makeBook([(nil, text)])
        let results = BookSearcher.search("ha", in: book)
        XCTAssertEqual(results.map(\.characterOffset), (0..<20).map { $0 * 3 })
    }

    // MARK: - Case-insensitivity

    func testSearchIsCaseInsensitive() {
        let book = makeBook([("One", "Ministry of truth. MINISTRY again, ministry twice.")])
        let results = BookSearcher.search("MiNiStRy", in: book)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.characterOffset), [0, 19, 35])
    }

    // MARK: - Chapter metadata

    func testResultsCarryChapterIndexAndTitle() {
        let book = makeBook([
            ("Opening", "nothing to see"),
            (nil, "the needle is here"),
        ])
        let results = BookSearcher.search("needle", in: book)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chapterIndex, 1)
        XCTAssertNil(results[0].chapterTitle)
        XCTAssertEqual(results[0].characterOffset, 4)
    }

    // MARK: - Result cap

    func testLimitCapsResultsWithinAChapter() {
        let book = makeBook([(nil, String(repeating: "ha ", count: 10))])
        let results = BookSearcher.search("ha", in: book, limit: 4)
        XCTAssertEqual(results.map(\.characterOffset), [0, 3, 6, 9])
    }

    func testLimitCapsResultsAcrossChapters() {
        let book = makeBook([
            ("One", "hit and hit"),
            ("Two", "hit and hit"),
        ])
        let results = BookSearcher.search("hit", in: book, limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.chapterIndex), [0, 0, 1])
    }

    func testDefaultCapIsApplied() {
        let book = makeBook([(nil, String(repeating: "ha ", count: BookSearcher.resultCap + 50))])
        XCTAssertEqual(BookSearcher.search("ha", in: book).count, BookSearcher.resultCap)
    }

    // MARK: - Snippets

    func testSnippetOfShortTextHasNoEllipses() {
        let book = makeBook([(nil, "just a needle here")])
        let results = BookSearcher.search("needle", in: book)
        XCTAssertEqual(results[0].snippet, "just a needle here")
    }

    func testSnippetAtTextStartOmitsLeadingEllipsis() {
        let text = "needle first, then a very long tail that runs past the context window for sure"
        let book = makeBook([(nil, text)])
        let snippet = BookSearcher.search("needle", in: book)[0].snippet
        XCTAssertTrue(snippet.hasPrefix("needle"))
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testSnippetAtTextEndOmitsTrailingEllipsis() {
        let text = "a very long preamble that runs well past the context window before the needle"
        let book = makeBook([(nil, text)])
        let snippet = BookSearcher.search("needle", in: book)[0].snippet
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("needle"))
    }

    func testSnippetInTheMiddleHasBothEllipsesAndCollapsesNewlines() {
        let text = String(repeating: "x", count: 50) + "\nneedle\n" + String(repeating: "y", count: 50)
        let book = makeBook([(nil, text)])
        let snippet = BookSearcher.search("needle", in: book)[0].snippet
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains(" needle "))
        XCTAssertFalse(snippet.contains("\n"))
    }
}
