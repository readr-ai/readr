import XCTest
@testable import ReadrKit

/// J1 — EPUB import: spine order, metadata, TOC, and DRM rejection.
final class EPUBBookParserTests: XCTestCase {

    private let parser = EPUBBookParser()

    private func makeContainer(includeEncryption: Bool = false) -> InMemoryEPUBContainer {
        let containerXML = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Nineteen Eighty-Four</dc:title>
            <dc:creator>George Orwell</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """
        let ch1 = """
        <html><body><h1>Chapter One</h1><p>It was a bright cold day in April.</p></body></html>
        """
        let ch2 = """
        <html><body><h2>Chapter Two</h2><p>The clocks were striking thirteen.</p></body></html>
        """
        var entries: [String: String] = [
            "META-INF/container.xml": containerXML,
            "OEBPS/content.opf": opf,
            "OEBPS/ch1.xhtml": ch1,
            "OEBPS/text/ch2.xhtml": ch2,
        ]
        if includeEncryption {
            entries["META-INF/encryption.xml"] = "<encryption/>"
        }
        return InMemoryEPUBContainer(textEntries: entries)
    }

    func testParsesMetadataSpineAndTOC() throws {
        let book = try parser.parse(container: makeContainer(), fallbackTitle: "fallback")
        XCTAssertEqual(book.metadata.title, "Nineteen Eighty-Four")
        XCTAssertEqual(book.metadata.authors, ["George Orwell"])
        XCTAssertEqual(book.metadata.language, "en")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertTrue(book.chapters[0].text.contains("bright cold day"))
        XCTAssertTrue(book.chapters[1].text.contains("striking thirteen"))
        XCTAssertEqual(book.metadata.tableOfContents.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertGreaterThan(book.estimatedTokenCount, 0)
    }

    func testDRMProtectedEPUBIsRejected() {
        XCTAssertThrowsError(
            try parser.parse(container: makeContainer(includeEncryption: true), fallbackTitle: "x")
        ) { error in
            guard case BookParserError.drmProtected = error else {
                return XCTFail("expected .drmProtected, got \(error)")
            }
        }
    }

    func testMissingContainerIsCorrupted() {
        let empty = InMemoryEPUBContainer(textEntries: [:])
        XCTAssertThrowsError(try parser.parse(container: empty, fallbackTitle: "x")) { error in
            guard case BookParserError.corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    func testHrefResolutionHandlesRelativePaths() {
        XCTAssertEqual(EPUBBookParser.resolve(base: "OEBPS", href: "ch1.xhtml"), "OEBPS/ch1.xhtml")
        XCTAssertEqual(EPUBBookParser.resolve(base: "OEBPS/text", href: "../images/x"), "OEBPS/images/x")
        XCTAssertEqual(EPUBBookParser.resolve(base: "OEBPS", href: "ch1.xhtml#frag"), "OEBPS/ch1.xhtml")
        XCTAssertEqual(EPUBBookParser.resolve(base: "", href: "content.opf"), "content.opf")
    }

    // MARK: - Cover image extraction

    /// Builds a minimal one-chapter EPUB whose OPF metadata/manifest blocks are
    /// injectable, plus optional binary entries (e.g. cover image bytes).
    private func makeCoverContainer(
        metadataExtra: String = "",
        manifestExtra: String = "",
        binaryEntries: [String: Data] = [:]
    ) -> InMemoryEPUBContainer {
        let containerXML = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Covered</dc:title>
            \(metadataExtra)
          </metadata>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            \(manifestExtra)
          </manifest>
          <spine>
            <itemref idref="c1"/>
          </spine>
        </package>
        """
        let ch1 = "<html><body><h1>One</h1><p>Some content here.</p></body></html>"
        var entries: [String: Data] = [
            "META-INF/container.xml": Data(containerXML.utf8),
            "OEBPS/content.opf": Data(opf.utf8),
            "OEBPS/ch1.xhtml": Data(ch1.utf8),
        ]
        for (path, data) in binaryEntries {
            entries[path] = data
        }
        return InMemoryEPUBContainer(entries: entries)
    }

    func testExtractsEPUB3CoverImageViaManifestProperties() throws {
        let jpegBytes = Data([0xFF, 0xD8, 0xFF])
        let container = makeCoverContainer(
            manifestExtra: """
            <item id="cov" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            """,
            binaryEntries: ["OEBPS/images/cover.jpg": jpegBytes]
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.coverImageData, jpegBytes)
    }

    func testExtractsEPUB2CoverImageViaMetaCover() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let container = makeCoverContainer(
            metadataExtra: #"<meta name="cover" content="cimg"/>"#,
            manifestExtra: """
            <item id="cimg" href="cover.png" media-type="image/png"/>
            """,
            binaryEntries: ["OEBPS/cover.png": pngBytes]
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.coverImageData, pngBytes)
    }

    func testEPUB3CoverTakesPriorityOverEPUB2Meta() throws {
        let epub3Bytes = Data([0xFF, 0xD8, 0xFF, 0x01])
        let epub2Bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let container = makeCoverContainer(
            metadataExtra: #"<meta name="cover" content="old"/>"#,
            manifestExtra: """
            <item id="new" href="new.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="old" href="old.png" media-type="image/png"/>
            """,
            binaryEntries: [
                "OEBPS/new.jpg": epub3Bytes,
                "OEBPS/old.png": epub2Bytes,
            ]
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.coverImageData, epub3Bytes)
    }

    func testCoverAcceptedByExtensionWhenMediaTypeMissing() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let container = makeCoverContainer(
            metadataExtra: #"<meta name="cover" content="cimg"/>"#,
            manifestExtra: """
            <item id="cimg" href="art/cover.PNG"/>
            """,
            binaryEntries: ["OEBPS/art/cover.PNG": bytes]
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.coverImageData, bytes)
    }

    func testNonImageCoverCandidateIsIgnored() throws {
        let container = makeCoverContainer(
            metadataExtra: #"<meta name="cover" content="c1"/>"#
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertNil(book.coverImageData)
    }

    func testMissingCoverEntryYieldsNilWithoutThrowing() throws {
        let container = makeCoverContainer(
            manifestExtra: """
            <item id="cov" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
            """
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertNil(book.coverImageData)
    }

    func testNoCoverDeclaredYieldsNil() throws {
        let book = try parser.parse(container: makeContainer(), fallbackTitle: "x")
        XCTAssertNil(book.coverImageData)
    }

    // MARK: - Inline images

    func testChapterImagesGetOffsetsAndDocumentRelativePaths() throws {
        let ch1 = """
        <html><body><h1>One</h1><p>Look:</p>\
        <img src="../images/fig%201.jpg" alt="Fig"/><p>Done.</p></body></html>
        """
        let entries: [String: Data] = [
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Imgs</dc:title></metadata>
              <manifest><item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c1"/></spine>
            </package>
            """.utf8),
            "OEBPS/text/ch1.xhtml": Data(ch1.utf8),
        ]
        let book = try parser.parse(
            container: InMemoryEPUBContainer(entries: entries), fallbackTitle: "x"
        )

        let chapter = try XCTUnwrap(book.chapters.first)
        let images = try XCTUnwrap(chapter.images)
        XCTAssertEqual(images.count, 1)
        // Resolved against the DOCUMENT's directory (OEBPS/text), with ../ and
        // percent-encoding handled.
        XCTAssertEqual(images[0].archivePath, "OEBPS/images/fig 1.jpg")
        XCTAssertEqual(images[0].alt, "Fig")
        // The offset points at the placeholder character in the chapter text.
        let chars = Array(chapter.text)
        XCTAssertEqual(chars[images[0].offset], XHTMLTextExtractor.imagePlaceholder)
    }
}
