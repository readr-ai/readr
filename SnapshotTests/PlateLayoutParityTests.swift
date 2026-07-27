import XCTest
import SwiftUI
import AppKit
import ReadrKit
@testable import Readr

/// A plate must look the same whichever layout the reader is in.
///
/// `platePresentation` was originally set only in `PagedChapterView`, so a
/// cover filled the page in Page/Spread but rendered at the publisher's
/// declared pixel size in Scroll — switching layout visibly shrank the
/// artwork. These tests pin the parity by rendering the real surfaces
/// offscreen and sampling the bitmap.
final class PlateLayoutParityTests: XCTestCase {
    /// The Hitchhiker title plate's real proportions, as a solid fill so it can
    /// be told from the page background by colour alone.
    private func plateImage(
        width: CGFloat = 300, height: CGFloat = 413
    ) -> NSImage {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    /// A chapter that is nothing but the image placeholder.
    private var plateChapter: Chapter {
        Chapter(title: "Cover", order: 0, text: "\u{FFFC}")
    }

    /// The same image inside real prose — an inline figure, not a plate.
    private var figureChapter: Chapter {
        Chapter(
            title: "Chapter One",
            order: 0,
            text: "Before the figure.\n\u{FFFC}\nAfter the figure."
        )
    }

    private func render(_ view: some View, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Widest run of red pixels on any sampled row, as a fraction of width.
    private func redWidthFraction(_ rep: NSBitmapImageRep) -> CGFloat {
        var widest = 0
        for row in stride(from: rep.pixelsHigh / 4, to: rep.pixelsHigh * 3 / 4, by: 8) {
            var run = 0
            for column in 0..<rep.pixelsWide {
                let pixel = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                let isRed = (pixel?.redComponent ?? 0) > 0.5
                    && (pixel?.greenComponent ?? 1) < 0.4
                    && (pixel?.blueComponent ?? 1) < 0.4
                run = isRed ? run + 1 : run
                widest = max(widest, run)
            }
        }
        return CGFloat(widest) / CGFloat(rep.pixelsWide)
    }

    private let size = CGSize(width: 900, height: 700)

    // MARK: - Parity

    func testPlateFillsTheColumnInScrollLayout() throws {
        let view = ScrollReadingColumn(
            chapter: plateChapter,
            style: ReaderStyle(theme: .paper, fontSize: 18),
            highlights: [],
            inlineImages: [0: InlineImage(image: plateImage(), displayWidth: 300, displayHeight: 413)]
        )
        let rep = try XCTUnwrap(render(view.background(ReadingTheme.paper.background), size: size))

        XCTAssertGreaterThan(
            redWidthFraction(rep), 0.5,
            "A plate must scale to the scroll column, not sit at its declared 300pt"
        )
    }

    func testPlateFillsThePageInPagedLayout() throws {
        let view = PagedChapterView(
            chapter: plateChapter,
            layout: .singlePage,
            style: ReaderStyle(theme: .paper, fontSize: 18),
            highlights: [],
            inlineImages: [0: InlineImage(image: plateImage(), displayWidth: 300, displayHeight: 413)],
            anchorOffset: .constant(0)
        )
        // A page-shaped canvas: in a short, wide window the page-height cap
        // binds first and a portrait plate is legitimately narrower than half
        // the width, which says nothing about whether it scaled.
        let rep = try XCTUnwrap(
            render(view.background(ReadingTheme.paper.background),
                   size: CGSize(width: 900, height: 1200))
        )

        XCTAssertGreaterThan(
            redWidthFraction(rep), 0.5,
            "A plate must scale to the page in paged layout"
        )
    }

    // MARK: - The distinction the fix depends on

    /// The regression guard: an image inside prose keeps its declared size in
    /// scroll layout, so an ornament cannot balloon to the full column.
    func testInlineFigureStaysSmallInScrollLayout() throws {
        let view = ScrollReadingColumn(
            chapter: figureChapter,
            style: ReaderStyle(theme: .paper, fontSize: 18),
            highlights: [],
            inlineImages: [
                19: InlineImage(image: plateImage(width: 60, height: 60), displayWidth: 60, displayHeight: 60)
            ]
        )
        let rep = try XCTUnwrap(render(view.background(ReadingTheme.paper.background), size: size))

        XCTAssertLessThan(
            redWidthFraction(rep), 0.3,
            "An inline figure must keep its declared size — only whole-chapter plates scale up"
        )
    }
}
