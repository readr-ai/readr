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
}
