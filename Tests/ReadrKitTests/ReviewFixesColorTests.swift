import XCTest
@testable import ReadrKit

/// Regressions from the review of the colour work (PR #65).
///
/// Each of these was a real defect found after the feature "worked" — mostly
/// where a plausible shortcut met an input the happy path never covered.
final class ReviewFixesColorTests: XCTestCase {

    private func style(_ css: String) -> ResolvedStyle {
        CSSStyleResolver.declarations(css)
    }

    // MARK: - Translucent colours were judged as if opaque

    /// `rgba(0, 0, 0, 0.05)` — the "subtle grey panel" idiom — is *painted* as
    /// a near-white wash but *measured* as pure black, so the legibility check
    /// picked white ink and the paragraph vanished into the page.
    func testTranslucentBackgroundIsJudgedOnWhatItLooksLike() throws {
        let wash = try XCTUnwrap(CSSStyleResolver.color("rgba(0, 0, 0, 0.05)"))
        let page = CSSColor(red: 0.98, green: 0.97, blue: 0.94)

        XCTAssertFalse(wash.isClear, "5% black is visible, so it opens a span")
        // Raw, it reads as black and would demand white ink.
        XCTAssertEqual(wash.legibleInk, .white)
        // Composited — what the reader sees — it is nearly the page colour.
        let painted = wash.composited(over: page)
        XCTAssertEqual(painted.legibleInk, .black, "the wash needs dark ink")
        XCTAssertTrue(painted.legibleInk.isReadable(on: painted))
    }

    /// The mirror case: near-transparent *text* passed the contrast check as
    /// its undiluted self and then rendered invisible.
    func testTranslucentTextIsJudgedOnWhatItLooksLike() throws {
        let ghost = try XCTUnwrap(CSSStyleResolver.color("rgba(0, 0, 0, 0.03)"))
        let page = CSSColor(red: 1, green: 1, blue: 1)

        XCTAssertTrue(ghost.isReadable(on: page), "raw black passes — the trap")
        XCTAssertFalse(
            ghost.composited(over: page).isReadable(on: page),
            "3% black on white is invisible and must be rejected"
        )
    }

    func testCompositingIsANoOpForOpaqueColours() {
        let solid = CSSColor(red: 0.2, green: 0.4, blue: 0.6)
        XCTAssertEqual(solid.composited(over: .white), solid)
    }

    func testFullyTransparentCompositesToTheBackdrop() {
        let clear = CSSColor(red: 1, green: 0, blue: 0, alpha: 0)
        XCTAssertEqual(clear.composited(over: .white), .white)
    }

    // MARK: - The `background` shorthand dropped functional colours

    /// Functional notation contains spaces, so splitting the shorthand on
    /// whitespace left only fragments and the declaration parsed as nothing —
    /// silently dropping exactly the highlight the feature exists to show.
    func testBackgroundShorthandParsesFunctionalColours() {
        XCTAssertEqual(
            style("background: rgba(255, 235, 59, 0.6)").background,
            CSSColor(red: 1, green: 235.0 / 255, blue: 59.0 / 255, alpha: 0.6)
        )
        XCTAssertNotNil(style("background: rgb(255, 0, 0)").background)
        XCTAssertNotNil(style("background: rgb(255 0 0)").background)
    }

    /// The colour can sit anywhere among the shorthand's other slots.
    func testBackgroundShorthandFindsTheColourAmongOtherSlots() {
        XCTAssertNotNil(style("background: none repeat rgb(255, 0, 0)").background)
        XCTAssertEqual(
            style("background: #ffff00 none repeat").background,
            CSSColor(red: 1, green: 1, blue: 0)
        )
    }

    func testBackgroundShorthandWithNoColourStaysUndeclared() {
        XCTAssertNil(style("background: url(paper.png) repeat-x").background)
    }

    // MARK: - Non-finite channels poisoned persistence

    /// `Double("nan")` succeeds and `min`/`max` pass NaN through, so
    /// `rgb(nan,0,0)` produced a `CSSColor` that `JSONEncoder` refuses. Because
    /// these ride inside a persisted `FormatSpan`, one hostile book stopped
    /// every later library save for the rest of the session.
    func testNonFiniteChannelsCannotSurviveIntoAColor() throws {
        for css in ["rgb(nan, 0, 0)", "rgb(infinity, 0, 0)", "rgba(0, 0, 0, nan)"] {
            guard let color = CSSStyleResolver.color(css) else { continue }
            XCTAssertTrue(color.red.isFinite, css)
            XCTAssertTrue(color.green.isFinite, css)
            XCTAssertTrue(color.blue.isFinite, css)
            XCTAssertTrue(color.alpha.isFinite, css)
        }
    }

    /// The property that actually matters: a colour must always encode.
    func testEveryParsedColourIsEncodable() throws {
        let encoder = JSONEncoder()
        for css in [
            "rgb(nan,0,0)", "rgb(999, -5, 0)", "#ff0000", "rgba(0,0,0,2)",
            "rgb(100%, 100%, 0%)", "yellow",
        ] {
            guard let color = CSSStyleResolver.color(css) else { continue }
            XCTAssertNoThrow(
                try encoder.encode(FormatSpan(start: 0, end: 1, kind: .colored(color))),
                "\(css) produced an unencodable colour"
            )
        }
    }

    func testChannelsAreClampedIntoRange() throws {
        let over = try XCTUnwrap(CSSStyleResolver.color("rgb(999, 0, 0)"))
        XCTAssertEqual(over.red, 1)
        let alpha = try XCTUnwrap(CSSStyleResolver.color("rgba(0, 0, 0, 5)"))
        XCTAssertEqual(alpha.alpha, 1)
    }

    // MARK: - Malformed values must stay undeclared

    /// `UInt8(_:radix:)` accepts a leading sign, so `#+f0f0f` parsed as a real
    /// colour instead of being rejected.
    func testSignedHexIsRejected() {
        XCTAssertNil(CSSStyleResolver.color("#+f0f0f"))
        XCTAssertNil(CSSStyleResolver.color("#-f0f0f"))
        XCTAssertNil(CSSStyleResolver.color("#ggghhh"))
    }

    /// `none` is the background-*image* slot, not a colour keyword. Treating it
    /// as a declared clear colour let it participate in the cascade.
    func testNoneIsNotAColour() {
        XCTAssertNil(CSSStyleResolver.color("none"))
        XCTAssertNil(style("color: none").foreground)
    }

    func testTransparentIsStillAColour() throws {
        let clear = try XCTUnwrap(CSSStyleResolver.color("transparent"))
        XCTAssertTrue(clear.isClear)
    }
}

/// A colour span covering the whole document is the page's own colour, not a
/// highlight (#47 review).
final class DocumentWideColorSpanTests: XCTestCase {

    /// calibre and InDesign wrap content in `<div class="calibre">` carrying
    /// the body's `background-color: #fff`. Excluding only `html`/`body` let
    /// that through as one highlight over every character — a full page of
    /// white paint with forced black ink, which on the dark theme is a glaring
    /// white block in a dark app.
    func testAWrapperDivBackgroundIsNotAHighlight() {
        let styles = CSSStyleResolver(css: ".calibre { background-color: #ffffff }")
        // Long enough for the fraction rule to apply — a real chapter, not a
        // title page (see `documentWideColorSpanMinimumLength`).
        let body = String(repeating: "<p>Ordinary prose in a chapter body.</p>", count: 8)
        let html = #"<div class="calibre">"# + body + "</div>"
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)

        XCTAssertFalse(
            result.spans.contains {
                if case .highlighted = $0.kind { return true }
                return false
            },
            "a document-wide background must not become a highlight"
        )
    }

    /// The same exclusion must not swallow a real highlight, however generous
    /// the passage it marks.
    func testAMarkOnOnePassageSurvives() {
        let styles = CSSStyleResolver(css: ".mark { background-color: #fff2a8 }")
        let html = """
        <p>Plenty of ordinary prose comes first, and then rather a lot more of \
        it, so the marked run stays a minority of the document.</p>\
        <p><span class="mark">Marked.</span></p>
        """
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)

        XCTAssertEqual(
            result.spans.filter {
                if case .highlighted = $0.kind { return true }
                return false
            }.count,
            1
        )
    }

    /// A wrapper `color` is the book's base ink and gets the same treatment.
    func testAWrapperDivColourIsNotAColouredRun() {
        let styles = CSSStyleResolver(css: ".calibre { color: #333333 }")
        let body = String(repeating: "<p>Ordinary prose in a chapter body.</p>", count: 8)
        let result = XHTMLTextExtractor.extract(
            from: #"<div class="calibre">"# + body + "</div>", styles: styles
        )
        XCTAssertFalse(
            result.spans.contains {
                if case .colored = $0.kind { return true }
                return false
            }
        )
    }

    func testTheFilterLeavesNonColourSpansAlone() {
        let styles = CSSStyleResolver(css: ".calibre { font-style: italic }")
        let body = String(repeating: "<p>Ordinary prose in a chapter body.</p>", count: 8)
        let result = XHTMLTextExtractor.extract(
            from: #"<div class="calibre">"# + body + "</div>", styles: styles
        )
        XCTAssertTrue(
            result.spans.contains { $0.kind == .italic },
            "a document-wide italic is a real formatting fact"
        )
    }
}
