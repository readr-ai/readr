import XCTest
import AppKit
@testable import Readr

/// Geometry rules for `ColumnFittingAttachment`.
///
/// The motivating bug: publishers declare a cover or volume title plate at the
/// bitmap's pixel size — the Hitchhiker title plate is a 300×413 JPEG with
/// `.calibre6 { height: 413px; width: 300px }` — and honoring that literally
/// rendered a postage stamp in an ~860pt column. Plates must scale UP to fill
/// the page; inline figures must NOT, or a small ornament would balloon.
final class PlateImageTests: XCTestCase {
    /// The real title plate's dimensions.
    private let plateSize = CGSize(width: 300, height: 413)
    private let column: CGFloat = 860
    private let pageHeight: CGFloat = 900

    private func attachment(
        imageSize: CGSize,
        declared: CGSize?,
        maxHeight: CGFloat?,
        scalesToFill: Bool
    ) -> ColumnFittingAttachment {
        let attachment = ColumnFittingAttachment()
        attachment.image = NSImage(size: imageSize)
        attachment.declaredWidth = declared?.width
        attachment.declaredHeight = declared?.height
        attachment.maxHeight = maxHeight
        attachment.scalesToFill = scalesToFill
        return attachment
    }

    private func bounds(_ attachment: ColumnFittingAttachment, width: CGFloat) -> CGRect {
        attachment.attachmentBounds(
            for: nil,
            proposedLineFragment: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude),
            glyphPosition: .zero,
            characterIndex: 0
        )
    }

    // MARK: - Plate scaling

    func testPlateScalesUpToFillThePage() {
        let plate = attachment(
            imageSize: plateSize, declared: plateSize,
            maxHeight: pageHeight, scalesToFill: true
        )
        let rect = bounds(plate, width: column)

        XCTAssertGreaterThan(
            rect.width, plateSize.width,
            "A plate must scale past its declared 300pt, not render as a stamp"
        )
        // 860 wide would be 1184 tall, so the page-height cap binds first.
        XCTAssertEqual(rect.height, pageHeight, accuracy: 0.5)
        XCTAssertEqual(
            rect.width / rect.height, plateSize.width / plateSize.height, accuracy: 0.01,
            "Scaling must preserve the plate's aspect ratio"
        )
    }

    /// A plate wider than it is tall fills the column, with the height cap slack.
    func testWidePlateFillsTheColumnWidth() {
        let wide = CGSize(width: 1200, height: 400)
        let plate = attachment(
            imageSize: wide, declared: wide, maxHeight: pageHeight, scalesToFill: true
        )
        let rect = bounds(plate, width: column)

        XCTAssertEqual(rect.width, column, accuracy: 0.5)
        XCTAssertEqual(rect.height, column * (400.0 / 1200.0), accuracy: 0.5)
    }

    /// Upscaling must not overflow the page in either axis — that would break
    /// `LayoutPaginator`, which bails to the estimate paginator when an
    /// attachment is taller than a page.
    func testPlateNeverExceedsThePage() {
        for size in [CGSize(width: 300, height: 413),
                     CGSize(width: 50, height: 50),
                     CGSize(width: 2000, height: 100)] {
            let plate = attachment(
                imageSize: size, declared: size, maxHeight: pageHeight, scalesToFill: true
            )
            let rect = bounds(plate, width: column)
            XCTAssertLessThanOrEqual(rect.width, column + 0.5, "\(size) overflowed the column")
            XCTAssertLessThanOrEqual(rect.height, pageHeight + 0.5, "\(size) overflowed the page")
        }
    }

    // MARK: - Inline figures keep the no-upscale rule

    /// The regression this fix must not cause: a small ornament or icon inside
    /// a text chapter keeps its declared size.
    func testInlineFigureIsNotUpscaled() {
        let icon = CGSize(width: 40, height: 40)
        let inline = attachment(
            imageSize: CGSize(width: 80, height: 80), // exported at 2×
            declared: icon, maxHeight: pageHeight, scalesToFill: false
        )
        let rect = bounds(inline, width: column)

        XCTAssertEqual(
            rect.width, 40, accuracy: 0.5,
            "A declared 40pt icon must stay 40pt — the declared size wins over the 2× bitmap"
        )
    }

    /// The same plate bitmap, rendered as ordinary chapter content, keeps the
    /// publisher's declared size. This is the exact pair that distinguishes the
    /// two code paths.
    func testSameImageStaysSmallWhenNotAPlate() {
        let inline = attachment(
            imageSize: plateSize, declared: plateSize,
            maxHeight: pageHeight, scalesToFill: false
        )
        XCTAssertEqual(bounds(inline, width: column).width, plateSize.width, accuracy: 0.5)
    }

    /// An oversized figure is still clamped DOWN when it is not a plate.
    func testInlineFigureWiderThanTheColumnIsClamped() {
        let huge = CGSize(width: 2000, height: 1000)
        let inline = attachment(
            imageSize: huge, declared: huge, maxHeight: pageHeight, scalesToFill: false
        )
        let rect = bounds(inline, width: column)

        XCTAssertEqual(rect.width, column, accuracy: 0.5)
        XCTAssertEqual(rect.height, column / 2, accuracy: 0.5)
    }
}
