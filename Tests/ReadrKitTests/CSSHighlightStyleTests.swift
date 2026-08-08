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

    /// `color` parses unconditionally; whether it is *honoured* is the
    /// renderer's judgement, made against the active theme.
    func testForegroundColourParses() {
        XCTAssertEqual(
            style("color: #ff0000").foreground,
            CSSColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        XCTAssertNil(style("color: #ff0000").background, "colour must not leak into background")
        XCTAssertNil(
            style("background-color: #ff0000").foreground,
            "background must not leak into foreground"
        )
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
        XCTAssertFalse(
            ResolvedStyle(foreground: CSSColor(red: 1, green: 0, blue: 0, alpha: 1)).isEmpty
        )
    }
}

/// The contrast rule that decides whether a book's `color` survives (#47).
///
/// This is what makes honouring `color` safe at all: a book picks its colours
/// against its own page, and Readr renders on three of them.
final class ColorContrastTests: XCTestCase {

    private let white = CSSColor(red: 1, green: 1, blue: 1)
    private let black = CSSColor(red: 0, green: 0, blue: 0)

    func testContrastRatioMatchesWCAG() {
        // Black on white is the maximum, 21:1.
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.01)
    }

    func testRatioIsSymmetric() {
        XCTAssertEqual(
            black.contrastRatio(against: white),
            white.contrastRatio(against: black),
            accuracy: 0.0001
        )
    }

    /// The case the whole rule exists for: a heading set in dark blue reads on
    /// the book's cream page and vanishes on Readr's dark theme.
    func testDarkBlueReadsOnPaperAndFailsOnNight() {
        let darkBlue = CSSColor(hex24: 0x1A237E)
        let paper = CSSColor(hex24: 0xFAF7F0)
        let night = CSSColor(hex24: 0x1E1B14)

        XCTAssertTrue(darkBlue.isReadable(on: paper), "should survive on the paper theme")
        XCTAssertFalse(darkBlue.isReadable(on: night), "must be dropped on the dark theme")
    }

    /// And the mirror: pale text a dark-paged book uses, which would vanish on
    /// Readr's paper theme.
    func testPaleTextFailsOnPaperAndReadsOnNight() {
        let paleYellow = CSSColor(hex24: 0xFFF8B0)
        XCTAssertFalse(paleYellow.isReadable(on: CSSColor(hex24: 0xFAF7F0)))
        XCTAssertTrue(paleYellow.isReadable(on: CSSColor(hex24: 0x1E1B14)))
    }

    /// The threshold is WCAG AA for body text, not a guess.
    func testThresholdIsAA() {
        XCTAssertEqual(CSSColor.minimumReadableContrast, 4.5)
    }

    /// A colour on its own highlight — the both-declared case the renderer
    /// resolves before falling back to black/white ink.
    func testDarkRedIsReadableOnAPaleHighlight() {
        XCTAssertTrue(CSSColor(hex24: 0x8B0000).isReadable(on: CSSColor(hex24: 0xFFF2A8)))
        XCTAssertFalse(CSSColor(hex24: 0xFFE0E0).isReadable(on: CSSColor(hex24: 0xFFF2A8)))
    }

    // MARK: - The ink chosen for a highlight

    /// Caught by the snapshot suite: choosing ink by a luminance threshold
    /// hands mid-tones the *worse* of the two. Grey scores 5.3:1 on black and
    /// 3.9:1 on white, so a "dark background → white ink" rule fails AA.
    func testMidTonesGetTheHigherContrastInkNotTheObviousOne() {
        for hex in [0x808080, 0xFF00FF, 0x00FF00, 0x1A237E] as [UInt32] {
            let background = CSSColor(hex24: hex)
            let ink = background.legibleInk
            XCTAssertTrue(
                ink.isReadable(on: background),
                "\(String(hex, radix: 16)) → contrast "
                    + "\(ink.contrastRatio(against: background))"
            )
        }
    }

    /// Black and white are the only outcomes — the ink is never the book's.
    func testLegibleInkIsAlwaysBlackOrWhite() {
        for hex in [0x000000, 0xFFFFFF, 0x808080, 0xFFF2A8] as [UInt32] {
            let ink = CSSColor(hex24: hex).legibleInk
            XCTAssertTrue(ink == .black || ink == .white, "\(ink)")
        }
    }

    /// The tightest case in the whole space: at luminance 0.179 the two inks
    /// tie. It still clears AA, which is what makes "best of two" sufficient
    /// rather than merely usually-right.
    func testTheWorstCaseBackgroundStillClearsAA() {
        // Grey whose relative luminance is ≈0.179 (sRGB ≈ 0x767676).
        let worst = CSSColor(hex24: 0x767676)
        XCTAssertEqual(worst.luminance, 0.179, accuracy: 0.01)
        XCTAssertTrue(
            worst.legibleInk.isReadable(on: worst),
            "contrast \(worst.legibleInk.contrastRatio(against: worst))"
        )
    }
}

private extension CSSColor {
    /// Test-local 0xRRGGBB convenience (the app target has its own for theme
    /// tokens; ReadrKit itself has no need of one).
    init(hex24: UInt32) {
        self.init(
            red: Double((hex24 >> 16) & 0xFF) / 255,
            green: Double((hex24 >> 8) & 0xFF) / 255,
            blue: Double(hex24 & 0xFF) / 255
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

    // MARK: - Foreground colour

    private func colored(
        _ result: XHTMLTextExtractor.ExtractionResult
    ) -> [XHTMLTextExtractor.Span] {
        result.spans.filter {
            if case .colored = $0.kind { return true }
            return false
        }
    }

    func testClassStyledColourBecomesAColoredSpan() throws {
        let styles = CSSStyleResolver(css: ".lede { color: #8b0000 }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span class="lede">A red run.</span> Plain.</p>"#, styles: styles
        )
        let spans = colored(result)
        XCTAssertEqual(spans.count, 1)

        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(String(Array(result.text)[span.start..<span.end]), "A red run.")
    }

    /// `body { color: … }` is the book's base ink, which the reader's theme
    /// already supplies — colouring every paragraph with it would override the
    /// theme wholesale.
    func testPageLevelColourIsNotAColoredSpan() {
        let styles = CSSStyleResolver(css: "body { color: #333333 } html { color: black }")
        let result = XHTMLTextExtractor.extract(
            from: "<body><p>Ordinary prose.</p></body>", styles: styles
        )
        XCTAssertTrue(colored(result).isEmpty)
    }

    /// A run carrying both gets both spans — the renderer resolves which ink
    /// survives against the background.
    func testAColouredHighlightCarriesBothSpans() {
        let styles = CSSStyleResolver(
            css: ".mark { color: #8b0000; background-color: #fff2a8 }"
        )
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span class="mark">both</span></p>"#, styles: styles
        )
        XCTAssertEqual(colored(result).count, 1)
        XCTAssertEqual(highlights(result).count, 1)
    }
}
