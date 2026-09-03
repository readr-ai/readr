import Foundation

/// An sRGB colour parsed from a stylesheet, components in 0…1.
public struct CSSColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        // Non-finite channels can't be clamped into range and can't be
        // encoded: `JSONEncoder` refuses `Double.nan`, and these ride inside
        // `FormatSpan`, which is persisted. One book declaring `rgb(nan,0,0)`
        // would otherwise throw on every subsequent library save for the rest
        // of the session, silently ending all persistence.
        func sanitize(_ value: Double) -> Double {
            value.isFinite ? min(max(value, 0), 1) : 0
        }
        self.red = sanitize(red)
        self.green = sanitize(green)
        self.blue = sanitize(blue)
        self.alpha = alpha.isFinite ? min(max(alpha, 0), 1) : 1
    }

    /// Nothing to paint — `transparent`, or any colour at zero alpha. Declared
    /// but invisible, which is how a rule cancels an inherited highlight.
    public var isClear: Bool { alpha <= 0.001 }

    /// Perceived lightness (WCAG relative luminance). The renderer picks a
    /// legible ink for a highlighted run from this rather than trusting the
    /// reader's theme colour to contrast with the book's chosen background.
    public var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour as the eye actually sees it once laid over `backdrop`.
    ///
    /// Every judgement below reads `red`/`green`/`blue` and ignores `alpha`,
    /// which is right for opaque colours and badly wrong for translucent ones:
    /// `rgba(0, 0, 0, 0.05)` — the "subtle grey panel" idiom books use
    /// constantly — is *painted* as a near-white wash but measures as pure
    /// black, so a legibility check run on it picks white ink and the
    /// paragraph disappears. Composite first, judge second.
    public func composited(over backdrop: CSSColor) -> CSSColor {
        guard alpha < 1 else { return self }
        let opacity = alpha
        return CSSColor(
            red: red * opacity + backdrop.red * (1 - opacity),
            green: green * opacity + backdrop.green * (1 - opacity),
            blue: blue * opacity + backdrop.blue * (1 - opacity),
            alpha: 1
        )
    }

    /// WCAG contrast ratio against another colour, 1…21.
    ///
    /// Assumes both colours are opaque — composite with `composited(over:)`
    /// first if either might not be.
    public func contrastRatio(against other: CSSColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG AA for body text. A book's own `color` is honoured only when it
    /// clears this against the surface it will actually sit on — see
    /// `ResolvedStyle.foreground`.
    public static let minimumReadableContrast = 4.5

    /// Whether text in this colour is readable on `background`.
    public func isReadable(on background: CSSColor) -> Bool {
        contrastRatio(against: background) >= Self.minimumReadableContrast
    }

    public static let black = CSSColor(red: 0, green: 0, blue: 0)
    public static let white = CSSColor(red: 1, green: 1, blue: 1)

    /// Black or white, whichever contrasts more with this colour — the ink the
    /// renderer puts on a highlight the book declared (#47).
    ///
    /// Picking by a luminance threshold is the obvious implementation and it
    /// is wrong: mid-tones sit far enough from both ends that the *lighter*
    /// choice can still fail AA. Plain grey (#808080) has luminance 0.22, so a
    /// "below 0.5 → white" rule hands it white at 3.9:1 when black would give
    /// 5.3:1. Comparing the two ratios always clears AA — the worst case, at
    /// luminance 0.179, scores 4.58:1 either way.
    /// A book-declared background as it should be painted on the reader's
    /// page. Honoured as declared when it sits on the same side of mid-grey
    /// as the page — a cream panel on Paper, a faint grey wash anywhere.
    /// When it would flip the page's polarity — an opaque near-white
    /// pull-quote panel on the dark theme, which rendered as a white block
    /// with black ink — it is toned down to a wash of itself, the same
    /// treatment the theme gives its own markers on a dark page, so the
    /// emphasis survives without the block.
    public func adapted(toPage page: CSSColor) -> CSSColor {
        let painted = composited(over: page)
        let pageIsDark = page.luminance < Self.midLuminance
        let paintedIsDark = painted.luminance < Self.midLuminance
        guard pageIsDark != paintedIsDark else { return self }
        return CSSColor(red: red, green: green, blue: blue, alpha: min(alpha, Self.washAlpha))
    }

    /// WCAG luminance of a perceptual mid-grey (#808080 ≈ 0.216); the line
    /// between a "light" and a "dark" surface for `adapted(toPage:)`.
    public static let midLuminance = 0.18
    /// The alpha a polarity-flipping background is toned down to.
    public static let washAlpha = 0.3

    public var legibleInk: CSSColor {
        contrastRatio(against: .black) >= contrastRatio(against: .white)
            ? .black
            : .white
    }
}

/// The formatting facts a stylesheet (or inline `style`) resolves to for one
/// element, as tri-state optionals: `nil` means "not declared", so overlaying
/// a higher-precedence source only replaces what that source actually
/// declares.
public struct ResolvedStyle: Equatable, Sendable {
    /// `font-style`: italic/oblique → true, normal → false.
    public var italic: Bool?
    /// `font-weight`: bold/bolder/600+ → true, normal/lighter/<600 → false.
    public var bold: Bool?
    /// `text-align`: left/center/right/justify.
    public var alignment: TextAlignment?
    /// The inset heuristic: margin-left AND margin-right each at least
    /// 1em / 5% / 16px (the `margin:` shorthand contributes its side slots).
    /// Any margin declaration that fails the test resolves `false` — a later
    /// `margin: 0` must be able to cancel an earlier inset.
    public var inset: Bool?
    /// `display: none` or `visibility: hidden`.
    public var hidden: Bool?
    /// `font-variant` / `font-variant-caps`: `small-caps`.
    public var smallCaps: Bool?
    /// `vertical-align`: `super` → `.raised`, `sub` → `.lowered`,
    /// `baseline` → `.baseline` (so an inner rule can cancel an outer
    /// super/sub). Box-alignment values (top/middle/lengths/percentages)
    /// stay undeclared — they align table cells, not text runs.
    public var verticalAlign: VerticalAlign?
    /// `background-color` (or the `background` shorthand's colour slot).
    ///
    /// Books mark "this is what a highlight looks like" runs with it, and
    /// without it those runs rendered as plain body text (#47). A clear value
    /// is *declared*, not absent — that's how `transparent` cancels.
    public var background: CSSColor?
    /// `color` — the book's own text colour.
    ///
    /// Honoured **conditionally**, unlike every other fact here. A book picks
    /// its colours against its own page; Readr renders in paper, sepia, and
    /// dark, so a dark-blue heading that reads beautifully on cream would go
    /// invisible on the dark theme. The renderer therefore keeps this only
    /// when it clears `CSSColor.minimumReadableContrast` against the surface
    /// the run will really sit on — the highlight colour if there is one, the
    /// theme's page if not — and falls back to the theme's ink otherwise.
    ///
    /// Parsing it here is unconditional; the judgement lives at the point that
    /// knows the active theme.
    public var foreground: CSSColor?

    /// Text-run vertical alignment relative to the baseline.
    public enum VerticalAlign: Equatable, Sendable {
        case baseline
        /// `vertical-align: super` — footnote markers, ordinals.
        case raised
        /// `vertical-align: sub` — chemical formulas.
        case lowered
    }

    public init(
        italic: Bool? = nil, bold: Bool? = nil, alignment: TextAlignment? = nil,
        inset: Bool? = nil, hidden: Bool? = nil, smallCaps: Bool? = nil,
        verticalAlign: VerticalAlign? = nil, background: CSSColor? = nil,
        foreground: CSSColor? = nil
    ) {
        self.italic = italic
        self.bold = bold
        self.alignment = alignment
        self.inset = inset
        self.hidden = hidden
        self.smallCaps = smallCaps
        self.verticalAlign = verticalAlign
        self.background = background
        self.foreground = foreground
    }

    /// True when no fact is declared at all.
    public var isEmpty: Bool {
        italic == nil && bold == nil && alignment == nil
            && inset == nil && hidden == nil && smallCaps == nil
            && verticalAlign == nil && background == nil && foreground == nil
    }

    /// Overlay a higher-precedence source: its non-nil facts win, its nil
    /// facts leave the receiver untouched.
    public mutating func overlay(_ other: ResolvedStyle) {
        if let value = other.italic { italic = value }
        if let value = other.bold { bold = value }
        if let value = other.alignment { alignment = value }
        if let value = other.inset { inset = value }
        if let value = other.hidden { hidden = value }
        if let value = other.smallCaps { smallCaps = value }
        if let value = other.verticalAlign { verticalAlign = value }
        if let value = other.background { background = value }
        if let value = other.foreground { foreground = value }
    }
}

/// A minimal CSS subset engine for EPUB content documents.
///
/// Commercial EPUBs (InDesign/calibre exports) express nearly all formatting
/// through classes and stylesheets — italics as `<span class="char-override-1">`,
/// centered paragraphs as `<p class="center">`, insets as
/// `<div class="extract">`, hidden content via classes. This resolver parses
/// just enough CSS to recover those STRUCTURAL facts (never fonts or sizes) so
/// `XHTMLTextExtractor` can emit the same format spans it already produces for
/// presentational markup.
///
/// Colour is the exception to "never colours": some books *describe* their own
/// highlight styling and show an example of it, which rendered as plain prose
/// without it (#47). `background-color` is honoured outright;
/// `color` is honoured only where it stays readable against the reader's
/// active theme — see `ResolvedStyle.foreground`.
///
/// Supported selectors: `element`, `.class`, and `element.class` (single
/// class). Selectors containing whitespace, `>`, `+`, `~`, `:`, `[`, or `#`
/// are dropped — the other selectors in the same comma list still apply.
/// `*` and `body` element selectors are ignored entirely: book-wide font
/// defaults must not become per-element structure.
///
/// Hardening, in the spirit of the archive extraction caps: at most
/// `maxCSSBytes` of CSS text and `maxRules` rules per resolver. Past either
/// cap the resolver degrades to EMPTY — styles are an enhancement, never a
/// parse failure. Everything is O(input size).
public struct CSSStyleResolver: Sendable {
    /// Maximum total CSS text (across all composed sheets): 512 KB.
    public static let maxCSSBytes = 512 * 1024
    /// Maximum number of rules honored per resolver.
    public static let maxRules = 20_000

    /// Merged style per element name (lowercased), e.g. `"p"`.
    private var byElement: [String: ResolvedStyle] = [:]
    /// Merged style per class name (case-sensitive, as CSS classes are).
    private var byClass: [String: ResolvedStyle] = [:]
    /// Merged style per `element.class` pair, keyed `"p.center"`.
    private var byElementClass: [String: ResolvedStyle] = [:]

    private var totalBytes = 0
    private var ruleCount = 0
    /// Set once a cap trips; the resolver is emptied and stays empty.
    private var degraded = false

    public init() {}

    public init(css: String) {
        add(sheet: css)
    }

    /// Compose several sheets in order (linked sheets first, then `<style>`
    /// blocks — matching document cascade order).
    public init(sheets: [String]) {
        for sheet in sheets { add(sheet: sheet) }
    }

    /// True when no rule is stored (including after cap degradation).
    public var isEmpty: Bool {
        byElement.isEmpty && byClass.isEmpty && byElementClass.isEmpty
    }

    /// Whether any bare-element rule exists for `element` — the scanner's
    /// fast-path check for tags carrying no class/style attribute.
    public func hasElementRule(_ element: String) -> Bool {
        byElement[element] != nil
    }

    /// Resolve one element: element rule, then each class in attribute order
    /// (`.class` then `element.class` per class), then the inline `style`
    /// declarations — later sources overlay earlier ones, non-nil facts win.
    public func style(
        element: String, classAttr: String?, inlineStyle: String?
    ) -> ResolvedStyle {
        var resolved = byElement[element] ?? ResolvedStyle()
        if let classAttr {
            for token in classAttr.split(whereSeparator: \.isWhitespace) {
                let name = String(token)
                if let fragment = byClass[name] { resolved.overlay(fragment) }
                if let fragment = byElementClass[element + "." + name] {
                    resolved.overlay(fragment)
                }
            }
        }
        if let inlineStyle {
            resolved.overlay(Self.declarations(inlineStyle))
        }
        return resolved
    }

    // MARK: - Sheet parsing

    /// Parse one sheet's rules into the buckets. Exceeding a hard cap
    /// degrades the WHOLE resolver to empty (styles are an enhancement —
    /// never a reason to fail a book).
    public mutating func add(sheet css: String) {
        guard !degraded else { return }
        totalBytes += css.utf8.count
        guard totalBytes <= Self.maxCSSBytes else {
            degrade()
            return
        }
        let text = Self.strippingComments(css)
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let ch = text[i]
            // Stray "}" (over-closed block) and inter-rule whitespace: skip.
            if ch.isWhitespace || ch == "}" {
                i = text.index(after: i)
                continue
            }
            if ch == "@" {
                i = Self.skippingAtRule(text, from: i)
                continue
            }
            // Qualified rule: selector list up to "{", declarations to "}".
            // Brace scanning skips quoted strings — `content: "}"` must not
            // terminate the block.
            guard let braceOpen = Self.firstUnquotedIndex(of: "{", in: text, from: i) else {
                break // trailing selector garbage with no block
            }
            let selectorList = text[i..<braceOpen]
            let bodyStart = text.index(after: braceOpen)
            let braceClose = Self.firstUnquotedIndex(of: "}", in: text, from: bodyStart)
            // No close brace: CSS auto-closes open blocks at end of input.
            let body = text[bodyStart..<(braceClose ?? end)]
            i = braceClose.map { text.index(after: $0) } ?? end
            ruleCount += 1
            guard ruleCount <= Self.maxRules else {
                degrade()
                return
            }
            let fragment = Self.declarations(String(body))
            guard !fragment.isEmpty else { continue }
            for selector in selectorList.split(separator: ",") {
                insert(
                    selector: selector.trimmingCharacters(in: .whitespacesAndNewlines),
                    fragment: fragment
                )
            }
        }
    }

    private mutating func degrade() {
        byElement.removeAll()
        byClass.removeAll()
        byElementClass.removeAll()
        degraded = true
    }

    /// Skip an at-rule starting at `start` (which points at "@"): `@import` /
    /// `@charset` end at their semicolon; block at-rules (`@media`,
    /// `@font-face`, …) are skipped whole by brace matching — nothing inside
    /// them contributes rules.
    private static func skippingAtRule(_ text: String, from start: String.Index) -> String.Index {
        let end = text.endIndex
        var i = start
        while i < end, text[i] != ";", text[i] != "{" {
            i = text.index(after: i)
        }
        guard i < end else { return end }
        if text[i] == ";" { return text.index(after: i) }
        var depth = 0
        while i < end {
            if text[i] == "{" {
                depth += 1
            } else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return end
    }

    /// First occurrence of `target` in `text[start...]` OUTSIDE quoted
    /// strings. Single/double-quoted runs are skipped whole, honoring
    /// backslash escapes (`\"` does not close a string). An unterminated
    /// string swallows the rest of the input — the scan returns nil, and
    /// the caller's auto-close/degrade paths apply (never a hang: the index
    /// only ever moves forward).
    private static func firstUnquotedIndex(
        of target: Character, in text: String, from start: String.Index
    ) -> String.Index? {
        var i = start
        let end = text.endIndex
        while i < end {
            let ch = text[i]
            if ch == target { return i }
            if ch == "\"" || ch == "'" {
                i = text.index(after: i)
                while i < end, text[i] != ch {
                    if text[i] == "\\" {
                        // Skip the escaped character with the backslash.
                        i = text.index(after: i)
                        guard i < end else { return nil }
                    }
                    i = text.index(after: i)
                }
                guard i < end else { return nil } // unterminated string
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Remove `/* … */` comments in one pass. Quoted strings are copied
    /// verbatim — a `/*` inside `content: "/*"` is content, not a comment.
    /// An unterminated comment drops the rest of the sheet (matching CSS
    /// error recovery).
    static func strippingComments(_ css: String) -> String {
        guard css.contains("/*") else { return css }
        var out = ""
        out.reserveCapacity(css.count)
        var i = css.startIndex
        let end = css.endIndex
        while i < end {
            let ch = css[i]
            if ch == "/", css.index(after: i) < end, css[css.index(after: i)] == "*" {
                let bodyStart = css.index(i, offsetBy: 2)
                guard let close = css.range(of: "*/", range: bodyStart..<end) else { break }
                i = close.upperBound
                continue
            }
            if ch == "\"" || ch == "'" {
                // Copy the whole quoted run (with escapes) untouched.
                out.append(ch)
                i = css.index(after: i)
                while i < end {
                    let c = css[i]
                    out.append(c)
                    i = css.index(after: i)
                    if c == "\\" {
                        if i < end {
                            out.append(css[i])
                            i = css.index(after: i)
                        }
                        continue
                    }
                    if c == ch { break }
                }
                continue
            }
            out.append(ch)
            i = css.index(after: i)
        }
        return out
    }

    // MARK: - Selector filtering

    /// Characters that mark a selector as outside the supported subset
    /// (combinators, pseudo-classes, attribute/id parts, the universal
    /// selector). Whitespace is checked separately.
    private static let rejectedSelectorCharacters: Set<Character> = [
        ">", "+", "~", ":", "[", "#", "*",
    ]

    private mutating func insert(selector: String, fragment: ResolvedStyle) {
        guard !selector.isEmpty,
              !selector.contains(where: {
                  $0.isWhitespace || Self.rejectedSelectorCharacters.contains($0)
              }) else { return }
        if let dot = selector.firstIndex(of: ".") {
            let className = String(selector[selector.index(after: dot)...])
            // Single class only: ".a.b" / "p.a.b" leave the subset.
            guard !className.isEmpty, !className.contains(".") else { return }
            let element = String(selector[..<dot]).lowercased()
            if element.isEmpty {
                byClass[className, default: ResolvedStyle()].overlay(fragment)
            } else {
                guard Self.isElementName(element) else { return }
                byElementClass[element + "." + className, default: ResolvedStyle()]
                    .overlay(fragment)
            }
        } else {
            let element = selector.lowercased()
            // `body` (like `*`, rejected above) styles the whole document —
            // book-wide fonts must not become per-element structure.
            guard element != "body", Self.isElementName(element) else { return }
            byElement[element, default: ResolvedStyle()].overlay(fragment)
        }
    }

    private static func isElementName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Declarations

    /// Parse a declaration list (a rule body or an inline `style` attribute)
    /// into the facts this engine models. Unknown properties are skipped;
    /// a trailing `!important` is stripped and otherwise ignored.
    static func declarations(_ text: String) -> ResolvedStyle {
        var style = ResolvedStyle()
        // Side-margin "big enough?" verdicts, filled by the longhands and the
        // `margin:` shorthand slots; folded into `inset` at the end.
        var marginLeftBig: Bool?
        var marginRightBig: Bool?
        for declaration in text.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let bang = value.range(
                of: "!\\s*important\\s*$", options: [.regularExpression]
            ) {
                value = String(value[..<bang.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { continue }
            switch property {
            case "font-style":
                if value.hasPrefix("italic") || value.hasPrefix("oblique") {
                    style.italic = true
                } else if value == "normal" {
                    style.italic = false
                }
            case "font-weight":
                if let bold = boldWeight(value) { style.bold = bold }
            case "text-align":
                if let keyword = value.split(whereSeparator: \.isWhitespace).first,
                   let alignment = TextAlignment(rawValue: String(keyword)) {
                    style.alignment = alignment
                }
            case "margin-left":
                marginLeftBig = isBigMargin(value)
            case "margin-right":
                marginRightBig = isBigMargin(value)
            case "margin":
                let slots = value.split(whereSeparator: \.isWhitespace).map(String.init)
                switch slots.count {
                case 1:
                    marginLeftBig = isBigMargin(slots[0])
                    marginRightBig = marginLeftBig
                case 2, 3:
                    // top | left+right (| bottom)
                    marginRightBig = isBigMargin(slots[1])
                    marginLeftBig = marginRightBig
                case 4:
                    // top | right | bottom | left
                    marginRightBig = isBigMargin(slots[1])
                    marginLeftBig = isBigMargin(slots[3])
                default:
                    break
                }
            case "color":
                if let color = color(value) { style.foreground = color }
            case "background-color":
                if let color = color(value) { style.background = color }
            case "background":
                if let color = shorthandColor(in: value) { style.background = color }
            case "display":
                style.hidden = value.hasPrefix("none")
            case "visibility":
                if value.hasPrefix("hidden") || value.hasPrefix("collapse") {
                    style.hidden = true
                } else if value.hasPrefix("visible") {
                    style.hidden = false
                }
            case "font-variant", "font-variant-caps":
                if value.split(whereSeparator: \.isWhitespace).contains("small-caps") {
                    style.smallCaps = true
                } else if value == "normal" {
                    style.smallCaps = false
                }
            case "vertical-align":
                // Only the text-run keywords map; box-alignment values
                // (top/middle/bottom/lengths/percentages) align table cells
                // and stay undeclared. `baseline` is declared explicitly so
                // an inner rule can cancel an outer super/sub.
                switch value {
                case "super": style.verticalAlign = .raised
                case "sub": style.verticalAlign = .lowered
                case "baseline": style.verticalAlign = .baseline
                default: break
                }
            case "text-indent":
                // Parsed (recognized) but IGNORED for v1: FormatSpan has no
                // first-line-indent kind. Listed so it never reads as an
                // accidentally "unknown" property.
                break
            default:
                break
            }
        }
        if marginLeftBig != nil || marginRightBig != nil {
            style.inset = marginLeftBig == true && marginRightBig == true
        }
        return style
    }

    /// `font-weight` → bold?: keywords, or the numeric 600+ threshold.
    /// Unmappable values (`inherit`, `revert`, …) contribute nothing.
    /// Parses the colour notations EPUB stylesheets actually use: `#rgb`,
    /// `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` with numbers or percentages,
    /// and the CSS named colours. Anything else — `inherit`, `currentColor`,
    /// `url(…)`, a malformed hex — returns nil rather than guessing, leaving
    /// the property undeclared so the cascade is unaffected.
    static func color(_ raw: String) -> CSSColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        // `transparent` is a real colour keyword; `none` is not one (it is the
        // background-*image* slot of the shorthand) and must stay undeclared
        // rather than register as a declared-but-clear colour in the cascade.
        if value == "transparent" {
            return CSSColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        if let named = namedColors[value] { return named }
        if value.hasPrefix("#") { return hexColor(String(value.dropFirst())) }
        if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
            return functionalColor(value)
        }
        return nil
    }

    /// The colour slot of a `background` shorthand.
    ///
    /// Splitting the value on whitespace and testing each slot looks
    /// sufficient and isn't: `background: rgba(255, 235, 59, 0.6)` is a single
    /// colour containing spaces, so every slot is a fragment and the whole
    /// declaration parses as nothing — silently dropping exactly the highlight
    /// this feature exists to show (#47). Functional notation is lifted out
    /// whole, by balanced parenthesis, before the slot scan runs.
    static func shorthandColor(in value: String) -> CSSColor? {
        if let open = value.range(of: "rgba(") ?? value.range(of: "rgb(") {
            var depth = 0
            var index = open.lowerBound
            while index < value.endIndex {
                if value[index] == "(" { depth += 1 }
                if value[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        let function = value[open.lowerBound...index]
                        if let color = self.color(String(function)) { return color }
                        break
                    }
                }
                index = value.index(after: index)
            }
        }
        // `#fff`, a named colour, or `none` — the remaining slots.
        for slot in value.split(whereSeparator: \.isWhitespace) {
            if let color = self.color(String(slot)) { return color }
        }
        return nil
    }

    private static func hexColor(_ digits: String) -> CSSColor? {
        func component(_ slice: Substring) -> Double? {
            // `UInt8(_:radix:)` accepts a leading sign, so "#+f0f0f" would
            // otherwise parse as a colour.
            guard slice.allSatisfy(\.isHexDigit),
                  let value = UInt8(slice, radix: 16) else { return nil }
            return Double(value) / 255
        }
        // #rgb / #rgba expand each digit: f → ff.
        let expanded: String
        switch digits.count {
        case 3, 4:
            expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = digits
        default:
            return nil
        }
        let characters = Array(expanded)
        func pair(_ index: Int) -> Substring {
            expanded[
                expanded.index(expanded.startIndex, offsetBy: index)
                ..< expanded.index(expanded.startIndex, offsetBy: index + 2)
            ]
        }
        guard characters.count >= 6,
              let red = component(pair(0)),
              let green = component(pair(2)),
              let blue = component(pair(4))
        else { return nil }
        let alpha = characters.count == 8 ? component(pair(6)) : 1
        guard let alpha else { return nil }
        return CSSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func functionalColor(_ value: String) -> CSSColor? {
        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"), open < close
        else { return nil }
        // Both comma and space separated forms are legal CSS.
        let arguments = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard arguments.count == 3 || arguments.count == 4 else { return nil }

        func channel(_ text: String) -> Double? {
            if text.hasSuffix("%") {
                guard let percent = Double(text.dropLast()) else { return nil }
                return min(max(percent / 100, 0), 1)
            }
            guard let number = Double(text) else { return nil }
            return min(max(number / 255, 0), 1)
        }
        guard let red = channel(arguments[0]),
              let green = channel(arguments[1]),
              let blue = channel(arguments[2])
        else { return nil }

        var alpha = 1.0
        if arguments.count == 4 {
            let text = arguments[3]
            if text.hasSuffix("%") {
                guard let percent = Double(text.dropLast()) else { return nil }
                alpha = min(max(percent / 100, 0), 1)
            } else {
                guard let number = Double(text) else { return nil }
                alpha = min(max(number, 0), 1)
            }
        }
        return CSSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The CSS named colours that turn up in book stylesheets. Not the full
    /// 148-entry table — the long tail is vanishingly rare in EPUBs, and an
    /// unrecognised name leaves the property undeclared, which is safe.
    private static let namedColors: [String: CSSColor] = {
        func rgb(_ red: Int, _ green: Int, _ blue: Int) -> CSSColor {
            CSSColor(
                red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255
            )
        }
        return [
            "black": rgb(0, 0, 0), "silver": rgb(192, 192, 192),
            "gray": rgb(128, 128, 128), "grey": rgb(128, 128, 128),
            "white": rgb(255, 255, 255), "maroon": rgb(128, 0, 0),
            "red": rgb(255, 0, 0), "purple": rgb(128, 0, 128),
            "fuchsia": rgb(255, 0, 255), "magenta": rgb(255, 0, 255),
            "green": rgb(0, 128, 0), "lime": rgb(0, 255, 0),
            "olive": rgb(128, 128, 0), "yellow": rgb(255, 255, 0),
            "navy": rgb(0, 0, 128), "blue": rgb(0, 0, 255),
            "teal": rgb(0, 128, 128), "aqua": rgb(0, 255, 255),
            "cyan": rgb(0, 255, 255), "orange": rgb(255, 165, 0),
            "gold": rgb(255, 215, 0), "pink": rgb(255, 192, 203),
            "beige": rgb(245, 245, 220), "ivory": rgb(255, 255, 240),
            "khaki": rgb(240, 230, 140), "lavender": rgb(230, 230, 250),
            "lightyellow": rgb(255, 255, 224), "lightgray": rgb(211, 211, 211),
            "lightgrey": rgb(211, 211, 211), "whitesmoke": rgb(245, 245, 245),
        ]
    }()

    private static func boldWeight(_ value: String) -> Bool? {
        switch value {
        case "bold", "bolder": return true
        case "normal", "lighter": return false
        default:
            guard let number = Double(value) else { return nil }
            return number >= 600
        }
    }

    /// The inset threshold for one margin side: at least 1em/1rem, 5%, or
    /// 16px. `auto`, zero, unknown units, and negatives all fail it.
    private static func isBigMargin(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        // "rem" before "em": hasSuffix("em") would also match "2rem".
        let thresholds: [(suffix: String, minimum: Double)] = [
            ("rem", 1), ("em", 1), ("%", 5), ("px", 16),
        ]
        for (suffix, minimum) in thresholds where value.hasSuffix(suffix) {
            let number = String(value.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespaces)
            return Double(number).map { $0 >= minimum } ?? false
        }
        return false
    }
}
