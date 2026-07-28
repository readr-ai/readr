import XCTest
import SwiftUI
import AppKit
import ReadrKit
@testable import Readr

/// Facing pages of a spread must share ONE text rectangle.
///
/// The kicker band used to be reserved only on the spread's first page, so
/// the facing page got a taller column that started a full band higher and
/// ended on a different line grid — visibly mismatched "page heights" on
/// every spread of every book (user-reported). Every page now reserves a
/// fixed-height kicker slot whether or not it draws the title, so body text
/// on both pages starts at the identical y and, for full pages of uniform
/// body text, ends on the identical grid row.
///
/// These tests render the REAL spread and read the ink, because the defect
/// class is precisely "the numbers said aligned, the pixels disagreed".
final class FacingPageAlignmentTests: XCTestCase {
    private let canvas = CGSize(width: 1150, height: 780)

    /// Enough uniform body text that the first spread's pages are both full.
    private var chapter: Chapter {
        Chapter(
            title: "Chapter Six",
            order: 0,
            text: String(
                repeating: "The quick brown fox jumps over the lazy dog near the riverbank at dawn. ",
                count: 400
            )
        )
    }

    private func renderSpread() throws -> NSBitmapImageRep {
        let view = PagedChapterView(
            chapter: chapter,
            layout: .doublePage,
            style: ReaderStyle(theme: .paper, fontSize: 18),
            highlights: [],
            anchorOffset: .constant(0)
        )
        .background(ReadingTheme.paper.background)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func isInk(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * color.redComponent
            + 0.587 * color.greenComponent
            + 0.114 * color.blueComponent
        return luminance < 0.5
    }

    /// First and last ink rows within a horizontal band, scanning rows from
    /// `fromRow` (so the kicker text can be excluded when finding body top).
    private func inkRows(
        _ rep: NSBitmapImageRep, xRange: Range<Int>, fromRow: Int
    ) -> (top: Int, bottom: Int)? {
        var top: Int?
        var bottom: Int?
        for y in fromRow..<rep.pixelsHigh {
            var rowHasInk = false
            for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 3) where isInk(rep, x: x, y: y) {
                rowHasInk = true
                break
            }
            if rowHasInk {
                if top == nil { top = y }
                bottom = y
            }
        }
        guard let top, let bottom else { return nil }
        return (top, bottom)
    }

    func testFacingPagesShareOneTextRectangle() throws {
        let rep = try renderSpread()
        let w = rep.pixelsWide
        let scale = CGFloat(w) / canvas.width

        // The kicker slot ends 80pt from the top (44pt inset + 36pt band);
        // start the body scan just above that so a body that wrongly starts
        // HIGHER is still seen, while the left page's kicker text (which sits
        // well above) is excluded.
        let bodyScanFrom = Int((44 + 36 - 6) * scale)

        let left = try XCTUnwrap(
            inkRows(rep, xRange: (w / 10)..<(w * 45 / 100), fromRow: bodyScanFrom),
            "Left page should contain body text"
        )
        let right = try XCTUnwrap(
            inkRows(rep, xRange: (w * 55 / 100)..<(w * 9 / 10), fromRow: bodyScanFrom),
            "Right page should contain body text"
        )

        // Same first baseline: the band that used to be missing on the right
        // page is a 36pt (72px at 2×) offset — tolerance 4px is far below it.
        XCTAssertEqual(
            left.top, right.top,
            accuracy: 4,
            "Facing pages' body text must start at the same y (left \(left.top), right \(right.top))"
        )
        // Same last grid row: uniform text in equal containers fits the same
        // line count, so full facing pages bottom out together.
        XCTAssertEqual(
            left.bottom, right.bottom,
            accuracy: 4,
            "Full facing pages must end on the same grid row (left \(left.bottom), right \(right.bottom))"
        )
    }

    /// The kicker itself still renders — reserving the slot everywhere must
    /// not have blanked the title on the spread's first page. The kicker is
    /// set in the theme's FAINT gray, well above the body-ink luminance
    /// threshold, so detect it as "differs from the paper background" rather
    /// than as ink.
    func testKickerStillRendersOnTheSpreadsFirstPage() throws {
        let rep = try renderSpread()
        let w = rep.pixelsWide
        let scale = CGFloat(w) / canvas.width
        let background = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))

        let bodyTop = Int((44 + 36 - 6) * scale)
        var found = false
        for y in Int(30 * scale)..<bodyTop where !found {
            for x in stride(from: w / 12, to: w * 45 / 100, by: 3) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.redComponent - background.redComponent) > 0.08
                    || abs(pixel.greenComponent - background.greenComponent) > 0.08
                    || abs(pixel.blueComponent - background.blueComponent) > 0.08 {
                    found = true
                    break
                }
            }
        }
        XCTAssertTrue(
            found,
            "The chapter kicker should draw above the body on the spread's first page"
        )
    }
}

private func XCTAssertEqual(
    _ lhs: Int, _ rhs: Int, accuracy: Int,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        abs(lhs - rhs), accuracy, message(), file: file, line: line
    )
}
