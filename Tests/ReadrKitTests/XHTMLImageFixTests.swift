import XCTest
@testable import ReadrKit

/// Regression tests for two inline-image defects:
/// 1. `<img>` inside a stripped `<script>`/`<style>`/`<head>` block used to
///    emit a ref without a surviving placeholder, desyncing the k-th
///    placeholder from `images[k]`.
/// 2. `attribute("src", ...)` used to match the tail of `data-src`.
final class XHTMLImageFixTests: XCTestCase {

    // MARK: - Placeholder/ref pairing

    func testImgInsideNonContentBlocksProducesNoPlaceholderAndNoRef() {
        let html = """
        <html><head><img src="head-cover.png"><style>.x{}</style></head><body>
        <script>document.write('<img src="tracker.gif">');</script>
        <p>Before.</p><img src="images/fig1.jpg" alt="Figure 1"/>\
        <p>Between.</p><img src="fig2.png"><p>After.</p>
        <style>p { color: red } /* <img src="style.png"> */</style>
        </body></html>
        """
        let (text, images) = XHTMLTextExtractor.textAndImages(from: html)

        // Only the two real figures survive — nothing from head/script/style.
        XCTAssertEqual(images, [
            .init(src: "images/fig1.jpg", alt: "Figure 1"),
            .init(src: "fig2.png", alt: nil),
        ])
        XCTAssertEqual(text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 2)

        // The k-th placeholder pairs with images[k]: the first placeholder
        // sits between "Before." and "Between.", the second after "Between.".
        let placeholders = text.indices.filter { text[$0] == XHTMLTextExtractor.imagePlaceholder }
        XCTAssertTrue(text[..<placeholders[0]].contains("Before."))
        XCTAssertFalse(text[..<placeholders[0]].contains("Between."))
        XCTAssertTrue(text[..<placeholders[1]].contains("Between."))
        XCTAssertFalse(text[..<placeholders[1]].contains("After."))
    }

    func testHeadOnlyImageYieldsCleanTextWithNoImages() {
        let html = "<html><head><img src=\"cover.png\"></head><body><p>Prose.</p></body></html>"
        let (text, images) = XHTMLTextExtractor.textAndImages(from: html)
        XCTAssertTrue(images.isEmpty)
        XCTAssertEqual(text, "Prose.")
    }

    // MARK: - src vs data-src

    func testSrcAttributeIsNotConfusedWithDataSrc() {
        let tag = "<img data-src=\"lazy.gif\" src=\"images/fig1.jpg\">"
        XCTAssertEqual(XHTMLTextExtractor.attribute("src", in: tag), "images/fig1.jpg")

        let (text, images) = XHTMLTextExtractor.textAndImages(from: "<p>a</p>\(tag)<p>b</p>")
        XCTAssertEqual(images, [.init(src: "images/fig1.jpg", alt: nil)])
        XCTAssertEqual(text.filter { $0 == XHTMLTextExtractor.imagePlaceholder }.count, 1)
    }

    func testImgWithOnlyDataSrcIsIgnoredEntirely() {
        let tag = "<img data-src=\"lazy.gif\">"
        XCTAssertNil(XHTMLTextExtractor.attribute("src", in: tag))

        let (text, images) = XHTMLTextExtractor.textAndImages(from: "<p>a</p>\(tag)<p>b</p>")
        XCTAssertTrue(images.isEmpty)
        XCTAssertFalse(text.contains(XHTMLTextExtractor.imagePlaceholder))
        XCTAssertEqual(text, "a\nb")
    }
}
