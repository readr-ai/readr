import XCTest
@testable import ReadrKit

final class XHTMLTextExtractorTests: XCTestCase {

    func testStripsTagsAndKeepsParagraphBreaks() {
        let html = "<html><body><p>First para.</p><p>Second para.</p></body></html>"
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "First para.\nSecond para.")
    }

    func testRemovesScriptAndStyle() {
        let html = """
        <html><head><style>.a{color:red}</style></head>
        <body><script>alert(1)</script><p>Visible.</p></body></html>
        """
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "Visible.")
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color"))
    }

    func testDecodesEntities() {
        let html = "<p>Tom &amp; Jerry &#39;hi&#39; &#x41; &mdash; end&nbsp;here</p>"
        let text = XHTMLTextExtractor.text(from: html)
        XCTAssertEqual(text, "Tom & Jerry 'hi' A — end here")
    }

    func testFirstHeadingExtraction() {
        let html = "<body><h2>Chapter <em>Two</em></h2><p>body</p></body>"
        XCTAssertEqual(XHTMLTextExtractor.firstHeading(from: html), "Chapter Two")
    }

    func testNoHeadingReturnsNil() {
        XCTAssertNil(XHTMLTextExtractor.firstHeading(from: "<p>no heading</p>"))
    }
}
