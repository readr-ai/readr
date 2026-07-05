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

    @State private var cache = PaginationCache()
    @FocusState private var focused: Bool

    // Chrome metrics (mirrored in `capacity(for:)` — keep them in sync).
    /// Horizontal gutter reserved outside the card for the floating arrows.
    private static let arrowGutter: CGFloat = 52
    /// Interior padding of each page on the card.
    private static let pageInsets = EdgeInsets(top: 34, leading: 28, bottom: 26, trailing: 28)
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
                        .padding(.horizontal, Self.arrowGutter)
                        .padding(.vertical, 18)

                    HStack {
                        turnButton(
                            glyph: "\u{2039}", direction: -1, in: pages,
                            disabled: start == 0,
                            help: "Previous page (←)", label: "Previous page"
                        )
                        Spacer()
                        turnButton(
                            glyph: "\u{203A}", direction: +1, in: pages,
                            disabled: pages.isEmpty
                                || start + layout.pagesPerSpread >= pages.count,
                            help: "Next page (→)", label: "Next page"
                        )
                    }
                    .padding(.horizontal, 9)
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
        }
    }

    // MARK: - Pages

    private func paginate(for size: CGSize) -> [Page] {
        let capacity = Self.capacity(for: size, layout: layout, style: style)
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
    /// first-page kicker allowance.
    static func capacity(for size: CGSize, layout: PageLayout, style: ReaderStyle) -> Int {
        let pointSize = style.fontSize
        let columns = layout == .doublePage ? 2.0 : 1.0
        let horizontalChrome = arrowGutter * 2
            + (pageInsets.leading + pageInsets.trailing) * columns
        let pageWidth = max(1, (size.width - horizontalChrome) / columns)
        // 18+18 card margin, insets, footer, and ~36 kicker allowance.
        let verticalChrome = 36 + pageInsets.top + pageInsets.bottom + footerHeight + 36
        let pageHeight = max(1, size.height - verticalChrome)
        let charsPerLine = pageWidth / (pointSize * 0.55)
        let lines = pageHeight / (pointSize * 1.45)
        // 0.85 safety factor so a page never overflows its frame.
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
        guard !pages.isEmpty else { return }
        let next = startIndex(in: pages) + direction * layout.pagesPerSpread
        let clamped = min(max(0, next), pages.count - 1)
        anchorOffset = pages[clamped].range.lowerBound
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
                onAnnotate: { target, action in
                    onAnnotate(chapterTarget(from: target, origin: origin), action)
                }
            )
        }
        .padding(Self.pageInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .contentShape(Circle())
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
                Text(minutes > 0 ? "\(pageText) · ~\(minutes) min left in chapter" : pageText)
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
