import XCTest
@testable import ReadrKit

/// J1 — registry dispatch, DRM rejection, and unsupported formats.
final class BookParserRegistryTests: XCTestCase {

    func testUnsupportedFormatThrows() async {
        let registry = BookParserRegistry.standard // plain-text only
        do {
            _ = try await registry.parse(URL(fileURLWithPath: "/x/book.epub"))
            XCTFail("expected unsupportedFormat")
        } catch BookParserError.unsupportedFormat {
            // expected
        } catch {
            XCTFail("expected .unsupportedFormat, got \(error)")
        }
    }

    func testDRMProtectedIsRejectedAndNothingImported() async {
        let registry = BookParserRegistry(parsers: [DRMSignalingParser()])
        do {
            _ = try await registry.parse(URL(fileURLWithPath: "/x/secured.epub"))
            XCTFail("expected drmProtected")
        } catch BookParserError.drmProtected {
            // expected — the importer surfaces this and adds nothing.
        } catch {
            XCTFail("expected .drmProtected, got \(error)")
        }
    }
}

/// Stands in for the Readium parser when it encounters a DRM-protected file.
private struct DRMSignalingParser: BookParser {
    func canParse(_ url: URL) -> Bool { url.pathExtension.lowercased() == "epub" }
    func parse(_ url: URL) async throws -> Book { throw BookParserError.drmProtected }
}
