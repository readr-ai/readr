import SwiftUI

#if os(macOS)
import AppKit

/// The reader stays useful at this size: the page still has room beside the
/// 280pt inspector, while the Ask transcript can collapse before its composer.
/// Keep the SwiftUI layout boundary and AppKit window constraint in lockstep.
enum ReaderWindowSizing {
    static let minimumContentSize = NSSize(width: 620, height: 420)
}

/// Enables the normal Mac window affordances on SwiftUI's value-keyed reader
/// windows. `WindowGroup(for:)` can otherwise create these as zoom-only
/// windows and derive a very tall minimum from the paged reader's content.
///
/// This representable never moves or resizes the window while it is being
/// created. It only installs capabilities and a bounded minimum after AppKit
/// has attached the hosting view; frame repair remains in `ReadrAppDelegate`.
struct ReaderWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderWindowConfigurationView {
        ReaderWindowConfigurationView()
    }

    func updateNSView(_ nsView: ReaderWindowConfigurationView, context: Context) {
        nsView.configureAttachedWindow()
    }
}

final class ReaderWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureAttachedWindow()
    }

    func configureAttachedWindow() {
        guard let window else { return }
        WindowFrameFitter.configureReader(window)
    }
}

/// Pulls a window back onto the screen it belongs on, after macOS has restored
/// a frame that does not fit.
///
/// macOS restores a saved window frame verbatim — including one saved while the
/// window sat partly on a second display, or saved on a taller display than the
/// one it opens on now. The reader window is where that hurts: its Ask composer
/// is pinned to the very bottom, so a window whose bottom edge lands off the
/// desktop puts the send field where the pointer cannot reach it, and the
/// reader reports "the page is too long, I can't press the button".
///
/// Deleting the stale `NSWindow Frame …` default does not fix it: AppKit saves
/// the frame again on the next move or quit, so it comes back — and the reader
/// window's autosave key contains a per-launch address, so a stale record can
/// resurface under a new key.
///
/// A window that already sits inside one screen's usable area is left exactly
/// as it is: this is not a window manager, it undoes a restore that landed off
/// the desktop, and nothing else. Its size is never grown, and its top edge is
/// kept — the title bar is what a reader aims at, and the bottom is the part
/// they could not see.
///
/// Frame repair is deliberately **not** done by the configurator above: a
/// `setFrame` from an `NSViewRepresentable` during `viewDidMoveToWindow` left
/// the window created but never ordered on screen. Repair runs from the app
/// delegate instead, when the window has finished coming forward, which is
/// after the restore and after layout.
enum WindowFrameFitter {
    /// Makes a reader a conventional resizable, full-screen-capable Mac
    /// window, with a minimum that protects the controls rather than one
    /// inferred from a full page of book content.
    static func configureReader(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = ReaderWindowSizing.minimumContentSize
        window.standardWindowButton(.zoomButton)?.isEnabled = true
    }

    static func fit(_ window: NSWindow) {
        let frame = window.frame
        // A frame the window has not grown into yet is not a restored frame.
        guard frame.width > 1, frame.height > 1 else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // Somewhere on the desktop, and inside one screen's usable area: the
        // reader (or the previous session) put it there on purpose.
        guard !screens.contains(where: { $0.visibleFrame.contains(frame) }) else { return }

        let target = screens.max { a, b in
            overlap(frame, a.visibleFrame) < overlap(frame, b.visibleFrame)
        } ?? screens[0]
        let allowed = target.visibleFrame
        let size = NSSize(
            width: min(frame.width, allowed.width),
            height: min(frame.height, allowed.height)
        )
        guard size.width > 1, size.height > 1 else { return }
        // Keep the top edge, then nudge the whole window back inside.
        var origin = NSPoint(x: frame.minX, y: frame.maxY - size.height)
        origin.x = min(max(origin.x, allowed.minX), allowed.maxX - size.width)
        origin.y = min(max(origin.y, allowed.minY), allowed.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// How much of `frame` sits on `screen`. `CGRect.intersection` answers
    /// `CGRect.null` for rectangles that do not meet, so it cannot be used
    /// as-is.
    private static func overlap(_ frame: CGRect, _ screen: CGRect) -> CGFloat {
        let box = screen.intersection(frame)
        return box.isNull || box.isEmpty ? 0 : box.width * box.height
    }
}
#endif
