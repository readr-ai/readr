import XCTest
@testable import ReadrKit

/// A citation says where in the book it points, and keeps decoding from
/// transcripts written before it could.
final class CitationTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        let citation = Citation(
            locator: "Ch. 4 ¶12",
            quotedText: "Off with their heads!",
            chapterIndex: 3,
            characterOffset: 8_412
        )

        let data = try JSONEncoder().encode(citation)
        XCTAssertEqual(try JSONDecoder().decode(Citation.self, from: data), citation)
    }

    /// Conversations persisted before the indices existed carry two fields.
    /// They must still decode — as a citation that names a place in words
    /// without pointing at one.
    func testLegacyJSONWithoutTheIndicesStillDecodes() throws {
        let legacy = #"{"locator":"Ch. 4 ¶12","quotedText":"Off with their heads!"}"#

        let citation = try JSONDecoder().decode(Citation.self, from: Data(legacy.utf8))

        XCTAssertEqual(citation.locator, "Ch. 4 ¶12")
        XCTAssertEqual(citation.quotedText, "Off with their heads!")
        XCTAssertNil(citation.chapterIndex)
        XCTAssertNil(citation.characterOffset)
    }

    /// The memberwise init defaults them, so every existing call site keeps
    /// compiling and says nothing it doesn't know.
    func testTheIndicesDefaultToNil() {
        let citation = Citation(locator: "Ch. 1", quotedText: "…")
        XCTAssertNil(citation.chapterIndex)
        XCTAssertNil(citation.characterOffset)
    }
}
