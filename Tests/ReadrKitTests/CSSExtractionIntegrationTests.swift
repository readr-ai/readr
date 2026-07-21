import XCTest
@testable import ReadrKit

/// The CSS subset engine wired into extraction: class/element stylesheet
/// rules become format spans and hidden diversions in the scanner, and
/// `EPUBBookParser` sources stylesheets from `<link rel="stylesheet">` /
/// `<style>` blocks (resolved relative to the document, fetched and parsed
/// once per archive path). CSS-free books must behave identically to the
/// plain `extract(from:)` path.
final class CSSExtractionIntegrationTests: XCTestCase {

    /// Character-offset slice of the final text (same unit as span offsets).
    private func slice(_ text: String, _ span: XHTMLTextExtractor.Span) -> String {
        let chars = Array(text)
        return String(chars[span.start..<span.end])
    }

    private func slice(_ text: String, _ span: FormatSpan) -> String {
        let chars = Array(text)
        return String(chars[span.start..<span.end])
    }

    // MARK: - Extractor + resolver

    func testCharStyleOverrideClassBecomesItalicSpanWithExactOffsets() {
        let styles = CSSStyleResolver(css: ".char-style-override-1 { font-style: italic }")
        let html = #"<p>He said <span class="char-style-override-1">very quietly</span> indeed.</p>"#
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "He said very quietly indeed.")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .italic)
        XCTAssertEqual(result.spans[0].start, 8)
        XCTAssertEqual(result.spans[0].end, 20)
        XCTAssertEqual(slice(result.text, result.spans[0]), "very quietly")
    }

    func testCenterClassBecomesAlignmentSpan() {
        let styles = CSSStyleResolver(css: ".center { text-align: center }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p>a</p><p class="center">Mid</p><p>b</p>"#, styles: styles
        )
        XCTAssertEqual(result.text, "a\nMid\nb")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.center))
        XCTAssertEqual(slice(result.text, result.spans[0]), "Mid")
    }

    func testMarginedExtractDivBecomesBlockquoteSpan() {
        let styles = CSSStyleResolver(css: ".extract { margin-left: 2em; margin-right: 2em }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p>before</p><div class="extract">Inset passage.</div><p>after</p>"#,
            styles: styles
        )
        XCTAssertEqual(result.text, "before\nInset passage.\nafter")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .blockquote)
        XCTAssertEqual(slice(result.text, result.spans[0]), "Inset passage.")
    }

    func testSmallCapsClassBecomesSmallCapsSpan() {
        let styles = CSSStyleResolver(css: ".sc { font-variant: small-caps }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span class="sc">Chapter One</span> begins.</p>"#, styles: styles
        )
        XCTAssertEqual(result.text, "Chapter One begins.")
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .smallCaps)
        XCTAssertEqual(slice(result.text, result.spans[0]), "Chapter One")
    }

    func testBoldClassOnElementRule() {
        // An element rule (no class attribute at all) still styles the tag.
        let styles = CSSStyleResolver(css: "figcaption { font-weight: bold }")
        let result = XHTMLTextExtractor.extract(
            from: "<figure><figcaption>Fig 1</figcaption></figure><p>body</p>",
            styles: styles
        )
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .bold)
        XCTAssertEqual(slice(result.text, result.spans[0]), "Fig 1")
    }

    func testClassHiddenDivDivertsLikeTheHiddenAttribute() {
        let styles = CSSStyleResolver(css: ".hide { display: none }")
        let html = """
        <p>a</p><div class="hide" id="n1">kept as note</div>\
        <div class="hide">dropped entirely</div><p>b</p>
        """
        let result = XHTMLTextExtractor.extract(from: html, styles: styles)
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.footnotes, [.init(id: "n1", text: "kept as note")])
        XCTAssertNil(result.anchors["n1"], "diverted ids stay out of the anchors map")
    }

    func testVisibilityHiddenClassAlsoDiverts() {
        let styles = CSSStyleResolver(css: ".invis { visibility: hidden }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p>a</p><div class="invis">gone</div><p>b</p>"#, styles: styles
        )
        XCTAssertEqual(result.text, "a\nb")
    }

    func testElementClassRuleBeatsClassRule() {
        let styles = CSSStyleResolver(
            css: ".x { font-weight: normal } span.x { font-weight: bold }"
        )
        let result = XHTMLTextExtractor.extract(
            from: #"<p><span class="x">heavy</span> <u class="x">light</u></p>"#,
            styles: styles
        )
        let bolds = result.spans.filter { $0.kind == .bold }
        XCTAssertEqual(bolds.count, 1, "only span.x resolves bold — .x alone is normal")
        XCTAssertEqual(slice(result.text, bolds[0]), "heavy")
    }

    func testElementRuleForPDoesNotHitSpan() {
        let styles = CSSStyleResolver(css: "p { font-style: italic }")
        let result = XHTMLTextExtractor.extract(
            from: "<p>Para text</p><div>Outside <span>inner</span></div>", styles: styles
        )
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .italic)
        XCTAssertEqual(slice(result.text, result.spans[0]), "Para text")
    }

    func testInlineStyleBeatsSheetRules() {
        let styles = CSSStyleResolver(css: ".c { text-align: left }")
        let result = XHTMLTextExtractor.extract(
            from: #"<p class="c" style="text-align: right">edge</p>"#, styles: styles
        )
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .alignment(.right))
    }

    func testFalseValuesOpenNoSpans() {
        // No un-bolding/un-italicizing in v1: normal/false facts open nothing.
        let styles = CSSStyleResolver(
            css: ".plain { font-style: normal; font-weight: normal }"
        )
        let result = XHTMLTextExtractor.extract(
            from: #"<p class="plain">just text</p>"#, styles: styles
        )
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testCSSFreeExtractionIsIdenticalToPlainExtract() {
        let html = """
        <html><body><h1 id="t">Title</h1><p align="center">mid</p>
        <p>Bold <b>run</b> and <i>italic</i> text<sup>1</sup>.</p>
        <aside epub:type="footnote" id="fn1">note body</aside>
        <img src="pic.png" alt="p"/><blockquote>quoted</blockquote>
        <ul><li>item</li></ul></body></html>
        """
        let plain = XHTMLTextExtractor.extract(from: html)
        let variants: [CSSStyleResolver?] = [nil, CSSStyleResolver()]
        for styles in variants {
            let styled = XHTMLTextExtractor.extract(from: html, styles: styles)
            XCTAssertEqual(styled.text, plain.text)
            XCTAssertEqual(styled.spans, plain.spans)
            XCTAssertEqual(styled.anchors, plain.anchors)
            XCTAssertEqual(styled.footnotes, plain.footnotes)
            XCTAssertEqual(styled.images, plain.images)
        }
    }

    // MARK: - EPUBBookParser stylesheet sourcing

    private let parser = EPUBBookParser()

    private let containerXML = """
    <?xml version="1.0"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private func makeOPF(manifest: String, spine: String) -> String {
        """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Styled Fixture</dc:title>
          </metadata>
          <manifest>
            \(manifest)
          </manifest>
          <spine>
            \(spine)
          </spine>
        </package>
        """
    }

    private func allEntries(
        manifest: String, spine: String, entries: [String: String]
    ) -> [String: String] {
        var all = entries
        all["META-INF/container.xml"] = containerXML
        all["OEBPS/content.opf"] = makeOPF(manifest: manifest, spine: spine)
        return all
    }

    private func parse(
        manifest: String, spine: String, entries: [String: String]
    ) throws -> Book {
        try parser.parse(
            container: InMemoryEPUBContainer(
                textEntries: allEntries(manifest: manifest, spine: spine, entries: entries)
            ),
            fallbackTitle: "x"
        )
    }

    func testLinkedSheetResolvesRelativeToTheDocumentDirectory() throws {
        let chapter = """
        <html><head>
        <link type="text/css" href="../css/style.css" rel="stylesheet"/>
        </head><body><p>He said <span class="i">quietly</span>.</p></body></html>
        """
        let book = try parse(
            manifest: """
            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="css/style.css" media-type="text/css"/>
            """,
            spine: #"<itemref idref="c1"/>"#,
            entries: [
                "OEBPS/text/ch1.xhtml": chapter,
                "OEBPS/css/style.css": ".i { font-style: italic }",
            ]
        )
        let chapterOne = book.chapters[0]
        XCTAssertEqual(chapterOne.text, "He said quietly.")
        let spans = chapterOne.formatSpans ?? []
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .italic)
        XCTAssertEqual(slice(chapterOne.text, spans[0]), "quietly")
    }

    func testSharedSheetStylesBothChaptersAndIsFetchedOnce() throws {
        func chapterHTML(_ word: String) -> String {
            """
            <html><head><link rel='stylesheet' href='style.css'/></head>
            <body><p><span class="i">\(word)</span></p></body></html>
            """
        }
        let recording = RecordingContainer(textEntries: allEntries(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            """,
            spine: #"<itemref idref="c1"/><itemref idref="c2"/>"#,
            entries: [
                "OEBPS/ch1.xhtml": chapterHTML("one"),
                "OEBPS/ch2.xhtml": chapterHTML("two"),
                "OEBPS/style.css": ".i { font-style: italic }",
            ]
        ))
        let book = try parser.parse(container: recording, fallbackTitle: "x")
        XCTAssertEqual(book.chapters.count, 2)
        for chapter in book.chapters {
            let spans = chapter.formatSpans ?? []
            XCTAssertEqual(spans.map(\.kind), [.italic], "chapter: \(chapter.text)")
        }
        XCTAssertEqual(
            recording.requests.filter { $0 == "OEBPS/style.css" }.count, 1,
            "the sheet is fetched once and reused across chapters"
        )
    }

    func testManifestCSSNeverLinkedIsNotFetched() throws {
        let recording = RecordingContainer(textEntries: allEntries(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="unused.css" media-type="text/css"/>
            """,
            spine: #"<itemref idref="c1"/>"#,
            entries: [
                "OEBPS/ch1.xhtml": "<html><body><p>plain text</p></body></html>",
                "OEBPS/unused.css": ".i { font-style: italic }",
            ]
        ))
        let book = try parser.parse(container: recording, fallbackTitle: "x")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertFalse(
            recording.requests.contains("OEBPS/unused.css"),
            "css never referenced by any document must not be fetched"
        )
    }

    func testStyleBlockRulesApplyAndComposeAfterLinkedSheets() throws {
        let chapter = """
        <html><head>
        <link rel="stylesheet" href="style.css"/>
        <style>.c { text-align: center }</style>
        </head><body><p class="c">mid</p><p class="b">strong</p></body></html>
        """
        let book = try parse(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            """,
            spine: #"<itemref idref="c1"/>"#,
            entries: [
                "OEBPS/ch1.xhtml": chapter,
                // The linked sheet says left; the later <style> block wins.
                "OEBPS/style.css": ".c { text-align: left } .b { font-weight: bold }",
            ]
        )
        let spans = book.chapters[0].formatSpans ?? []
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].kind, .alignment(.center))
        XCTAssertEqual(slice(book.chapters[0].text, spans[0]), "mid")
        XCTAssertEqual(spans[1].kind, .bold)
        XCTAssertEqual(slice(book.chapters[0].text, spans[1]), "strong")
    }

    func testSmallCapsClassSurvivesToChapterFormatSpans() throws {
        let chapter = """
        <html><head><style>.sc { font-variant: small-caps }</style></head>
        <body><p><span class="sc">Anno Domini</span> era</p></body></html>
        """
        let book = try parse(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#,
            entries: ["OEBPS/ch1.xhtml": chapter]
        )
        let spans = book.chapters[0].formatSpans ?? []
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .smallCaps)
        XCTAssertEqual(slice(book.chapters[0].text, spans[0]), "Anno Domini")
    }

    func testClassHiddenContentBecomesChapterFootnote() throws {
        let chapter = """
        <html><head><style>.hide { display: none }</style></head>
        <body><p>a</p><div class="hide" id="n1">the note</div><p>b</p></body></html>
        """
        let book = try parse(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#,
            entries: ["OEBPS/ch1.xhtml": chapter]
        )
        XCTAssertEqual(book.chapters[0].text, "a\nb")
        XCTAssertEqual(book.chapters[0].footnotes, [Footnote(id: "n1", text: "the note")])
    }

    func testMissingLinkedSheetIsIgnored() throws {
        let chapter = """
        <html><head><link rel="stylesheet" href="missing.css"/></head>
        <body><p class="i">still readable</p></body></html>
        """
        let book = try parse(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#,
            entries: ["OEBPS/ch1.xhtml": chapter]
        )
        XCTAssertEqual(book.chapters[0].text, "still readable")
        XCTAssertNil(book.chapters[0].formatSpans)
    }
}

/// Wraps `InMemoryEPUBContainer` and records every `data(at:)` request, so
/// tests can assert what got fetched (and how many times).
private final class RecordingContainer: EPUBContainer {
    private let inner: InMemoryEPUBContainer
    private(set) var requests: [String] = []
    var extractionBudget: EPUBExtractionBudget { inner.extractionBudget }

    init(textEntries: [String: String]) {
        inner = InMemoryEPUBContainer(textEntries: textEntries)
    }

    func entryExists(_ path: String) -> Bool { inner.entryExists(path) }

    func data(at path: String) throws -> Data {
        requests.append(path)
        return try inner.data(at: path)
    }
}
