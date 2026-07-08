import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Annotation vocabulary

/// One highlight to paint, in the local coordinates of the text being shown.
/// Carries the `Highlight`'s id so menu actions can be resolved back to the
/// model even after the range is shifted into page coordinates.
struct HighlightSpan: Equatable, Identifiable {
    let id: UUID
    var range: Range<Int>
    var color: HighlightColor
    /// Painted with a note indicator (see `TextRangeConvert.attributedString`).
    var hasNote: Bool
}

/// What the annotation menu was opened for.
enum AnnotationTarget: Equatable {
    /// A fresh selection (create mode), in local text coordinates.
    case selection(Range<Int>)
    /// An existing highlight the reader clicked (edit mode).
    case span(HighlightSpan)
}

/// A button press inside the annotation menu.
enum AnnotationAction: Equatable {
    /// Create (selection target) or recolor (span target) a highlight.
    case highlight(HighlightColor)
    case note
    case ask
    case copy
    /// Span targets only.
    case remove
}

/// Builds the shared menu content for a target, funneling every button into a
/// single `fire` so hosts dismiss + forward in one place (the menu view itself
/// is presentation-agnostic — see AnnotationMenuView).
private func makeAnnotationMenu(
    for target: AnnotationTarget,
    theme: ReadingTheme,
    fire: @escaping (AnnotationAction) -> Void
) -> AnnotationMenuView {
    let mode: AnnotationMenuView.Mode
    switch target {
    case .selection:
        mode = .create
    case let .span(span):
        mode = .edit(currentColor: span.color, hasNote: span.hasNote)
    }
    var removeAction: (() -> Void)?
    if case .span = target { removeAction = { fire(.remove) } }
    return AnnotationMenuView(
        mode: mode,
        theme: theme,
        onHighlight: { fire(.highlight($0)) },
        onNote: { fire(.note) },
        onAsk: { fire(.ask) },
        onCopy: { fire(.copy) },
        onRemove: removeAction
    )
}

// MARK: - SelectableTextView

/// A read-only, selectable text view that paints highlights in their marker
/// colors and owns the select-to-annotate gesture. Wraps `UITextView` (iOS) /
/// `NSTextView` (macOS) because SwiftUI's `Text` exposes neither selection
/// ranges nor selection geometry.
///
/// - macOS: releasing a selection (or clicking an existing highlight) anchors
///   an `NSPopover` with `AnnotationMenuView` at the selection rect.
/// - iOS: a committed selection (or a tap on a highlight) shows a floating
///   material bar with the same menu at the bottom of the text area.
struct SelectableTextView: View {
    let text: String
    /// Highlights to paint, in `text` coordinates.
    let highlights: [HighlightSpan]
    var style = ReaderStyle()
    /// Inline images keyed by the character offset of their U+FFFC placeholder
    /// in `text`.
    var inlineImages: [Int: PlatformImage] = [:]
    /// Programmatic jump: a character offset to scroll into view. The view
    /// performs the scroll on its next update, then clears the binding
    /// (asynchronously — never during the update pass) so the same offset can
    /// be targeted again later. Defaulted so paged-mode embedders, which
    /// never jump within a page, are unaffected.
    var scrollToOffset: Binding<Int?>? = nil
    /// Paged embedders size their text to fit and set this false so the
    /// platform text view never claims swipe/scroll gestures (page turns need
    /// them) and never rubber-bands. Scroll mode keeps the default.
    var allowsInternalScrolling = true
    /// An annotation-menu action, with the target in `text` coordinates.
    var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void = { _, _ in }

    #if canImport(UIKit)
    /// The target the floating bar is showing for (nil ⇒ bar hidden).
    @State private var barTarget: AnnotationTarget?

    var body: some View {
        Representable(
            text: text,
            highlights: highlights,
            style: style,
            inlineImages: inlineImages,
            // Read the wrapped value here so SwiftUI re-runs update* when
            // the host sets a new target.
            scrollTarget: scrollToOffset?.wrappedValue,
            clearScrollTarget: { scrollToOffset?.wrappedValue = nil },
            allowsInternalScrolling: allowsInternalScrolling,
            onTarget: { barTarget = $0 }
        )
        .overlay(alignment: .bottom) {
            if let target = barTarget {
                // Marginalia: an elevated capsule with a hairline border — no
                // material blur (the menu supplies its own elev background).
                makeAnnotationMenu(for: target, theme: style.theme) { action in
                    barTarget = nil
                    onAnnotate(target, action)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(style.theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 12)
            }
        }
    }
    #else
    var body: some View {
        Representable(
            text: text,
            highlights: highlights,
            style: style,
            inlineImages: inlineImages,
            // Read the wrapped value here so SwiftUI re-runs update* when
            // the host sets a new target.
            scrollTarget: scrollToOffset?.wrappedValue,
            clearScrollTarget: { scrollToOffset?.wrappedValue = nil },
            allowsInternalScrolling: allowsInternalScrolling,
            onAnnotate: onAnnotate
        )
    }
    #endif
}

// MARK: - Range conversion helpers

enum TextRangeConvert {
    /// Platform NSRange (UTF-16) → character-offset range into `text`.
    static func characterRange(from nsRange: NSRange, in text: String) -> Range<Int>? {
        guard nsRange.length > 0, let r = Range(nsRange, in: text) else { return nil }
        let lower = text.distance(from: text.startIndex, to: r.lowerBound)
        let upper = text.distance(from: text.startIndex, to: r.upperBound)
        return lower..<upper
    }

    /// UTF-16 location (e.g. an insertion point) → character offset into `text`.
    static func characterOffset(fromUTF16Location location: Int, in text: String) -> Int? {
        guard location >= 0, location <= text.utf16.count,
              let r = Range(NSRange(location: location, length: 0), in: text)
        else { return nil }
        return text.distance(from: text.startIndex, to: r.lowerBound)
    }

    /// Character-offset range → NSRange (UTF-16) for attributing the string.
    static func nsRange(from range: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: range.upperBound, limitedBy: text.endIndex)
        else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    static func attributedString(
        _ text: String,
        highlights: [HighlightSpan],
        style: ReaderStyle,
        inlineImages: [Int: PlatformImage] = [:]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.fontSize * 0.6

        attributed.addAttribute(.font, value: style.contentFont, range: full)
        attributed.addAttribute(.foregroundColor, value: style.theme.ink, range: full)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: full)

        for span in highlights {
            guard let ns = nsRange(from: span.range, in: text) else { continue }
            attributed.addAttribute(
                .backgroundColor, value: style.theme.marker(span.color), range: ns
            )
            if span.hasNote {
                // Note indicator: a single underline in the marker's base
                // color. Chosen over a superscript glyph because underline
                // attributes never perturb text layout or character offsets —
                // inserting marker characters would shift every stored range.
                attributed.addAttribute(
                    .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: ns
                )
                attributed.addAttribute(
                    .underlineColor, value: ReadingTheme.markerBase(span.color), range: ns
                )
            }
        }

        for (offset, image) in inlineImages.sorted(by: { $0.key < $1.key }) {
            guard let ns = nsRange(from: offset..<(offset + 1), in: text),
                  let placeholder = Range(ns, in: text),
                  text[placeholder] == "\u{FFFC}"
            else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            if size.width > 0, size.height > 0 {
                // Cap width so oversized figures don't blow out the column;
                // preserve the aspect ratio.
                let maxWidth: CGFloat = 500
                let width = min(maxWidth, size.width)
                let height = width * size.height / size.width
                attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            }
            attributed.addAttribute(.attachment, value: attachment, range: ns)
        }
        return attributed
    }
}

// MARK: - Platform representable

#if canImport(UIKit)

/// UITextView subclass that suppresses the system edit menu — the floating
/// annotation bar replaces it (and provides Copy itself).
private final class AnnotatingUITextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

private struct Representable: UIViewRepresentable {
    let text: String
    let highlights: [HighlightSpan]
    let style: ReaderStyle
    let inlineImages: [Int: PlatformImage]
    /// Pending programmatic scroll (character offset into `text`); nil ⇒ none.
    let scrollTarget: Int?
    /// Clears the host's scroll target once the scroll has been issued.
    let clearScrollTarget: () -> Void
    let allowsInternalScrolling: Bool
    /// Reports the annotation target to show the bar for (nil ⇒ hide).
    let onTarget: (AnnotationTarget?) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = AnnotatingUITextView()
        view.isEditable = false
        view.isSelectable = true
        // Paged mode: the page fits by construction, and a scroll-enabled
        // text view would claim horizontal swipes meant to turn the page.
        view.isScrollEnabled = allowsInternalScrolling
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.textContainerInset = .zero
        view.adjustsFontForContentSizeCategory = true
        if !allowsInternalScrolling {
            // Paged mode disables scrolling, and a non-scrolling UITextView
            // lays its text out at its full intrinsic width — spilling off the
            // page and clipping at the screen edge. Pin the text container to
            // the view's width and drop the default line padding so lines wrap
            // to the page column (see `sizeThatFits`, which feeds it the
            // proposed width). Scoped to paged mode: scroll mode wraps fine
            // already, and zeroing its 5pt line padding would shift the
            // scrolling reader's line breaks for no reason.
            view.textContainer.widthTracksTextView = true
            view.textContainer.lineFragmentPadding = 0
        }
        context.coordinator.textView = view

        // Tap on an existing highlight opens the edit variant of the bar.
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTarget = onTarget
        coordinator.text = text
        coordinator.spans = highlights
        // Only rebuild the attributed string when the content actually changed —
        // reassigning it resets the user's selection and re-fires the delegate.
        if coordinator.needsRender(
            text: text, spans: highlights, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) {
            // Hiding the bar writes SwiftUI state via onTarget, which is
            // undefined behavior synchronously inside a view update — defer.
            coordinator.hideBarAsync()
            view.attributedText = TextRangeConvert.attributedString(
                text, highlights: highlights, style: style, inlineImages: inlineImages
            )
        }
        performPendingScroll(on: view)
    }

    /// Paged mode: honor the width SwiftUI proposes so the non-scrolling text
    /// view wraps to the page column and reports the height it actually needs,
    /// instead of ballooning to its single-line intrinsic width. Scroll mode
    /// returns nil to keep SwiftUI's default fill-and-scroll sizing.
    /// The fitted height is cached on the coordinator (keyed by width,
    /// invalidated with the render cache) — `UITextView.sizeThatFits` runs a
    /// full TextKit layout, far too heavy to repeat on every layout pass.
    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextView, context: Context
    ) -> CGSize? {
        guard !allowsInternalScrolling,
              let width = proposal.width, width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        if coordinator.fittedWidth != width {
            coordinator.fittedHeight = uiView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            coordinator.fittedWidth = width
        }
        let maxHeight = proposal.height ?? .infinity
        return CGSize(width: width, height: min(coordinator.fittedHeight, maxHeight))
    }

    /// Programmatic jump (search hit / bookmark / notes panel): scroll the
    /// target offset into view, then clear the host's binding on the next
    /// runloop turn — writing SwiftUI state synchronously from update* is
    /// undefined behavior (and re-issuing an idempotent scroll before the
    /// clear lands is harmless).
    private func performPendingScroll(on view: UITextView) {
        guard let offset = scrollTarget else { return }
        let lower = min(max(0, offset), text.count)
        let upper = min(lower + 1, text.count)
        if let ns = TextRangeConvert.nsRange(from: lower..<upper, in: text) {
            view.scrollRangeToVisible(ns)
        }
        DispatchQueue.main.async { clearScrollTarget() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, onTarget: onTarget) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var text: String
        var spans: [HighlightSpan] = []
        var onTarget: (AnnotationTarget?) -> Void
        weak var textView: UITextView?
        /// `sizeThatFits` cache (paged mode): the fitted height for the last
        /// proposed width. Invalidated whenever the rendered content changes.
        var fittedWidth: CGFloat = -1
        var fittedHeight: CGFloat = 0

        private var debounce: Timer?
        private var barVisible = false
        private var renderedText: String?
        private var renderedSpans: [HighlightSpan] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []

        init(text: String, onTarget: @escaping (AnnotationTarget?) -> Void) {
            self.text = text
            self.onTarget = onTarget
        }

        deinit { debounce?.invalidate() }

        func needsRender(
            text: String, spans: [HighlightSpan], style: ReaderStyle, imageOffsets: [Int]
        ) -> Bool {
            guard renderedText == text, renderedSpans == spans, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedSpans = spans; renderedStyle = style
                renderedImageOffsets = imageOffsets
                fittedWidth = -1 // content changed — the cached height is stale
                return true
            }
            return false
        }

        func hideBar() {
            debounce?.invalidate()
            guard barVisible else { return }
            barVisible = false
            onTarget(nil)
        }

        /// Content is being replaced during a SwiftUI update pass: the bar
        /// (if shown) must go, but the actual hide runs async because
        /// `onTarget` writes SwiftUI state. `barVisible` gates repeat calls.
        func hideBarAsync() {
            debounce?.invalidate()
            guard barVisible else { return }
            DispatchQueue.main.async { [weak self] in self?.hideBar() }
        }

        private func show(_ target: AnnotationTarget) {
            barVisible = true
            onTarget(target)
        }

        // Selection handles fire continuously while dragging; debounce so the
        // bar appears once the selection is committed.
        func textViewDidChangeSelection(_ textView: UITextView) {
            debounce?.invalidate()
            let selected = textView.selectedRange
            guard selected.length > 0 else {
                hideBar()
                return
            }
            debounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, let view = self.textView else { return }
                let current = view.selectedRange
                guard current.length > 0,
                      let range = TextRangeConvert.characterRange(from: current, in: self.text)
                else { return }
                self.show(.selection(range))
            }
        }

        // Scrolling under an open bar would leave it pointing at moved text.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if barVisible { hideBar() }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = textView,
                  let position = view.closestPosition(to: gesture.location(in: view))
            else { return }
            let utf16 = view.offset(from: view.beginningOfDocument, to: position)
            // The tap also collapses the selection, whose delegate callback
            // hides the bar — resolve the tapped span after that settles.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let offset = TextRangeConvert.characterOffset(
                          fromUTF16Location: utf16, in: self.text
                      ),
                      let span = self.spans.first(where: { $0.range.contains(offset) })
                else { return }
                self.show(.span(span))
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true // don't steal UITextView's own selection gestures
        }
    }
}

#elseif canImport(AppKit)

/// NSTextView subclass that reports mouse-up so the coordinator can anchor the
/// annotation popover at the *committed* selection (delegate selection-change
/// callbacks fire continuously during a drag).
private final class AnnotatingNSTextView: NSTextView {
    var onMouseUp: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }
}

private struct Representable: NSViewRepresentable {
    let text: String
    let highlights: [HighlightSpan]
    let style: ReaderStyle
    let inlineImages: [Int: PlatformImage]
    /// Pending programmatic scroll (character offset into `text`); nil ⇒ none.
    let scrollTarget: Int?
    /// Clears the host's scroll target once the scroll has been issued.
    let clearScrollTarget: () -> Void
    let allowsInternalScrolling: Bool
    let onAnnotate: (AnnotationTarget, AnnotationAction) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand (not NSTextView.scrollableTextView()) so the document
        // view is our mouse-up-reporting subclass.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = allowsInternalScrolling
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if !allowsInternalScrolling {
            // Paged mode: pages fit by construction. Kill elasticity so
            // two-finger swipes rubber-band nothing and reach the page-turn
            // catcher instead.
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
        }

        let textView = AnnotatingNSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 100, height: CGFloat.greatestFiniteMagnitude
        )
        if !allowsInternalScrolling {
            // Paged mode: the text view's width comes from `sizeThatFits`
            // pinning it to the proposed page column — autoresizing alone
            // leaves it at a stale width (the clip view was smaller when the
            // document view was attached), so lines wrap wider than the page
            // and clip at the card edge. Drop the 5pt line padding to match
            // the iOS paged path and the paginator's width assumption.
            textView.textContainer?.lineFragmentPadding = 0
        }
        textView.delegate = context.coordinator
        textView.onMouseUp = { [weak coordinator = context.coordinator] in
            coordinator?.handleMouseUp()
        }
        scroll.documentView = textView
        context.coordinator.textView = textView

        // A scroll moves the anchored text out from under the popover.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onAnnotate = onAnnotate
        coordinator.text = text
        coordinator.spans = highlights
        coordinator.theme = style.theme
        if coordinator.needsRender(
            text: text, spans: highlights, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) {
            // Content changed under the popover (chapter turn, highlight
            // edits) — its anchor rect is stale.
            coordinator.dismissMenu()
            textView.textStorage?.setAttributedString(
                TextRangeConvert.attributedString(
                    text, highlights: highlights, style: style, inlineImages: inlineImages
                )
            )
        }
        performPendingScroll(on: textView)
    }

    /// Paged mode: honor the width SwiftUI proposes so the text wraps to the
    /// page column, and report the height the laid-out text actually needs —
    /// the AppKit analogue of the iOS `sizeThatFits` above. Without it the
    /// scroll view just fills the page frame and the document view keeps
    /// whatever width autoresizing left it, wrapping wider than the visible
    /// page. The fitted height is cached on the coordinator (keyed by width,
    /// invalidated with the render cache) — forcing a full layout on every
    /// sizing pass is far too heavy.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        guard !allowsInternalScrolling,
              let width = proposal.width, width > 0, width.isFinite,
              let textView = nsView.documentView as? NSTextView,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }
        let coordinator = context.coordinator
        if coordinator.fittedWidth != width {
            // Pin the wrap width; widthTracksTextView mirrors it into the
            // container, but set both so the measurement below can't race a
            // pending autoresize.
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(
                width: width, height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: container)
            coordinator.fittedHeight = ceil(layoutManager.usedRect(for: container).height)
            coordinator.fittedWidth = width
        }
        let maxHeight = proposal.height ?? .infinity
        return CGSize(width: width, height: min(coordinator.fittedHeight, maxHeight))
    }

    /// Programmatic jump (search hit / bookmark / notes panel): scroll the
    /// target offset into view, then clear the host's binding on the next
    /// runloop turn — writing SwiftUI state synchronously from update* is
    /// undefined behavior (and re-issuing an idempotent scroll before the
    /// clear lands is harmless).
    private func performPendingScroll(on textView: NSTextView) {
        guard let offset = scrollTarget else { return }
        let lower = min(max(0, offset), text.count)
        let upper = min(lower + 1, text.count)
        if let ns = TextRangeConvert.nsRange(from: lower..<upper, in: text) {
            textView.scrollRangeToVisible(ns)
        }
        DispatchQueue.main.async { clearScrollTarget() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, theme: style.theme, onAnnotate: onAnnotate)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String
        var spans: [HighlightSpan] = []
        /// Reading theme of the hosting page, forwarded to the menu.
        var theme: ReadingTheme
        var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void
        weak var textView: NSTextView?
        /// `sizeThatFits` cache (paged mode): the fitted height for the last
        /// proposed width. Invalidated whenever the rendered content changes.
        var fittedWidth: CGFloat = -1
        var fittedHeight: CGFloat = 0

        /// The popover + hosting controller are created once and reused; only
        /// the root view (mode + callbacks) changes per presentation.
        private var popover: NSPopover?
        private var hosting: NSHostingController<AnnotationMenuView>?
        private var keyboardDebounce: Timer?
        private var scrollObserver: NSObjectProtocol?

        private var renderedText: String?
        private var renderedSpans: [HighlightSpan] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []

        init(
            text: String,
            theme: ReadingTheme,
            onAnnotate: @escaping (AnnotationTarget, AnnotationAction) -> Void
        ) {
            self.text = text
            self.theme = theme
            self.onAnnotate = onAnnotate
        }

        deinit {
            keyboardDebounce?.invalidate()
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            popover?.close()
        }

        func needsRender(
            text: String, spans: [HighlightSpan], style: ReaderStyle, imageOffsets: [Int]
        ) -> Bool {
            guard renderedText == text, renderedSpans == spans, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedSpans = spans; renderedStyle = style
                renderedImageOffsets = imageOffsets
                fittedWidth = -1 // content changed — the cached height is stale
                return true
            }
            return false
        }

        func observeScroll(of contentView: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
            ) { [weak self] _ in
                self?.dismissMenu()
            }
        }

        func dismissMenu() {
            keyboardDebounce?.invalidate()
            if popover?.isShown == true { popover?.close() }
        }

        /// Mouse released: a non-empty selection opens the create menu; a bare
        /// click inside an existing highlight opens the edit menu; anything
        /// else dismisses.
        func handleMouseUp() {
            keyboardDebounce?.invalidate()
            guard let textView else { return }
            let selected = textView.selectedRange()
            if selected.length > 0 {
                guard let range = TextRangeConvert.characterRange(from: selected, in: text)
                else { return }
                present(target: .selection(range), anchor: selected)
            } else if let offset = TextRangeConvert.characterOffset(
                fromUTF16Location: selected.location, in: text
            ),
                let span = spans.first(where: { $0.range.contains(offset) }),
                let anchor = TextRangeConvert.nsRange(from: span.range, in: text) {
                present(target: .span(span), anchor: anchor)
            } else {
                dismissMenu()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, (notification.object as? NSTextView) === textView else { return }
            let selected = textView.selectedRange()
            keyboardDebounce?.invalidate()
            guard selected.length > 0 else {
                // Selection collapsed — the menu no longer has a subject.
                dismissMenu()
                return
            }
            // Keyboard-extended selections (⇧→, ⇧⌘→, …) never see a mouseUp;
            // present once the selection has settled. Skipped while a mouse
            // drag is in flight — mouseUp handles that path immediately.
            keyboardDebounce = Timer.scheduledTimer(
                withTimeInterval: 0.4, repeats: false
            ) { [weak self] _ in
                guard let self, NSEvent.pressedMouseButtons == 0,
                      let view = self.textView else { return }
                let current = view.selectedRange()
                guard current.length > 0,
                      let range = TextRangeConvert.characterRange(from: current, in: self.text)
                else { return }
                self.present(target: .selection(range), anchor: current)
            }
        }

        private func present(target: AnnotationTarget, anchor: NSRange) {
            guard let textView, let window = textView.window else { return }
            // Selection geometry comes back in screen coordinates; the popover
            // wants view coordinates. Screen → window → view.
            var rect = textView.firstRect(forCharacterRange: anchor, actualRange: nil)
            rect = window.convertFromScreen(rect)
            rect = textView.convert(rect, from: nil)
            rect.size.width = max(rect.size.width, 1)
            rect.size.height = max(rect.size.height, 1)

            let menu = makeAnnotationMenu(for: target, theme: theme) { [weak self] action in
                self?.dismissMenu()
                self?.onAnnotate(target, action)
            }
            if let hosting {
                hosting.rootView = menu
            } else {
                let controller = NSHostingController(rootView: menu)
                controller.sizingOptions = .preferredContentSize
                hosting = controller
            }
            if popover == nil {
                let created = NSPopover()
                created.behavior = .transient
                created.animates = false
                created.contentViewController = hosting
                popover = created
            }
            // Size the popover to the menu's fitting size — mode changes
            // (create ↔ edit) change the row's width.
            if let view = hosting?.view {
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                if size.width > 0, size.height > 0 { popover?.contentSize = size }
            }
            // AppKit popovers follow NSApp.effectiveAppearance, not the
            // window's pinned (theme-derived) color scheme — adopt the text
            // view's appearance so the frame can't clash with the paper.
            popover?.appearance = textView.effectiveAppearance
            popover?.show(relativeTo: rect, of: textView, preferredEdge: .minY)
        }
    }
}
#endif
