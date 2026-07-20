import XCTest
@testable import ReadrKit

/// EPUB rendering overhaul at the parser/model layer: spine de-duplication,
/// `sourcePath`/`formatSpans`/`anchors` on `Chapter`, link-target resolution,
/// image display sizes, and Codable compatibility for persisted libraries.
final class EPUBStructureParsingTests: XCTestCase {

    private let parser = EPUBBookParser()

    private let standardContainerXML = """
    <?xml version="1.0"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private func makeOPF(
        metadata: String = "<dc:title>Fixture</dc:title>",
        manifest: String,
        spine: String
    ) -> String {
        """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)
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

    private func container(opf: String, entries: [String: String]) -> InMemoryEPUBContainer {
        var all = entries
        all["META-INF/container.xml"] = standardContainerXML
        all["OEBPS/content.opf"] = opf
        return InMemoryEPUBContainer(textEntries: all)
    }

    private let chapterOne = """
    <html><body><h1>Chapter One</h1><p>It was a bright cold day in April.</p></body></html>
    """
    private let chapterTwo = """
    <html><body><h2>Chapter Two</h2><p>The clocks were striking thirteen.</p></body></html>
    """

    // MARK: - Spine de-duplication

    /// Two itemrefs (distinct manifest ids) resolving to the same content
    /// document must emit ONE chapter — the first occurrence wins.
    func testTwoItemrefsResolvingToSameHrefEmitOneChapter() throws {
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1dup" href="./ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c1dup"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/ch2.xhtml": chapterTwo,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertEqual(book.chapters.map(\.order), [0, 1])
    }

    /// The same idref repeated in the spine must also emit one chapter.
    func testDuplicateIdrefsEmitOneChapter() throws {
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            <itemref idref="c1"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/ch2.xhtml": chapterTwo,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two"])
    }

    // MARK: - sourcePath / formatSpans / anchors wiring

    func testChaptersCarrySourcePathFormatSpansAndAnchors() throws {
        let ch1 = """
        <html><body><h1 id="top">Chapter One</h1><p id="p1">It was a <b>bright</b> day.</p></body></html>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/text/ch1.xhtml": ch1]),
            fallbackTitle: "x"
        )
        let chapter = try XCTUnwrap(book.chapters.first)
        XCTAssertEqual(chapter.sourcePath, "OEBPS/text/ch1.xhtml")
        XCTAssertEqual(chapter.text, "Chapter One\nIt was a bright day.")

        let spans = try XCTUnwrap(chapter.formatSpans)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].kind, .heading(1))
        XCTAssertEqual(spans[0].start, 0)
        XCTAssertEqual(spans[0].end, 11)
        XCTAssertEqual(spans[1].kind, .bold)
        XCTAssertEqual(spans[1].start, 21)
        XCTAssertEqual(spans[1].end, 27)

        let anchors = try XCTUnwrap(chapter.anchors)
        XCTAssertEqual(anchors, ["top": 0, "p1": 12])
    }

    // MARK: - Link target resolution

    func testLinkTargetsResolveExternalInternalAndBareFragment() throws {
        let ch1 = """
        <html><body><p>
        <a href="https://example.com/a">ext</a>
        <a href="mailto:x@y.z">mail</a>
        <a href="../notes.xhtml#n1">note</a>
        <a href="#top">top</a>
        <a href="other.xhtml">plain</a>
        </p></body></html>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/text/ch1.xhtml": ch1]),
            fallbackTitle: "x"
        )
        let spans = try XCTUnwrap(book.chapters.first?.formatSpans)
        XCTAssertEqual(spans.map(\.kind), [
            .link(.external(url: "https://example.com/a")),
            .link(.external(url: "mailto:x@y.z")),
            .link(.internalDoc(path: "OEBPS/notes.xhtml", fragment: "n1")),
            // Bare fragment: the chapter's own document.
            .link(.internalDoc(path: "OEBPS/text/ch1.xhtml", fragment: "top")),
            .link(.internalDoc(path: "OEBPS/text/other.xhtml", fragment: nil)),
        ])
        // Spans cover the link texts in the final text.
        let chars = Array(book.chapters[0].text)
        XCTAssertEqual(String(chars[spans[0].start..<spans[0].end]), "ext")
        XCTAssertEqual(String(chars[spans[3].start..<spans[3].end]), "top")
    }

    func testSchemeAndProtocolRelativeHrefsAreExternalAndFragmentsDecode() {
        // Any RFC 3986 scheme or a protocol-relative href leaves the book —
        // these used to be mangled into bogus internal archive paths.
        for href in ["//example.com/p", "tel:+15551234567",
                     "data:image/png;base64,AAAA", "HTTPS://x.y/z"] {
            XCTAssertEqual(
                EPUBBookParser.linkTarget(
                    href: href, documentPath: "OEBPS/text/ch1.xhtml", documentDir: "OEBPS/text"
                ),
                .external(url: href), "\(href) should be external"
            )
        }
        // A colon later in a relative href is not a scheme.
        XCTAssertEqual(
            EPUBBookParser.linkTarget(
                href: "ch2.xhtml#note:1", documentPath: "OEBPS/text/ch1.xhtml",
                documentDir: "OEBPS/text"
            ),
            .internalDoc(path: "OEBPS/text/ch2.xhtml", fragment: "note:1")
        )
        // Fragments percent-decode, matching the path half and the raw
        // markup ids in Chapter.anchors.
        XCTAssertEqual(
            EPUBBookParser.linkTarget(
                href: "ch2.xhtml#note%201", documentPath: "OEBPS/text/ch1.xhtml",
                documentDir: "OEBPS/text"
            ),
            .internalDoc(path: "OEBPS/text/ch2.xhtml", fragment: "note 1")
        )
    }

    // MARK: - Image display sizes

    func testChapterImagesPropagateDisplaySizes() throws {
        let ch1 = """
        <html><body><p>Look:</p>\
        <img src="../images/icon.png" alt="icon" width="24" height="24"/>\
        <img src="../images/photo.jpg" alt="photo"/></body></html>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/text/ch1.xhtml": ch1]),
            fallbackTitle: "x"
        )
        let images = try XCTUnwrap(book.chapters.first?.images)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].archivePath, "OEBPS/images/icon.png")
        XCTAssertEqual(images[0].displayWidth, 24)
        XCTAssertEqual(images[0].displayHeight, 24)
        XCTAssertNil(images[1].displayWidth)
        XCTAssertNil(images[1].displayHeight)
    }

    // MARK: - Codable compatibility

    func testChapterWithNewFieldsRoundTripsThroughCodable() throws {
        let chapter = Chapter(
            title: "One",
            order: 0,
            text: "Heading\nSome linked text \u{FFFC}",
            images: [ChapterImage(
                offset: 25, archivePath: "OEBPS/img/a.png", alt: "A",
                displayWidth: 24, displayHeight: 12.5
            )],
            formatSpans: [
                FormatSpan(start: 0, end: 7, kind: .heading(2)),
                FormatSpan(start: 8, end: 12, kind: .bold),
                FormatSpan(start: 13, end: 19, kind: .italic),
                FormatSpan(start: 8, end: 19, kind: .blockquote),
                FormatSpan(start: 13, end: 19, kind: .link(.external(url: "https://e.com"))),
                FormatSpan(start: 20, end: 24, kind: .link(
                    .internalDoc(path: "OEBPS/ch2.xhtml", fragment: "n1")
                )),
                FormatSpan(start: 20, end: 24, kind: .link(
                    .internalDoc(path: "OEBPS/ch3.xhtml", fragment: nil)
                )),
            ],
            sourcePath: "OEBPS/ch1.xhtml",
            anchors: ["top": 0, "p1": 8]
        )
        let data = try JSONEncoder().encode(chapter)
        let decoded = try JSONDecoder().decode(Chapter.self, from: data)
        XCTAssertEqual(decoded, chapter)
    }

    /// Libraries persisted before this change carry chapters without the new
    /// fields — they must still decode (all new fields are optional).
    func testLegacyChapterJSONWithoutNewFieldsDecodes() throws {
        let legacyJSON = """
        {
          "id": "6F1E25C5-3F76-4A62-8D0A-111111111111",
          "title": "Old",
          "order": 3,
          "text": "Legacy text \u{FFFC}",
          "images": [
            {"offset": 12, "archivePath": "OEBPS/img/x.png", "alt": "X"}
          ]
        }
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(chapter.title, "Old")
        XCTAssertEqual(chapter.order, 3)
        XCTAssertNil(chapter.formatSpans)
        XCTAssertNil(chapter.sourcePath)
        XCTAssertNil(chapter.anchors)
        let image = try XCTUnwrap(chapter.images?.first)
        XCTAssertEqual(image.archivePath, "OEBPS/img/x.png")
        XCTAssertNil(image.displayWidth)
        XCTAssertNil(image.displayHeight)
    }
}
