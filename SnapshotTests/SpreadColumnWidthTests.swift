import XCTest
import SwiftUI
import ReadrKit
@testable import Readr

/// Pins the spine arithmetic in `PagedChapterView.columnWidth(for:)`.
///
/// The double-page HStack is `[page, 1pt spine, page]`, so the two cells
/// share `block − 1`. The paginator originally measured with
/// `size.width / columns` — half a point wider than the live cell — and any
/// justified line whose natural width fell inside that half-point re-wrapped
/// at render time, pushing one extra line onto the page, which the clipped
/// page then sliced mid-glyph at the bottom (Hitchhiker's ch. 4, pages 5–6
/// of 8, was the reported case).
///
/// The live width itself is SwiftUI's layout division, which a unit test
/// cannot observe; what CAN be pinned exactly is that the formula reconstructs
/// the block: two columns plus the spine must equal the window width, to the
/// point. The old formula fails that by the missing 1pt.
final class SpreadColumnWidthTests: XCTestCase {
    private func view(_ layout: PageLayout) -> PagedChapterView {
        PagedChapterView(
            chapter: Chapter(title: "Ch", order: 0, text: "text"),
            layout: layout,
            style: ReaderStyle(theme: .paper, fontSize: 18),
            highlights: [],
            anchorOffset: .constant(0)
        )
    }

    /// Below the measure cap, the block is the window: 2·column + spine must
    /// give back the width exactly. This is the assertion the shipped formula
    /// violated (it returned w/2, so 2·column + 1 = w + 1).
    func testSpreadColumnsPlusSpineReconstructTheWindow() {
        let spread = view(.doublePage)
        for width in [640.0, 700.0, 731.5, 800.0] {
            let column = spread.columnWidth(for: CGSize(width: width, height: 700))
            XCTAssertEqual(
                column * 2 + 1, width, accuracy: 0.001,
                "At \(width)pt the two cells and the 1pt spine must fill the block exactly"
            )
        }
    }

    /// Single-page layout has no spine; the column is the full block.
    func testSinglePageColumnHasNoSpineDeduction() {
        let single = view(.singlePage)
        XCTAssertEqual(
            single.columnWidth(for: CGSize(width: 700, height: 700)), 700,
            accuracy: 0.001
        )
    }

    /// Above the cap the column stops growing — surplus becomes paper margin.
    /// (Guards against a regression that subtracts the spine from the window
    /// instead of the capped block.)
    func testColumnWidthIsCappedOnWideWindows() {
        let spread = view(.doublePage)
        let wide = spread.columnWidth(for: CGSize(width: 4000, height: 700))
        let wider = spread.columnWidth(for: CGSize(width: 9000, height: 700))
        XCTAssertEqual(wide, wider, accuracy: 0.001, "Beyond the cap, width must not grow")
        XCTAssertLessThan(wide, 2000, "The cap must actually bind on a wide window")
    }
}
