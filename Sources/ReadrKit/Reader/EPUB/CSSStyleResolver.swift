import Foundation

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
        verticalAlign: VerticalAlign? = nil
    ) {
        self.italic = italic
        self.bold = bold
        self.alignment = alignment
        self.inset = inset
        self.hidden = hidden
        self.smallCaps = smallCaps
        self.verticalAlign = verticalAlign
    }

    /// True when no fact is declared at all.
    public var isEmpty: Bool {
        italic == nil && bold == nil && alignment == nil
            && inset == nil && hidden == nil && smallCaps == nil
            && verticalAlign == nil
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
    }
}

/// A minimal CSS subset engine for EPUB content documents.
///
/// Commercial EPUBs (InDesign/calibre exports) express nearly all formatting
/// through classes and stylesheets — italics as `<span class="char-override-1">`,
/// centered paragraphs as `<p class="center">`, insets as
/// `<div class="extract">`, hidden content via classes. This resolver parses
/// just enough CSS to recover those STRUCTURAL facts (never fonts, colors, or
/// sizes) so `XHTMLTextExtractor` can emit the same format spans it already
/// produces for presentational markup.
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
