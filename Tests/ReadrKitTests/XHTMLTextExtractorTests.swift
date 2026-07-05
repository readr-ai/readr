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

    // MARK: - Inline images

    func testTextAndImagesReplacesImgWithPlaceholderInOrder() {
        let html = """
        <html><body><p>Before.</p><img src="images/fig1.jpg" alt="Figure 1"/>\
        <p>Between.</p><img src='pic2.png'><p>After.</p></body></html>
        """
        let (text, images) = XHTMLTextExtractor.textAndImages(from: html)

        XCTAssertEqual(images, [
            .init(src: "images/fig1.jpg", alt: "Figure 1"),
            .init(src: "pic2.png", alt: nil),
        ])
        XCTAssertEqual(text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 2)
        // Placeholders sit between the surrounding prose, in order.
        let first = text.firstIndex(of: XHTMLTextExtractor.imagePlaceholder)!
        XCTAssertTrue(text[..<first].contains("Before."))
        XCTAssertFalse(text[..<first].contains("Between."))
    }

    func testImgWithoutSrcIsIgnored() {
        let (text, images) = XHTMLTextExtractor.textAndImages(from: "<p>x</p><img alt=\"no src\"><p>y</p>")
        XCTAssertTrue(images.isEmpty)
        XCTAssertFalse(text.contains(XHTMLTextExtractor.imagePlaceholder))
    }

    func testPlainTextPathStillStripsImages() {
        let text = XHTMLTextExtractor.text(from: "<p>a</p><img src=\"x.png\"><p>b</p>")
        XCTAssertFalse(text.contains(XHTMLTextExtractor.imagePlaceholder))
        XCTAssertEqual(text, "a\nb")
    }
}
