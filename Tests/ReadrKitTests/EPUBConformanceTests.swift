import XCTest
@testable import ReadrKit

/// Real-world EPUB variance the launch corpus exercises (Standard Ebooks,
/// Project Gutenberg, Calibre conversions, technical publishers): container
/// quirks, OPF/spine oddities, encodings, and the two declared TOC sources
/// (EPUB 3 nav document preferred, EPUB 2 NCX fallback).
final class EPUBConformanceTests: XCTestCase {

    private let parser = EPUBBookParser()

    // MARK: - Fixture builders

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
        spine: String,
        spineAttributes: String = ""
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
          <spine\(spineAttributes)>
            \(spine)
          </spine>
        </package>
        """
    }

    private let chapterOne = """
    <html><body><h1>Chapter One</h1><p>It was a bright cold day in April.</p></body></html>
    """
    private let chapterTwo = """
    <html><body><h2>Chapter Two</h2><p>The clocks were striking thirteen.</p></body></html>
    """

    private func container(
        containerXML: String? = nil,
        opf: String,
        entries extraEntries: [String: String] = [:],
        binaryEntries: [String: Data] = [:]
    ) -> InMemoryEPUBContainer {
        var entries: [String: Data] = [
            "META-INF/container.xml": Data((containerXML ?? standardContainerXML).utf8),
            "OEBPS/content.opf": Data(opf.utf8),
        ]
        for (path, text) in extraEntries { entries[path] = Data(text.utf8) }
        for (path, data) in binaryEntries { entries[path] = data }
        return InMemoryEPUBContainer(entries: entries)
    }

    // MARK: - container.xml quirks

    func testMultipleRootfilesPicksThePackageDocument() throws {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="extras/preview.txt" media-type="text/plain"/>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(containerXML: containerXML, opf: opf,
                                 entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
    }

    func testRootfilePathToleratesBackslashesAndDotSlash() throws {
        let containerXML = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path=".\\OEBPS\\content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(containerXML: containerXML, opf: opf,
                                 entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
    }

    // MARK: - OPF / spine variance

    func testLinearNoSpineItemsKeepPositionAndAreFlaggedNonLinear() throws {
        let opf = makeOPF(
            manifest: """
            <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="notes" linear="no"/>
            <itemref idref="c1"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/notes.xhtml": "<html><body><p>Endnotes here.</p></body></html>",
            ]),
            fallbackTitle: "x"
        )
        // linear="no" items keep their spine POSITION (links into them keep
        // working, no surprise reordering) but are flagged non-linear so
        // continuous reading order skips them.
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[0].text.contains("Endnotes here."))
        XCTAssertEqual(book.chapters[0].isLinear, false)
        XCTAssertTrue(book.chapters[1].text.contains("bright cold day"))
        XCTAssertNil(book.chapters[1].isLinear)
        XCTAssertEqual(book.chapters.map(\.order), [0, 1])
    }

    func testSpineIdrefCaseMismatchStillResolves() throws {
        let opf = makeOPF(
            manifest: #"<item id="Chapter1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="chapter1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
    }

    func testDuplicateManifestIDsFirstDeclarationWins() throws {
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="missing.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("bright cold day"))
    }

    func testURLEncodedManifestHrefResolvesToArchiveEntry() throws {
        let opf = makeOPF(
            manifest: #"<item id="c1" href="my%20chapter.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/my chapter.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
    }

    func testSpineEntryMissingFromArchiveSkipsChapterNotBook() throws {
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="gone.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("bright cold day"))
    }

    func testEmptyChapterDocumentIsSkipped() throws {
        let opf = makeOPF(
            manifest: """
            <item id="blank" href="blank.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="blank"/>
            <itemref idref="c1"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/blank.xhtml": "<html><body><p>   </p></body></html>",
                "OEBPS/ch1.xhtml": chapterOne,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].order, 0)
    }

    // MARK: - encryption.xml: DRM vs font obfuscation

    /// Professionally produced EPUBs (InDesign exports) often carry an
    /// encryption.xml that only declares obfuscated embedded fonts — that is
    /// NOT DRM and the book must open.
    func testFontObfuscationOnlyEncryptionXMLIsNotTreatedAsDRM() throws {
        let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/Custom.otf"/></enc:CipherData>
          </enc:EncryptedData>
          <enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/Other.ttf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "META-INF/encryption.xml": encryption,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
    }

    func testRealDRMEncryptionXMLIsStillRejected() {
        let encryption = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <enc:EncryptedData xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        XCTAssertThrowsError(try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "META-INF/encryption.xml": encryption,
            ]),
            fallbackTitle: "x"
        )) { error in
            guard case BookParserError.drmProtected = error else {
                return XCTFail("expected .drmProtected, got \(error)")
            }
        }
    }

    func testUnreadableEncryptionXMLStaysConservativelyDRM() {
        // No declared algorithms at all — keep the conservative rejection.
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        XCTAssertThrowsError(try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "META-INF/encryption.xml": "<encryption/>",
            ]),
            fallbackTitle: "x"
        )) { error in
            guard case BookParserError.drmProtected = error else {
                return XCTFail("expected .drmProtected, got \(error)")
            }
        }
    }

    // MARK: - Metadata

    func testTitleEntitiesDecodeAndMultipleCreatorsCollect() throws {
        let opf = makeOPF(
            metadata: """
            <dc:title>Pride &amp; Prejudice &#8212; Annotated</dc:title>
            <dc:creator>Jane Austen</dc:creator>
            <dc:creator>A. N. Editor</dc:creator>
            """,
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.metadata.title, "Pride & Prejudice — Annotated")
        XCTAssertEqual(book.metadata.authors, ["Jane Austen", "A. N. Editor"])
    }

    func testMissingTitleFallsBackToProvidedFilename() throws {
        let opf = makeOPF(
            metadata: "<dc:creator>Anonymous</dc:creator>",
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: ["OEBPS/ch1.xhtml": chapterOne]),
            fallbackTitle: "my-book.epub"
        )
        XCTAssertEqual(book.metadata.title, "my-book.epub")
    }

    // MARK: - Encodings and BOMs

    private let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    func testUTF8BOMOnEveryFileStillParsesCleanly() throws {
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let entries: [String: Data] = [
            "META-INF/container.xml": utf8BOM + Data(standardContainerXML.utf8),
            "OEBPS/content.opf": utf8BOM + Data(opf.utf8),
            "OEBPS/ch1.xhtml": utf8BOM + Data(chapterOne.utf8),
        ]
        let book = try parser.parse(
            container: InMemoryEPUBContainer(entries: entries), fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertFalse(book.chapters[0].text.contains("\u{FEFF}"))
        XCTAssertTrue(book.chapters[0].text.hasPrefix("Chapter One"))
    }

    func testUTF16LittleEndianChapterWithBOMDecodes() throws {
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let utf16 = Data([0xFF, 0xFE]) + chapterOne.data(using: .utf16LittleEndian)!
        let book = try parser.parse(
            container: container(opf: opf, binaryEntries: ["OEBPS/ch1.xhtml": utf16]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("bright cold day"))
        XCTAssertFalse(book.chapters[0].text.contains("\u{FEFF}"))
    }

    func testUTF16BigEndianChapterWithBOMDecodes() throws {
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let utf16 = Data([0xFE, 0xFF]) + chapterOne.data(using: .utf16BigEndian)!
        let book = try parser.parse(
            container: container(opf: opf, binaryEntries: ["OEBPS/ch1.xhtml": utf16]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("bright cold day"))
    }

    func testLatin1ChapterWithDeclaredEncodingDecodes() throws {
        let latin1Chapter = """
        <?xml version="1.0" encoding="iso-8859-1"?>
        <html><body><p>Un caf\u{E9} pr\u{E8}s de la Seine.</p></body></html>
        """
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let book = try parser.parse(
            container: container(opf: opf, binaryEntries: [
                "OEBPS/ch1.xhtml": latin1Chapter.data(using: .isoLatin1)!,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("café près"))
    }

    func testUndeclaredNonUTF8ChapterFallsBackToLatin1() throws {
        let opf = makeOPF(
            manifest: #"<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#
        )
        let chapter = "<html><body><p>Un caf\u{E9} sans prologue.</p></body></html>"
        let book = try parser.parse(
            container: container(opf: opf, binaryEntries: [
                "OEBPS/ch1.xhtml": chapter.data(using: .isoLatin1)!,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("café"))
    }

    // MARK: - Table of contents sources

    /// Two-chapter book with an EPUB 3 nav doc AND an EPUB 2 NCX, each naming
    /// the chapters differently from their headings — so the tests can tell
    /// exactly which TOC source won.
    private func tocFixture(includeNav: Bool, includeNCX: Bool) -> InMemoryEPUBContainer {
        var manifest = """
        <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
        """
        var entries = [
            "OEBPS/ch1.xhtml": chapterOne,
            "OEBPS/text/ch2.xhtml": chapterTwo,
        ]
        if includeNav {
            manifest += "\n<item id=\"nav\" href=\"nav.xhtml\" properties=\"nav\" media-type=\"application/xhtml+xml\"/>"
            entries["OEBPS/nav.xhtml"] = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="landmarks"><ol><li><a href="ch1.xhtml">Begin</a></li></ol></nav>
            <nav epub:type="toc"><h1>Contents</h1><ol>
              <li><a href="ch1.xhtml">Nav One</a></li>
              <li><a href="text/ch2.xhtml#start">Nav&nbsp;&amp;&nbsp;Two</a></li>
            </ol></nav>
            </body></html>
            """
        }
        if includeNCX {
            manifest += "\n<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
            entries["OEBPS/toc.ncx"] = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="n1" playOrder="1">
                  <navLabel><text>Part I &amp; Intro</text></navLabel>
                  <content src="ch1.xhtml"/>
                  <navPoint id="n2" playOrder="2">
                    <navLabel><text>Nested Second</text></navLabel>
                    <content src="text/ch2.xhtml#s1"/>
                  </navPoint>
                </navPoint>
              </navMap>
            </ncx>
            """
        }
        let opf = makeOPF(
            manifest: manifest,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """,
            spineAttributes: includeNCX ? " toc=\"ncx\"" : ""
        )
        return container(opf: opf, entries: entries)
    }

    func testEPUB3NavDocTOCIsPreferredOverNCXAndHeadings() throws {
        let book = try parser.parse(
            container: tocFixture(includeNav: true, includeNCX: true), fallbackTitle: "x"
        )
        // Titles come from the toc nav (not landmarks, not NCX, not headings);
        // &nbsp;/&amp; decode; the fragment href still maps to chapter 1 and
        // keeps its fragment for the in-document jump.
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["Nav One", "Nav & Two"])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.fragment), [nil, "start"])
    }

    func testNCXTOCIsUsedWhenThereIsNoNavDoc() throws {
        let book = try parser.parse(
            container: tocFixture(includeNav: false, includeNCX: true), fallbackTitle: "x"
        )
        // Nested navPoints flatten in document order; XML entities decode.
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["Part I & Intro", "Nested Second"]
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1])
    }

    func testHeadingTOCRemainsTheFallbackWhenNeitherSourceExists() throws {
        let book = try parser.parse(
            container: tocFixture(includeNav: false, includeNCX: false), fallbackTitle: "x"
        )
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["Chapter One", "Chapter Two"]
        )
    }

    /// Several TOC entries pointing into ONE spine document all survive
    /// (fragments distinguish them for in-document jumps); only EXACT
    /// duplicates (same chapter + fragment + title) collapse, and entries
    /// whose target isn't a parsed chapter are still dropped.
    func testNavTOCKeepsFragmentEntriesAndDropsUnknownTargets() throws {
        let navDoc = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol>
          <li><a href="ch1.xhtml">Intro</a></li>
          <li><a href="ch1.xhtml#part2">Intro, Part 2</a></li>
          <li><a href="ch1.xhtml#part2">Intro, Part 2</a></li>
          <li><a href="notes.xhtml">Notes (not in spine)</a></li>
          <li><a href="text/ch2.xhtml">Two</a></li>
        </ol></nav>
        </body></html>
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/nav.xhtml": navDoc,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["Intro", "Intro, Part 2", "Two"]
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 0, 1])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.fragment), [nil, "part2", nil])
    }

    // MARK: - TOC nav selection (epub:type / role token matching)

    /// `epub:type="no-toc"` must not be mistaken for the toc nav (the old
    /// `\btoc\b` regex matched at the hyphen) — the REAL toc nav later in the
    /// document wins.
    func testHyphenatedNoTocNavIsNotSelectedAsTheTOC() throws {
        let navDoc = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="no-toc"><ol><li><a href="ch1.xhtml">Wrong</a></li></ol></nav>
        <nav epub:type="toc"><ol>
          <li><a href="ch1.xhtml">Right One</a></li>
          <li><a href="text/ch2.xhtml">Right Two</a></li>
        </ol></nav>
        </body></html>
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/nav.xhtml": navDoc,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title), ["Right One", "Right Two"]
        )
    }

    /// When no nav carries the toc type, landmarks and page-list navs are
    /// skipped in favor of the first non-auxiliary nav.
    func testLandmarksAndPageListNavsAreSkippedWhenNoTocNavExists() throws {
        let navDoc = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="landmarks"><ol><li><a href="ch1.xhtml">Guide</a></li></ol></nav>
        <nav epub:type="page-list"><ol><li><a href="ch1.xhtml">1</a></li></ol></nav>
        <nav><ol>
          <li><a href="ch1.xhtml">One</a></li>
          <li><a href="text/ch2.xhtml">Two</a></li>
        </ol></nav>
        </body></html>
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/nav.xhtml": navDoc,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["One", "Two"])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1])
    }

    // MARK: - NCX fragments and malformed srcs

    /// NCX entries carry their (percent-decoded) fragment; a fragment-only
    /// `content src="#x"` is malformed in an NCX and is dropped.
    func testNCXPopulatesFragmentsAndDropsFragmentOnlySrc() throws {
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1"><navLabel><text>One</text></navLabel><content src="ch1.xhtml"/></navPoint>
            <navPoint id="n2"><navLabel><text>Bad</text></navLabel><content src="#loose"/></navPoint>
            <navPoint id="n3"><navLabel><text>Two</text></navLabel><content src="text/ch2.xhtml#s%201"/></navPoint>
          </navMap>
        </ncx>
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """,
            spineAttributes: " toc=\"ncx\""
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/toc.ncx": ncx,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["One", "Two"])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.fragment), [nil, "s 1"])
    }

    // MARK: - Partial-TOC rejection and fall-through

    /// A nav doc that resolves only 1 of its 5 entries is a broken source —
    /// it must fall through to the complete NCX instead of shipping a
    /// one-entry Contents list.
    func testNavResolvingFewEntriesFallsThroughToCompleteNCX() throws {
        let navDoc = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol>
          <li><a href="gone1.xhtml">Lost One</a></li>
          <li><a href="gone2.xhtml">Lost Two</a></li>
          <li><a href="gone3.xhtml">Lost Three</a></li>
          <li><a href="gone4.xhtml">Lost Four</a></li>
          <li><a href="ch1.xhtml">Nav One</a></li>
        </ol></nav>
        </body></html>
        """
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1"><navLabel><text>NCX One</text></navLabel><content src="ch1.xhtml"/></navPoint>
            <navPoint id="n2"><navLabel><text>NCX Two</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """,
            spineAttributes: " toc=\"ncx\""
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/nav.xhtml": navDoc,
                "OEBPS/toc.ncx": ncx,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["NCX One", "NCX Two"])
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1])
    }

    /// An NCX whose XML parse aborts mid-document — truncated in the LAST
    /// navPoint, so `parserError` is set (premature EOF; on Darwin an
    /// undeclared `&nbsp;` entity aborts the same way) — still parsed most
    /// of its entries. That partial TOC beats the heading fallback and is
    /// kept.
    func testAbortedNCXKeepsMostlyParsedEntries() throws {
        var manifest = ""
        var spine = ""
        var entries: [String: String] = [:]
        for (i, name) in ["One", "Two", "Three", "Four", "Five"].enumerated() {
            manifest += "<item id=\"c\(i)\" href=\"ch\(i).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i)\"/>\n"
            entries["OEBPS/ch\(i).xhtml"] =
                "<html><body><h1>Heading \(name)</h1><p>Text.</p></body></html>"
        }
        manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        // Truncated mid-way through the fifth navPoint's label: the XML
        // parse aborts with four complete navPoints collected.
        entries["OEBPS/toc.ncx"] = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n0"><navLabel><text>NCX One</text></navLabel><content src="ch0.xhtml"/></navPoint>
            <navPoint id="n1"><navLabel><text>NCX Two</text></navLabel><content src="ch1.xhtml"/></navPoint>
            <navPoint id="n2"><navLabel><text>NCX Three</text></navLabel><content src="ch2.xhtml"/></navPoint>
            <navPoint id="n3"><navLabel><text>NCX Four</text></navLabel><content src="ch3.xhtml"/></navPoint>
            <navPoint id="n4"><navLabel><text>NCX Five
        """
        let opf = makeOPF(
            manifest: manifest, spine: spine, spineAttributes: " toc=\"ncx\""
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: entries), fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 5)
        // Four of five entries parsed before the abort — kept, not headings.
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["NCX One", "NCX Two", "NCX Three", "NCX Four"]
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [0, 1, 2, 3])
    }

    /// The same mid-document abort in the FIRST navPoint leaves nothing
    /// usable — the parser must fall through to the heading fallback.
    func testAbortedNCXEarlyFallsThroughToHeadings() throws {
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1"><navLabel><text>Part I
        """
        let opf = makeOPF(
            manifest: """
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            """,
            spine: """
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """,
            spineAttributes: " toc=\"ncx\""
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/text/ch2.xhtml": chapterTwo,
                "OEBPS/toc.ncx": ncx,
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["Chapter One", "Chapter Two"]
        )
    }

    // MARK: - Heading fallback completeness

    /// With no declared TOC, every LINEAR chapter gets an entry — heading
    /// when it has one, "Section N" when it doesn't — and non-linear
    /// chapters (notes files) stay out of Contents.
    func testHeadingFallbackCoversHeadinglessChaptersAndSkipsNonLinear() throws {
        let opf = makeOPF(
            manifest: """
            <item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            """,
            spine: """
            <itemref idref="notes" linear="no"/>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            """
        )
        let book = try parser.parse(
            container: container(opf: opf, entries: [
                "OEBPS/notes.xhtml": "<html><body><p>Endnotes here.</p></body></html>",
                "OEBPS/ch1.xhtml": chapterOne,
                "OEBPS/ch2.xhtml": "<html><body><p>No heading, just prose.</p></body></html>",
            ]),
            fallbackTitle: "x"
        )
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(
            book.metadata.tableOfContents.map(\.title),
            ["Chapter One", "Section 2"]
        )
        XCTAssertEqual(book.metadata.tableOfContents.map(\.chapterIndex), [1, 2])
    }
}
