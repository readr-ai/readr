import XCTest
@testable import ReadrKit

/// Note references must read as raised markers, not full-size body text.
///
/// #43 covered the classed-span pattern (`vertical-align: super` in the
/// stylesheet). This covers the other common shape: an EPUB 3 producer marks
/// the reference semantically — `epub:type="noteref"` or `role="doc-noteref"`
/// — and leaves the raising to the reading system, shipping no `<sup>` and no
/// vertical-align. Those came out inline at full size ("…right there.123").
///
/// The tests also pin the guard against double-raising: exactly ONE
/// superscript span may cover a marker, because the renderer shrinks per span
/// and two would compound to 0.56×.
final class NoteReferenceSuperscriptTests: XCTestCase {

    private func slice(_ text: String, _ span: XHTMLTextExtractor.Span) -> String {
        let chars = Array(text)
        return String(chars[span.start..<span.end])
    }

    private func superscripts(
        _ result: XHTMLTextExtractor.ExtractionResult
    ) -> [XHTMLTextExtractor.Span] {
        result.spans.filter { $0.kind == .superscript }
    }

    // MARK: - Semantics-only markers

    func testEpubTypeNoterefIsRaised() {
        let html = #"<p>right there.<a epub:type="noteref" href="#fn123">123</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        XCTAssertEqual(result.text, "right there.123")
        let raised = superscripts(result)
        XCTAssertEqual(raised.count, 1, "expected exactly one superscript span")
        XCTAssertEqual(slice(result.text, raised[0]), "123")
    }

    func testDocNoterefRoleIsRaised() {
        let html = #"<p>text<a role="doc-noteref" href="#n1">7</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        let raised = superscripts(result)
        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(slice(result.text, raised[0]), "7")
    }

    func testBiblioRefIsRaised() {
        let html = #"<p>as shown<a role="doc-biblioref" href="#b4">[4]</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        let raised = superscripts(result)
        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(slice(result.text, raised[0]), "[4]")
    }

    /// The marker keeps being a link — raising it must not cost the tap
    /// target that opens the note.
    func testRaisedNoterefKeepsItsLinkSpan() {
        let html = #"<p>text<a epub:type="noteref" href="#fn9">9</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        let links = result.spans.filter {
            if case .link = $0.kind { return true }
            return false
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(slice(result.text, links[0]), "9")
        XCTAssertEqual(links[0].kind, .link(href: "#fn9"))
    }

    /// Word-boundary match, same as the note-body types: a class-ish value
    /// that merely CONTAINS the substring must not raise.
    func testTokenMatchDoesNotRaiseOnSubstring() {
        let html = #"<p>text<a epub:type="noterefx" href="#fn1">1</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertTrue(superscripts(result).isEmpty)
    }

    /// Ordinary links stay on the baseline.
    func testPlainLinkIsNotRaised() {
        let html = #"<p>see <a href="chapter2.xhtml">Chapter 2</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertTrue(superscripts(result).isEmpty)
    }

    // MARK: - No double raising

    /// A `<sup>` wrapper already raises the marker; the semantic attribute
    /// must not add a second span over the same characters.
    func testNoterefInsideSupIsRaisedOnlyOnce() {
        let html = #"<p>text<sup><a epub:type="noteref" href="#fn1">1</a></sup></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        let raised = superscripts(result)
        XCTAssertEqual(
            raised.count, 1,
            "a <sup> wrapper plus epub:type=noteref must yield ONE raise, not two"
        )
        XCTAssertEqual(slice(result.text, raised[0]), "1")
    }

    /// A literal `<sup>` inside the anchor is the same situation the other
    /// way round.
    func testSupInsideNoterefIsRaisedOnlyOnce() {
        let html = #"<p>text<a epub:type="noteref" href="#fn1"><sup>1</sup></a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)

        XCTAssertEqual(superscripts(result).count, 1)
    }

    /// A stylesheet that already raises the anchor wins; the semantic
    /// attribute must not stack on top of it.
    func testStylesheetRaisedNoterefIsRaisedOnlyOnce() {
        let html = #"""
        <html><head><style>
        a.noteref { vertical-align: super; font-size: 0.7em; }
        </style></head>
        <body><p>text<a class="noteref" epub:type="noteref" href="#fn1">1</a></p></body></html>
        """#
        let result = XHTMLTextExtractor.extract(from: html)

        XCTAssertEqual(
            superscripts(result).count, 1,
            "vertical-align plus epub:type=noteref must yield ONE raise"
        )
    }

    // MARK: - The collapse backstop, directly

    private func span(_ start: Int, _ end: Int, _ kind: XHTMLTextExtractor.Span.Kind)
        -> XHTMLTextExtractor.Span {
        XHTMLTextExtractor.Span(start: start, end: end, kind: kind)
    }

    func testCollapseKeepsTheOutermostOfNestedRaises() {
        let collapsed = XHTMLTextExtractor.collapsingNestedBaselineShifts([
            span(0, 10, .superscript),
            span(2, 8, .superscript),
            span(4, 6, .superscript),
        ])
        XCTAssertEqual(collapsed, [span(0, 10, .superscript)])
    }

    /// Innermost-first ordering must collapse to the same answer.
    func testCollapseIsIndependentOfSpanOrder() {
        let collapsed = XHTMLTextExtractor.collapsingNestedBaselineShifts([
            span(4, 6, .superscript),
            span(2, 8, .superscript),
            span(0, 10, .superscript),
        ])
        XCTAssertEqual(collapsed, [span(0, 10, .superscript)])
    }

    func testCollapseKeepsExactlyOneOfTwoIdenticalRaises() {
        let collapsed = XHTMLTextExtractor.collapsingNestedBaselineShifts([
            span(3, 4, .superscript),
            span(3, 4, .superscript),
        ])
        XCTAssertEqual(collapsed, [span(3, 4, .superscript)])
    }

    /// Separate markers are not nested — both survive.
    func testCollapseLeavesDisjointRaisesAlone() {
        let spans = [span(3, 4, .superscript), span(9, 10, .superscript)]
        XCTAssertEqual(XHTMLTextExtractor.collapsingNestedBaselineShifts(spans), spans)
    }

    /// Different kinds never collapse into each other, even nested.
    func testCollapseDoesNotMixSuperscriptAndSubscript() {
        let spans = [span(0, 10, .superscript), span(2, 4, .`subscript`)]
        XCTAssertEqual(XHTMLTextExtractor.collapsingNestedBaselineShifts(spans), spans)
    }

    /// Other span kinds pass through untouched, nesting or not.
    func testCollapseIgnoresOtherKinds() {
        let spans = [
            span(0, 10, .bold),
            span(2, 4, .bold),
            span(2, 4, .link(href: "#a")),
        ]
        XCTAssertEqual(XHTMLTextExtractor.collapsingNestedBaselineShifts(spans), spans)
    }

    // MARK: - Interaction with note bodies

    /// The reference is raised; the note body it points at still gets lifted
    /// out of the text (and takes no superscript with it).
    func testReferenceIsRaisedWhileItsNoteBodyIsStillDiverted() {
        let html = """
        <p>Body<a epub:type="noteref" href="#fn1">1</a> text.</p>
        <aside epub:type="footnote" id="fn1"><p>The note body.</p></aside>
        """
        let result = XHTMLTextExtractor.extract(from: html)

        XCTAssertEqual(result.text, "Body1 text.")
        XCTAssertEqual(result.footnotes, [.init(id: "fn1", text: "The note body.")])
        let raised = superscripts(result)
        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(slice(result.text, raised[0]), "1")
    }
}
