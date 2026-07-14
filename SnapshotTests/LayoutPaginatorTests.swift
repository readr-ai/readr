import XCTest
import AppKit
import ReadrKit
@testable import Readr

/// The paged reader's page breaks must come from real text layout, not a
/// character-count estimate: an open book shows two FULL facing pages whose
/// last lines sit on the same baseline. These tests pin the layout-accurate
/// paginator's contract — exact coverage, `Page` folding semantics, and
/// visual fullness/balance — by re-measuring each produced page with the
/// same TextKit configuration the reading surface renders with.
@MainActor
final class LayoutPaginatorTests: XCTestCase {

    private let style = ReaderStyle()
    private let pageSize = CGSize(width: 420, height: 540)

    /// A chapter-sized text: varied paragraph lengths so page breaks land in
    /// interesting places (mid-paragraph, straight after a break, …).
    private func makeText(paragraphs: Int = 60) -> String {
        let sentences = [
            "It was a bright cold day in the reading room, and the lamps burned low.",
            "Nobody had opened the ledger in years; its spine cracked like thin ice when she lifted the cover.",
            "A short line.",
            "The argument of the third chapter, restated plainly, is that attention is a finite instrument and every page spends a little of it.",
            "He wrote in the margin, then crossed it out, then wrote it again in smaller letters.",
        ]
        var paras: [String] = []
        for index in 0..<paragraphs {
            let count = 1 + (index * 7) % 5
            let body = (0..<count).map { sentences[($0 + index) % sentences.count] }
            paras.append(body.joined(separator: " "))
        }
        return paras.joined(separator: "\n\n")
    }

    private func paginate(
        _ text: String, size: CGSize? = nil
    ) -> [ReadrKit.Page] {
        let paginator = LayoutPaginator(style: style, inlineImages: [:])
        let box = size ?? pageSize
        return paginator.paginate(text) { _ in box }
    }

    /// Rendered height of a page's text at the page width, measured with the
    /// exact attribute set the reading surface uses.
    private func renderedHeight(of pageText: String, width: CGFloat) -> CGFloat {
        let attributed = TextRangeConvert.attributedString(
            pageText, highlights: [], style: style
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// The structural fill quantum: the most a full page can fall short of
    /// its container. Chapters separate paragraphs with a blank line, so the
    /// largest unit that can fail to fit at a page bottom is
    /// paragraph-spacing + empty line + paragraph-spacing + text line —
    /// two line boxes and two paragraph spacings. (A page can't be fuller
    /// than "the next unit wouldn't fit"; mid-paragraph breaks only need one
    /// line box of this.)
    private var fillQuantum: CGFloat {
        let lineBox = style.fontSize * 1.2 + style.lineSpacing
        return lineBox * 2 + style.paragraphSpacing * 2 + 4
    }

    // MARK: - Contract

    func testPagesTileTheChapterExactly() {
        let text = makeText()
        let pages = paginate(text)
        XCTAssertGreaterThan(pages.count, 3, "Fixture should span several pages")
        XCTAssertEqual(pages.first?.range.lowerBound, 0)
        XCTAssertEqual(pages.last?.range.upperBound, text.count)
        for (a, b) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(
                a.range.upperBound, b.range.lowerBound,
                "Ranges must be contiguous — no gap or overlap at page joins"
            )
        }
    }

    func testPageTextNeverStartsWithWhitespace() {
        let pages = paginate(makeText())
        for page in pages {
            XCTAssertFalse(
                page.text.first?.isWhitespace ?? true,
                "Boundary whitespace must fold into the range, not the text"
            )
        }
    }

    func testTextStartOffsetRecoversTheChapterSlice() {
        let text = makeText()
        let chars = Array(text)
        for page in paginate(text) {
            let origin = page.textStartOffset
            let slice = String(chars[origin..<(origin + page.text.count)])
            XCTAssertEqual(slice, page.text, "textStartOffset must map page text back into the chapter")
        }
    }

    // MARK: - Fullness (the open-book property)

    func testInteriorPagesAreVisuallyFull() {
        let pages = paginate(makeText())
        // Every page except the last must be full to within the structural
        // quantum of the container height — that's what "fixed pages" means.
        for page in pages.dropLast() {
            let height = renderedHeight(of: page.text, width: pageSize.width)
            XCTAssertGreaterThanOrEqual(
                height, pageSize.height - fillQuantum,
                "An interior page must fill its frame (got \(height) of \(pageSize.height))"
            )
            XCTAssertLessThanOrEqual(
                height, pageSize.height + 1,
                "A page must never overflow its frame"
            )
        }
    }

    func testFacingPagesBottomOutTogether() {
        let pages = paginate(makeText())
        guard pages.count >= 4 else { return XCTFail("Fixture should span several pages") }
        // Consecutive interior pages (a spread) must end within the
        // structural quantum of each other — the two sides of an open book.
        for index in stride(from: 0, to: pages.count - 2, by: 2) {
            let left = renderedHeight(of: pages[index].text, width: pageSize.width)
            let right = renderedHeight(of: pages[index + 1].text, width: pageSize.width)
            XCTAssertLessThanOrEqual(
                abs(left - right), fillQuantum,
                "Facing pages \(index)/\(index + 1) differ by \(abs(left - right))pt"
            )
        }
    }

    /// Hyphenation (on by default with justified text) hyphenates the bottom
    /// line of a measured page — the break must fold the word fragment onto
    /// the next page, never render "beauti" / "ful" across a page turn.
    func testPagesNeverBreakMidWord() {
        let text = makeText()
        let chars = Array(text)
        for page in paginate(text).dropLast() {
            let end = page.range.upperBound
            guard end < chars.count else { continue }
            let brokeMidWord = !chars[end].isWhitespace
                && !chars[end - 1].isWhitespace
                && chars[end - 1] != "-"
            XCTAssertFalse(
                brokeMidWord,
                "Page break splits a word: …\(String(chars[max(0, end - 12)..<end]))"
                    + "|\(String(chars[end..<min(chars.count, end + 12)]))…"
            )
        }
    }

    // MARK: - Variable container sizes (kicker band)

    func testPerPageContainerSizesAreHonored() {
        let text = makeText()
        let paginator = LayoutPaginator(style: style, inlineImages: [:])
        let shortFirst = CGSize(width: pageSize.width, height: pageSize.height - 80)
        let pages = paginator.paginate(text) { index in
            index == 0 ? shortFirst : self.pageSize
        }
        guard pages.count >= 2 else { return XCTFail("Fixture should span several pages") }
        let first = renderedHeight(of: pages[0].text, width: pageSize.width)
        XCTAssertLessThanOrEqual(first, shortFirst.height + 1)
        XCTAssertGreaterThanOrEqual(first, shortFirst.height - fillQuantum)
    }

    // MARK: - Degenerate input

    func testEmptyTextYieldsNoPages() {
        XCTAssertTrue(paginate("").isEmpty)
    }

    func testDegenerateGeometryFallsBackToEmpty() {
        // The view falls back to the estimate-based paginator when layout
        // measurement can't proceed; the signal is an empty result.
        XCTAssertTrue(paginate(makeText(), size: CGSize(width: 2, height: 2)).isEmpty)
    }

    func testShortTextIsOnePage() {
        let pages = paginate("One quiet paragraph.")
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].text, "One quiet paragraph.")
        XCTAssertEqual(pages[0].range, 0..<"One quiet paragraph.".count)
    }
}
