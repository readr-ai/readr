import XCTest
@testable import ReadrKit

/// The minimal CSS subset engine (`CSSStyleResolver`): parser robustness
/// (comments, at-rules, malformed input recovery), the accepted selector
/// subset, property mapping, cascade order, and hard-cap degradation.
final class CSSStyleResolverTests: XCTestCase {

    /// Resolve one element against a freshly parsed sheet.
    private func style(
        _ css: String, element: String = "p",
        classAttr: String? = nil, inline: String? = nil
    ) -> ResolvedStyle {
        CSSStyleResolver(css: css)
            .style(element: element, classAttr: classAttr, inlineStyle: inline)
    }

    // MARK: - Parser: comments

    func testCommentsAreStripped() {
        let css = """
        /* leading comment */
        .a { /* inside */ font-style: /* mid */ italic; }
        /* trailing
           multi-line */
        """
        XCTAssertEqual(style(css, classAttr: "a").italic, true)
    }

    func testUnterminatedCommentDropsOnlyTheRest() {
        let css = ".a { font-weight: bold } /* runs off .b { font-style: italic }"
        XCTAssertEqual(style(css, classAttr: "a").bold, true)
        XCTAssertNil(style(css, classAttr: "b").italic)
    }

    // MARK: - Parser: selectors

    func testMultiSelectorListAppliesToEachSelector() {
        let css = "p, .note, em.fancy { text-align: center }"
        XCTAssertEqual(style(css).alignment, .center)
        XCTAssertEqual(style(css, element: "div", classAttr: "note").alignment, .center)
        XCTAssertEqual(style(css, element: "em", classAttr: "fancy").alignment, .center)
        // The em.fancy pair is element-scoped.
        XCTAssertNil(style(css, element: "span", classAttr: "fancy").alignment)
    }

    func testRejectedSelectorsLeaveCommaSiblingsAlive() {
        let css = """
        p > span, div p, h1:first-child, [data-x], #page, .a.b, a.b.c, .good \
        { font-weight: bold }
        """
        XCTAssertEqual(style(css, classAttr: "good").bold, true)
        XCTAssertNil(style(css, element: "span").bold)
        XCTAssertNil(style(css, element: "p").bold)
        XCTAssertNil(style(css, element: "h1").bold)
        XCTAssertNil(style(css, element: "a", classAttr: "b c").bold)
        XCTAssertNil(style(css, classAttr: "a b").bold)
    }

    func testUniversalAndBodySelectorsAreIgnored() {
        let css = "* { font-style: italic } body { font-weight: bold; text-align: center }"
        let resolver = CSSStyleResolver(css: css)
        XCTAssertTrue(resolver.isEmpty)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: nil, inlineStyle: nil), ResolvedStyle()
        )
        XCTAssertEqual(
            resolver.style(element: "body", classAttr: nil, inlineStyle: nil), ResolvedStyle()
        )
    }

    func testClassRuleDoesNotApplyWithoutTheClass() {
        let css = ".c { font-weight: bold }"
        XCTAssertNil(style(css, element: "p").bold)
        XCTAssertNil(style(css, element: "p", classAttr: "other").bold)
    }

    // MARK: - Parser: merge semantics

    func testLastRuleWinsWithinABucket() {
        let css = ".a { font-style: italic } .a { font-style: normal }"
        XCTAssertEqual(style(css, classAttr: "a").italic, false)
    }

    func testRepeatedRulesMergeNonConflictingProperties() {
        let css = ".a { font-weight: bold } .a { font-style: italic }"
        let resolved = style(css, classAttr: "a")
        XCTAssertEqual(resolved.bold, true)
        XCTAssertEqual(resolved.italic, true)
    }

    // MARK: - Parser: malformed CSS recovery

    func testUnclosedFinalBraceStillAppliesTheRule() {
        // CSS auto-closes open blocks at end of input; earlier rules are
        // unaffected either way.
        let css = ".first { font-weight: bold } .a { font-style: italic"
        XCTAssertEqual(style(css, classAttr: "first").bold, true)
        XCTAssertEqual(style(css, classAttr: "a").italic, true)
    }

    func testStrayCloseBracesAreSkipped() {
        let css = "} } .a { font-style: italic } }"
        XCTAssertEqual(style(css, classAttr: "a").italic, true)
    }

    func testAtMediaBlockIsSkippedWhole() {
        let css = """
        @media print { .a { font-style: italic } .b { display: none } }
        .c { font-weight: bold }
        """
        XCTAssertNil(style(css, classAttr: "a").italic)
        XCTAssertNil(style(css, classAttr: "b").hidden)
        XCTAssertEqual(style(css, classAttr: "c").bold, true)
    }

    func testAtImportAndCharsetSkipToSemicolon() {
        let css = """
        @charset "utf-8";
        @import url("other.css");
        .a { font-style: italic }
        """
        XCTAssertEqual(style(css, classAttr: "a").italic, true)
    }

    func testImportantSuffixIsStrippedAndIgnored() {
        let css = ".a { font-style: italic !important; text-align: center ! IMPORTANT }"
        let resolved = style(css, classAttr: "a")
        XCTAssertEqual(resolved.italic, true)
        XCTAssertEqual(resolved.alignment, .center)
    }

    func testUnknownPropertiesAreSkipped() {
        let css = """
        .a { color: red; font-family: "Bembo", serif; font-style: italic; line-height: 1.4 }
        """
        let resolved = style(css, classAttr: "a")
        XCTAssertEqual(resolved.italic, true)
        XCTAssertEqual(
            resolved, ResolvedStyle(italic: true),
            "unknown properties contribute nothing"
        )
    }

    func testTextIndentIsRecognizedButIgnored() {
        // No FormatSpan kind for first-line indent in v1.
        XCTAssertEqual(style(".a { text-indent: 2em }", classAttr: "a"), ResolvedStyle())
    }

    // MARK: - Parser: quoted strings

    func testQuotedCloseBraceInContentDoesNotEatFollowingRules() {
        let css = #"a::before { content: "}"; } .it { font-style: italic }"#
        XCTAssertEqual(style(css, classAttr: "it").italic, true)
    }

    func testQuotedBracesAndEscapesInsideStringsAreSkipped() {
        // "{", "}", and an escaped quote inside a string are content, not
        // rule structure; the declaration after the string still parses and
        // the following rule survives.
        let css = #".a { content: "{}\"}"; font-weight: bold } .it { font-style: italic }"#
        XCTAssertEqual(style(css, classAttr: "a").bold, true)
        XCTAssertEqual(style(css, classAttr: "it").italic, true)
        // Same with single quotes.
        let single = ".a { content: '}'; font-weight: bold } .it { font-style: italic }"
        XCTAssertEqual(style(single, classAttr: "a").bold, true)
        XCTAssertEqual(style(single, classAttr: "it").italic, true)
    }

    func testQuotedCommentOpenerInsideStringIsNotAComment() {
        let css = #".a { content: "/*"; font-weight: bold } .it { font-style: italic }"#
        XCTAssertEqual(style(css, classAttr: "a").bold, true)
        XCTAssertEqual(style(css, classAttr: "it").italic, true)
    }

    func testUnterminatedQuoteDegradesWithoutHangingOrCrashing() {
        // An unterminated string swallows the rest of the sheet (CSS error
        // recovery) — earlier rules survive, nothing loops or crashes.
        let css = #".first { font-weight: bold } .a { content: "unterminated } .it { font-style: italic }"#
        let resolver = CSSStyleResolver(css: css)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "first", inlineStyle: nil).bold, true
        )
        XCTAssertNil(
            resolver.style(element: "p", classAttr: "it", inlineStyle: nil).italic
        )
    }

    // MARK: - Property mapping

    func testFontWeightMapping() {
        XCTAssertEqual(style(".a { font-weight: bold }", classAttr: "a").bold, true)
        XCTAssertEqual(style(".a { font-weight: bolder }", classAttr: "a").bold, true)
        XCTAssertEqual(style(".a { font-weight: 600 }", classAttr: "a").bold, true)
        XCTAssertEqual(style(".a { font-weight: 700 }", classAttr: "a").bold, true)
        XCTAssertEqual(style(".a { font-weight: 599 }", classAttr: "a").bold, false)
        XCTAssertEqual(style(".a { font-weight: 400 }", classAttr: "a").bold, false)
        XCTAssertEqual(style(".a { font-weight: normal }", classAttr: "a").bold, false)
        XCTAssertEqual(style(".a { font-weight: lighter }", classAttr: "a").bold, false)
        XCTAssertNil(style(".a { font-weight: inherit }", classAttr: "a").bold)
    }

    func testFontStyleMapping() {
        XCTAssertEqual(style(".a { font-style: italic }", classAttr: "a").italic, true)
        XCTAssertEqual(style(".a { font-style: oblique }", classAttr: "a").italic, true)
        XCTAssertEqual(style(".a { font-style: oblique 14deg }", classAttr: "a").italic, true)
        XCTAssertEqual(style(".a { font-style: normal }", classAttr: "a").italic, false)
    }

    func testTextAlignMapping() {
        XCTAssertEqual(style(".a { text-align: left }", classAttr: "a").alignment, .left)
        XCTAssertEqual(style(".a { text-align: center }", classAttr: "a").alignment, .center)
        XCTAssertEqual(style(".a { text-align: right }", classAttr: "a").alignment, .right)
        XCTAssertEqual(style(".a { text-align: justify }", classAttr: "a").alignment, .justify)
        XCTAssertNil(style(".a { text-align: start }", classAttr: "a").alignment)
    }

    func testMarginLonghandsDriveTheInsetHeuristic() {
        XCTAssertEqual(
            style(".a { margin-left: 2em; margin-right: 2em }", classAttr: "a").inset, true
        )
        XCTAssertEqual(style(".a { margin-left: 2em }", classAttr: "a").inset, false)
        XCTAssertEqual(
            style(".a { margin-left: 2em; margin-right: 0 }", classAttr: "a").inset, false
        )
        XCTAssertNil(style(".a { font-style: italic }", classAttr: "a").inset)
    }

    func testMarginShorthandSlots() {
        XCTAssertEqual(style(".a { margin: 2em }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 2em }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 1em 2em 3em }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 2em 0 2em }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 2em 0 }", classAttr: "a").inset, false)
        // Four-slot: right is big but left (slot 4) is not.
        XCTAssertEqual(style(".a { margin: 0 2em 0 0 }", classAttr: "a").inset, false)
        XCTAssertEqual(style(".a { margin: 0 }", classAttr: "a").inset, false)
    }

    func testMarginUnitsAndThresholds() {
        XCTAssertEqual(style(".a { margin: 0 1em }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 0.9em }", classAttr: "a").inset, false)
        XCTAssertEqual(style(".a { margin: 0 5% }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 4% }", classAttr: "a").inset, false)
        XCTAssertEqual(style(".a { margin: 0 16px }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 15px }", classAttr: "a").inset, false)
        XCTAssertEqual(style(".a { margin: 0 1.5rem }", classAttr: "a").inset, true)
        XCTAssertEqual(style(".a { margin: 0 auto }", classAttr: "a").inset, false)
    }

    func testDisplayAndVisibilityMapToHidden() {
        XCTAssertEqual(style(".a { display: none }", classAttr: "a").hidden, true)
        XCTAssertEqual(style(".a { display: block }", classAttr: "a").hidden, false)
        XCTAssertEqual(style(".a { visibility: hidden }", classAttr: "a").hidden, true)
        XCTAssertEqual(style(".a { visibility: visible }", classAttr: "a").hidden, false)
        XCTAssertNil(style(".a { font-style: italic }", classAttr: "a").hidden)
    }

    func testFontVariantSmallCaps() {
        XCTAssertEqual(
            style(".a { font-variant: small-caps }", classAttr: "a").smallCaps, true
        )
        XCTAssertEqual(
            style(".a { font-variant-caps: small-caps }", classAttr: "a").smallCaps, true
        )
        XCTAssertEqual(style(".a { font-variant: normal }", classAttr: "a").smallCaps, false)
    }

    func testVerticalAlignSuperSubAndBaseline() {
        // The footnote-marker pattern (#43): InDesign-produced EPUBs mark
        // note refs with a classed span + `vertical-align: super`, no <sup>.
        XCTAssertEqual(
            style(".a { vertical-align: super }", classAttr: "a").verticalAlign, .raised
        )
        XCTAssertEqual(
            style(".a { vertical-align: sub }", classAttr: "a").verticalAlign, .lowered
        )
        // An explicit baseline must be able to cancel an outer super/sub.
        XCTAssertEqual(
            style(".a { vertical-align: baseline }", classAttr: "a").verticalAlign, .baseline
        )
    }

    func testVerticalAlignBoxValuesStayUndeclared() {
        // top/middle/bottom (and lengths/percentages) are table-cell/box
        // alignment, not text super/sub — they must not declare the fact.
        XCTAssertNil(style(".a { vertical-align: top }", classAttr: "a").verticalAlign)
        XCTAssertNil(style(".a { vertical-align: middle }", classAttr: "a").verticalAlign)
        XCTAssertNil(style(".a { vertical-align: text-bottom }", classAttr: "a").verticalAlign)
        XCTAssertNil(style(".a { vertical-align: 20% }", classAttr: "a").verticalAlign)
        XCTAssertNil(style(".a { vertical-align: -0.2em }", classAttr: "a").verticalAlign)
    }

    // MARK: - Cascade order

    func testCascadeOrderElementThenClassThenElementClassThenInline() {
        let css = """
        p { text-align: left; font-style: italic }
        .c { text-align: center }
        p.c { text-align: right }
        """
        let resolver = CSSStyleResolver(css: css)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: nil, inlineStyle: nil).alignment, .left
        )
        // class beats element…
        XCTAssertEqual(
            resolver.style(element: "div", classAttr: "c", inlineStyle: nil).alignment, .center
        )
        // …element.class beats class…
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "c", inlineStyle: nil).alignment, .right
        )
        // …inline beats everything; unrelated element facts survive.
        let inline = resolver.style(
            element: "p", classAttr: "c", inlineStyle: "text-align: justify"
        )
        XCTAssertEqual(inline.alignment, .justify)
        XCTAssertEqual(inline.italic, true)
    }

    func testMultiClassAttributeOrderLastWins() {
        let css = ".a { text-align: left } .b { text-align: center }"
        let resolver = CSSStyleResolver(css: css)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "a b", inlineStyle: nil).alignment, .center
        )
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "b a", inlineStyle: nil).alignment, .left
        )
    }

    func testOverlayMergesNonConflictingFacts() {
        let css = "p { font-style: italic } .c { font-weight: bold }"
        let resolved = CSSStyleResolver(css: css)
            .style(element: "p", classAttr: "c", inlineStyle: "font-variant: small-caps")
        XCTAssertEqual(resolved.italic, true)
        XCTAssertEqual(resolved.bold, true)
        XCTAssertEqual(resolved.smallCaps, true)
    }

    func testResolvedStyleOverlayNonNilWins() {
        var base = ResolvedStyle(italic: true, bold: false, alignment: .left)
        base.overlay(ResolvedStyle(bold: true, hidden: false))
        XCTAssertEqual(base.italic, true, "untouched — overlay had nil")
        XCTAssertEqual(base.bold, true, "replaced by the overlay")
        XCTAssertEqual(base.alignment, .left, "untouched")
        XCTAssertEqual(base.hidden, false, "gained from the overlay")
        XCTAssertNil(base.smallCaps)
    }

    // MARK: - Hard caps: degrade to empty, never throw

    func testOversizedCSSDegradesToEmptyResolver() {
        var css = ".real { font-style: italic }\n"
        css += String(repeating: "/* padding padding padding */\n", count: 20_000)
        XCTAssertGreaterThan(css.utf8.count, CSSStyleResolver.maxCSSBytes)
        let resolver = CSSStyleResolver(css: css)
        XCTAssertTrue(resolver.isEmpty)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "real", inlineStyle: nil), ResolvedStyle()
        )
    }

    func testTooManyRulesDegradesToEmptyResolver() {
        var css = ".real { font-style: italic }\n"
        for index in 0...CSSStyleResolver.maxRules { css += ".x\(index){}\n" }
        XCTAssertLessThan(
            css.utf8.count, CSSStyleResolver.maxCSSBytes,
            "the rule cap must trip before the byte cap for this fixture"
        )
        let resolver = CSSStyleResolver(css: css)
        XCTAssertTrue(resolver.isEmpty)
        XCTAssertEqual(
            resolver.style(element: "p", classAttr: "real", inlineStyle: nil), ResolvedStyle()
        )
    }

    func testByteCapAppliesAcrossComposedSheets() {
        var resolver = CSSStyleResolver(css: ".a { font-weight: bold }")
        XCTAssertFalse(resolver.isEmpty)
        resolver.add(sheet: String(repeating: " ", count: CSSStyleResolver.maxCSSBytes))
        XCTAssertTrue(resolver.isEmpty)
        resolver.add(sheet: ".b { font-style: italic }")
        XCTAssertTrue(resolver.isEmpty, "a degraded resolver stays empty")
    }

    func testUnderCapSheetsParseNormally() {
        let css = String(repeating: ".a { font-weight: bold }\n", count: 100)
        XCTAssertEqual(style(css, classAttr: "a").bold, true)
    }
}
