import XCTest
@testable import ReadrKit

/// EPUB rendering overhaul — the extractor no longer flattens structure away.
/// `XHTMLTextExtractor.extract(from:)` produces the normalized text PLUS
/// format spans (headings, emphasis, blockquotes, links), an anchors map
/// (element id → character offset), list-item prefixes, and image display
/// sizes. All offsets index the FINAL normalized text.
final class XHTMLStructureExtractionTests: XCTestCase {

    /// Character-offset slice of the final text (spans use character offsets,
    /// the same unit `ChapterImage.offset` uses).
    private func slice(_ text: String, _ span: XHTMLTextExtractor.Span) -> String {
        let chars = Array(text)
        return String(chars[span.start..<span.end])
    }

    // MARK: - Headings

    func testHeadingSpanLevelAndRangeAreExact() {
        let result = XHTMLTextExtractor.extract(
            from: "<body><h2>The &amp; Title</h2><p>Body text</p></body>"
        )
        XCTAssertEqual(result.text, "The & Title\nBody text")
        XCTAssertEqual(result.spans.count, 1)
        let span = result.spans[0]
        XCTAssertEqual(span.kind, .heading(2))
        XCTAssertEqual(span.start, 0)
        XCTAssertEqual(span.end, 11)
        XCTAssertEqual(slice(result.text, span), "The & Title")
    }

    func testEveryHeadingLevelIsCaptured() {
        let html = (1...6).map { "<h\($0)>Head\($0)</h\($0)>" }.joined()
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, (1...6).map { "Head\($0)" }.joined(separator: "\n"))
        XCTAssertEqual(result.spans.map(\.kind), (1...6).map { .heading($0) })
        for span in result.spans {
            XCTAssertTrue(slice(result.text, span).hasPrefix("Head"))
        }
    }

    // MARK: - Bold / italic / nesting

    func testBoldItalicAndNestedEmphasisSpans() {
        let html = "<p>plain <strong>bold</strong> mid <em>ital</em> <b>out <i>in</i></b></p>"
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "plain bold mid ital out in")

        XCTAssertEqual(result.spans.count, 4)
        XCTAssertEqual(result.spans[0].kind, .bold)
        XCTAssertEqual(slice(result.text, result.spans[0]), "bold")
        XCTAssertEqual(result.spans[1].kind, .italic)
        XCTAssertEqual(slice(result.text, result.spans[1]), "ital")
        // Nested: the outer <b> covers "out in", the inner <i> covers "in" —
        // overlapping spans are expected and fine.
        XCTAssertEqual(result.spans[2].kind, .bold)
        XCTAssertEqual(slice(result.text, result.spans[2]), "out in")
        XCTAssertEqual(result.spans[3].kind, .italic)
        XCTAssertEqual(slice(result.text, result.spans[3]), "in")
    }

    func testEmptyEmphasisElementProducesNoSpan() {
        let result = XHTMLTextExtractor.extract(from: "<p>x<b></b>y</p>")
        XCTAssertEqual(result.text, "xy")
        XCTAssertTrue(result.spans.isEmpty)
    }

    // MARK: - Blockquote

    func testBlockquoteSpanCoversTheQuotedText() {
        let html = "<p>Intro</p><blockquote>Quoted words</blockquote><p>After</p>"
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Intro\nQuoted words\nAfter")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .blockquote)
        XCTAssertEqual(slice(result.text, result.spans[0]), "Quoted words")
    }

    // MARK: - Links (extractor emits the RAW href; the parser resolves it)

    func testLinkSpanCarriesRawHref() {
        let result = XHTMLTextExtractor.extract(
            from: #"<p>See <a href="ch2.xhtml#note1">the note</a>.</p>"#
        )
        XCTAssertEqual(result.text, "See the note.")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .link(href: "ch2.xhtml#note1"))
        XCTAssertEqual(result.spans[0].start, 4)
        XCTAssertEqual(result.spans[0].end, 12)
        XCTAssertEqual(slice(result.text, result.spans[0]), "the note")
    }

    func testAnchorWithoutHrefProducesNoSpan() {
        let result = XHTMLTextExtractor.extract(from: #"<p><a id="here">target</a></p>"#)
        XCTAssertEqual(result.text, "target")
        XCTAssertTrue(result.spans.isEmpty)
        XCTAssertEqual(result.anchors, ["here": 0])
    }

    /// Index-like back matter: a list of page-number links must yield one link
    /// span per anchor and no duplicated text.
    func testIndexStyleLinkListProducesLinkSpansAndNoDuplicatedText() {
        let html = """
        <p>Index</p>
        <p><a href="ch1.xhtml">1</a>, <a href="ch1.xhtml#p2">2</a>, <a href="ch2.xhtml">3</a></p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Index\n1, 2, 3")
        XCTAssertEqual(result.spans.map(\.kind), [
            .link(href: "ch1.xhtml"),
            .link(href: "ch1.xhtml#p2"),
            .link(href: "ch2.xhtml"),
        ])
        XCTAssertEqual(result.spans.map { slice(result.text, $0) }, ["1", "2", "3"])
        XCTAssertEqual(result.spans.map(\.start), [6, 9, 12])
    }

    // MARK: - Lists

    func testUnorderedListItemsGetBulletPrefixes() {
        let result = XHTMLTextExtractor.extract(
            from: "<ul><li>alpha</li><li>beta</li></ul>"
        )
        XCTAssertEqual(result.text, "• alpha\n• beta")
    }

    func testOrderedListItemsGetOneBasedNumberPrefixes() {
        let result = XHTMLTextExtractor.extract(
            from: "<ol><li>first</li><li>second</li><li>third</li></ol>"
        )
        XCTAssertEqual(result.text, "1. first\n2. second\n3. third")
    }

    func testNestedListsRestartNumberingAndKeepTheirOwnMarkers() {
        let mixed = XHTMLTextExtractor.extract(
            from: "<ol><li>one<ul><li>sub</li></ul></li><li>two</li></ol>"
        )
        XCTAssertEqual(mixed.text, "1. one\n• sub\n2. two")

        let nestedOrdered = XHTMLTextExtractor.extract(
            from: "<ol><li>a<ol><li>x</li><li>y</li></ol></li><li>b</li></ol>"
        )
        XCTAssertEqual(nestedOrdered.text, "1. a\n1. x\n2. y\n2. b")
    }

    func testEmptyListItemLeavesNoStrayMarker() {
        let result = XHTMLTextExtractor.extract(
            from: "<ul><li></li><li>real</li></ul><p>After</p>"
        )
        XCTAssertEqual(result.text, "• real\nAfter")
    }

    // MARK: - Anchors

    func testAnchorsMapRecordsIdOffsetsFirstOccurrenceWins() {
        let html = #"<p id="p1">One</p><h2 id="s2">Two</h2><p id="p1">dup</p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "One\nTwo\ndup")
        XCTAssertEqual(result.anchors, ["p1": 0, "s2": 4])
    }

    func testAnchorOnTrailingEmptyElementClampsToTextEnd() {
        let result = XHTMLTextExtractor.extract(from: #"<p>x</p><p id="end"></p>"#)
        XCTAssertEqual(result.text, "x")
        XCTAssertEqual(result.anchors, ["end": 1])
    }

    // MARK: - Offset correctness through normalization

    /// Spans and anchors must index the FINAL text: entity decoding and
    /// whitespace collapsing before a heading/link must not skew offsets.
    func testOffsetsSurviveEntitiesAndWhitespaceCollapse() {
        let html = """
        <p>Tom &amp;   Jerry&nbsp;&nbsp;run</p>
        <h1> The &ldquo;End&rdquo; </h1>
        <p>See <a href="x.xhtml">n&#111;te</a></p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Tom & Jerry run\nThe “End”\nSee note")

        XCTAssertEqual(result.spans.count, 2)
        XCTAssertEqual(result.spans[0].kind, .heading(1))
        XCTAssertEqual(result.spans[0].start, 16)
        XCTAssertEqual(result.spans[0].end, 25)
        XCTAssertEqual(slice(result.text, result.spans[0]), "The “End”")

        XCTAssertEqual(result.spans[1].kind, .link(href: "x.xhtml"))
        XCTAssertEqual(result.spans[1].start, 30)
        XCTAssertEqual(result.spans[1].end, 34)
        XCTAssertEqual(slice(result.text, result.spans[1]), "note")
    }

    func testOffsetsSurviveImagePlaceholderInterleaving() {
        let html = #"<p>a &amp; b <img src="pic.png" alt="P"/> <b>c</b></p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a & b \u{FFFC} c")
        XCTAssertEqual(result.images, [
            .init(src: "pic.png", alt: "P"),
        ])
        let chars = Array(result.text)
        XCTAssertEqual(chars[6], XHTMLTextExtractor.imagePlaceholder)
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .bold)
        XCTAssertEqual(result.spans[0].start, 8)
        XCTAssertEqual(result.spans[0].end, 9)
    }

    // MARK: - Malformed markup

    func testUnclosedTagsCloseAtDocumentEndWithoutCorruptingOffsets() {
        let result = XHTMLTextExtractor.extract(from: "<p>start <b>bold text")
        XCTAssertEqual(result.text, "start bold text")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .bold)
        XCTAssertEqual(slice(result.text, result.spans[0]), "bold text")
    }

    func testStrayCloseTagsAreTolerated() {
        let result = XHTMLTextExtractor.extract(from: "<p>a</i></b> b</a></p>")
        XCTAssertEqual(result.text, "a b")
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testMismatchedEmphasisCloseTagStillClosesTheKind() {
        // Sloppy real-world markup: <b> closed by </strong>. Same kind — close it.
        let result = XHTMLTextExtractor.extract(from: "<p><b>x</strong> y</p>")
        XCTAssertEqual(result.text, "x y")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .bold)
        XCTAssertEqual(slice(result.text, result.spans[0]), "x")
    }

    // MARK: - Image display sizes

    func testImageWidthHeightAttributesAreCapturedAsCSSPixels() {
        let result = XHTMLTextExtractor.extract(
            from: #"<p><img src="a.png" width="120" height="80"/></p>"#
        )
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].displayWidth, 120)
        XCTAssertEqual(result.images[0].displayHeight, 80)
    }

    func testImageStyleWidthHeightAreParsed() {
        let result = XHTMLTextExtractor.extract(
            from: #"<p><img src="b.png" style="width: 32px; height:20.5px"/></p>"#
        )
        XCTAssertEqual(result.images[0].displayWidth, 32)
        XCTAssertEqual(result.images[0].displayHeight, 20.5)
    }

    func testPercentageAndNonPixelUnitsYieldNil() {
        let result = XHTMLTextExtractor.extract(from: """
        <img src="c.png" width="50%" height="2em">\
        <img src="d.png" style="width:40%; height:1.5em">
        """)
        XCTAssertEqual(result.images.count, 2)
        XCTAssertNil(result.images[0].displayWidth)
        XCTAssertNil(result.images[0].displayHeight)
        XCTAssertNil(result.images[1].displayWidth)
        XCTAssertNil(result.images[1].displayHeight)
    }

    func testStyleDeclarationOverridesWidthAttribute() {
        // CSS beats presentational attributes at render time; a style that
        // declares a percentage width means "no fixed pixel intent" even when
        // a width attribute exists.
        let result = XHTMLTextExtractor.extract(
            from: #"<img src="e.png" width="200" style="width:40%">"#
        )
        XCTAssertNil(result.images[0].displayWidth)
    }

    func testMaxWidthDoesNotMasqueradeAsWidth() {
        let result = XHTMLTextExtractor.extract(
            from: #"<img src="f.png" style="max-width:100px; line-height:2px">"#
        )
        XCTAssertNil(result.images[0].displayWidth)
        XCTAssertNil(result.images[0].displayHeight)
    }

    func testImageWithoutSizeHintsHasNilDisplaySize() {
        let result = XHTMLTextExtractor.extract(from: #"<img src="g.png" alt="plain">"#)
        XCTAssertNil(result.images[0].displayWidth)
        XCTAssertNil(result.images[0].displayHeight)
    }

    // MARK: Malformed markup recovery

    func testUnterminatedCommentRecoversAtFirstGreaterThan() {
        // A typo'd terminator (`->`) with no later `-->` must not swallow the
        // rest of the chapter — recover at the first `>`, as the old
        // stripping passes did.
        let result = XHTMLTextExtractor.extract(
            from: "<p>a</p><!-- broken comment -><p>rest of the chapter</p>"
        )
        XCTAssertEqual(result.text, "a\nrest of the chapter")
    }

    func testAbruptlyClosedCommentsDoNotEatContent() {
        // HTML5 allows `<!-->` and `<!--->` as (empty) comments.
        XCTAssertEqual(XHTMLTextExtractor.extract(from: "<!-->x").text, "x")
        XCTAssertEqual(XHTMLTextExtractor.extract(from: "<!--->y").text, "y")
    }

    func testWellFormedCommentContainingTagsAndGtIsSkippedWhole() {
        let result = XHTMLTextExtractor.extract(
            from: "<p>a</p><!-- a > b <p>not content</p> --><p>b</p>"
        )
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testMismatchedHeadingCloseDoesNotStyleTheRestOfTheChapter() {
        // `<h1>…</h2>` closes the open heading instead of leaving an
        // unterminated h1 span running to the end of the document.
        let result = XHTMLTextExtractor.extract(
            from: "<h1>Title</h2><p>Body paragraph after the heading.</p>"
        )
        let headings = result.spans.filter {
            if case .heading = $0.kind { return true }
            return false
        }
        XCTAssertEqual(headings.count, 1)
        XCTAssertEqual(headings[0].start, 0)
        XCTAssertEqual(headings[0].end, "Title".count)
    }

    func testThousandsOfEmptyAnchorsStayLinear() {
        // Real page-list files carry thousands of consecutive empty
        // `<span id="pgN"/>` elements; membership checks used to be O(n²)
        // (a ~10s hang at 20k, unbounded for hostile files).
        var html = "<p>"
        for n in 1...20_000 { html += "<span id=\"pg\(n)\"></span>" }
        html += "done</p>"
        let started = Date()
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        XCTAssertEqual(result.anchors.count, 20_000)
        XCTAssertEqual(result.anchors["pg1"], 0)
        XCTAssertEqual(result.anchors["pg20000"], 0)
        XCTAssertEqual(result.text, "done")
    }
}
