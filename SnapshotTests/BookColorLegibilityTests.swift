import XCTest
import SwiftUI
@testable import Readr
import ReadrKit

/// A book's own colours must never make its text unreadable in Readr (#47).
///
/// `CSSStyleResolver` now parses `color` and `background-color`, which is what
/// lets a book that *describes* its highlight styling actually show it. The
/// risk that comes with it is the whole reason this file exists: a book picks
/// its colours against its own page, and Readr renders on three different
/// ones. The rule — honour the colour only where it clears WCAG AA against the
/// active surface — is enforced in the renderer, so it is pinned here against
/// the real theme tokens rather than against constants copied into a test.
final class BookColorLegibilityTests: XCTestCase {

    private let allThemes: [ReadingTheme] = [.paper, .sepia, .night]

    /// `pageColor` exists so the contrast check runs against the surface the
    /// text really sits on. If it ever drifts from `paper`, every judgement
    /// below is made against the wrong colour — silently.
    func testPageColorMatchesTheRenderedPaper() throws {
        for theme in allThemes {
            let rendered = try XCTUnwrap(
                CSSColor(platform: PlatformColor(theme.paper)),
                "\(theme) paper should convert to sRGB"
            )
            let declared = theme.pageColor

            XCTAssertEqual(rendered.red, declared.red, accuracy: 0.01, "\(theme) red")
            XCTAssertEqual(rendered.green, declared.green, accuracy: 0.01, "\(theme) green")
            XCTAssertEqual(rendered.blue, declared.blue, accuracy: 0.01, "\(theme) blue")
        }
    }

    /// The theme's own ink is readable on its own page — the fallback the
    /// renderer drops back to has to be safe in every theme.
    func testThemeInkIsReadableOnItsOwnPage() throws {
        for theme in allThemes {
            let ink = try XCTUnwrap(CSSColor(platform: theme.ink))
            XCTAssertTrue(
                ink.isReadable(on: theme.pageColor),
                "\(theme): ink contrast is "
                    + "\(ink.contrastRatio(against: theme.pageColor)), below AA"
            )
        }
    }

    /// The concrete regression: a mid-tone colour that reads on one theme and
    /// not another is accepted on the first and rejected on the second. Were
    /// the check ever dropped, this colour would render invisible on night.
    func testAColourIsJudgedPerThemeNotGlobally() {
        let darkBlue = CSSColor(hex: 0x1A237E)

        XCTAssertTrue(darkBlue.isReadable(on: ReadingTheme.paper.pageColor))
        XCTAssertTrue(darkBlue.isReadable(on: ReadingTheme.sepia.pageColor))
        XCTAssertFalse(
            darkBlue.isReadable(on: ReadingTheme.night.pageColor),
            "dark blue on the dark theme is the case the rule exists for"
        )
    }

    /// Round-tripping a colour through the platform representation must not
    /// shift it — the renderer contrast-checks colours it reads back out of
    /// the attributed string.
    func testColorSurvivesTheRoundTripThroughPlatformColor() throws {
        for hex in [0x000000, 0xFFFFFF, 0x8B0000, 0xFFF2A8, 0x1A237E] as [UInt32] {
            let original = CSSColor(hex: hex)
            let restored = try XCTUnwrap(CSSColor(platform: PlatformColor(original)))

            XCTAssertEqual(restored.red, original.red, accuracy: 0.005, "\(hex) red")
            XCTAssertEqual(restored.green, original.green, accuracy: 0.005, "\(hex) green")
            XCTAssertEqual(restored.blue, original.blue, accuracy: 0.005, "\(hex) blue")
        }
    }

    /// Whatever a book declares as a highlight, the ink the renderer picks for
    /// it must be legible — that choice is unconditional, so it must hold for
    /// every colour a stylesheet could name.
    func testTheFallbackInkIsLegibleOnAnyHighlight() {
        let candidates: [UInt32] = [
            0xFFFF00, 0xFFF2A8, 0xFFFFFF, 0x000000, 0x8B0000,
            0x1A237E, 0x808080, 0x00FF00, 0xFF00FF,
        ]
        for hex in candidates {
            let background = CSSColor(hex: hex)
            let ink = background.legibleInk
            XCTAssertTrue(
                ink.isReadable(on: background),
                "highlight \(String(hex, radix: 16)) got illegible ink "
                    + "(contrast \(ink.contrastRatio(against: background)))"
            )
        }
    }
}
