import XCTest
import SwiftUI
import AppKit
import ReadrKit
@testable import Readr

/// The Aa popover must present on macOS without a layout loop. CI's macOS
/// lane found the app hanging on the Aa click and dying with AppKit's
/// `_postWindowNeedsUpdateConstraints` exception (September 2026) — the
/// SwiftUI popover bridge re-showing itself under a re-rendering presenter.
/// The Aa popover now lives in an AppKit popover (`MacPopover`); this
/// presents it from a real window, re-renders the presenter under it a few
/// times, and pumps the run loop: a loop reproduces here as the same
/// exception, in minutes rather than a CI hour.
@MainActor
final class AppearancePopoverPresentationTests: XCTestCase {

    private struct Host: View {
        @State private var themeRaw = ReadingTheme.paper.rawValue
        @State private var layoutRaw = PageLayout.singlePage.rawValue
        @State private var fontSize: Double = 18
        @State private var fontRaw = ReaderFont.newYork.rawValue
        @State private var lineSpacingRaw = ReaderLineSpacing.normal.rawValue
        @State private var isJustified = false
        @State private var pdfShowsOriginal = true
        @State private var shown = true
        /// Bumped from outside to re-render the presenter under the popover.
        @Binding var generation: Int

        var body: some View {
            Color.white
                .frame(width: 900, height: 700)
                .overlay(alignment: .topTrailing) {
                    Text("render \(generation)").font(.caption).padding()
                }
                .overlay(alignment: .topTrailing) {
                    MacPopover(isPresented: $shown) {
                        AppearancePopover(
                            themeRaw: $themeRaw,
                            layoutRaw: $layoutRaw,
                            fontSize: $fontSize,
                            fontRaw: $fontRaw,
                            lineSpacingRaw: $lineSpacingRaw,
                            isJustified: $isJustified,
                            isPDF: false,
                            pdfShowsOriginal: $pdfShowsOriginal
                        )
                        .environment(\.popoverDismiss, PopoverDismiss { shown = false })
                    }
                    .frame(width: 1, height: 1)
                    .padding(.trailing, 150)
                }
        }
    }

    private final class Ticker: ObservableObject {
        @Published var generation = 0
    }

    private struct Root: View {
        @ObservedObject var ticker: Ticker
        var body: some View { Host(generation: $ticker.generation) }
    }

    func testAppearancePopoverPresentsWithoutALayoutLoop() {
        let ticker = Ticker()
        let host = NSHostingView(rootView: Root(ticker: ticker))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        // Pump the run loop, re-rendering the presenter as we go; a loop
        // throws inside it (AppKit's display-cycle guard) and takes the
        // process down.
        let deadline = Date().addingTimeInterval(4)
        var popoverSeen = false
        var ticks = 0
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            ticks += 1
            if ticks % 10 == 0 { ticker.generation += 1 }
            if NSApp.windows.contains(where: { String(describing: type(of: $0)).contains("Popover") }) {
                popoverSeen = true
            }
        }
        XCTAssertTrue(popoverSeen, "the Aa popover should have presented in a window")
        window.orderOut(nil)
    }
}
