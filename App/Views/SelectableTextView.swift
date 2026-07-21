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

/// An inline image ready to render: the decoded bitmap plus the source
/// markup's intended display size (CSS pixels, treated 1:1 as points; nil ⇒
/// unknown, size from the bitmap). Keyed by the character offset of the
/// U+FFFC placeholder wherever a `[Int: InlineImage]` appears.
struct InlineImage: Equatable {
    var image: PlatformImage
    var displayWidth: CGFloat?
    var displayHeight: CGFloat?

    init(image: PlatformImage, displayWidth: CGFloat? = nil, displayHeight: CGFloat? = nil) {
        self.image = image
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

/// Encodes `LinkTarget`s as `.link` attribute URLs and decodes them back in
/// the platform delegates. External targets carry their real URL so the
/// platform's default interaction opens them in the browser; internal jumps
/// ride a custom scheme the delegates intercept and route to `onLinkTap`.
enum ReaderLinkURL {
    static let internalScheme = "readr-internal"

    static func url(for target: LinkTarget) -> URL? {
        switch target {
        case let .external(url):
            return URL(string: url)
        case let .internalDoc(path, fragment):
            // URLComponents percent-encodes the query values (archive paths
            // contain slashes; fragments can contain anything).
            var components = URLComponents()
            components.scheme = internalScheme
            components.host = "jump"
            var items = [URLQueryItem(name: "path", value: path)]
            if let fragment {
                items.append(URLQueryItem(name: "fragment", value: fragment))
            }
            components.queryItems = items
            return components.url
        }
    }

    /// The internal jump a URL encodes, or nil for anything else (external
    /// links keep their default open-in-browser interaction).
    static func internalTarget(from url: URL) -> LinkTarget? {
        guard url.scheme == internalScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        else { return nil }
        let fragment = components.queryItems?.first(where: { $0.name == "fragment" })?.value
        return .internalDoc(path: path, fragment: fragment)
    }
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
    var inlineImages: [Int: InlineImage] = [:]
    /// Formatting runs (headings, emphasis, blockquotes, links) in `text`
    /// coordinates — page embedders pass spans already shifted/clamped into
    /// their slice.
    var formatSpans: [FormatSpan] = []
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
    /// The committed selection, in `text` coordinates (nil ⇒ none). Reported
    /// whenever it changes so hosts can drive selection-dependent keyboard
    /// shortcuts (⇧⌘H highlight, ⇧⌘M note) — the selection itself lives only
    /// in the platform text view.
    var onSelectionChange: (Range<Int>?) -> Void = { _ in }
    /// iOS: a clean tap on the page — one that hit no highlight, dismissed no
    /// annotation bar, and collapsed no selection. Reports the tap's location
    /// and the text view's size so hosts can carve Apple-Books tap zones
    /// (the column's outer quarters turn pages, the middle toggles chrome).
    /// Delivered after a short settle window (see handleTap). Unused on macOS.
    var onPageTap: ((CGPoint, CGSize) -> Void)? = nil
    /// An INTERNAL link (`LinkTarget.internalDoc`) was tapped/clicked — the
    /// host resolves the archive path + fragment and jumps. External links
    /// never reach this: they keep the platform's default open-in-browser
    /// interaction (see the delegates).
    var onLinkTap: ((LinkTarget) -> Void)? = nil

    #if canImport(UIKit)
    /// The target the floating bar is showing for (nil ⇒ bar hidden).
    @State private var barTarget: AnnotationTarget?

    var body: some View {
        Representable(
            text: text,
            highlights: highlights,
            style: style,
            inlineImages: inlineImages,
            formatSpans: formatSpans,
            // Read the wrapped value here so SwiftUI re-runs update* when
            // the host sets a new target.
            scrollTarget: scrollToOffset?.wrappedValue,
            clearScrollTarget: { scrollToOffset?.wrappedValue = nil },
            allowsInternalScrolling: allowsInternalScrolling,
            onTarget: { barTarget = $0 },
            onSelectionChange: onSelectionChange,
            onPageTap: onPageTap,
            onLinkTap: onLinkTap
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
        // Unmounting (layout switch, PDF display toggle, spread shrinking)
        // takes the live selection down with the text view, and the delegate
        // never fires a final collapse — report it here so the host's
        // mirrored state can't outlive the surface.
        .onDisappear { onSelectionChange(nil) }
    }
    #else
    var body: some View {
        Representable(
            text: text,
            highlights: highlights,
            style: style,
            inlineImages: inlineImages,
            formatSpans: formatSpans,
            // Read the wrapped value here so SwiftUI re-runs update* when
            // the host sets a new target.
            scrollTarget: scrollToOffset?.wrappedValue,
            clearScrollTarget: { scrollToOffset?.wrappedValue = nil },
            allowsInternalScrolling: allowsInternalScrolling,
            onAnnotate: onAnnotate,
            onSelectionChange: onSelectionChange,
            onLinkTap: onLinkTap
        )
        // See the iOS body: a torn-down surface must not leave the host's
        // mirrored selection state stale.
        .onDisappear { onSelectionChange(nil) }
    }
    #endif
}

// MARK: - Selection reporting

/// Funnels committed-selection reports from a platform coordinator to the
/// host: deduped (a drag's continuous delegate callbacks must not spam SwiftUI
/// state) and dispatched async (the selection can collapse inside
/// `updateUIView`/`updateNSView` when the attributed string is replaced, and a
/// synchronous SwiftUI state write there is undefined behavior). One shared
/// implementation so the two coordinators can't drift on these semantics.
final class SelectionReporter {
    /// Re-pointed on every update pass so reports reach the current closure.
    var callback: (Range<Int>?) -> Void
    private var lastReported: Range<Int>?

    init(_ callback: @escaping (Range<Int>?) -> Void) {
        self.callback = callback
    }

    func report(_ range: Range<Int>?) {
        // Dedupe only nil→nil (caret moves fire a collapse on every click).
        // A repeat of the same non-nil range must still be delivered: the
        // host mirrors many reporters into one slot, so another surface (the
        // facing page of a spread) may have reset it since we last reported.
        if range == nil, lastReported == nil { return }
        lastReported = range
        DispatchQueue.main.async { [weak self] in self?.callback(range) }
    }
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
        inlineImages: [Int: InlineImage] = [:],
        formatSpans: [FormatSpan] = []
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        if style.isJustified {
            // Book-style justification needs hyphenation or long words tear
            // rivers into narrow phone columns (Apple Books does the same).
            paragraph.alignment = .justified
            paragraph.hyphenationFactor = 0.9
        }

        attributed.addAttribute(.font, value: style.contentFont, range: full)
        attributed.addAttribute(.foregroundColor, value: style.theme.ink, range: full)
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: full)

        applyFormatSpans(formatSpans, to: attributed, text: text, style: style, base: paragraph)

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

        for (offset, inline) in inlineImages.sorted(by: { $0.key < $1.key }) {
            guard let ns = nsRange(from: offset..<(offset + 1), in: text),
                  let placeholder = Range(ns, in: text),
                  text[placeholder] == "\u{FFFC}"
            else { continue }
            let attachment = ColumnFittingAttachment()
            attachment.image = inline.image
            attachment.declaredWidth = inline.displayWidth
            attachment.declaredHeight = inline.displayHeight
            attachment.maxHeight = style.maxImageHeight
            attributed.addAttribute(.attachment, value: attachment, range: ns)
        }
        return attributed
    }

    /// Applies formatting runs on top of the uniform base attributes. Spans
    /// arrive in the coordinates of `text` (page embedders shift/clamp them
    /// into their slice first) and are clamped again here, so a span truncated
    /// by a page boundary can never index out of bounds.
    ///
    /// Two channels. CHARACTER attributes (fonts, ink, links, baseline
    /// shifts) go on the exact clamped range, structural first: heading fonts
    /// land before bold/italic merge symbolic traits into whatever font the
    /// range already carries, super/subscript then scale that composed font,
    /// and links decorate last — sorting by phase makes that hold regardless
    /// of parser emission order. PARAGRAPH styles (heading spacing, quote
    /// indents, alignment) are computed ONCE per paragraph and applied over
    /// the full paragraph range including its trailing newline:
    /// `.paragraphStyle` is a whole-paragraph attribute, and the old per-span
    /// application let the last span win over sub-paragraph ranges — quote
    /// paragraphs indented only up to where the span happened to end.
    private static func applyFormatSpans(
        _ spans: [FormatSpan],
        to attributed: NSMutableAttributedString,
        text: String,
        style: ReaderStyle,
        base paragraph: NSParagraphStyle
    ) {
        guard !spans.isEmpty else { return }
        let count = text.count

        // Clamp every span once; route each kind to its channel(s).
        var character: [(ns: NSRange, kind: FormatSpan.Kind)] = []
        var paragraphLevel: [(ns: NSRange, kind: FormatSpan.Kind)] = []
        for span in spans {
            let lower = min(max(0, span.start), count)
            let upper = min(max(lower, span.end), count)
            guard lower < upper,
                  let ns = nsRange(from: lower..<upper, in: text) else { continue }
            switch span.kind {
            case .heading, .blockquote:
                // Font/ink at character level, spacing/indents at paragraph.
                character.append((ns, span.kind))
                paragraphLevel.append((ns, span.kind))
            case .alignment:
                paragraphLevel.append((ns, span.kind))
            case .bold, .italic, .link, .superscript, .`subscript`, .smallCaps:
                character.append((ns, span.kind))
            }
        }

        func phase(_ kind: FormatSpan.Kind) -> Int {
            switch kind {
            case .heading: return 0
            case .blockquote: return 1
            case .bold: return 2
            case .italic: return 3
            case .smallCaps: return 4
            case .superscript, .`subscript`: return 5
            case .link: return 6
            case .alignment: return 7
            }
        }

        for (ns, kind) in character.sorted(by: { phase($0.kind) < phase($1.kind) }) {
            switch kind {
            case let .heading(level):
                attributed.addAttribute(
                    .font, value: style.headingFont(level: level), range: ns
                )

            case .blockquote:
                attributed.addAttribute(
                    .foregroundColor, value: style.theme.mutedInk, range: ns
                )

            case .bold, .italic:
                let bold = kind == .bold
                // Merge the trait into whatever font each sub-run already has
                // (the base font, a heading font, the other emphasis trait).
                attributed.enumerateAttribute(.font, in: ns) { value, subrange, _ in
                    let current = (value as? PlatformFont) ?? style.contentFont
                    attributed.addAttribute(
                        .font,
                        value: ReaderStyle.fontMergingTraits(
                            into: current, bold: bold, italic: !bold
                        ),
                        range: subrange
                    )
                }

            case .smallCaps:
                attributed.enumerateAttribute(.font, in: ns) { value, subrange, _ in
                    let current = (value as? PlatformFont) ?? style.contentFont
                    attributed.addAttribute(
                        .font,
                        value: ReaderStyle.fontAddingSmallCaps(to: current),
                        range: subrange
                    )
                }

            case .superscript, .`subscript`:
                let raised = kind == .superscript
                // Fractions of the size the run would otherwise render at, so
                // a note marker inside a heading scales with the heading.
                attributed.enumerateAttribute(.font, in: ns) { value, subrange, _ in
                    let current = (value as? PlatformFont) ?? style.contentFont
                    attributed.addAttribute(
                        .font,
                        value: ReaderStyle.fontResized(current, to: current.pointSize * 0.75),
                        range: subrange
                    )
                    attributed.addAttribute(
                        .baselineOffset,
                        value: current.pointSize * (raised ? 0.33 : -0.33),
                        range: subrange
                    )
                }

            case let .link(target):
                guard let url = ReaderLinkURL.url(for: target) else { continue }
                attributed.addAttribute(.link, value: url, range: ns)
                attributed.addAttribute(
                    .foregroundColor, value: style.theme.linkInk, range: ns
                )
                attributed.addAttribute(
                    .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: ns
                )

            case .alignment:
                break // paragraph channel only
            }
        }

        guard !paragraphLevel.isEmpty else { return }
        // Paragraph channel: walk the paragraphs once and give each ONE
        // winning style over its FULL range (trailing newline included —
        // heading spacing lives on that newline). Spans intersect via the
        // paragraph's CONTENT range so a run that only touches the newline
        // separator never styles the paragraph before it. Fold order: quote
        // geometry, then heading spacing, then an explicit alignment.
        let nsText = text as NSString
        var location = 0
        while location < nsText.length {
            var pStart = 0
            var pEnd = 0
            var contentsEnd = 0
            nsText.getParagraphStart(
                &pStart, end: &pEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard pEnd > location else { break }
            location = pEnd
            let paragraphRange = NSRange(location: pStart, length: pEnd - pStart)
            let contentRange = NSRange(location: pStart, length: contentsEnd - pStart)
            guard contentRange.length > 0 else { continue }

            func intersects(_ ns: NSRange) -> Bool {
                NSIntersectionRange(ns, contentRange).length > 0
            }

            var winner: NSMutableParagraphStyle?
            func mutable() -> NSMutableParagraphStyle {
                if let winner { return winner }
                let created = NSMutableParagraphStyle()
                created.setParagraphStyle(paragraph)
                winner = created
                return created
            }

            if paragraphLevel.contains(where: { $0.kind == .blockquote && intersects($0.ns) }) {
                let quote = mutable()
                let indent = style.fontSize * 1.5
                quote.firstLineHeadIndent = indent
                quote.headIndent = indent
                // Negative tailIndent measures from the trailing edge — the
                // quote insets symmetrically. Ragged-right: justifying the
                // narrowed measure tears rivers.
                quote.tailIndent = -indent
                quote.alignment = .natural
            }
            if paragraphLevel.contains(where: { entry in
                if case .heading = entry.kind { return intersects(entry.ns) }
                return false
            }) {
                // Headings breathe: extra space before and after.
                let heading = mutable()
                heading.paragraphSpacingBefore = style.fontSize * 0.8
                heading.paragraphSpacing = style.paragraphSpacing + style.fontSize * 0.3
            }
            var alignmentOverride: ReadrKit.TextAlignment?
            for entry in paragraphLevel {
                if case let .alignment(value) = entry.kind, intersects(entry.ns) {
                    alignmentOverride = value
                }
            }
            if let alignmentOverride {
                let aligned = mutable()
                switch alignmentOverride {
                case .left:
                    aligned.alignment = .left
                case .center:
                    // Centered/right-set lines must never justify or
                    // hyphenate ("* * *" separators, captions, verse).
                    aligned.alignment = .center
                    aligned.hyphenationFactor = 0
                case .right:
                    aligned.alignment = .right
                    aligned.hyphenationFactor = 0
                case .justify:
                    aligned.alignment = .justified
                    aligned.hyphenationFactor = 0.9
                }
            }
            if let winner {
                attributed.addAttribute(.paragraphStyle, value: winner, range: paragraphRange)
            }
        }
    }
}

/// A text attachment that sizes its image to the column it's laid out in:
/// width fits the line fragment (so a figure can never spill past the text
/// edge — the fixed 500pt cap it replaces clipped charts on phone columns),
/// aspect ratio preserved, and an optional height cap so paged mode can
/// guarantee no image exceeds a page. Sizing happens per layout pass, so the
/// same attributed string renders correctly at any width — which also keeps
/// `LayoutPaginator`'s measurement identical to the live page.
///
/// BOTH layout engines are overridden: `LayoutPaginator` and `NSTextView`
/// measure through TextKit 1 (`NSLayoutManager` asks the four-argument
/// method), while the live iOS `UITextView` runs TextKit 2 on this target's
/// iOS 17 floor and asks the `location:`-based method instead — overriding
/// only TK1 would render native-size images on the one platform this fix is
/// for. Both funnel into one sizing function so the engines cannot drift.
final class ColumnFittingAttachment: NSTextAttachment {
    /// Page-height cap (paged mode); nil ⇒ only the width constrains.
    var maxHeight: CGFloat?
    /// The source markup's intended display size (CSS px, 1:1 points).
    /// A declared width wins over the bitmap's native width — a 40px icon
    /// exported at 2× (80px bitmap) must render 40pt — but the column still
    /// caps it. nil ⇒ size from the bitmap, never upscaled past native.
    var declaredWidth: CGFloat?
    var declaredHeight: CGFloat?

    /// The shared sizing rule: width = min(declared ?? native, column),
    /// height from the declared aspect when both dimensions are declared
    /// (else the bitmap's), honor the page-height cap.
    private func fittedBounds(proposedWidth: CGFloat) -> CGRect? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let native = image.size
        let declared = declaredWidth.flatMap { $0 > 0 ? $0 : nil }
        let declaredH = declaredHeight.flatMap { $0 > 0 ? $0 : nil }
        let aspect: CGFloat // height per unit width
        if let declared, let declaredH {
            aspect = declaredH / declared
        } else {
            aspect = native.height / native.width
        }
        // A height-only declaration (height="200" with no width — common in
        // EPUB markup) still expresses a size intent: derive the width from
        // it through the bitmap's aspect.
        let baseWidth = declared ?? declaredH.map { $0 / aspect } ?? native.width
        var width = proposedWidth > 0 ? min(baseWidth, proposedWidth) : baseWidth
        var height = width * aspect
        if let maxHeight, maxHeight > 0, height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    // TextKit 1 (NSLayoutManager): the paginator's measurement pass, macOS
    // NSTextView, and any TK1-compatibility fallback.
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        fittedBounds(proposedWidth: lineFrag.width)
            ?? super.attachmentBounds(
                for: textContainer, proposedLineFragment: lineFrag,
                glyphPosition: position, characterIndex: charIndex
            )
    }

    // TextKit 2 (NSTextLayoutManager): the live iOS UITextView.
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        fittedBounds(proposedWidth: proposedLineFragment.width)
            ?? super.attachmentBounds(
                for: attributes, location: location, textContainer: textContainer,
                proposedLineFragment: proposedLineFragment, position: position
            )
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
    let inlineImages: [Int: InlineImage]
    let formatSpans: [FormatSpan]
    /// Pending programmatic scroll (character offset into `text`); nil ⇒ none.
    let scrollTarget: Int?
    /// Clears the host's scroll target once the scroll has been issued.
    let clearScrollTarget: () -> Void
    let allowsInternalScrolling: Bool
    /// Reports the annotation target to show the bar for (nil ⇒ hide).
    let onTarget: (AnnotationTarget?) -> Void
    /// Reports the committed selection (see SelectableTextView).
    let onSelectionChange: (Range<Int>?) -> Void
    /// Reports a clean page tap (see SelectableTextView).
    let onPageTap: ((CGPoint, CGSize) -> Void)?
    /// Reports a tapped internal link (see SelectableTextView).
    let onLinkTap: ((LinkTarget) -> Void)?

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
        coordinator.selectionReporter.callback = onSelectionChange
        coordinator.onPageTap = onPageTap
        coordinator.onLinkTap = onLinkTap
        coordinator.text = text
        coordinator.spans = highlights
        // Only rebuild the attributed string when the content actually changed —
        // reassigning it resets the user's selection and re-fires the delegate.
        if coordinator.needsRender(
            text: text, spans: highlights, formatSpans: formatSpans, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) {
            // Hiding the bar writes SwiftUI state via onTarget, which is
            // undefined behavior synchronously inside a view update — defer.
            coordinator.hideBarAsync()
            // Applied to link ranges OVER the string's own attributes — keep
            // it in the theme's accent, not the system tint blue.
            view.linkTextAttributes = [
                .foregroundColor: style.theme.linkInk,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            view.attributedText = TextRangeConvert.attributedString(
                text, highlights: highlights, style: style,
                inlineImages: inlineImages, formatSpans: formatSpans
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

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onTarget: onTarget, onSelectionChange: onSelectionChange)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var text: String
        var spans: [HighlightSpan] = []
        var onTarget: (AnnotationTarget?) -> Void
        var onPageTap: ((CGPoint, CGSize) -> Void)?
        var onLinkTap: ((LinkTarget) -> Void)?
        let selectionReporter: SelectionReporter
        weak var textView: UITextView?
        /// `sizeThatFits` cache (paged mode): the fitted height for the last
        /// proposed width. Invalidated whenever the rendered content changes.
        var fittedWidth: CGFloat = -1
        var fittedHeight: CGFloat = 0

        private var debounce: Timer?
        private var barVisible = false
        private var renderedText: String?
        private var renderedSpans: [HighlightSpan] = []
        private var renderedFormatSpans: [FormatSpan] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []

        init(
            text: String,
            onTarget: @escaping (AnnotationTarget?) -> Void,
            onSelectionChange: @escaping (Range<Int>?) -> Void
        ) {
            self.text = text
            self.onTarget = onTarget
            self.selectionReporter = SelectionReporter(onSelectionChange)
        }

        deinit { debounce?.invalidate() }

        func needsRender(
            text: String, spans: [HighlightSpan], formatSpans: [FormatSpan],
            style: ReaderStyle, imageOffsets: [Int]
        ) -> Bool {
            guard renderedText == text, renderedSpans == spans,
                  renderedFormatSpans == formatSpans, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedSpans = spans; renderedStyle = style
                renderedFormatSpans = formatSpans
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
        // bar appears once the selection is committed. The host's selection
        // mirror is updated immediately, though — a hardware-keyboard
        // shortcut right after the last handle move must see the range the
        // user sees, not the one from before the 0.4s settle (downstream
        // re-renders are cheap: the render/pagination caches all hit).
        func textViewDidChangeSelection(_ textView: UITextView) {
            debounce?.invalidate()
            let selected = textView.selectedRange
            guard selected.length > 0 else {
                selectionReporter.report(nil)
                hideBar()
                return
            }
            if let range = TextRangeConvert.characterRange(from: selected, in: text) {
                selectionReporter.report(range)
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

        /// Link taps (iOS 17 text-item interaction): internal jumps route to
        /// the host's `onLinkTap`; external links keep the default action,
        /// which opens them in the browser.
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            if case let .link(url) = textItem.content,
               let target = ReaderLinkURL.internalTarget(from: url) {
                let onLinkTap = self.onLinkTap
                return UIAction { _ in onLinkTap?(target) }
            }
            return defaultAction
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = textView,
                  let position = view.closestPosition(to: gesture.location(in: view))
            else { return }
            let location = gesture.location(in: view)
            let size = view.bounds.size
            // Captured NOW: a tap whose job is dismissing something (the
            // annotation bar, or collapsing a selection) must not also fire
            // the page-tap action — the system collapses the selection and
            // the delegate hides the bar before the async hop below lands.
            let wasDismissal = barVisible || view.selectedRange.length > 0
            let utf16 = view.offset(from: view.beginningOfDocument, to: position)
            // The tap also collapses the selection, whose delegate callback
            // hides the bar — resolve the tapped span after that settles.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let offset = TextRangeConvert.characterOffset(
                       fromUTF16Location: utf16, in: self.text
                   ),
                   let span = self.spans.first(where: { $0.range.contains(offset) }) {
                    self.show(.span(span))
                    return
                }
                // A tap on a link belongs to the link interaction (which the
                // system delivers separately) — it must not ALSO turn a page
                // or toggle chrome out from under the navigation.
                if let rendered = self.textView?.attributedText, utf16 < rendered.length,
                   rendered.attribute(.link, at: utf16, effectiveRange: nil) != nil {
                    return
                }
                // A clean tap on plain page text: hand it to the host
                // (page-turn zones / chrome toggle, Apple-Books-style).
                guard !wasDismissal else { return }
                // Settle before firing: the first tap of a double-tap word
                // selection also lands here, and its second tap arrives
                // 100–350ms later — acting immediately would toggle chrome
                // (or worse, turn the page out from under the selection).
                // After the settle window, a real double-tap has produced a
                // selection (or the bar), and the tap wasn't clean after all.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.barVisible,
                          (self.textView?.selectedRange.length ?? 0) == 0 else { return }
                    self.onPageTap?(location, size)
                }
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
    let inlineImages: [Int: InlineImage]
    let formatSpans: [FormatSpan]
    /// Pending programmatic scroll (character offset into `text`); nil ⇒ none.
    let scrollTarget: Int?
    /// Clears the host's scroll target once the scroll has been issued.
    let clearScrollTarget: () -> Void
    let allowsInternalScrolling: Bool
    let onAnnotate: (AnnotationTarget, AnnotationAction) -> Void
    /// Reports the committed selection (see SelectableTextView).
    let onSelectionChange: (Range<Int>?) -> Void
    /// Reports a clicked internal link (see SelectableTextView).
    let onLinkTap: ((LinkTarget) -> Void)?

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
        // No autoresizing: it derives the document view's width from the
        // *change* in the clip view's size, so a text view attached before
        // the clip view reaches its real width ends up permanently wider —
        // wrapping past the visible edge (the clipped m01–m03/m08 renders).
        // The clip-view frame observer below syncs the width directly instead.
        textView.autoresizingMask = []
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
        // Keep the wrap width locked to the visible width on every clip-view
        // resize (window resize, inspector toggle, the initial layout pass).
        // Synchronous on purpose: the offscreen snapshot renderer lays out and
        // captures in one pass, so an async sync would miss the frame.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onAnnotate = onAnnotate
        coordinator.selectionReporter.callback = onSelectionChange
        coordinator.onLinkTap = onLinkTap
        coordinator.text = text
        coordinator.spans = highlights
        coordinator.theme = style.theme
        if coordinator.needsRender(
            text: text, spans: highlights, formatSpans: formatSpans, style: style,
            imageOffsets: inlineImages.keys.sorted()
        ) {
            // Content changed under the popover (chapter turn, highlight
            // edits) — its anchor rect is stale.
            coordinator.dismissMenu()
            // Applied to link ranges OVER the string's own attributes — keep
            // links in the theme's accent, not the system link blue.
            textView.linkTextAttributes = [
                .foregroundColor: style.theme.linkInk,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            textView.textStorage?.setAttributedString(
                TextRangeConvert.attributedString(
                    text, highlights: highlights, style: style,
                    inlineImages: inlineImages, formatSpans: formatSpans
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
        Coordinator(
            text: text, theme: style.theme,
            onAnnotate: onAnnotate, onSelectionChange: onSelectionChange
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String
        var spans: [HighlightSpan] = []
        /// Reading theme of the hosting page, forwarded to the menu.
        var theme: ReadingTheme
        var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void
        var onLinkTap: ((LinkTarget) -> Void)?
        let selectionReporter: SelectionReporter
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
        private var frameObserver: NSObjectProtocol?

        private var renderedText: String?
        private var renderedSpans: [HighlightSpan] = []
        private var renderedFormatSpans: [FormatSpan] = []
        private var renderedStyle: ReaderStyle?
        private var renderedImageOffsets: [Int] = []

        init(
            text: String,
            theme: ReadingTheme,
            onAnnotate: @escaping (AnnotationTarget, AnnotationAction) -> Void,
            onSelectionChange: @escaping (Range<Int>?) -> Void
        ) {
            self.text = text
            self.theme = theme
            self.onAnnotate = onAnnotate
            self.selectionReporter = SelectionReporter(onSelectionChange)
        }

        deinit {
            keyboardDebounce?.invalidate()
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            popover?.close()
        }

        func needsRender(
            text: String, spans: [HighlightSpan], formatSpans: [FormatSpan],
            style: ReaderStyle, imageOffsets: [Int]
        ) -> Bool {
            guard renderedText == text, renderedSpans == spans,
                  renderedFormatSpans == formatSpans, renderedStyle == style,
                  renderedImageOffsets == imageOffsets else {
                renderedText = text; renderedSpans = spans; renderedStyle = style
                renderedFormatSpans = formatSpans
                renderedImageOffsets = imageOffsets
                fittedWidth = -1 // content changed — the cached height is stale
                return true
            }
            return false
        }

        /// Internal links jump within the book (handled here, so AppKit never
        /// tries to open the custom scheme); external links fall through to
        /// the default handling, which opens them in the browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let target = ReaderLinkURL.internalTarget(from: url) else {
                return false
            }
            onLinkTap?(target)
            return true
        }

        func observeScroll(of contentView: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
            ) { [weak self] _ in
                self?.dismissMenu()
            }
        }

        /// Clip view resized → pin the document view's wrap width to it.
        /// `queue: nil` runs the block synchronously on the posting (main)
        /// thread, so a single offscreen layout pass sees the synced width.
        func observeFrame(of contentView: NSClipView) {
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: contentView, queue: nil
            ) { [weak self] note in
                guard let self, let textView = self.textView,
                      let clip = note.object as? NSClipView else { return }
                let width = clip.bounds.width
                guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
                textView.setFrameSize(
                    NSSize(width: width, height: textView.frame.height)
                )
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
                selectionReporter.report(range)
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
                selectionReporter.report(nil)
                dismissMenu()
                return
            }
            // Keyboard-extended selections (⇧→, ⇧⌘→, …) must reach the host
            // NOW, not after the menu's settle delay — a shortcut pressed
            // mid-extension would otherwise act on the previous, narrower
            // range. Mouse drags stay off this path (they'd report every
            // pixel); mouseUp reports those.
            if NSEvent.pressedMouseButtons == 0,
               let range = TextRangeConvert.characterRange(from: selected, in: text) {
                selectionReporter.report(range)
            }
            // Keyboard-extended selections never see a mouseUp; present the
            // menu once the selection has settled. Skipped while a mouse
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
                self.selectionReporter.report(range)
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
