import XCTest
@testable import ReadrKit

/// Model answers arrive as Markdown. Rendering them as a plain string showed
/// the punctuation instead of the formatting — `**the words you use**` and
/// `> "What is a depressed mood, exactly?"` reached the reader verbatim
/// (user-reported, from the Ask panel).
///
/// These pin the block structure the renderer needs. Inline runs are
/// deliberately left in the strings for the platform's own Markdown parser.
final class AnswerMarkdownTests: XCTestCase {

    private func blocks(_ markdown: String) -> [AnswerBlock] {
        AnswerMarkdown.blocks(from: markdown)
    }

    // MARK: - Paragraphs

    func testBlankLineSeparatesParagraphs() {
        XCTAssertEqual(
            blocks("First paragraph.\n\nSecond paragraph."),
            [.paragraph("First paragraph."), .paragraph("Second paragraph.")]
        )
    }

    /// A soft-wrapped source line is one paragraph, not two.
    func testSoftWrappedLinesJoinIntoOneParagraph() {
        XCTAssertEqual(
            blocks("The meaning is that\nthose are not the same experience."),
            [.paragraph("The meaning is that those are not the same experience.")]
        )
    }

    /// Inline markers survive untouched — the view hands them to
    /// `AttributedString(markdown:)`.
    func testInlineMarkupIsLeftInTheText() {
        XCTAssertEqual(
            blocks("This is **bold** and *italic* and `code`."),
            [.paragraph("This is **bold** and *italic* and `code`.")]
        )
    }

    func testRunsOfBlankLinesCollapse() {
        XCTAssertEqual(
            blocks("One.\n\n\n\nTwo."),
            [.paragraph("One."), .paragraph("Two.")]
        )
    }

    func testEmptyAnswerHasNoBlocks() {
        XCTAssertEqual(blocks(""), [])
        XCTAssertEqual(blocks("   \n\n  \n"), [])
    }

    // MARK: - Headings

    func testHeadingLevels() {
        XCTAssertEqual(
            blocks("# One\n## Two\n###### Six"),
            [
                .heading(level: 1, text: "One"),
                .heading(level: 2, text: "Two"),
                .heading(level: 6, text: "Six"),
            ]
        )
    }

    func testClosingHashesAreTrimmed() {
        XCTAssertEqual(blocks("## Themes ##"), [.heading(level: 2, text: "Themes")])
    }

    /// Seven hashes is not a heading, and a hash with no space is a word.
    func testNonHeadings() {
        XCTAssertEqual(blocks("####### Seven"), [.paragraph("####### Seven")])
        XCTAssertEqual(blocks("#hashtag"), [.paragraph("#hashtag")])
    }

    // MARK: - Quotes

    func testQuotedLinesBecomeOneQuoteBlock() {
        XCTAssertEqual(
            blocks("> What is a depressed mood, exactly?\n> Sadness? Emptiness?"),
            [.quote(["What is a depressed mood, exactly? Sadness? Emptiness?"])]
        )
    }

    /// A bare `>` separates paragraphs inside the same quote.
    func testBareMarkerSplitsQuoteParagraphs() {
        XCTAssertEqual(
            blocks("> First.\n>\n> Second."),
            [.quote(["First.", "Second."])]
        )
    }

    func testQuoteEndsAtTheNextOrdinaryLine() {
        XCTAssertEqual(
            blocks("> Quoted.\nBack to body."),
            [.quote(["Quoted."]), .paragraph("Back to body.")]
        )
    }

    func testNestedQuoteMarkersReadAsOneQuote() {
        XCTAssertEqual(blocks(">> Deep."), [.quote(["Deep."])])
    }

    func testQuoteWithoutASpaceAfterTheMarker() {
        XCTAssertEqual(blocks(">Tight."), [.quote(["Tight."])])
    }

    // MARK: - Lists

    func testBulletList() {
        XCTAssertEqual(
            blocks("- One\n* Two\n+ Three"),
            [.list(ordered: false, items: [
                .init(marker: "\u{2022}", text: "One"),
                .init(marker: "\u{2022}", text: "Two"),
                .init(marker: "\u{2022}", text: "Three"),
            ])]
        )
    }

    func testOrderedListKeepsItsNumbers() {
        XCTAssertEqual(
            blocks("1. First\n2. Second\n3) Third"),
            [.list(ordered: true, items: [
                .init(marker: "1.", text: "First"),
                .init(marker: "2.", text: "Second"),
                .init(marker: "3.", text: "Third"),
            ])]
        )
    }

    /// Switching marker style starts a new list rather than mixing them.
    func testBulletsAndNumbersFormSeparateLists() {
        XCTAssertEqual(
            blocks("- One\n1. Two"),
            [
                .list(ordered: false, items: [.init(marker: "\u{2022}", text: "One")]),
                .list(ordered: true, items: [.init(marker: "1.", text: "Two")]),
            ]
        )
    }

    func testIndentedLineContinuesTheItemAboveIt() {
        XCTAssertEqual(
            blocks("- One that wraps\n  onto a second line\n- Two"),
            [.list(ordered: false, items: [
                .init(marker: "\u{2022}", text: "One that wraps onto a second line"),
                .init(marker: "\u{2022}", text: "Two"),
            ])]
        )
    }

    func testListEndsAtTheNextParagraph() {
        XCTAssertEqual(
            blocks("- One\nPlain line."),
            [
                .list(ordered: false, items: [.init(marker: "\u{2022}", text: "One")]),
                .paragraph("Plain line."),
            ]
        )
    }

    /// Emphasis at the start of a line is not a bullet.
    func testBoldLeadIsNotABullet() {
        XCTAssertEqual(
            blocks("**Bold lead** and the rest."),
            [.paragraph("**Bold lead** and the rest.")]
        )
    }

    // MARK: - Rules

    func testThematicBreaks() {
        XCTAssertEqual(blocks("a\n\n---\n\nb"), [.paragraph("a"), .rule, .paragraph("b")])
        XCTAssertEqual(blocks("***"), [.rule])
        XCTAssertEqual(blocks("___"), [.rule])
    }

    func testTwoDashesIsNotARule() {
        XCTAssertEqual(blocks("--"), [.paragraph("--")])
    }

    // MARK: - Code

    func testFencedCodeIsVerbatim() {
        XCTAssertEqual(
            blocks("```swift\nlet x = 1\n# not a heading\n```"),
            [.code(language: "swift", text: "let x = 1\n# not a heading")]
        )
    }

    func testFenceWithoutALanguage() {
        XCTAssertEqual(blocks("```\nplain\n```"), [.code(language: nil, text: "plain")])
    }

    func testTildeFence() {
        XCTAssertEqual(blocks("~~~\nplain\n~~~"), [.code(language: nil, text: "plain")])
    }

    // MARK: - Partial input (the streaming case)

    /// The parser runs on every streamed token, so half-written structures
    /// must render as their best guess instead of vanishing.
    func testUnterminatedFenceStillRendersAsCode() {
        XCTAssertEqual(
            blocks("```swift\nlet x = 1"),
            [.code(language: "swift", text: "let x = 1")]
        )
    }

    func testTrailingPartialLineIsStillAParagraph() {
        XCTAssertEqual(
            blocks("Complete.\n\nStill arri"),
            [.paragraph("Complete."), .paragraph("Still arri")]
        )
    }

    func testUnclosedListAndQuoteStillRender() {
        XCTAssertEqual(
            blocks("- One\n- Tw"),
            [.list(ordered: false, items: [
                .init(marker: "\u{2022}", text: "One"),
                .init(marker: "\u{2022}", text: "Tw"),
            ])]
        )
        XCTAssertEqual(blocks("> partial quo"), [.quote(["partial quo"])])
    }

    /// An empty fence contributes nothing rather than an empty code box.
    func testEmptyFenceIsDropped() {
        XCTAssertEqual(blocks("```\n```"), [])
    }

    // MARK: - The reported answer, end to end

    func testTheReportedAnswerParsesIntoItsBlocks() {
        let answer = """
        This passage is saying that **the words you use for your feelings matter**.

        Dr Julie Smith's point is that broad labels become vague. She asks:

        > "What is a depressed mood, exactly? Sadness? Emptiness?"

        The book explains that:

        - Naming the feeling narrows it
        - Narrowing it makes it easier to respond to
        """

        XCTAssertEqual(blocks(answer), [
            .paragraph("This passage is saying that **the words you use for your feelings matter**."),
            .paragraph("Dr Julie Smith's point is that broad labels become vague. She asks:"),
            .quote(["\"What is a depressed mood, exactly? Sadness? Emptiness?\""]),
            .paragraph("The book explains that:"),
            .list(ordered: false, items: [
                .init(marker: "\u{2022}", text: "Naming the feeling narrows it"),
                .init(marker: "\u{2022}", text: "Narrowing it makes it easier to respond to"),
            ]),
        ])
    }
}
