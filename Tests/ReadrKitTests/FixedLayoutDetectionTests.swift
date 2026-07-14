import XCTest
@testable import ReadrKit

/// Fixed-layout (FXL) EPUB detection — Apple Books Asset Guide vocabulary:
/// book-level `<meta property="rendition:layout">pre-paginated</meta>`, the
/// per-spine-item `rendition:layout-pre-paginated` override, and the legacy
/// Apple `com.apple.ibooks.display-options.xml` declaration. The flag is
/// optional on `BookMetadata` so pre-existing `library.json` files decode
/// unchanged (nil == reflowable), mirroring how the v2 fields were added.
final class FixedLayoutDetectionTests: XCTestCase {

    private let parser = EPUBBookParser()

    private func makeContainer(
        metadataExtra: String = "",
        spineItemExtra: String = "",
        extraEntries: [String: String] = [:]
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
            <dc:title>Layout Fixture</dc:title>
            \(metadataExtra)
          </metadata>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"\(spineItemExtra)/>
          </spine>
        </package>
        """
        var entries = [
            "META-INF/container.xml": containerXML,
            "OEBPS/content.opf": opf,
            "OEBPS/ch1.xhtml": "<html><body><h1>One</h1><p>Picture-book page.</p></body></html>",
        ]
        for (path, text) in extraEntries { entries[path] = text }
        return InMemoryEPUBContainer(textEntries: entries)
    }

    // MARK: - Detection at parse time

    func testBookLevelPrePaginatedMetaMarksFixedLayout() throws {
        let container = makeContainer(
            metadataExtra: #"<meta property="rendition:layout">pre-paginated</meta>"#
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.metadata.isFixedLayout, true)
    }

    func testSpineItemPrePaginatedOverrideMarksFixedLayout() throws {
        let container = makeContainer(
            spineItemExtra: #" properties="rendition:layout-pre-paginated""#
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.metadata.isFixedLayout, true)
    }

    func testReflowableBookLeavesFlagNil() throws {
        let book = try parser.parse(container: makeContainer(), fallbackTitle: "x")
        XCTAssertNil(book.metadata.isFixedLayout)
    }

    func testExplicitReflowableMetaLeavesFlagNil() throws {
        let container = makeContainer(
            metadataExtra: #"<meta property="rendition:layout">reflowable</meta>"#
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertNil(book.metadata.isFixedLayout)
    }

    func testLegacyAppleDisplayOptionsMarksFixedLayout() throws {
        let displayOptions = """
        <?xml version="1.0" encoding="UTF-8"?>
        <display_options>
          <platform name="*">
            <option name="fixed-layout">true</option>
          </platform>
        </display_options>
        """
        let container = makeContainer(
            extraEntries: ["META-INF/com.apple.ibooks.display-options.xml": displayOptions]
        )
        let book = try parser.parse(container: container, fallbackTitle: "x")
        XCTAssertEqual(book.metadata.isFixedLayout, true)
    }

    // MARK: - Codable back-compat

    func testMetadataJSONWithoutFixedLayoutKeyStillDecodes() throws {
        // Exactly what a pre-FXL JSONEncoder wrote: no `isFixedLayout` key.
        let json = """
        {"title": "Old Book", "authors": ["A"], "tableOfContents": []}
        """
        let metadata = try JSONDecoder().decode(BookMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.isFixedLayout)
        XCTAssertEqual(metadata.title, "Old Book")
    }

    func testNilFlagEncodesWithoutTheKey() throws {
        // Synthesized Codable omits nil optionals, so reflowable books keep
        // writing byte-identical metadata to what pre-FXL builds wrote.
        let metadata = BookMetadata(title: "Reflow")
        let raw = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(raw.contains("isFixedLayout"))
    }

    func testFixedLayoutFlagRoundTripsThroughCodable() throws {
        let book = Book(
            metadata: BookMetadata(title: "FXL", isFixedLayout: true),
            chapters: [Chapter(title: "One", order: 0, text: "hello")],
            estimatedTokenCount: 2
        )
        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded.metadata.isFixedLayout, true)
    }
}
