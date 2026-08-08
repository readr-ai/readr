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

    func testTrailingWhitespaceFoldKeepsTextStartOffsetAligned() {
        // Regression: the chapter-trailing whitespace tail used to extend
        // only the last page's RANGE, shifting its derived textStartOffset —
        // the origin every page-local highlight/image/span rebase uses.
        let text = makeText() + "\n\n   "
        let chars = Array(text)
        let pages = paginate(text)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.last?.range.upperBound, chars.count, "tail stays covered")
        for page in pages {
            let origin = page.textStartOffset
            let slice = String(chars[origin..<(origin + page.text.count)])
            XCTAssertEqual(slice, page.text, "tail fold must not shift the origin")
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

    // MARK: - Format spans

    /// Heading fonts, heading paragraph spacing, blockquote indents and
    /// paragraph alignment overrides all move page breaks — but the paginator
    /// must still tile the chapter EXACTLY: every character on exactly one
    /// page, no loss, no duplication.
    func testPagesWithFormatSpansTileTheChapterExactly() {
        let text = makeText()
        var spans: [FormatSpan] = [
            FormatSpan(start: 0, end: 40, kind: .heading(1)),
            FormatSpan(start: 0, end: 12, kind: .bold),
            FormatSpan(start: text.count / 3, end: text.count / 3 + 60, kind: .heading(2)),
            FormatSpan(start: text.count / 2, end: text.count / 2 + 200, kind: .blockquote),
            // The audit's new kinds: alignment snaps to whole paragraphs and
            // super/subscript/small-caps change glyph metrics — none may
            // break the tiling contract.
            FormatSpan(
                start: text.count / 4, end: text.count / 4 + 30,
                kind: .alignment(.center)
            ),
            FormatSpan(start: text.count / 5, end: text.count / 5 + 3, kind: .superscript),
            FormatSpan(start: text.count / 5 + 40, end: text.count / 5 + 43, kind: .`subscript`),
            FormatSpan(start: text.count / 6, end: text.count / 6 + 12, kind: .smallCaps),
            FormatSpan(
                start: text.count - 90, end: text.count - 30,
                kind: .link(.external(url: "https://example.com"))
            ),
        ]
        // Deterministic emphasis runs sprinkled through the chapter so
        // several page breaks land inside styled text.
        var cursor = 200
        var bold = true
        while cursor + 120 < text.count {
            spans.append(FormatSpan(
                start: cursor, end: cursor + 80, kind: bold ? .bold : .italic
            ))
            bold.toggle()
            cursor += 900
        }

        let paginator = LayoutPaginator(style: style, inlineImages: [:], formatSpans: spans)
        let pages = paginator.paginate(text) { _ in pageSize }
        XCTAssertGreaterThan(pages.count, 3, "Fixture should span several pages")
        XCTAssertEqual(pages.first?.range.lowerBound, 0)
        XCTAssertEqual(pages.last?.range.upperBound, text.count)
        for (a, b) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(
                a.range.upperBound, b.range.lowerBound,
                "Ranges must be contiguous — no gap or overlap at page joins"
            )
        }
        // And every page's text still maps back into the chapter verbatim.
        let chars = Array(text)
        for page in pages {
            let origin = page.textStartOffset
            XCTAssertEqual(String(chars[origin..<(origin + page.text.count)]), page.text)
        }
    }

    // MARK: - Cost

    /// Pagination cost must be LINEAR in chapter length.
    ///
    /// It was quadratic: each page sliced, copied and re-walked the whole
    /// REMAINDER of the chapter, so cost grew with pages × chapter. A
    /// heading-less `.txt` (a Gutenberg novel) is one 300–600 KB chapter, and
    /// on an iPhone 17 Pro that measured 4.4–4.8 s of blocked main thread per
    /// pagination — a frozen reader on every book open and every chrome tap.
    ///
    /// Ratio-based on purpose: an absolute millisecond budget is a machine
    /// benchmark that flakes on loaded CI. Quadratic growth puts 4× the text
    /// at ~16× the time; linear puts it at ~4×. The 8× gate sits between them
    /// with room for TextKit's own per-page constant and scheduling noise.
    func testPaginationCostGrowsLinearlyWithChapterLength() {
        // The large fixture is deliberately novel-sized (300 KB+): the whole
        // point is the single-chapter `.txt`, so the ratio must be measured at
        // the size that actually broke rather than extrapolated from a small
        // one.
        let small = makeText(paragraphs: 350)
        let large = makeText(paragraphs: 1_400)
        XCTAssertEqual(
            large.count / small.count, 4,
            "Fixture sizes must be a clean 4× for the ratio below to mean anything"
        )

        // Warm TextKit and the font cache so the first run doesn't pay for
        // both and inflate the baseline (which would MASK quadratic growth).
        _ = paginate(makeText(paragraphs: 20))

        let smallElapsed = timePagination(of: small)
        let largeElapsed = timePagination(of: large)

        XCTAssertLessThan(
            largeElapsed, smallElapsed * 8,
            """
            Pagination is growing super-linearly: 4× the text took \
            \(String(format: "%.1f", largeElapsed / smallElapsed))× the time \
            (\(Int(smallElapsed * 1000))ms → \(Int(largeElapsed * 1000))ms). \
            Linear is ~4×; quadratic is ~16×.
            """
        )
    }

    /// A large chapter must still satisfy the tiling contract — the windowing
    /// that makes pagination linear must not drop or duplicate a character,
    /// and must not change where pages break.
    func testLargeChapterStillTilesExactly() {
        let text = makeText(paragraphs: 600)
        let pages = paginate(text)
        XCTAssertGreaterThan(pages.count, 50, "Fixture should span many pages")
        XCTAssertEqual(pages.first?.range.lowerBound, 0)
        XCTAssertEqual(pages.last?.range.upperBound, text.count)
        for (a, b) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(a.range.upperBound, b.range.lowerBound)
        }
        let chars = Array(text)
        for page in pages {
            let origin = page.textStartOffset
            XCTAssertEqual(String(chars[origin..<(origin + page.text.count)]), page.text)
        }
    }

    /// Windowing must be invisible: a page-sized measurement window and an
    /// unbounded one have to produce IDENTICAL breaks. A window that clipped
    /// the measurement short would end pages early — pages that still tile
    /// and still map back, so only a direct comparison catches it.
    /// Swept across scripts and window sizes, not just ASCII English at the
    /// default window — the narrowness of the original fixture is precisely
    /// what let the unbounded whitespace scan (see
    /// `testUnspacedTextCostAlsoGrowsLinearly`) go unnoticed: on spaced
    /// English the snap always found a boundary within a few characters, so
    /// windowed and unwindowed agreed for the wrong reason.
    func testWindowedPaginationMatchesUnwindowedBreaks() {
        let fixtures: [(name: String, text: String)] = [
            ("english", makeText(paragraphs: 120)),
            ("unspaced", makeUnspacedText(characters: 12_000)),
            ("unspaced paragraphs", makeUnspacedText(characters: 12_000, paragraphEvery: 2_000)),
            // One unbroken run longer than any window, then normal prose: the
            // snap has nothing to find until the run ends.
            ("long run", String(repeating: "a", count: 9_000) + " " + makeText(paragraphs: 20)),
        ]
        // Windows far below, around and above a page's worth of text, so the
        // widen-and-re-measure path is exercised as well as the common case.
        for window in [1, 7, 64, 512, 2_048, 4_096, 20_000] {
            for fixture in fixtures {
                let windowed = LayoutPaginator(
                    style: style, inlineImages: [:], measurementWindow: window
                ).paginate(fixture.text) { _ in pageSize }
                let unwindowed = LayoutPaginator(
                    style: style, inlineImages: [:], measurementWindow: .max
                ).paginate(fixture.text) { _ in pageSize }
                XCTAssertEqual(
                    windowed.map(\.range), unwindowed.map(\.range),
                    "Window \(window) moved a page break in \(fixture.name)"
                )
                XCTAssertEqual(
                    windowed.map(\.text), unwindowed.map(\.text),
                    "Window \(window) changed page text in \(fixture.name)"
                )
            }
        }
    }

    /// Formatting moves page breaks, so the windowed and unwindowed passes
    /// must agree with spans applied too — including spans that straddle a
    /// window edge, where a mis-sliced attributed range would show up first.
    func testWindowedPaginationMatchesUnwindowedWithFormatSpans() {
        let text = makeText(paragraphs: 120)
        var spans: [FormatSpan] = [
            FormatSpan(start: 0, end: 40, kind: .heading(1)),
            FormatSpan(start: text.count / 2, end: text.count / 2 + 200, kind: .blockquote),
        ]
        var cursor = 300
        var bold = true
        while cursor + 120 < text.count {
            spans.append(FormatSpan(start: cursor, end: cursor + 90, kind: bold ? .bold : .italic))
            bold.toggle()
            cursor += 512 // deliberately near the swept window sizes
        }
        for window in [512, 2_048, 4_096] {
            let windowed = LayoutPaginator(
                style: style, inlineImages: [:], formatSpans: spans, measurementWindow: window
            ).paginate(text) { _ in pageSize }
            let unwindowed = LayoutPaginator(
                style: style, inlineImages: [:], formatSpans: spans, measurementWindow: .max
            ).paginate(text) { _ in pageSize }
            XCTAssertEqual(
                windowed.map(\.range), unwindowed.map(\.range),
                "Window \(window) moved a break with format spans applied"
            )
        }
    }

    /// Text with NO whitespace to break on.
    ///
    /// Not a synthetic edge case: Chinese and Japanese prose has no spaces by
    /// construction, and the reader advertises plain-text support. A CJK `.txt`
    /// is one chapter of exactly this, and CJK fits ~3× fewer characters per
    /// page than English, so it pages more, not less.
    private func makeUnspacedText(characters: Int, paragraphEvery: Int? = nil) -> String {
        let glyphs = Array("的一是不了人我在有他这为之大来以个中上们到说国和地也子时道出而要于就下得可你年生")
        var out = ""
        out.reserveCapacity(characters * 2)
        for index in 0..<characters {
            if let gap = paragraphEvery, index > 0, index % gap == 0 { out += "\n\n" }
            out.append(glyphs[index % glyphs.count])
        }
        return out
    }

    /// The whitespace snap must not become an unbounded scan.
    ///
    /// The bounded measurement window snaps FORWARD to a word boundary so a
    /// truncated word can't hand the line breaker a short fragment. That snap
    /// looks for WHITESPACE — so on text that has none it ran to the chapter's
    /// end, the slice became the whole remainder, and the window was a no-op:
    /// byte-for-byte the quadratic behaviour it exists to prevent, with the
    /// scan itself added on top. English hid it completely.
    func testUnspacedTextCostAlsoGrowsLinearly() {
        let small = makeUnspacedText(characters: 25_000)
        let large = makeUnspacedText(characters: 100_000)
        _ = paginate(makeText(paragraphs: 20)) // warm

        let smallElapsed = timePagination(of: small)
        let largeElapsed = timePagination(of: large)

        XCTAssertLessThan(
            largeElapsed, smallElapsed * 8,
            """
            Pagination is super-linear on unspaced text: 4× took \
            \(String(format: "%.1f", largeElapsed / smallElapsed))× \
            (\(Int(smallElapsed * 1000))ms → \(Int(largeElapsed * 1000))ms). \
            The word-boundary snap has no whitespace to find and is scanning \
            to the end of the chapter.
            """
        )
    }

    /// The same, for the realistic shape: CJK prose in long paragraphs, so
    /// there IS whitespace but thousands of characters apart.
    func testUnspacedParagraphsCostGrowsLinearly() {
        let small = makeUnspacedText(characters: 25_000, paragraphEvery: 2_000)
        let large = makeUnspacedText(characters: 100_000, paragraphEvery: 2_000)
        _ = paginate(makeText(paragraphs: 20)) // warm

        let smallElapsed = timePagination(of: small)
        let largeElapsed = timePagination(of: large)
        XCTAssertLessThan(
            largeElapsed, smallElapsed * 8,
            "CJK-shaped paragraphs grew \(String(format: "%.1f", largeElapsed / smallElapsed))×"
        )
    }

    private func timePagination(of text: String) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        let pages = paginate(text)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertFalse(pages.isEmpty, "Fixture must actually paginate")
        return elapsed
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
