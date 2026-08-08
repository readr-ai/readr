import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Layout-accurate pagination for the paged reading surface.
///
/// `ReadrKit.Paginator` splits on an estimated character capacity, so every
/// page holds a different visual amount of text — ragged bottoms, and facing
/// pages whose last lines sit at different heights, nothing like an open
/// book. This paginator instead measures pages with TextKit using the SAME
/// attributes the reading surface renders (font, line/paragraph spacing,
/// image attachment bounds, zero insets and fragment padding — see
/// `TextRangeConvert.attributedString` and the `SelectableTextView`
/// representables).
///
/// Each page is measured EXACTLY as it will render: the layout for page k
/// starts at that page's first visible character (boundary whitespace is
/// folded into ranges, never rendered — see `Page`), fills one container of
/// the page's text size, and keeps what fits. Measuring the whole chapter in
/// one storage with chained containers instead would drift from rendering:
/// paragraph-gap newlines at a page top occupy container space in a chained
/// layout but are folded out of the rendered page, and trailing newlines
/// would render a phantom empty line — the ragged bottoms this exists to fix.
///
/// Lives in the app target: it needs TextKit, which `ReadrKit` (Linux-clean)
/// can't import. `ReadrKit.Paginator` remains the geometry-free fallback and
/// the host of the shared `Page`/spread index helpers.
struct LayoutPaginator {
    let style: ReaderStyle
    let inlineImages: [Int: InlineImage]
    /// Formatting runs in chapter coordinates — heading fonts, blockquote
    /// indents and heading paragraph spacing all move page breaks, so the
    /// measurement pass must carry the exact attributes the pages render.
    var formatSpans: [FormatSpan] = []

    /// How many characters past a page's first one are handed to the measuring
    /// container. Only the text that FITS decides where a page breaks, so
    /// feeding the container the whole rest of the chapter — as this did — is
    /// wasted work that grows with every page: pagination was quadratic, and a
    /// heading-less `.txt` (a Gutenberg novel is one 300–600 KB chapter) took
    /// 4.4–4.8 s of blocked main thread on an iPhone 17 Pro, on every book
    /// open and every tap that toggles the chrome.
    ///
    /// The window is only ever an optimisation, never a semantic: a page whose
    /// measurement consumed the ENTIRE window may have held more, so the
    /// window doubles and re-measures until the container fills short of its
    /// end (or the window reaches the chapter's end). `windowEnd` also snaps
    /// forward to a word boundary, so a truncated word can never present a
    /// short "word" to the line breaker and move a break. Tests pin the
    /// equivalence directly by paginating the same text with `.max`.
    var measurementWindow: Int = 4_096

    /// Split `text` into pages, where page `i`'s text area is
    /// `containerSize(i)`. (The API allows per-page sizes; the reader now
    /// passes a UNIFORM size — the kicker band is reserved on every page so
    /// facing pages share one text rectangle. Do not reintroduce per-index
    /// sizing without re-deriving the facing-page alignment.) `Page`
    /// semantics mirror
    /// `ReadrKit.Paginator`: ranges are contiguous and cover the whole text,
    /// and boundary whitespace is covered by a `range` but excluded from
    /// `text`. Interior page ranges END at their last visible character —
    /// the whitespace run at a break belongs to the NEXT page's range — so
    /// `textStartOffset` (which derives the origin from the range's end)
    /// stays exact for every page.
    ///
    /// Returns `[]` when measurement cannot proceed (degenerate geometry, an
    /// attachment taller than a page) — the caller falls back to the
    /// estimate-based paginator so reading never breaks.
    func paginate(_ text: String, containerSize: (Int) -> CGSize) -> [Page] {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return [] }

        // Spans are applied in chapter coordinates ONCE and sliced along with
        // the text below — `attributedSubstring` preserves attributes, so
        // each measured page carries exactly what the live page renders
        // (which applies the same spans clamped into page coordinates).
        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style, inlineImages: inlineImages,
            formatSpans: formatSpans
        )

        var pages: [Page] = []
        var rangeStart = 0
        // UTF-16 offset of `rangeStart`, carried forward one page at a time.
        // Deriving it per page instead (`text.index(startIndex, offsetBy:)`,
        // `NSRange(_:in:)`) walks the string from its start every time — the
        // other half of the quadratic cost, and invisible because it hides
        // behind two innocuous-looking `TextRangeConvert` calls.
        var utf16RangeStart = 0
        while rangeStart < n {
            // Fold boundary whitespace into this page's range; rendering
            // starts at the first visible character.
            var textStart = rangeStart
            while textStart < n, chars[textStart].isWhitespace { textStart += 1 }
            if textStart >= n {
                // Only chapter-trailing whitespace remains: fold it into the
                // last page's range AND text together, so the derived
                // `textStartOffset` (upperBound − text.count) keeps pointing
                // at the page's first character — the origin every page-local
                // highlight/image/span rebase depends on. The invisible tail
                // lays out below the measured content and clips harmlessly.
                if var last = pages.last {
                    last.text += String(chars[last.range.upperBound..<n])
                    last.range = last.range.lowerBound..<n
                    pages[pages.count - 1] = last
                }
                break
            }

            // UTF-16 offset of the page's first visible character: the run of
            // folded whitespace, measured once, added to the carried cursor.
            let utf16TextStart = utf16RangeStart
                + String(chars[rangeStart..<textStart]).utf16.count

            let size = containerSize(pages.count)
            guard size.width > 8, size.height > style.fontSize else {
                return [] // degenerate geometry — caller falls back
            }

            // Lay out from this page's first visible character in one
            // page-sized container — identical to how the page's own text view
            // will lay it out. Only a WINDOW of the remaining text is fed in
            // (see `measurementWindow`); if it turns out to be too small the
            // window doubles and this re-measures.
            var window = measurementWindow
            var end: Int
            while true {
                let windowEnd = Self.windowEnd(
                    from: textStart, window: window, in: chars, count: n
                )
                let sliceText = String(chars[textStart..<windowEnd])
                let slice = attributed.attributedSubstring(
                    from: NSRange(
                        location: utf16TextStart, length: sliceText.utf16.count
                    )
                )
                let storage = NSTextStorage(attributedString: slice)
                let layoutManager = NSLayoutManager()
                storage.addLayoutManager(layoutManager)
                let container = NSTextContainer(size: size)
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                layoutManager.ensureLayout(for: container)
                let glyphRange = layoutManager.glyphRange(for: container)
                let charRange = layoutManager.characterRange(
                    forGlyphRange: glyphRange, actualGlyphRange: nil
                )
                let localUTF16End = charRange.location + charRange.length
                guard localUTF16End > 0 else {
                    // The container accepted nothing (an attachment taller
                    // than the page, or a measurement anomaly). Bail rather
                    // than loop.
                    return []
                }

                if localUTF16End >= storage.length {
                    guard windowEnd >= n else {
                        // The container swallowed the whole window, so the
                        // page may hold more than we offered it. Widen and
                        // re-measure — never accept a break the window itself
                        // caused.
                        window = min(n, window * 2)
                        continue
                    }
                    end = n
                } else {
                    // Glyph→character mapping lands on character boundaries;
                    // if a boundary ever fell mid-scalar, nudge FORWARD until
                    // it converts (nothing is lost — the next page starts
                    // here).
                    var location = localUTF16End
                    var converted = TextRangeConvert.characterOffset(
                        fromUTF16Location: location, in: sliceText
                    )
                    while converted == nil, location < storage.length {
                        location += 1
                        converted = TextRangeConvert.characterOffset(
                            fromUTF16Location: location, in: sliceText
                        )
                    }
                    end = textStart + (converted ?? sliceText.count)
                }
                break
            }
            end = min(max(end, textStart + 1), n)

            if end < n {
                // Hyphenation (on by default with justified text) can land
                // the measured break MID-WORD: the layout hyphenated the
                // page's bottom line, but the rendered slice ends there — no
                // hyphen glyph, just "beauti" / next page "ful". Fold the
                // fragment onto the next page by backing up to the last break
                // opportunity. Explicit hyphens/dashes are legitimate break
                // points; a page that is one giant unbroken word keeps the
                // measured cut (progress guarantee).
                if !chars[end].isWhitespace, !chars[end - 1].isWhitespace,
                   chars[end - 1] != "-", chars[end - 1] != "\u{2010}",
                   chars[end - 1] != "\u{00AD}" {
                    var back = end
                    while back > textStart, !chars[back - 1].isWhitespace { back -= 1 }
                    if back > textStart { end = back }
                }
                // Trailing boundary whitespace belongs to the NEXT page's
                // range (its leading fold): rendered page text must not end
                // in newlines, which would draw a phantom empty line. Never
                // trim below one visible character.
                while end > textStart + 1, chars[end - 1].isWhitespace { end -= 1 }
            }

            let pageText = String(chars[textStart..<end])
            pages.append(Page(text: pageText, range: rangeStart..<end))
            // Carry the cursor: the next page's range starts where this one
            // ended, and its UTF-16 offset is this page's start plus the text
            // we just consumed.
            utf16RangeStart = utf16TextStart + pageText.utf16.count
            rangeStart = end
        }
        return pages
    }

    /// End of the measurement window for a page starting at `start`, snapped
    /// FORWARD to a word boundary.
    ///
    /// The snap is what makes windowing invisible to line breaking. Cutting
    /// mid-word would hand the breaker a short fragment ("beauti" for
    /// "beautiful") that fits where the real word would not, moving a break —
    /// a wrong page that still tiles correctly, so only a direct comparison
    /// against an unbounded run would ever catch it.
    private static func windowEnd(
        from start: Int, window: Int, in chars: [Character], count n: Int
    ) -> Int {
        guard window < n - start else { return n }
        var end = start + window
        while end < n, !chars[end].isWhitespace { end += 1 }
        return end
    }
}
