import XCTest
@testable import ReadrKit

/// Real-world XHTML variance the launch corpus (Standard Ebooks, Gutenberg,
/// Calibre conversions, technical publishers) exercises: HTML named entities
/// beyond the XML five, ruby annotations, table degradation, soft hyphens,
/// and non-quadratic behavior on very large chapters.
final class XHTMLExtractorConformanceTests: XCTestCase {

    // MARK: - Entities

    func testDecodesCommonTypographicNamedEntities() {
        let html = "<p>&ldquo;caf&eacute;&rdquo; &copy; 2026 &middot; 30&deg;C &bull; &frac12; done &hellip;</p>"
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "“café” © 2026 · 30°C • ½ done …")
    }

    func testDecodesLatin1LetterEntities() {
        let text = XHTMLTextExtractor.text(from: "<p>Bront&euml; &amp; G&ouml;del &ndash; na&iuml;ve</p>")
        XCTAssertEqual(text, "Brontë & Gödel – naïve")
    }

    func testUnknownNamedEntityIsLeftIntact() {
        let text = XHTMLTextExtractor.text(from: "<p>totally &bogus; entity</p>")
        XCTAssertEqual(text, "totally &bogus; entity")
    }

    func testDoubleEscapedEntitiesAreNotDoubleDecoded() {
        // `&amp;lt;` is the literal text "&lt;" — it must NOT become "<".
        let text = XHTMLTextExtractor.text(from: "<p>&amp;lt;tag&amp;gt; and &amp;#65;</p>")
        XCTAssertEqual(text, "&lt;tag&gt; and &#65;")
    }

    func testSoftHyphenAndZeroWidthEntitiesAreDropped() {
        let text = XHTMLTextExtractor.text(from: "<p>hy&shy;phen&zwnj;ated&zwj;!</p>")
        XCTAssertEqual(text, "hyphenated!")
    }

    func testUnicodeSpaceEntitiesBecomePlainSpacesAndCollapse() {
        let text = XHTMLTextExtractor.text(from: "<p>a&ensp;&emsp;b&thinsp;c&nbsp;&nbsp;d</p>")
        XCTAssertEqual(text, "a b c d")
    }

    func testNumericEntitiesStillDecodeDecimalAndHex() {
        let text = XHTMLTextExtractor.text(from: "<p>&#65;&#x42;&#X43; &#8212;</p>")
        XCTAssertEqual(text, "ABC —")
    }

    func testMalformedNumericEntityIsLeftIntact() {
        let text = XHTMLTextExtractor.text(from: "<p>&#xZZ; &#99999999999;</p>")
        XCTAssertEqual(text, "&#xZZ; &#99999999999;")
    }

    // MARK: - Structure

    func testBrProducesLineBreak() {
        let text = XHTMLTextExtractor.text(from: "<p>line one<br/>line two<br>line three</p>")
        XCTAssertEqual(text, "line one\nline two\nline three")
    }

    func testBlockElementsProduceParagraphBreaks() {
        // Updated for the structure overhaul: list items now carry visible
        // markers ("• " for <ul>, "N. " for <ol>) instead of flattening to
        // bare lines — a deliberate text-content improvement. Headings and
        // blockquotes still break paragraphs (their styling now travels
        // separately as format spans).
        let html = "<div>intro</div><h2>Head</h2><blockquote>quote</blockquote><ul><li>one</li><li>two</li></ul>"
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "intro\nHead\nquote\n• one\n• two")
    }

    func testRubyAnnotationTextIsNotDuplicated() {
        // <rt> holds the phonetic reading, <rp> the fallback parens — neither
        // belongs in the extracted prose.
        let html = "<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>を読む</p>"
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "漢字を読む")
        XCTAssertFalse(text.contains("かんじ"))
    }

    func testTablesDegradeToReadableRows() {
        let html = """
        <table><tr><th>Name</th><th>Age</th></tr>\
        <tr><td>Ada</td><td>36</td></tr></table><p>After.</p>
        """
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "Name Age\nAda 36\nAfter.")
    }

    // MARK: - Scale

    /// A very large single chapter (~1.2 MB of markup) must extract without
    /// quadratic blow-up — a superlinear pass over this input would hang the
    /// suite rather than finish in milliseconds.
    func testVeryLargeChapterExtractsCompletely() {
        let paragraph = "<p>Tom &amp; Jerry &mdash; scene &#8220;42&#8221;, take&nbsp;7.</p>\n"
        let html = "<html><body>" + String(repeating: paragraph, count: 20_000) + "</body></html>"
        let (text, images) = XHTMLTextExtractor.textAndImages(from: html)
        XCTAssertTrue(images.isEmpty)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 20_000)
        XCTAssertTrue(text.hasPrefix("Tom & Jerry — scene “42”, take 7."))
        XCTAssertTrue(text.hasSuffix("Tom & Jerry — scene “42”, take 7."))
    }
}
