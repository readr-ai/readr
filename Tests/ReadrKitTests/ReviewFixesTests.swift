import XCTest
@testable import ReadrKit

/// Regression tests for issues found in code review of the M1/M2 PR.
final class ReviewFixesTests: XCTestCase {

    // MARK: Anthropic — system prompt preserved alongside cached prefix

    func testAnthropicKeepsSystemMessageWithCachePrefix() throws {
        let request = ChatRequest(
            messages: [
                .init(role: .system, content: "You are a reading companion."),
                .init(role: .user, content: "What happens?"),
            ],
            cacheableSystemPrefix: "THE WHOLE BOOK",
            maxOutputTokens: 100
        )
        let data = try AnthropicProvider.encodeBody(request, model: "claude-opus-4-8")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])

        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["text"] as? String, "You are a reading companion.")
        XCTAssertEqual(system[1]["text"] as? String, "THE WHOLE BOOK")
        XCTAssertNotNil(system[1]["cache_control"], "the large prefix carries the cache breakpoint")
        XCTAssertNil(system[0]["cache_control"])
    }

    // MARK: XHTML — `&amp;` decoded last

    func testEscapedEntityIsNotDoubleDecoded() {
        // `&amp;lt;` is the escaped form of the literal text `&lt;`.
        let text = XHTMLTextExtractor.text(from: "<p>Tom &amp;lt; Jerry</p>")
        XCTAssertEqual(text, "Tom &lt; Jerry")
    }

    // MARK: EPUB — percent-encoded hrefs resolve to real entry names

    func testHrefPercentDecoding() {
        XCTAssertEqual(
            EPUBBookParser.resolve(base: "OEBPS", href: "text/chapter%201.xhtml"),
            "OEBPS/text/chapter 1.xhtml"
        )
    }

    // MARK: EPUB — Dublin Core metadata with a non-`dc:` prefix

    func testMetadataWithAlternateDCPrefix() throws {
        let container = InMemoryEPUBContainer(textEntries: [
            "META-INF/container.xml": """
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """,
            "content.opf": """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata>
                <dcns:title xmlns:dcns="http://purl.org/dc/elements/1.1/">Aliased Title</dcns:title>
                <dcns:creator xmlns:dcns="http://purl.org/dc/elements/1.1/">A. Writer</dcns:creator>
              </metadata>
              <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="c1"/></spine>
            </package>
            """,
            "c1.xhtml": "<html><body><p>Body text here.</p></body></html>",
        ])
        let book = try EPUBBookParser().parse(container: container, fallbackTitle: "fallback")
        XCTAssertEqual(book.metadata.title, "Aliased Title")
        XCTAssertEqual(book.metadata.authors, ["A. Writer"])
    }

    // MARK: FileLibraryStore — corrupt file is preserved, not overwritten

    func testCorruptLibraryFileIsBackedUpNotDestroyed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        try Data("this is not valid json".utf8).write(to: url)

        let store = FileLibraryStore(fileURL: url)
        XCTAssertTrue(store.allBooks().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
            "the unreadable file should be set aside, not silently dropped"
        )
    }

    // MARK: OAuth — provider error surfaces correctly

    func testCallbackAccessDeniedMapsToUserCancelled() {
        let client = OAuthClient(config: .openAI)
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?error=access_denied&state=s")!
        XCTAssertThrowsError(try client.handleCallback(url: url, expectedState: "s")) {
            XCTAssertEqual($0 as? AuthError, .userCancelled)
        }
    }

    func testCallbackOtherErrorSurfacesDescription() {
        let client = OAuthClient(config: .openAI)
        let url = URL(string: "http://127.0.0.1:1455/auth/callback?error=server_error&error_description=Boom&state=s")!
        XCTAssertThrowsError(try client.handleCallback(url: url, expectedState: "s")) {
            XCTAssertEqual($0 as? AuthError, .tokenExchangeFailed("Boom"))
        }
    }
}
