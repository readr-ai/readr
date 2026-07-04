import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders a chapter as fixed pages — one page, or two facing pages like an
/// open book. Pagination is done by `ReadrKit.Paginator` from a character
/// capacity derived from the view's geometry and the body font, so pages
/// reflow on window resize. Text selection still reports **chapter**
/// coordinates, so highlights and Ask work identically to scroll mode.
struct PagedChapterView: View {
    let chapter: Chapter
    let layout: PageLayout
    /// Highlight ranges in chapter coordinates.
    let highlightRanges: [Range<Int>]
    /// Selection callback in chapter coordinates.
    let onSelect: (Range<Int>) -> Void

    /// Reading position as a **character offset** into the chapter, so it
    /// survives re-pagination (layout switches, window resizes) without
    /// jumping — the page index is derived from it at render time.
    @State private var anchorOffset = 0
    @State private var cache = PaginationCache()
    @FocusState private var focused: Bool

    /// Memoizes the last pagination so page turns/selection don't re-scan the
    /// whole chapter on every body evaluation. Reference type on purpose:
    /// mutating it during render doesn't invalidate the view.
    private final class PaginationCache {
        var chapterID: UUID?
        var capacity = 0
        var pages: [Page] = []
    }

    var body: some View {
        GeometryReader { geo in
            let pages = paginate(for: geo.size)
            let start = startIndex(in: pages)
            let visible = visiblePages(from: start, in: pages)

            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { item in
                        pageView(item.element)
                        if layout == .doublePage, item.offset == 0, visible.count > 1 {
                            Divider().padding(.vertical)
                        }
                    }
                    // Keep the book "spine" centered when the last spread has
                    // a single page.
                    if layout == .doublePage, visible.count == 1 {
                        Divider().padding(.vertical)
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                pageBar(start: start, pages: pages)
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .onKeyPress(.rightArrow) { turnPage(+1, in: pages); return .handled }
            .onKeyPress(.leftArrow) { turnPage(-1, in: pages); return .handled }
            .onAppear { focused = true }
            .onChange(of: chapter.id) { _, _ in anchorOffset = 0 }
        }
    }

    // MARK: - Pages

    private func paginate(for size: CGSize) -> [Page] {
        let capacity = Self.capacity(for: size, layout: layout)
        if cache.chapterID == chapter.id, cache.capacity == capacity {
            return cache.pages
        }
        let pages = Paginator(capacity: capacity).paginate(chapter.text)
        cache.chapterID = chapter.id
        cache.capacity = capacity
        cache.pages = pages
        return pages
    }

    /// Conservative characters-per-page estimate from geometry + body font.
    static func capacity(for size: CGSize, layout: PageLayout) -> Int {
        #if canImport(UIKit)
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        #else
        let pointSize = NSFont.preferredFont(forTextStyle: .body).pointSize
        #endif
        let columns = layout == .doublePage ? 2.0 : 1.0
        let pageWidth = max(1, (size.width - 48) / columns)
        let pageHeight = max(1, size.height - 72) // page bar + padding
        let charsPerLine = pageWidth / (pointSize * 0.55)
        let lines = pageHeight / (pointSize * 1.45)
        // 0.85 safety factor so a page never overflows its frame.
        return max(80, Int(charsPerLine * lines * 0.85))
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

    // MARK: - Subviews

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        SelectableTextView(
            text: page.text,
            highlightRanges: highlightRanges.compactMap { range in
                // Intersect chapter-coordinate highlights with this page, then
                // shift into page coordinates.
                let lower = max(range.lowerBound, page.range.lowerBound)
                let upper = min(range.upperBound, page.range.lowerBound + page.text.count)
                guard lower < upper else { return nil }
                return (lower - page.range.lowerBound)..<(upper - page.range.lowerBound)
            },
            onSelect: { pageRange in
                // Shift back into chapter coordinates.
                let offset = page.range.lowerBound
                onSelect((pageRange.lowerBound + offset)..<(pageRange.upperBound + offset))
            }
        )
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pageBar(start: Int, pages: [Page]) -> some View {
        HStack {
            Button { turnPage(-1, in: pages) } label: {
                Image(systemName: "arrow.left")
            }
            .accessibilityLabel("Previous page")
            .disabled(start == 0)

            Spacer()
            if !pages.isEmpty {
                let last = min(start + layout.pagesPerSpread, pages.count)
                Text(
                    layout == .doublePage && last - start > 1
                        ? "Pages \(start + 1)–\(last) of \(pages.count)"
                        : "Page \(start + 1) of \(pages.count)"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()

            Button { turnPage(+1, in: pages) } label: {
                Image(systemName: "arrow.right")
            }
            .accessibilityLabel("Next page")
            .disabled(pages.isEmpty || start + layout.pagesPerSpread >= pages.count)
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 6)
    }
}
