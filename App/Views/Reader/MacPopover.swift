#if os(macOS)
import SwiftUI
import AppKit

/// An AppKit popover for SwiftUI content, anchored to this (invisible) view.
///
/// SwiftUI's own `.popover` on macOS is bridged through the presenting
/// host's preferences: whenever the presenter re-renders under it — the
/// toolbar re-vended, the window's activation flipping as the popover takes
/// key — the bridge re-shows the popover, which re-renders the presenter,
/// until AppKit's display-cycle guard throws
/// (`_postWindowNeedsUpdateConstraints`) and the app dies. CI's macOS lane
/// hit that on every Aa click (September 2026; crash reports and samples in
/// the ci-screenshots branch). An `NSPopover` owns its window and does not
/// care what the presenter does, so the Aa popover uses this instead.
struct MacPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// Where the popover hangs from the anchor: `.minY` is below it.
    var preferredEdge: NSRectEdge = .minY
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if isPresented {
            if let popover = coordinator.popover {
                // Keep the content current with the presenter's state.
                (popover.contentViewController as? NSHostingController<Content>)?.rootView = content()
            } else {
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = false
                popover.contentViewController = NSHostingController(rootView: content())
                popover.delegate = coordinator
                coordinator.popover = popover
                // Not from inside a SwiftUI update: presenting is a layout
                // of its own.
                DispatchQueue.main.async {
                    guard coordinator.popover === popover, view.window != nil else { return }
                    popover.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
                }
            }
        } else if let popover = coordinator.popover {
            coordinator.popover = nil
            popover.close()
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        /// A click outside (transient behaviour) or Escape closed it: tell
        /// the presenter, so its state matches the screen.
        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if isPresented.wrappedValue {
                isPresented.wrappedValue = false
            }
        }
    }
}
#endif
