import XCTest
@testable import ReadrKit

/// Collect a chunk stream's text deltas into a single string.
func collectStream(_ stream: AsyncThrowingStream<ChatChunk, Error>) async throws -> String {
    var result = ""
    for try await chunk in stream { result += chunk.textDelta }
    return result
}

final class SSEParserTests: XCTestCase {

    func testDataLineYieldsDataEvent() {
        XCTAssertEqual(SSEParser.parseLine(#"data: {"x":1}"#), .data(#"{"x":1}"#))
    }

    func testDoneSentinelYieldsDone() {
        XCTAssertEqual(SSEParser.parseLine("data: [DONE]"), .done)
    }

    func testBlankLineIsIgnored() {
        XCTAssertNil(SSEParser.parseLine(""))
        XCTAssertNil(SSEParser.parseLine("   "))
    }

    func testCommentLineIsIgnored() {
        XCTAssertNil(SSEParser.parseLine(": this is a comment"))
    }

    func testDataLineWithoutLeadingSpace() {
        XCTAssertEqual(SSEParser.parseLine("data:hi"), .data("hi"))
    }

    func testNonDataFieldIsIgnored() {
        XCTAssertNil(SSEParser.parseLine("event: message"))
    }

    func testDataOverloadFromData() {
        let line = Data(#"data: {"x":1}"#.utf8)
        XCTAssertEqual(SSEParser.parseLine(line), .data(#"{"x":1}"#))
    }
}
