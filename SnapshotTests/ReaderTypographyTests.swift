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
            inlineImages: [0: solidImage(width: 1200, height: 800)]
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
            inlineImages: [0: solidImage(width: 600, height: 2400)]
        )
        let size = try XCTUnwrap(resolvedAttachmentSize(attributed, layoutWidth: 320))
        XCTAssertLessThanOrEqual(size.height, 400.5, "A figure must never exceed a page")
        XCTAssertEqual(size.width / size.height, 600.0 / 2400.0, accuracy: 0.01)
    }

    func testSmallImageIsNeverUpscaled() throws {
        let attributed = TextRangeConvert.attributedString(
            "\u{FFFC}", highlights: [], style: ReaderStyle(),
            inlineImages: [0: solidImage(width: 80, height: 60)]
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
            inlineImages: [0: solidImage(width: 1200, height: 900)]
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

    /// The pagination regression behind the cap: an image taller than the
    /// page used to make `LayoutPaginator` bail to the estimate fallback.
    /// With the page-height cap the paginator must cover the chapter with
    /// real measured pages.
    func testPaginationSurvivesAnImageTallerThanThePage() {
        var style = ReaderStyle()
        style.maxImageHeight = 460 // page text height, as PagedChapterView sets it
        let text = "Before the figure.\n\u{FFFC}\nAfter the figure, more prose follows."
        let images = [19: solidImage(width: 800, height: 3000)]
        let paginator = LayoutPaginator(style: style, inlineImages: images)
        let pages = paginator.paginate(text) { _ in CGSize(width: 420, height: 540) }
        XCTAssertFalse(pages.isEmpty, "The capped figure must fit a measured page")
        XCTAssertEqual(pages.last?.range.upperBound, text.count, "Pages must cover the chapter")
    }
}
