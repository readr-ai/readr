import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Marginalia footer progress track: a 2pt hairline with an ink fill at
/// the given fraction. Shared by the scroll footer (ReaderView) and the paged
/// footer below.
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
/// Marginalia: the page(s) render on a centered paper card (hairline border,
/// radius 10, soft shadow) over the chrome background; a 1pt spine separates
/// facing pages; circular ‹ › buttons float outside the card; the 40pt footer
/// carries a hairline progress track and "Page x of y · ~N min left".
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Compact width (iPhone portrait): trim the arrow gutters and page insets
    /// so the reading column isn't crowded out by chrome — on a phone the
    /// wide default gutters read as oversized margins. Read from the
    /// environment so every embedder gets the right chrome automatically.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    // Chrome metrics (`capacity(for:)` reads these same properties, so the
    // estimate always matches what the body renders).
    /// Horizontal gutter reserved outside the card for the floating arrows.
    /// Narrower on compact widths so the arrows don't eat a quarter of a
    /// phone — but always wide enough to contain the 34pt buttons at their
    /// inset, so they never overlap the card or steal its taps.
    private var arrowGutter: CGFloat { isCompact ? 40 : 52 }
    /// Interior padding of each page on the card.
    private var pageInsets: EdgeInsets {
        isCompact
            ? EdgeInsets(top: 28, leading: 20, bottom: 22, trailing: 20)
            : EdgeInsets(top: 34, leading: 28, bottom: 26, trailing: 28)
    }
    /// Inset of the floating arrows from the view edge (they sit in the gutter).
    private var arrowInset: CGFloat { isCompact ? 3 : 9 }
    private static let footerHeight: CGFloat = 40

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

            VStack(spacing: 0) {
                ZStack {
                    pageCard(visible: visible)
                        .padding(.horizontal, arrowGutter)
                        .padding(.vertical, 18)

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
                    .padding(.horizontal, arrowInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer(start: start, pages: pages)
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .onKeyPress(.rightArrow) { turnPage(+1, in: pages); return .handled }
            .onKeyPress(.leftArrow) { turnPage(-1, in: pages); return .handled }
            .onAppear { focused = true }
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
    /// Subtracts the card chrome: arrow gutters, page insets, footer, and a
    /// first-page kicker allowance — read from the same instance properties
    /// the body renders with, so the two can't drift apart.
    private func capacity(for size: CGSize) -> Int {
        let pointSize = style.fontSize
        let columns = layout == .doublePage ? 2.0 : 1.0
        let horizontalChrome = arrowGutter * 2
            + (pageInsets.leading + pageInsets.trailing) * columns
        let pageWidth = max(1, (size.width - horizontalChrome) / columns)
        // 18+18 card margin, insets, footer, and ~36 kicker allowance.
        let verticalChrome = 36 + pageInsets.top + pageInsets.bottom + Self.footerHeight + 36
        let pageHeight = max(1, size.height - verticalChrome)
        let charsPerLine = pageWidth / (pointSize * 0.55)
        // Line box ≈ the font's natural line height (~1.2 em) plus the extra
        // leading the paragraph style adds (`ReaderStyle.lineSpacing`). The
        // old 1.45 magic factor ignored that leading and over-packed pages:
        // on phone widths a charsPerLine underestimate happened to cancel it,
        // but on desktop page widths the estimate is accurate and pages ran
        // one line past the card (caught by the m01–m03 macOS snapshots).
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

    // MARK: - Card & pages

    /// The paper card: page(s) on `theme.paper`, hairline border, radius 10,
    /// soft shadow; a 1pt spine hairline between facing pages.
    private func pageCard(visible: [Page]) -> some View {
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
        .background(style.theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style.theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }

    private var spine: some View {
        Rectangle().fill(style.theme.line).frame(width: 1)
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
        // Top-aligned: the text view sizes to its content now, and the frame's
        // default .center would float an underfull page (chapter ends, the
        // paginator's 0.85 safety slack) to the middle of the card.
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

    /// Circular floating page-turn button (elev fill, hairline border),
    /// vertically centered beside the card. Same actions the footer arrows
    /// used to run.
    private func turnButton(
        glyph: String, direction: Int, in pages: [Page],
        disabled: Bool, help: String, label: String
    ) -> some View {
        Button { turnPage(direction, in: pages) } label: {
            Text(glyph)
                .font(.system(size: 15))
                .foregroundStyle(style.theme.inkColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(style.theme.elevated))
                .overlay(Circle().strokeBorder(style.theme.line, lineWidth: 1))
                // The visible control is a 34pt circle, but the hit area is
                // the full-height gutter strip beside the card (Apple Books
                // edge-tap) — a 34pt circle is a needlessly hard target,
                // especially one-handed on a phone.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    /// 40pt footer: hairline progress track (ink fill at the pages-read
    /// fraction) + right-aligned "Page x of y · ~N min left in chapter".
    @ViewBuilder
    private func footer(start: Int, pages: [Page]) -> some View {
        let last = pages.isEmpty ? 0 : min(start + layout.pagesPerSpread, pages.count)
        let fraction = pages.isEmpty ? 0 : Double(last) / Double(pages.count)
        HStack(spacing: 14) {
            ReaderProgressTrack(
                fraction: fraction,
                ink: style.theme.inkColor,
                track: style.theme.line
            )
            if !pages.isEmpty {
                let pageText = layout == .doublePage && last - start > 1
                    ? "Pages \(start + 1)–\(last) of \(pages.count)"
                    : "Page \(start + 1) of \(pages.count)"
                // "min left" from the top of the visible spread — the same
                // anchor the parent persists. Cached per pagination; scanning
                // chapter.text here would run on every body evaluation.
                let minutes = minutesLeft(fromPage: start)
                // Compact drops "in chapter" — the full phrase truncates to
                // "~1 min left in ch…" beside the progress track on a phone.
                let suffix = isCompact ? "min left" : "min left in chapter"
                Text(minutes > 0 ? "\(pageText) · ~\(minutes) \(suffix)" : pageText)
                    .font(.system(size: 11))
                    .foregroundStyle(style.theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.footerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(style.theme.line).frame(height: 1)
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
