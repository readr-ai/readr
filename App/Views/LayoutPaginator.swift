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
    let inlineImages: [Int: PlatformImage]

    /// Split `text` into pages, where page `i`'s text area is
    /// `containerSize(i)` (sizes vary per page: the spread's first page
    /// reserves the kicker band). `Page` semantics mirror
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

        let attributed = TextRangeConvert.attributedString(
            text, highlights: [], style: style, inlineImages: inlineImages
        )

        var pages: [Page] = []
        var rangeStart = 0
        while rangeStart < n {
            // Fold boundary whitespace into this page's range; rendering
            // starts at the first visible character.
            var textStart = rangeStart
            while textStart < n, chars[textStart].isWhitespace { textStart += 1 }
            if textStart >= n {
                // Only chapter-trailing whitespace remains: extend the last
                // page's range over it. (Its `text` is unchanged, so this is
                // the one place `textStartOffset`'s suffix derivation shifts
                // by the folded run — same behavior as `Paginator`, and
                // harmless: no visible character lives in that tail.)
                if var last = pages.last {
                    last.range = last.range.lowerBound..<n
                    pages[pages.count - 1] = last
                }
                break
            }

            // Lay out the remainder from this page's first visible character
            // in one page-sized container — identical to how the page's own
            // text view will lay it out.
            guard let sliceStart = TextRangeConvert.nsRange(
                from: textStart..<n, in: text
            ) else { return [] }
            let slice = attributed.attributedSubstring(from: sliceStart)
            let sliceText = String(chars[textStart..<n])

            let size = containerSize(pages.count)
            guard size.width > 8, size.height > style.fontSize else {
                return [] // degenerate geometry — caller falls back
            }
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
                // The container accepted nothing (an attachment taller than
                // the page, or a measurement anomaly). Bail rather than loop.
                return []
            }

            var end: Int
            if localUTF16End >= storage.length {
                end = n
            } else {
                // Glyph→character mapping lands on character boundaries; if
                // a boundary ever fell mid-scalar, nudge FORWARD until it
                // converts (nothing is lost — the next page starts here).
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

            pages.append(Page(text: String(chars[textStart..<end]), range: rangeStart..<end))
            rangeStart = end
        }
        return pages
    }
}
