import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Marginalia footer progress track: a 2pt hairline with an ink fill at
/// the given fraction. Used by the scroll-mode footer in ReaderView; paged
/// mode dropped its footer for a full-bleed page, so it no longer draws one.
struct ReaderProgressTrack: View {
    /// 0...1 fraction read.
    let fraction: Double
    let ink: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(ink)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// Renders a chapter as fixed pages — one page, or two facing pages like an
/// open book. Pagination is done by `ReadrKit.Paginator` from a character
/// capacity derived from the view's geometry and the body font, so pages
/// reflow on window resize. Text selection still reports **chapter**
/// coordinates, so highlights and Ask work identically to scroll mode.
///
/// Marginalia (Apple-Books-on-Mac surface): the paper IS the window — the
/// whole surface is `theme.paper`, no card. The text column is capped at a
/// font-relative measure and centered, so extra window width becomes symmetric
/// paper margin. A subtle hairline is the spine between facing pages. Chrome is
/// unobtrusive overlay: a small muted page label centered at the bottom, and
/// full-height edge strips carrying a bare ‹ › chevron (fading in on hover on
/// macOS, always shown on iOS).
struct PagedChapterView: View {
    let chapter: Chapter
    let layout: PageLayout
    /// Theme + typography used to render pages; also drives the
    /// characters-per-page capacity estimate.
    var style: ReaderStyle = ReaderStyle()
    /// Highlights in chapter coordinates.
    let highlights: [HighlightSpan]
    /// Inline images keyed by character offset in **chapter** coordinates.
    var inlineImages: [Int: PlatformImage] = [:]
    /// Reading position as a **character offset** into the chapter, so it
    /// survives re-pagination (layout switches, window resizes) without
    /// jumping — the page index is derived from it at render time. Owned by
    /// the parent so it can persist the position, anchor bookmarks, and jump
    /// programmatically (TOC / bookmarks / search / notes panel).
    @Binding var anchorOffset: Int
    /// Annotation-menu actions, reported in chapter coordinates.
    var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void = { _, _ in }
    /// Whether a turn past the first/last page has somewhere to go (the
    /// parent has an adjacent chapter). Keeps the arrows live at the edges.
    var canOverflowBackward = false
    var canOverflowForward = false
    /// A turn ran past either end (−1 backward / +1 forward): the parent
    /// crosses into the adjacent chapter. Arrow keys, the floating buttons,
    /// and swipes all funnel through here, so paging flows through the whole
    /// book instead of stopping at chapter walls.
    var onOverflow: ((Int) -> Void)? = nil

    @State private var cache = PaginationCache()
    @FocusState private var focused: Bool
    /// macOS only: the pointer is over the reading surface, so the quiet
    /// page-turn chevrons fade in (Apple Books). Never set on iOS (no hover).
    @State private var hoveringSurface = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Compact width (iPhone portrait): tighten the literary page insets so the
    /// reading column isn't crowded out — on a phone the wide regular-width
    /// margins would swallow the text. Read from the environment so every
    /// embedder gets the right chrome automatically.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    // Chrome metrics (`capacity(for:)` reads these same instance properties, so
    // the estimate always matches what the body renders).
    /// Text columns per spread — drives both the measure cap and capacity.
    private var columns: CGFloat { layout == .doublePage ? 2 : 1 }
    /// ~40 em, like `ScrollReadingColumn` (avg serif glyph ≈ 0.5 em ⇒ ~75–80
    /// chars/line). Sharing the em count keeps paged and scroll lines the same
    /// length at any text size.
    private static let measureEms: CGFloat = 40
    /// Per-column width cap: 40 em of text plus the interior side insets. On a
    /// window wider than the cap the block is centered and the surplus becomes
    /// symmetric paper margin; narrower, columns shrink to fit (see capacity).
    private var measure: CGFloat {
        style.fontSize * Self.measureEms + pageInsets.leading + pageInsets.trailing
    }
    /// Interior page margins. Regular widths get generous, literary margins
    /// (the paper fills the window, so the text can breathe); compact stays
    /// tighter so a phone column isn't starved. Invariant: the leading/trailing
    /// inset is >= `arrowStripWidth` on BOTH size classes, so the full-height
    /// edge strip lands entirely in the margin and never overlaps the text
    /// column — otherwise the strip's button swallows selection-handle drags
    /// and long-press-to-annotate over the first/last glyphs of every line
    /// (the strips z-order above the column and the paper fills the window, so
    /// on a phone the column reaches the window edge). Regular already matches
    /// (56 == 56); compact matches at 40.
    private var pageInsets: EdgeInsets {
        isCompact
            ? EdgeInsets(top: 28, leading: 40, bottom: 22, trailing: 40)
            : EdgeInsets(top: 44, leading: 56, bottom: 40, trailing: 56)
    }
    /// Reserved band at the bottom for the muted page label, kept clear of the
    /// text (added to the page's bottom padding and to the capacity estimate)
    /// so the overlay never sits on a line.
    private var labelAllowance: CGFloat { isCompact ? 24 : 28 }
    /// First-page kicker (running head) reservation: the 11pt caps title plus
    /// its 22pt bottom padding, rounded up.
    private static let kickerAllowance: CGFloat = 36
    /// Full-height edge hit strip for the page-turn chevron (Apple-Books
    /// edge-tap). Narrower on a phone so it doesn't cover the column's edge.
    private var arrowStripWidth: CGFloat { isCompact ? 40 : 56 }

    /// Memoizes the last pagination so page turns/selection don't re-scan the
    /// whole chapter on every body evaluation. Reference type on purpose:
    /// mutating it during render doesn't invalidate the view.
    private final class PaginationCache {
        var chapterID: UUID?
        var capacity = 0
        var pages: [Page] = []
        /// Words from the start of each page to the chapter's end (index-
        /// aligned with `pages`). Computed once per pagination so the page
        /// bar's "min left" never re-scans the chapter text in body.
        var remainingWords: [Int] = []
    }

    var body: some View {
        GeometryReader { geo in
            let pages = paginate(for: geo.size)
            let start = startIndex(in: pages)
            let visible = visiblePages(from: start, in: pages)

            ZStack {
                // The paper is the window — one full-bleed surface; the text
                // column centers within it and the margins are the same paper.
                style.theme.paper

                pageColumns(visible: visible)

                // Full-height edge strips carry a bare chevron (no card, so no
                // filled circle). On macOS they fade in on hover; on iOS the
                // gutter has no hover, so they stay visible as before.
                HStack {
                    turnButton(
                        glyph: "\u{2039}", direction: -1, in: pages,
                        disabled: start == 0 && !canOverflowBackward,
                        help: "Previous page (←)", label: "Previous page"
                    )
                    Spacer()
                    turnButton(
                        glyph: "\u{203A}", direction: +1, in: pages,
                        disabled: (pages.isEmpty
                            || start + layout.pagesPerSpread >= pages.count)
                            && !canOverflowForward,
                        help: "Next page (→)", label: "Next page"
                    )
                }

                pageLabel(start: start, pages: pages)
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .onKeyPress(.rightArrow) { turnPage(+1, in: pages); return .handled }
            .onKeyPress(.leftArrow) { turnPage(-1, in: pages); return .handled }
            .onAppear { focused = true }
            #if os(macOS)
            .onHover { hoveringSurface = $0 }
            #endif
            .modifier(SwipeToTurn { direction in turnPage(direction, in: pages) })
        }
    }

    // MARK: - Pages

    private func paginate(for size: CGSize) -> [Page] {
        let capacity = capacity(for: size)
        if cache.chapterID == chapter.id, cache.capacity == capacity {
            return cache.pages
        }
        let pages = Paginator(capacity: capacity).paginate(chapter.text)
        cache.chapterID = chapter.id
        cache.capacity = capacity
        cache.pages = pages
        // Suffix-sum per-page word counts (pages break on whitespace, so the
        // sum matches counting the chapter once). One O(chapter) pass here
        // instead of one per render in the page bar.
        var remaining = [Int](repeating: 0, count: pages.count)
        var total = 0
        for index in pages.indices.reversed() {
            total += ReadingTimeEstimator.wordCount(in: pages[index].text)
            remaining[index] = total
        }
        cache.remainingWords = remaining
        return pages
    }

    /// "min left" from the top of the visible spread, derived from the cached
    /// word counts. Mirrors `ReadingTimeEstimator.minutes(for:)`: round up,
    /// minimum 1 while words remain.
    private func minutesLeft(fromPage start: Int) -> Int {
        guard cache.remainingWords.indices.contains(start) else { return 0 }
        let words = cache.remainingWords[start]
        guard words > 0 else { return 0 }
        return max(
            1, Int((Double(words) / ReadingTimeEstimator.defaultWordsPerMinute).rounded(.up))
        )
    }

    /// Conservative characters-per-page estimate from geometry + the reader
    /// style's font size, so pages reflow when the user changes text size.
    /// Read from the SAME instance properties the body renders with — the
    /// measure cap, page insets, bottom label band, and first-page kicker — so
    /// the estimate can't drift from the laid-out page.
    private func capacity(for size: CGSize) -> Int {
        let pointSize = style.fontSize
        // Per-column text width: the body caps each column at `measure` and
        // centers the block; a window narrower than the cap shrinks the columns
        // to `size.width / columns` (there is no gutter to subtract — the arrow
        // strips overlay the paper). Then remove the interior side insets.
        let columnWidth = min(measure, size.width / columns)
        let textWidth = max(1, columnWidth - (pageInsets.leading + pageInsets.trailing))
        // Height minus the top/bottom insets, the reserved bottom label band,
        // and the first-page kicker allowance — every vertical term the body
        // consumes before text.
        let verticalChrome = pageInsets.top + pageInsets.bottom
            + labelAllowance + Self.kickerAllowance
        let pageHeight = max(1, size.height - verticalChrome)
        let charsPerLine = textWidth / (pointSize * 0.55)
        // Line box ≈ the font's natural line height (~1.2 em) plus the extra
        // leading the paragraph style adds (`ReaderStyle.lineSpacing`). The
        // old 1.45 magic factor ignored that leading and over-packed pages:
        // on phone widths a charsPerLine underestimate happened to cancel it,
        // but on desktop page widths the estimate is accurate and pages ran
        // one line past the page (caught by the m01–m03 macOS snapshots).
        let lines = pageHeight / (pointSize * 1.2 + style.lineSpacing)
        // 0.85 safety factor (covers paragraph spacing, ~0.6 em per break)
        // so a page never overflows its frame.
        return max(30, Int(charsPerLine * lines * 0.85))
    }

    /// First visible page index, derived from the character-offset anchor.
    private func startIndex(in pages: [Page]) -> Int {
        guard !pages.isEmpty else { return 0 }
        let index = Paginator.pageIndex(containing: anchorOffset, in: pages)
        return Paginator.spreadStart(for: index, layout: layout)
    }

    private func visiblePages(from start: Int, in pages: [Page]) -> [Page] {
        guard !pages.isEmpty else { return [] }
        let end = min(start + layout.pagesPerSpread, pages.count)
        return Array(pages[start..<end])
    }

    private func turnPage(_ direction: Int, in pages: [Page]) {
        guard !pages.isEmpty else {
            if direction > 0, canOverflowForward { onOverflow?(1) }
            if direction < 0, canOverflowBackward { onOverflow?(-1) }
            return
        }
        let next = startIndex(in: pages) + direction * layout.pagesPerSpread
        if next < 0 {
            if canOverflowBackward { onOverflow?(-1) }
            return
        }
        if next >= pages.count {
            if canOverflowForward { onOverflow?(1) }
            return
        }
        anchorOffset = pages[next].range.lowerBound
    }

    // MARK: - Columns & pages

    /// The centered text column(s): each column caps at `measure` and the whole
    /// block is centered, so surplus window width becomes symmetric paper
    /// margin (the surface behind is already `theme.paper`). A subtle hairline
    /// is the spine between facing pages.
    private func pageColumns(visible: [Page]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { item in
                pageView(item.element, showsKicker: item.offset == 0)
                if layout == .doublePage, item.offset == 0, visible.count > 1 {
                    spine
                }
            }
            // Keep the book "spine" centered when the last spread has a
            // single page.
            if layout == .doublePage, visible.count == 1 {
                spine
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Cap the block at one measure per column; the outer infinite frame
        // then centers it, leaving equal paper margins on a wide window.
        .frame(maxWidth: measure * columns)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Facing-page gutter: a hairline at reduced opacity. Full-bleed paper has
    /// no card edge for a hard 1pt rule to sit against, so it stays quiet.
    private var spine: some View {
        Rectangle().fill(style.theme.line.opacity(0.5)).frame(width: 1)
    }

    @ViewBuilder
    private func pageView(_ page: Page, showsKicker: Bool) -> some View {
        // Images whose placeholder falls on this page, shifted into page
        // coordinates (same textStartOffset origin as highlights below).
        let origin = page.textStartOffset
        let pageImages = Dictionary(uniqueKeysWithValues: inlineImages.compactMap { offset, image in
            (offset >= origin && offset < origin + page.text.count) ? (offset - origin, image) : nil
        })
        VStack(alignment: .leading, spacing: 0) {
            // Chapter kicker as a running head on the spread's first page.
            // Displayed in caps, but exposed to accessibility under the
            // original title so UI tests (and VoiceOver) still find e.g.
            // "Chapter One" on ANY page — the seeded reading position lands
            // mid-chapter. (Capacity reserves a fixed allowance for it.)
            if showsKicker, let title = chapter.title {
                Text(title.uppercased())
                    .font(.system(size: 11))
                    .kerning(2)
                    .foregroundStyle(style.theme.faint)
                    .lineLimit(1)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(title)
                    .padding(.bottom, 22)
            }
            SelectableTextView(
                text: page.text,
                highlights: highlights.compactMap { span in
                    // Intersect chapter-coordinate highlights with this page, then
                    // shift into page coordinates. The origin is textStartOffset,
                    // NOT range.lowerBound — folded boundary whitespace is inside
                    // the range but not the text.
                    let lower = max(span.range.lowerBound, origin)
                    let upper = min(span.range.upperBound, origin + page.text.count)
                    guard lower < upper else { return nil }
                    return HighlightSpan(
                        id: span.id,
                        range: (lower - origin)..<(upper - origin),
                        color: span.color,
                        hasNote: span.hasNote
                    )
                },
                style: style,
                inlineImages: pageImages,
                // Pages fit by construction — internal scrolling off, so the
                // platform text view can't claim the swipe (iOS pan) or
                // rubber-band under it (macOS elasticity).
                allowsInternalScrolling: false,
                onAnnotate: { target, action in
                    onAnnotate(chapterTarget(from: target, origin: origin), action)
                }
            )
        }
        .padding(pageInsets)
        // Reserve the bottom label band so a full page's last line never runs
        // under the muted page label (capacity subtracts the same allowance).
        .padding(.bottom, labelAllowance)
        // Top-aligned: the text view sizes to its content now, and the frame's
        // default .center would float an underfull page (chapter ends, the
        // paginator's 0.85 safety slack) to the middle of the page.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Shift a page-coordinate target back into chapter coordinates (text
    /// origin — see pageView). Spans are restored from the chapter-coordinate
    /// source list by id, so a highlight clipped at a page boundary still
    /// reports its full range.
    private func chapterTarget(from target: AnnotationTarget, origin: Int) -> AnnotationTarget {
        switch target {
        case let .selection(range):
            return .selection((range.lowerBound + origin)..<(range.upperBound + origin))
        case let .span(span):
            if let full = highlights.first(where: { $0.id == span.id }) {
                return .span(full)
            }
            var shifted = span
            shifted.range = (span.range.lowerBound + origin)..<(span.range.upperBound + origin)
            return .span(shifted)
        }
    }

    // MARK: - Chrome

    /// Bare page-turn chevron on a full-height edge strip (no card ⇒ no filled
    /// circle). The hit area is the whole strip (Apple Books edge-tap). On
    /// macOS the glyph is hidden until the pointer is over the surface, then
    /// fades in; disabled arrows stay consistently dimmed. iOS keeps them
    /// visible (no hover). Actions, `.help`, labels, and disabled logic are
    /// unchanged.
    private func turnButton(
        glyph: String, direction: Int, in pages: [Page],
        disabled: Bool, help: String, label: String
    ) -> some View {
        Button { turnPage(direction, in: pages) } label: {
            Text(glyph)
                .font(.system(size: 22))
                .foregroundStyle(style.theme.faint)
                .frame(width: arrowStripWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .disabled(disabled)
        .opacity(arrowOpacity(disabled: disabled))
        #if os(macOS)
        .animation(.easeInOut(duration: 0.15), value: hoveringSurface)
        #endif
    }

    /// Chevron opacity: disabled arrows sit at 0.35 (consistently dimmed),
    /// live ones at full. On macOS the whole thing hides (0) until the pointer
    /// enters the surface, so at rest the page reads uncluttered.
    private func arrowOpacity(disabled: Bool) -> Double {
        let base = disabled ? 0.35 : 1.0
        #if os(macOS)
        return hoveringSurface ? base : 0
        #else
        return base
        #endif
    }

    /// Small muted page label, centered in the reserved bottom band. Same text
    /// logic as the old footer ("Page x of y" / "Pages x–y of N" + "· ~N min
    /// left"), minus the progress track. Non-interactive so it never eats an
    /// edge-strip tap.
    @ViewBuilder
    private func pageLabel(start: Int, pages: [Page]) -> some View {
        if !pages.isEmpty {
            let last = min(start + layout.pagesPerSpread, pages.count)
            let pageText = layout == .doublePage && last - start > 1
                ? "Pages \(start + 1)–\(last) of \(pages.count)"
                : "Page \(start + 1) of \(pages.count)"
            // "min left" from the top of the visible spread — the same anchor
            // the parent persists. Cached per pagination; scanning chapter.text
            // here would run on every body evaluation.
            let minutes = minutesLeft(fromPage: start)
            // Compact drops "in chapter" so the phrase fits a phone width.
            let suffix = isCompact ? "min left" : "min left in chapter"
            Text(minutes > 0 ? "\(pageText) · ~\(minutes) \(suffix)" : pageText)
                .font(.system(size: 11))
                .foregroundStyle(style.theme.muted)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: labelAllowance)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Swipe to turn

/// Turns horizontal swipes into page turns (−1 back / +1 forward), matching
/// the platform's native gesture: a drag on iOS, a two-finger trackpad swipe
/// on macOS. Natural direction — content follows the fingers, so swiping left
/// goes forward.
private struct SwipeToTurn: ViewModifier {
    let onTurn: (Int) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    // Deliberate horizontal swipes only — a sloppy vertical
                    // drag must not turn pages, and neither should a slow
                    // horizontal selection-handle drag (flicks carry
                    // velocity; handle drags end near-stationary).
                    guard abs(h) > abs(v) * 1.2,
                          abs(value.velocity.width) > 220 else { return }
                    onTurn(h < 0 ? +1 : -1)
                }
        )
        #else
        content.background(MacTrackpadSwipeCatcher(onSwipe: onTurn))
        #endif
    }
}

#if canImport(AppKit)
/// Observes scroll-wheel phases via a local event monitor and reports one
/// page turn per completed two-finger horizontal swipe. A monitor (not a
/// gesture recognizer) because the page's NSScrollView sits above us and
/// would swallow direct events; momentum events are ignored so one physical
/// swipe never turns two pages. Only fires for events over this view in its
/// own window.
private struct MacTrackpadSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onSwipe: (Int) -> Void
        private var monitor: Any?
        private weak var view: NSView?
        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0

        init(onSwipe: @escaping (Int) -> Void) {
            self.onSwipe = onSwipe
        }

        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            remove()
        }

        private func handle(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window else { return }
            let location = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(location) else { return }
            // Momentum after the fingers lift must not turn a second page.
            guard event.momentumPhase.isEmpty else { return }
            switch event.phase {
            case .began:
                accumulatedX = 0
                accumulatedY = 0
            case .changed:
                accumulatedX += event.scrollingDeltaX
                accumulatedY += event.scrollingDeltaY
            case .ended:
                // Deliberate horizontal travel only; natural scrolling means
                // content follows the fingers, so left = next page.
                if abs(accumulatedX) > 60, abs(accumulatedX) > abs(accumulatedY) * 1.5 {
                    onSwipe(accumulatedX < 0 ? +1 : -1)
                }
                accumulatedX = 0
                accumulatedY = 0
            default:
                break
            }
        }
    }
}
#endif
