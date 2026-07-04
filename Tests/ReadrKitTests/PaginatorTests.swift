import XCTest
@testable import ReadrKit

/// Page-layout engine tests: single/double-page rendering is built on these
/// guarantees, so they are the spec for the paged reader.
final class PaginatorTests: XCTestCase {

    func testShortTextIsASinglePage() {
        let pages = Paginator(capacity: 100).paginate("Just a short chapter.")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].text, "Just a short chapter.")
        XCTAssertEqual(pages[0].range, 0..<21)
    }

    func testEmptyTextHasNoPages() {
        XCTAssertTrue(Paginator(capacity: 100).paginate("").isEmpty)
    }

    func testPagesNeverExceedCapacityAndNeverCutWords() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let capacity = 80
        let pages = Paginator(capacity: capacity).paginate(words)

        XCTAssertGreaterThan(pages.count, 1)
        for page in pages {
            XCTAssertLessThanOrEqual(page.text.count, capacity)
            XCTAssertFalse(page.text.hasPrefix(" "))
            // No page starts or ends mid-word: every page's text is a
            // whole-word subsequence of the original word list.
            for token in page.text.split(separator: " ") {
                XCTAssertTrue(token.hasPrefix("word"), "mid-word cut: \(token)")
                XCTAssertNotNil(Int(token.dropFirst(4)), "mid-word cut: \(token)")
            }
        }
    }

    func testAllWordsAreCoveredExactlyOnceInOrder() {
        let words = (0..<150).map { "w\($0)" }
        let text = words.joined(separator: " ")
        let pages = Paginator(capacity: 64).paginate(text)

        let reassembled = pages.flatMap { $0.text.split(separator: " ").map(String.init) }
        XCTAssertEqual(reassembled, words)
    }

    func testRangesAreContiguousAscendingAndCoverTheText() {
        let text = (0..<120).map { "token\($0)" }.joined(separator: " ")
        let pages = Paginator(capacity: 70).paginate(text)

        XCTAssertEqual(pages.first?.range.lowerBound, 0)
        XCTAssertEqual(pages.last?.range.upperBound, text.count)
        for i in 1..<pages.count {
            XCTAssertEqual(
                pages[i].range.lowerBound, pages[i - 1].range.upperBound,
                "ranges must be contiguous"
            )
        }
    }

    func testGiantWordIsHardWrappedNotInfinite() {
        let giant = String(repeating: "x", count: 500)
        let pages = Paginator(capacity: 100).paginate(giant)
        XCTAssertEqual(pages.count, 5)
        XCTAssertTrue(pages.allSatisfy { $0.text.count <= 100 })
    }

    func testPageIndexContainingOffset() {
        let text = (0..<100).map { "t\($0)" }.joined(separator: " ")
        let pages = Paginator(capacity: 50).paginate(text)

        XCTAssertEqual(Paginator.pageIndex(containing: 0, in: pages), 0)
        let lastStart = pages[pages.count - 1].range.lowerBound
        XCTAssertEqual(Paginator.pageIndex(containing: lastStart, in: pages), pages.count - 1)
        // Out-of-range clamps to the last page.
        XCTAssertEqual(Paginator.pageIndex(containing: 999_999, in: pages), pages.count - 1)
        XCTAssertEqual(Paginator.pageIndex(containing: 0, in: []), 0)
    }

    func testSpreadStartMath() {
        XCTAssertEqual(Paginator.spreadStart(for: 0, layout: .doublePage), 0)
        XCTAssertEqual(Paginator.spreadStart(for: 1, layout: .doublePage), 0)
        XCTAssertEqual(Paginator.spreadStart(for: 2, layout: .doublePage), 2)
        XCTAssertEqual(Paginator.spreadStart(for: 5, layout: .doublePage), 4)
        XCTAssertEqual(Paginator.spreadStart(for: 5, layout: .singlePage), 5)
    }

    func testLeadingWhitespaceNeverCutsWordsOrMakesBlankPages() {
        // Regression: the word after leading whitespace is exactly `capacity`
        // long — it must land whole on the first page, not be hard-wrapped.
        let pages = Paginator(capacity: 10).paginate(" abcdefghij rest")
        XCTAssertEqual(pages.first?.text, "abcdefghij")
        XCTAssertEqual(pages.first?.range.lowerBound, 0, "range still anchors at 0")

        // Regression: a run of leading whitespace must not become a blank page.
        let indented = Paginator(capacity: 4).paginate("  abcd ef")
        XCTAssertFalse(
            indented.contains {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            "no whitespace-only pages"
        )
        for page in indented {
            XCTAssertFalse(page.text.hasPrefix(" "), "pages start on a word")
        }
    }

    func testTrailingWhitespaceIsFoldedIntoTheLastPage() {
        let text = (0..<60).map { "w\($0)" }.joined(separator: " ") + "   \n"
        let pages = Paginator(capacity: 40).paginate(text)
        XCTAssertEqual(pages.last?.range.upperBound, text.count)
        for i in 1..<pages.count {
            XCTAssertEqual(pages[i].range.lowerBound, pages[i - 1].range.upperBound)
        }
    }

    func testTextStartOffsetLocatesPageTextExactly() {
        // Multi-space word boundaries force whitespace folding, so ranges start
        // before the text does; textStartOffset must still locate the text.
        let text = "alpha  beta   gamma delta  epsilon zeta eta theta iota kappa"
        let chars = Array(text)
        let pages = Paginator(capacity: 14).paginate(text)
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages {
            let start = page.textStartOffset
            XCTAssertEqual(
                String(chars[start..<(start + page.text.count)]), page.text,
                "textStartOffset must be the chapter offset of the page's text"
            )
        }
    }

    func testPageLayoutSpreadSizes() {
        XCTAssertEqual(PageLayout.scroll.pagesPerSpread, 1)
        XCTAssertEqual(PageLayout.singlePage.pagesPerSpread, 1)
        XCTAssertEqual(PageLayout.doublePage.pagesPerSpread, 2)
    }
}
