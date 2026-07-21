import XCTest
@testable import ReadrKit

/// EPUB format audit — extractor semantics: footnote/hidden diversion,
/// sup/sub and alignment spans, the corrected whitespace model (source
/// newlines are NOT paragraph breaks; deliberate blank lines survive),
/// Windows-1252 numeric references and the Greek/math entity sets, SVG
/// image refs, structural block tags, U+FFFC sanitizing, blockquote
/// recovery, and the hardened `firstHeading`.
final class XHTMLSemanticsTests: XCTestCase {

    /// Character-offset slice of the final text (same unit as span offsets).
    private func slice(_ text: String, _ span: XHTMLTextExtractor.Span) -> String {
        let chars = Array(text)
        return String(chars[span.start..<span.end])
    }

    // MARK: - Footnote / hidden diversion

    func testEpubTypeFootnoteAsideIsDivertedIntoFootnotes() {
        let html = """
        <p>Body<a epub:type="noteref" href="#fn1">1</a> text.</p>
        <aside epub:type="footnote" id="fn1"><p>The note body.</p></aside>
        <p>After.</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Body1 text.\nAfter.")
        XCTAssertEqual(result.footnotes, [
            .init(id: "fn1", text: "The note body."),
        ])
        // The note's id belongs to the footnote store, not the anchors map.
        XCTAssertNil(result.anchors["fn1"])
    }

    func testEndnoteRearnoteAndNoteTypesAlsoDivert() {
        for type in ["endnote", "rearnote", "note", "aside footnote"] {
            let html = "<p>x</p><div epub:type=\"\(type)\" id=\"n\">hidden note</div><p>y</p>"
            let result = XHTMLTextExtractor.extract(from: html)
            XCTAssertEqual(result.text, "x\ny", "epub:type=\(type)")
            XCTAssertEqual(result.footnotes, [.init(id: "n", text: "hidden note")])
        }
    }

    func testNoterefAndEndnotesContainerAreNotDiverted() {
        // Word-boundary match: `noteref` is the MARKER, `endnotes` the visible
        // section container — neither is a note body.
        let html = """
        <section epub:type="endnotes"><p>Visible notes intro.</p></section>
        <p><a epub:type="noteref" href="#n1">1</a></p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Visible notes intro.\n1")
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    func testRoleDocFootnoteAndDocEndnoteDivert() {
        let html = """
        <p>a</p><aside role="doc-footnote" id="f1">foot</aside>\
        <aside role="doc-endnote" id="e1">end</aside><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes, [
            .init(id: "f1", text: "foot"),
            .init(id: "e1", text: "end"),
        ])
    }

    func testNestedSameNameElementsDoNotEndTheDiversionEarly() {
        let html = """
        <p>a</p>\
        <div epub:type="footnote" id="n1">outer <div>inner</div> tail</div>\
        <p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes.count, 1)
        XCTAssertEqual(result.footnotes[0].id, "n1")
        // The nested div's boundaries become breaks inside the note text.
        XCTAssertEqual(result.footnotes[0].text, "outer\ninner\ntail")
    }

    func testHiddenAttributeDivertsKeyedByIdOrDropsWithoutId() {
        let html = """
        <p>a</p><div hidden id="h1">kept as note</div>\
        <div hidden>dropped entirely</div><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes, [.init(id: "h1", text: "kept as note")])
    }

    func testHiddenWordInsideAttributeValueDoesNotDivert() {
        // `class="hidden"` and an href naming hidden.xhtml are NOT the
        // boolean `hidden` attribute (no CSS engine — class means nothing).
        let html = #"<p class="hidden">shown</p><p><a href="hidden.xhtml">link</a></p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "shown\nlink")
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    func testDisplayNoneAndVisibilityHiddenStylesDivert() {
        let html = """
        <p>a</p><div style="display:none" id="d1">gone</div>\
        <div style="margin:0; visibility: hidden" id="v1">also gone</div>\
        <div style="display: block">still here</div><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nstill here\nb")
        XCTAssertEqual(result.footnotes, [
            .init(id: "d1", text: "gone"),
            .init(id: "v1", text: "also gone"),
        ])
    }

    func testAnchorsAndImagesInsideDivertedRegionAreDropped() {
        let html = """
        <p>a</p>\
        <aside epub:type="footnote" id="n1"><span id="inner">note</span>\
        <img src="note-decoration.png"/></aside>\
        <img src="real.png"/><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        // Interior ids map to the note, not the main text; interior images
        // must not desync the k-th placeholder from images[k].
        XCTAssertNil(result.anchors["inner"])
        XCTAssertNil(result.anchors["n1"])
        XCTAssertEqual(result.images, [.init(src: "real.png", alt: nil)])
        XCTAssertEqual(
            result.text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 1
        )
        XCTAssertEqual(result.footnotes, [.init(id: "n1", text: "note")])
    }

    func testHiddenVoidElementDoesNotSwallowTheRestOfTheChapter() {
        // `<img hidden>` (lazy-load markup) has no close tag — the element
        // is dropped, the chapter is not.
        let result = XHTMLTextExtractor.extract(
            from: "<p>a</p><img hidden src=\"lazy.png\"><hr hidden><p>b</p>"
        )
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    func testUnclosedDivertedRegionFlushesAtDocumentEnd() {
        let result = XHTMLTextExtractor.extract(
            from: "<p>a</p><aside epub:type=\"footnote\" id=\"n1\">runs to the end"
        )
        XCTAssertEqual(result.text, "a")
        XCTAssertEqual(result.footnotes, [.init(id: "n1", text: "runs to the end")])
    }

    func testTemplateAndSvgTitleDescAreDroppedEntirely() {
        let html = """
        <p>a</p><template><p>never content</p></template>\
        <svg><title>Cover art</title><desc>A description</desc>\
        <text>SVG caption</text></svg><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nSVG caption\nb")
        XCTAssertTrue(result.footnotes.isEmpty)
    }

    // MARK: - Superscript / subscript

    func testSupAndSubBecomeSuperscriptAndSubscriptSpans() {
        let result = XHTMLTextExtractor.extract(from: "<p>E = mc<sup>2</sup> and H<sub>2</sub>O</p>")
        XCTAssertEqual(result.text, "E = mc2 and H2O")
        XCTAssertEqual(result.spans.count, 2)
        XCTAssertEqual(result.spans[0].kind, .superscript)
        XCTAssertEqual(slice(result.text, result.spans[0]), "2")
        XCTAssertEqual(result.spans[1].kind, .`subscript`)
        XCTAssertEqual(slice(result.text, result.spans[1]), "2")
    }

    // MARK: - Alignment spans (inline sources only — no CSS engine)

    func testCenterTagEmitsCenterAlignmentSpan() {
        let result = XHTMLTextExtractor.extract(from: "<p>a</p><center>Centered line</center><p>b</p>")
        XCTAssertEqual(result.text, "a\nCentered line\nb")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.center))
        XCTAssertEqual(slice(result.text, result.spans[0]), "Centered line")
    }

    func testAlignAttributeOnBlockTagsEmitsAlignmentSpans() {
        let html = """
        <p align="center">mid</p><div align="right">edge</div>\
        <p align="justify">both</p><p align="LEFT">flush</p><p align="bogus">none</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "mid\nedge\nboth\nflush\nnone")
        XCTAssertEqual(result.spans.map(\.kind), [
            .alignment(.center), .alignment(.right), .alignment(.justify), .alignment(.left),
        ])
        XCTAssertEqual(result.spans.map { slice(result.text, $0) }, ["mid", "edge", "both", "flush"])
    }

    func testInlineTextAlignStyleEmitsAlignmentSpanAndWinsOverAlignAttr() {
        let html = #"<p style="text-align: right" align="center">styled</p>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.right))
        XCTAssertEqual(slice(result.text, result.spans[0]), "styled")
    }

    func testHeadingWithAlignGetsBothHeadingAndAlignmentSpans() {
        let result = XHTMLTextExtractor.extract(
            from: #"<h2 align="center">Title</h2><p>body</p>"#
        )
        XCTAssertEqual(result.text, "Title\nbody")
        XCTAssertEqual(result.spans.count, 2)
        XCTAssertTrue(result.spans.contains { $0.kind == .heading(2) })
        XCTAssertTrue(result.spans.contains { $0.kind == .alignment(.center) })
        for span in result.spans {
            XCTAssertEqual(slice(result.text, span), "Title")
        }
    }

    // MARK: - Whitespace model

    func testSourceNewlinesInsideTextCollapseToSpacesNotBreaks() {
        // A hard-wrapped sentence in the source is ONE paragraph — only tags
        // create block breaks.
        let html = "<p>line one\nline two\r\nline three</p>"
        XCTAssertEqual(XHTMLTextExtractor.text(from: html), "line one line two line three")
    }

    func testEmptyParagraphYieldsVisibleBlankLine() {
        for scene in ["<p></p>", "<p>&nbsp;</p>", "<p> </p>", "<p/>"] {
            let text = XHTMLTextExtractor.text(from: "<p>Before.</p>\(scene)<p>After.</p>")
            XCTAssertEqual(text, "Before.\n\u{00A0}\nAfter.", "for \(scene)")
        }
    }

    func testDoubleBrYieldsVisibleBlankLineSingleBrJustBreaks() {
        XCTAssertEqual(
            XHTMLTextExtractor.text(from: "<p>one<br/>two<br/><br/>three</p>"),
            "one\ntwo\n\u{00A0}\nthree"
        )
    }

    func testLeadingAndTrailingBlankLinesAreTrimmed() {
        XCTAssertEqual(
            XHTMLTextExtractor.text(from: "<p></p><br/><br/><p>only</p><p></p>"),
            "only"
        )
    }

    func testHrEmitsCenteredSceneBreakParagraph() {
        let result = XHTMLTextExtractor.extract(from: "<p>a</p><hr/><p>b</p>")
        XCTAssertEqual(result.text, "a\n* * *\nb")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.center))
        XCTAssertEqual(slice(result.text, result.spans[0]), "* * *")
    }

    // MARK: - Entities

    func testC1NumericReferencesMapThroughWindows1252() {
        // Word-exported EPUBs emit CP1252 code points as numeric references;
        // decoded literally they'd be invisible C1 control characters.
        let html = "<p>&#145;a&#146; &#147;b&#148; c&#150;d e&#151;f &#133; &#149; &#x93;x&#x94;</p>"
        XCTAssertEqual(
            XHTMLTextExtractor.text(from: html),
            "\u{2018}a\u{2019} \u{201C}b\u{201D} c\u{2013}d e\u{2014}f \u{2026} \u{2022} \u{201C}x\u{201D}"
        )
    }

    func testGreekLetterEntitiesDecode() {
        let html = "<p>&alpha;&beta;&gamma; &Alpha;&Omega; &pi;r&sup2; &thetasym;&upsih;&piv; &sigmaf;</p>"
        XCTAssertEqual(XHTMLTextExtractor.text(from: html), "αβγ ΑΩ πr² ϑϒϖ ς")
    }

    func testMathAndSymbolEntitiesDecode() {
        let html = "<p>&sum;&radic;&int; &asymp;&equiv; &lang;x&rang; &oplus;&otimes;&perp; "
            + "&isin;&cap;&cup; &loz;&spades;&clubs;&hearts;&diams;</p>"
        XCTAssertEqual(
            XHTMLTextExtractor.text(from: html),
            "∑√∫ ≈≡ ⟨x⟩ ⊕⊗⊥ ∈∩∪ ◊♠♣♥♦"
        )
    }

    // MARK: - SVG images

    func testSvgImageWithHrefOrXlinkHrefBecomesImageRef() {
        let html = """
        <svg viewBox="0 0 600 800"><image xlink:href="cover.jpg" width="600" height="800"/></svg>\
        <p>text</p><svg><image href="fig.png"/></svg>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.images.map(\.src), ["cover.jpg", "fig.png"])
        XCTAssertEqual(result.images[0].displayWidth, 600)
        XCTAssertEqual(result.images[0].displayHeight, 800)
        XCTAssertEqual(
            result.text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 2
        )
    }

    // MARK: - Structural block tags

    func testFigureCaptionTableDlPreBoundariesBreakParagraphs() {
        let html = """
        <p>intro</p><figure><img src="f.png"/><figcaption>Fig 1</figcaption></figure>\
        <aside>An aside</aside><dl><dt>Term</dt><dd>Meaning</dd></dl>\
        <pre>code here</pre><p>outro</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "intro\n\u{FFFC}\nFig 1\nAn aside\nTerm\nMeaning\ncode here\noutro")
    }

    func testTableCaptionBreaksAndThGetsBoldSpan() {
        let html = """
        <table><caption>Stats</caption><tr><th>Name</th><th>Age</th></tr>\
        <tr><td>Ada</td><td>36</td></tr></table><p>After.</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Stats\nName Age\nAda 36\nAfter.")
        XCTAssertEqual(result.spans.count, 2)
        XCTAssertEqual(result.spans.map(\.kind), [.bold, .bold])
        XCTAssertEqual(result.spans.map { slice(result.text, $0) }, ["Name", "Age"])
    }

    func testEpubSwitchEmitsOnlyTheDefaultBranch() {
        let html = """
        <p>Formula: <epub:switch>\
        <epub:case required-namespace="http://www.w3.org/1998/Math/MathML">\
        <math><mi>never shown</mi></math></epub:case>\
        <epub:default>a2 + b2 = c2</epub:default>\
        </epub:switch> done.</p>
        """
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "Formula: a2 + b2 = c2 done.")
        XCTAssertFalse(text.contains("never shown"))
    }

    // MARK: - U+FFFC sanitizing

    func testLiteralObjectReplacementCharactersInSourceAreStripped() {
        let html = "<p>a\u{FFFC}b &#65532;c</p><img src=\"real.png\"/>"
        let (text, images) = XHTMLTextExtractor.textAndImages(from: html)
        XCTAssertEqual(images.count, 1)
        // Exactly ONE placeholder survives — the real image's.
        XCTAssertEqual(text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 1)
        XCTAssertEqual(text, "ab c\n\u{FFFC}")
    }

    // MARK: - Blockquote recovery

    func testUnclosedBlockquoteIsClosedWhenAHeadingOpens() {
        let html = "<blockquote><p>quote text</p><h2>Next Section</h2><p>body</p>"
        let result = XHTMLTextExtractor.extract(from: html)
        let quotes = result.spans.filter { $0.kind == .blockquote }
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(slice(result.text, quotes[0]), "quote text")
    }

    func testClosedBlockquoteBeforeHeadingIsUnaffected() {
        let html = "<blockquote>quote</blockquote><h2>Head</h2>"
        let result = XHTMLTextExtractor.extract(from: html)
        let quotes = result.spans.filter { $0.kind == .blockquote }
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(slice(result.text, quotes[0]), "quote")
    }

    func testUnclosedBlockquoteWithNoHeadingStillClosesAtDocumentEnd() {
        let result = XHTMLTextExtractor.extract(from: "<blockquote><p>runs on")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .blockquote)
        XCTAssertEqual(slice(result.text, result.spans[0]), "runs on")
    }

    // MARK: - CSS/align span close bookkeeping (same-name nesting)

    func testCSSSpanSurvivesInnerSameNameElement() {
        // The inner (unstyled) </div> must NOT close the outer div's
        // CSS-derived italic span — "gamma" keeps its italics.
        let styles = CSSStyleResolver(css: ".it { font-style: italic }")
        let html = #"<div class="it">alpha <div>beta</div> gamma</div>"#
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "alpha\nbeta\ngamma")
        let italics = result.spans.filter { $0.kind == .italic }
        XCTAssertEqual(italics.count, 1)
        XCTAssertEqual(slice(result.text, italics[0]), "alpha\nbeta\ngamma")
    }

    func testInnerStyledSameNameElementClosesOnlyItsOwnSpans() {
        // The inner </div> closes the inner div's bold span ONLY — not the
        // outer div's italic span too.
        let styles = CSSStyleResolver(
            css: ".it { font-style: italic } .b { font-weight: bold }"
        )
        let html = #"<div class="it">a <div class="b">x</div> y</div>"#
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "a\nx\ny")
        let italics = result.spans.filter { $0.kind == .italic }
        let bolds = result.spans.filter { $0.kind == .bold }
        XCTAssertEqual(italics.count, 1)
        XCTAssertEqual(slice(result.text, italics[0]), "a\nx\ny")
        XCTAssertEqual(bolds.count, 1)
        XCTAssertEqual(slice(result.text, bolds[0]), "x")
    }

    func testAlignAttributeSpanSurvivesInnerSameNameElement() {
        let html = #"<div align="center">alpha <div>beta</div> gamma</div>"#
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "alpha\nbeta\ngamma")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.center))
        XCTAssertEqual(slice(result.text, result.spans[0]), "alpha\nbeta\ngamma")
    }

    func testDeepSameNameNestingKeepsOuterSpanAndStaysLinear() {
        let depth = 1500
        let styles = CSSStyleResolver(css: ".it { font-style: italic }")
        let html = "<div class=\"it\">start"
            + String(repeating: "<div>", count: depth) + "core"
            + String(repeating: "</div>", count: depth)
            + "finish</div>"
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "start\ncore\nfinish")
        let italics = result.spans.filter { $0.kind == .italic }
        XCTAssertEqual(italics.count, 1)
        XCTAssertEqual(italics[0].start, 0)
        XCTAssertEqual(italics[0].end, result.text.count)
    }

    // MARK: - Blockquote split at headings (well-formed markup)

    func testWellFormedBlockquoteWithLeadingHeadingKeepsQuoteAfterHeading() {
        // Epigraph shape: the heading must not swallow the quote — the
        // blockquote span covers the content AFTER the heading.
        let html = "<blockquote><h2>Epigraph</h2><p>quoted</p></blockquote>"
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "Epigraph\nquoted")
        let quotes = result.spans.filter { $0.kind == .blockquote }
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(slice(result.text, quotes[0]), "quoted")
        let headings = result.spans.filter { $0.kind == .heading(2) }
        XCTAssertEqual(headings.count, 1)
        XCTAssertEqual(slice(result.text, headings[0]), "Epigraph")
    }

    func testHeadingInsideBlockquoteSplitsTheQuoteSpan() {
        let html = """
        <blockquote><p>intro</p><h2>Head</h2><p>tail</p></blockquote><p>after</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "intro\nHead\ntail\nafter")
        let quotes = result.spans.filter { $0.kind == .blockquote }
        XCTAssertEqual(quotes.map { slice(result.text, $0) }, ["intro", "tail"])
    }

    func testUnclosedBlockquoteReopenedFragmentIsDroppedAtDocumentEnd() {
        // Genuinely unclosed quote + heading: the split fragment reopened
        // after the heading never sees its close tag, so it is dropped —
        // the chapter tail stays unstyled.
        let html = "<blockquote><p>quote</p><h2>Chapter II</h2><p>body runs to the end"
        let result = XHTMLTextExtractor.extract(from: html)
        let quotes = result.spans.filter { $0.kind == .blockquote }
        XCTAssertEqual(quotes.map { slice(result.text, $0) }, ["quote"])
    }

    // MARK: - Hidden content inside diverted (footnote) regions

    func testHiddenElementInsideFootnoteIsDropped() {
        let html = """
        <p>a</p>\
        <aside epub:type="footnote" id="f1">Visible \
        <img hidden src="d.png"> <span hidden>SECRET</span> tail</aside>\
        <p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes, [.init(id: "f1", text: "Visible tail")])
    }

    func testCSSHiddenElementInsideFootnoteIsDropped() {
        let styles = CSSStyleResolver(css: ".hide { display: none }")
        let html = """
        <p>a</p>\
        <aside epub:type="footnote" id="f1">outer \
        <div class="hide">SECRET</div> tail</aside>\
        <p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes, [.init(id: "f1", text: "outer tail")])
    }

    func testHiddenSameNameNestingInsideFootnoteDropsWholeRegion() {
        // The inner </div> must not end the hidden drop region early.
        let html = """
        <aside epub:type="footnote" id="f1">keep \
        <div hidden>drop <div>inner</div> more</div> end</aside><p>x</p>
        """
        let result = XHTMLTextExtractor.extract(from: html)
        XCTAssertEqual(result.text, "x")
        XCTAssertEqual(result.footnotes, [.init(id: "f1", text: "keep end")])
    }

    // MARK: - firstHeading hardening

    func testFirstHeadingMatchesAcrossNewlines() {
        let html = "<body>\n<h1>\nThe Long\nTitle\n</h1>\n</body>"
        XCTAssertEqual(XHTMLTextExtractor.firstHeading(from: html), "The Long Title")
    }

    func testFirstHeadingRequiresMatchingCloseLevel() {
        // `<h1>…</h2>` is not a heading pair; the well-formed <h2> wins.
        let html = "<h1>Broken</h2>\n<h2>Real Title</h2>"
        XCTAssertEqual(XHTMLTextExtractor.firstHeading(from: html), "Real Title")
    }

    func testFirstHeadingSkipsHeadingsThatStripToEmpty() {
        let html = "<h1><img src=\"decoration.png\"/></h1><h2> &nbsp; </h2><h3>Actual</h3>"
        XCTAssertEqual(XHTMLTextExtractor.firstHeading(from: html), "Actual")
    }

    func testFirstHeadingFallsBackToTitleElement() {
        let html = """
        <html><head><title>Chapter 7 &mdash; The Return</title></head>
        <body><p>No headings at all.</p></body></html>
        """
        XCTAssertEqual(XHTMLTextExtractor.firstHeading(from: html), "Chapter 7 — The Return")
    }

    func testFirstHeadingReturnsNilWhenTitleIsEmptyToo() {
        XCTAssertNil(XHTMLTextExtractor.firstHeading(
            from: "<head><title> </title></head><body><p>x</p></body>"
        ))
    }
}
