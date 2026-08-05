import XCTest
@testable import ReadrKit

/// Text a book styles as a highlight must look highlighted (#47).
///
/// In "The Book of Elon" the "Notes on This Book" chapter says highlights
/// "look like this" and gives an inline example — which rendered as plain body
/// text, making the sentence nonsense. Bold worked in the same chapter, so it
/// wasn't a general CSS failure: `ResolvedStyle` had no notion of colour at
/// all, so a class styled with `background-color` resolved to nothing.
///
/// Only `background-color` is honoured, deliberately — see
/// `CSSStyleResolver`'s note on why a book's `color` is not allowed to
/// override the reader's theme.
final class CSSColorParsingTests: XCTestCase {

    private func style(_ css: String) -> ResolvedStyle {
        CSSStyleResolver.declarations(css)
    }

    // MARK: - Notations

    func testParsesSixDigitHex() {
        XCTAssertEqual(
            style("background-color: #ffff00").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
    }

    func testParsesThreeDigitHex() {
        // #ff0 expands to #ffff00, not #0f0f00.
        XCTAssertEqual(
            style("background-color: #ff0").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
    }

    func testParsesEightDigitHexWithAlpha() {
        let color = style("background-color: #ffff0080").background
        XCTAssertEqual(color?.red, 1)
        XCTAssertEqual(try XCTUnwrap(color?.alpha), 0.5, accuracy: 0.01)
    }

    func testParsesRGBAndRGBA() {
        XCTAssertEqual(
            style("background-color: rgb(255, 255, 0)").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
        let rgba = style("background-color: rgba(255, 0, 0, 0.5)").background
        XCTAssertEqual(try XCTUnwrap(rgba?.alpha), 0.5, accuracy: 0.01)
        XCTAssertEqual(rgba?.red, 1)
    }

    /// Percentages are legal in `rgb()` and calibre exports use them.
    func testParsesRGBPercentages() {
        XCTAssertEqual(
            style("background-color: rgb(100%, 100%, 0%)").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
    }

    func testParsesNamedColours() {
        XCTAssertEqual(
            style("background-color: yellow").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
        XCTAssertEqual(
            style("background-color: white").background,
            CSSColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    }

    /// The `background` shorthand carries the colour in most EPUB stylesheets.
    func testParsesTheBackgroundShorthand() {
        XCTAssertEqual(
            style("background: #ffff00").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
        // A shorthand with more than a colour still yields its colour slot.
        XCTAssertEqual(
            style("background: #ffff00 none repeat").background,
            CSSColor(red: 1, green: 1, blue: 0, alpha: 1)
        )
    }

    // MARK: - Nothing to paint

    /// `transparent` and `none` cancel an inherited highlight rather than
    /// painting one — they must resolve to a declared-but-invisible value, not
    /// to "undeclared".
    func testTransparentResolvesToClearNotNil() throws {
        let color = try XCTUnwrap(style("background-color: transparent").background)
        XCTAssertEqual(color.alpha, 0)
        XCTAssertTrue(color.isClear)
    }

    func testUnparseableValuesLeaveItUndeclared() {
        for value in ["inherit", "currentColor", "url(bg.png)", "#12345", "rgb(1,2)", "chartreusey"] {
            XCTAssertNil(
                style("background-color: \(value)").background,
                "\(value) should stay undeclared rather than guess"
            )
        }
    }

    /// A book's `color` must not override the reader's theme — see the
    /// resolver's note. It stays unparsed on purpose.
    func testForegroundColourIsDeliberatelyIgnored() {
        XCTAssertTrue(style("color: #ff0000").isEmpty)
    }

    // MARK: - Cascade

    func testBackgroundParticipatesInOverlay() {
        var base = ResolvedStyle(background: CSSColor(red: 1, green: 1, blue: 0, alpha: 1))
        base.overlay(ResolvedStyle(bold: true))
        XCTAssertEqual(base.background?.red, 1, "an unrelated overlay must not clear it")

        base.overlay(ResolvedStyle(background: CSSColor(red: 0, green: 0, blue: 0, alpha: 0)))
        XCTAssertEqual(base.background?.alpha, 0, "a later rule must be able to cancel it")
    }

    func testAStyleWithOnlyABackgroundIsNotEmpty() {
        XCTAssertFalse(
            ResolvedStyle(background: CSSColor(red: 1, green: 1, blue: 0, alpha: 1)).isEmpty
        )
    }
}

/// End-to-end: the reported chapter shape, from stylesheet to spans.
final class HighlightedRunExtractionTests: XCTestCase {

    private func highlights(
        _ result: XHTMLTextExtractor.ExtractionResult
    ) -> [XHTMLTextExtractor.Span] {
        result.spans.filter {
            if case .highlighted = $0.kind { return true }
            return false
        }
    }

    /// The bug as filed: a classed inline run that the stylesheet highlights.
    func testClassStyledRunBecomesAHighlightedSpan() throws {
        let styles = CSSStyleResolver(css: ".highlight { background-color: #fff2a8 }")
        let html = #"<p>They look like this: <span class="highlight">I am a highlight.</span></p>"#
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)

        let spans = highlights(result)
        XCTAssertEqual(spans.count, 1, "the classed run must carry a highlight span")

        let span = try XCTUnwrap(spans.first)
        let characters = Array(result.text)
        XCTAssertEqual(String(characters[span.start..<span.end]), "I am a highlight.")

        guard case .highlighted(let color) = span.kind else {
            return XCTFail("expected a highlighted span, got \(span.kind)")
        }
        XCTAssertEqual(color.alpha, 1)
    }

    /// Body-wide `background: white` is page furniture, not a highlight —
    /// painting it over every paragraph would fight the reader's theme.
    func testPageLevelBackgroundsAreNotTreatedAsHighlights() {
        let styles = CSSStyleResolver(
            css: "body { background-color: #ffffff } html { background: white }"
        )
        let result = XHTMLTextExtractor.extract(
            from: "<body><p>Ordinary prose.</p></body>", styles: styles
        )
        XCTAssertTrue(
            highlights(result).isEmpty,
            "a page background must not become a text highlight"
        )
    }

    /// `transparent` exists to cancel, so it must open no span.
    func testTransparentBackgroundOpensNoSpan() {
        let styles = CSSStyleResolver(css: ".plain { background-color: transparent }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span class="plain">Nothing here.</span></p>"#, styles: styles
        )
        XCTAssertTrue(highlights(result).isEmpty)
    }

    /// An inline `style` attribute is the other way books mark these runs.
    func testInlineStyleBackgroundAlsoHighlights() {
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span style="background-color: yellow">marked</span></p>"#,
            styles: CSSStyleResolver(css: "")
        )
        XCTAssertEqual(highlights(result).count, 1)
    }
}
