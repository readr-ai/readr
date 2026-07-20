import XCTest
import AppKit
import ReadrKit
@testable import Readr

/// Pins the reader's Apple-Books-style typography contract: comfortable
/// book leading (not the airy 1.7× the beta shipped with), justified +
/// hyphenated body text by default, a curated device-font list, and inline
/// images that fit the column and page instead of clipping at a fixed cap.
@MainActor
final class ReaderTypographyTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultLeadingIsBookComfortableAndScalesWithFontSize() {
        var style = ReaderStyle()
        // Normal preset: extra leading well under the old 0.52 em — the
        // glyph box (~1.2 em) plus this lands near Apple Books' ~1.4×.
        XCTAssertEqual(style.spacing, .normal)
        XCTAssertLessThanOrEqual(style.lineSpacing / style.fontSize, 0.30)
        XCTAssertGreaterThanOrEqual(style.lineSpacing / style.fontSize, 0.15)
        // Ratios hold at any text size (the "doesn't get better when I
        // change the size" complaint).
        let ratio = style.lineSpacing / style.fontSize
        style.fontSize = 26
        XCTAssertEqual(style.lineSpacing / style.fontSize, ratio, accuracy: 0.001)
        // The presets are ordered and distinct.
        XCTAssertLessThan(
            ReaderLineSpacing.compact.multiplier, ReaderLineSpacing.normal.multiplier
        )
        XCTAssertLessThan(
            ReaderLineSpacing.normal.multiplier, ReaderLineSpacing.relaxed.multiplier
        )
    }

    func testDefaultParagraphSpacingIsModest() {
        let style = ReaderStyle()
        // Chapter text separates paragraphs with ONE newline; the rendered
        // gap must read as a book's paragraph break, not a blank line.
        XCTAssertLessThanOrEqual(style.paragraphSpacing / style.fontSize, 0.45)
        XCTAssertGreaterThan(style.paragraphSpacing, 0)
    }

    func testBodyTextIsJustifiedAndHyphenatedByDefault() throws {
        let attributed = TextRangeConvert.attributedString(
            "A paragraph long enough to wrap.", highlights: [], style: ReaderStyle()
        )
        let paragraph = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .justified)
        XCTAssertGreaterThan(
            paragraph.hyphenationFactor, 0,
            "Justification without hyphenation tears rivers into phone columns"
        )
        XCTAssertEqual(paragraph.paragraphSpacing, ReaderStyle().paragraphSpacing)
    }

    func testJustificationToggleProducesNaturalAlignment() throws {
        var style = ReaderStyle()
        style.isJustified = false
        let attributed = TextRangeConvert.attributedString(
            "Ragged right.", highlights: [], style: style
        )
        let paragraph = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertNotEqual(paragraph.alignment, .justified)
    }

    // MARK: - Fonts

    func testEveryReaderFontResolvesAtTheRequestedSize() {
        for font in ReaderFont.allCases {
            var style = ReaderStyle()
            style.font = font
            style.fontSize = 21
            let resolved = style.contentFont
            XCTAssertEqual(
                resolved.pointSize, 21,
                "\(font.displayName) must resolve at the requested size"
            )
        }
    }

    func testNamedFamiliesActuallyResolveToThemselves() {
        // The named faces ship with every macOS/iOS — a silent fallback to
        // the system font would make the picker a placebo.
        for (font, family) in [(ReaderFont.charter, "Charter"),
                               (.georgia, "Georgia"),
                               (.palatino, "Palatino")] {
            var style = ReaderStyle()
            style.font = font
            XCTAssertEqual(
                style.contentFont.familyName, family,
                "\(font.displayName) should resolve to the \(family) family"
            )
        }
    }

    // MARK: - Inline images fit the column and the page

    private func solidImage(width: CGFloat, height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemGray.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// Lays out `attributed` at `width` and returns the attachment's used
    /// bounds as TextKit resolved them.
    private func resolvedAttachmentSize(
        _ attributed: NSAttributedString, layoutWidth: CGFloat
    ) -> CGSize? {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var found: CGSize?
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let rect = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil
                ),
                in: container
            )
            found = attachment.attachmentBounds(
                for: container,
                proposedLineFragment: CGRect(x: 0, y: 0, width: layoutWidth, height: rect.height),
                glyphPosition: .zero, characterIndex: range.location
            ).size
        }
        return found
    }

    func testWideImageFitsTheColumnWidth() throws {
        let style = ReaderStyle()
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: style,
            inlineImages: [0: InlineImage(image: solidImage(width: 1200, height: 800))]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 320))
        XCTAssertLessThanOrEqual(size.width, 320.5, "A figure must never spill past the column")
        XCTAssertEqual(size.height / size.width, 800.0 / 1200.0, accuracy: 0.01)
    }

    func testTallImageRespectsThePageHeightCap() throws {
        var style = ReaderStyle()
        style.maxImageHeight = 400
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: style,
            inlineImages: [0: InlineImage(image: solidImage(width: 600, height: 2400))]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 320))
        XCTAssertLessThanOrEqual(size.height, 400.5, "A figure must never exceed a page")
        XCTAssertEqual(size.width / size.height, 600.0 / 2400.0, accuracy: 0.01)
    }

    func testSmallImageIsNeverUpscaled() throws {
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: ReaderStyle(),
            inlineImages: [0: InlineImage(image: solidImage(width: 80, height: 60))]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 320))
        XCTAssertEqual(size.width, 80, accuracy: 0.5)
        XCTAssertEqual(size.height, 60, accuracy: 0.5)
    }

    /// The live iOS UITextView lays out through TextKit 2, which asks the
    /// `location:`-based attachmentBounds — NOT the TextKit 1 method the
    /// paginator uses. Both overrides must apply the same fitting rule, or
    /// iOS renders native-size images while measurement assumed fitted ones.
    func testTextKit2LayoutPathAppliesTheSameFitting() throws {
        var style = ReaderStyle()
        style.maxImageHeight = 400
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: style,
            inlineImages: [0: InlineImage(image: solidImage(width: 1200, height: 900))]
        )
        let attachment = try XCTUnwrap(
            attributed.attribute(.attachment, at: 0, effectiveRange: nil)
                as? NSTextAttachment
        )
        let location = NSTextContentStorage().documentRange.location
        let bounds = attachment.attachmentBounds(
            for: [:], location: location, textContainer: nil,
            proposedLineFragment: CGRect(x: 0, y: 0, width: 320, height: 1000),
            position: .zero
        )
        XCTAssertLessThanOrEqual(bounds.width, 320.5, "TK2 must fit the column too")
        XCTAssertLessThanOrEqual(bounds.height, 400.5, "TK2 must honor the page cap too")
    }

    // MARK: - Declared image sizes (CSS px 1:1 points)

    /// A 2×-exported 40px icon (80px bitmap, `width="40"`) must render 40pt —
    /// the declared display size wins over the bitmap's native size.
    func testDeclaredWidthSizesTheImageBelowItsNativeSize() throws {
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: ReaderStyle(),
            inlineImages: [0: InlineImage(
                image: solidImage(width: 80, height: 80),
                displayWidth: 40, displayHeight: 40
            )]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 300))
        XCTAssertEqual(size.width, 40, accuracy: 0.5)
        XCTAssertEqual(size.height, 40, accuracy: 0.5)
    }

    /// A declared width wider than the column still clamps to the column,
    /// keeping the DECLARED aspect ratio.
    func testDeclaredWidthWiderThanTheColumnStillClamps() throws {
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: ReaderStyle(),
            inlineImages: [0: InlineImage(
                image: solidImage(width: 1000, height: 500),
                displayWidth: 500, displayHeight: 250
            )]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 300))
        XCTAssertEqual(size.width, 300, accuracy: 0.5, "declared > column must clamp")
        XCTAssertEqual(size.height, 150, accuracy: 0.5, "height follows the declared aspect")
    }

    /// A height-only declaration (`height="60"` with no width — common EPUB
    /// markup) still expresses a size intent: the width derives from it
    /// through the bitmap's aspect.
    func testDeclaredHeightAloneSizesTheImage() throws {
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: ReaderStyle(),
            inlineImages: [0: InlineImage(
                image: solidImage(width: 240, height: 120),
                displayHeight: 60
            )]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 300))
        XCTAssertEqual(size.width, 120, accuracy: 0.5, "width follows the bitmap aspect")
        XCTAssertEqual(size.height, 60, accuracy: 0.5)
    }

    /// The pagination regression behind the cap: an image taller than the
    /// page used to make `LayoutPaginator` bail to the estimate fallback.
    /// With the page-height cap the paginator must cover the chapter with
    /// real measured pages.
    func testPaginationSurvivesAnImageTallerThanThePage() {
        var style = ReaderStyle()
        style.maxImageHeight = 460 // page text height, as PagedChapterView sets it
        let text = "Before the figure.\n\u{FFFC}\nAfter the figure, more prose follows."
        let images = [19: InlineImage(image: solidImage(width: 800, height: 3000))]
        let paginator = LayoutPaginator(style: style, inlineImages: images)
        let pages = paginator.paginate(text) { _ in CGSize(width: 420, height: 540) }
        XCTAssertFalse(pages.isEmpty, "The capped figure must fit a measured page")
        XCTAssertEqual(pages.last?.range.upperBound, text.count, "Pages must cover the chapter")
    }

    // MARK: - Format spans (headings, emphasis, blockquotes, links)

    func testHeadingRunUsesLargerBoldFontWhileBodyKeepsContentFont() throws {
        let style = ReaderStyle()
        let text = "Title\nBody paragraph follows."
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style,
            formatSpans: [FormatSpan(start: 0, end: 5, kind: .heading(1))]
        )
        let heading = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(heading.pointSize, (style.fontSize * 1.6).rounded())
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.bold))
        // Headings breathe: extra paragraph spacing around the run.
        let headingParagraph = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertGreaterThan(headingParagraph.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(headingParagraph.paragraphSpacing, style.paragraphSpacing)
        // The body run keeps the plain content font and base paragraph style.
        let body = try XCTUnwrap(
            attributed.attribute(.font, at: 8, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(body.pointSize, style.fontSize)
        XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.bold))
        let bodyParagraph = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 8, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(bodyParagraph.paragraphSpacing, style.paragraphSpacing)
    }

    /// Bold + italic inside a heading: traits merge into the font already on
    /// the range, so emphasis inside a heading keeps the heading size.
    func testEmphasisTraitsMergeInsideAHeading() throws {
        let style = ReaderStyle()
        let text = "Big bold title"
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style,
            // Deliberately emitted out of application order — the renderer
            // must sort structure before trait merges.
            formatSpans: [
                FormatSpan(start: 4, end: 8, kind: .italic),
                FormatSpan(start: 0, end: text.count, kind: .heading(2)),
                FormatSpan(start: 4, end: 8, kind: .bold),
            ]
        )
        let merged = try XCTUnwrap(
            attributed.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(
            merged.pointSize, (style.fontSize * 1.35).rounded(),
            "Emphasis inside a heading must keep the heading size"
        )
        XCTAssertTrue(merged.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(merged.fontDescriptor.symbolicTraits.contains(.italic))
        // Outside the emphasis run the heading is bold but not italic.
        let plain = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testLinkRangeCarriesLinkAccentAndUnderline() throws {
        let style = ReaderStyle()
        let text = "See the appendix for more."
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style,
            formatSpans: [FormatSpan(
                start: 8, end: 16, kind: .link(.external(url: "https://example.com/a"))
            )]
        )
        let url = try XCTUnwrap(
            attributed.attribute(.link, at: 9, effectiveRange: nil) as? URL
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/a")
        let underline = try XCTUnwrap(
            attributed.attribute(.underlineStyle, at: 9, effectiveRange: nil) as? Int
        )
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
        let color = try XCTUnwrap(
            attributed.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
        )
        XCTAssertNotEqual(color, style.theme.ink, "Links render in the accent, not body ink")
        // Outside the range: plain body text, no link.
        XCTAssertNil(attributed.attribute(.link, at: 0, effectiveRange: nil))
    }

    /// Internal links encode as the custom jump scheme and decode back to the
    /// exact target (path + fragment survive percent-encoding).
    func testInternalLinkEncodesARoundTrippableJumpURL() throws {
        let target = LinkTarget.internalDoc(path: "OEBPS/text/ch 2.xhtml", fragment: "note-3")
        let text = "footnote"
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: ReaderStyle(),
            formatSpans: [FormatSpan(start: 0, end: text.count, kind: .link(target))]
        )
        let url = try XCTUnwrap(
            attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL
        )
        XCTAssertEqual(url.scheme, ReaderLinkURL.internalScheme)
        XCTAssertEqual(ReaderLinkURL.internalTarget(from: url), target)
        // External URLs are NOT internal jumps — they keep the default
        // open-in-browser interaction.
        XCTAssertNil(
            ReaderLinkURL.internalTarget(from: try XCTUnwrap(URL(string: "https://example.com")))
        )
    }

    func testBlockquoteIndentsAndMutes() throws {
        let style = ReaderStyle()
        let text = "He said:\nQuoted wisdom here.\nBack to prose."
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style,
            formatSpans: [FormatSpan(start: 9, end: 28, kind: .blockquote)]
        )
        let quote = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 10, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(quote.headIndent, style.fontSize * 1.5)
        XCTAssertEqual(quote.firstLineHeadIndent, style.fontSize * 1.5)
        let color = try XCTUnwrap(
            attributed.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor
        )
        XCTAssertNotEqual(color, style.theme.ink, "Blockquotes render in the muted ink")
        // Prose outside the quote keeps the un-indented base paragraph.
        let body = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(body.headIndent, 0)
    }

    /// Page slices pass spans shifted into slice coordinates — truncated runs
    /// can start negative or end past the slice. They must clamp (never trap)
    /// and still style the surviving run.
    func testSpansClampedToAPageSliceStyleTheRightRun() throws {
        let text = "Sliced page"
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: ReaderStyle(),
            formatSpans: [
                FormatSpan(start: -3, end: 6, kind: .bold),
                FormatSpan(start: 7, end: 400, kind: .italic),
                FormatSpan(start: 20, end: 30, kind: .heading(1)), // fully off-slice
            ]
        )
        let bold = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = try XCTUnwrap(
            attributed.attribute(.font, at: text.count - 1, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(italic.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
