import Foundation

/// Extracts readable text from an EPUB XHTML content document. Tolerant of
/// minor markup quirks (a scanning pass rather than strict XML parsing) so a
/// slightly malformed chapter still yields text.
///
/// `extract(from:)` is the full-fidelity entry point: a single pass over the
/// markup produces the normalized text PLUS format spans (headings, bold,
/// italic, blockquotes, links), an anchors map (element id → offset), inline
/// image refs with display-size hints, and list-item markers. All offsets are
/// character offsets into the FINAL normalized text.
public enum XHTMLTextExtractor {

    /// Tags whose open AND close boundaries become paragraph breaks.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "section", "article", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// Container tags whose entire contents are non-content and get dropped.
    /// `rt`/`rp` hold ruby phonetic annotations — keeping them would duplicate
    /// the annotated base text in the extracted prose.
    private static let nonContentTags: Set<String> = ["script", "style", "head", "rt", "rp"]

    /// The placeholder each `<img>` becomes in extracted text: U+FFFC OBJECT
    /// REPLACEMENT CHARACTER — the same character `NSAttributedString` uses for
    /// attachments, so renderers can attach the image in place and every other
    /// layer (highlights, pagination) just sees one ordinary character.
    public static let imagePlaceholder: Character = "\u{FFFC}"

    /// An inline image reference found in a content document, in document order.
    public struct InlineImageRef: Equatable, Sendable {
        /// The raw `src` attribute (relative to the document; not yet resolved).
        public var src: String
        public var alt: String?
        /// Intended display width/height in CSS pixels, from `width=`/`height=`
        /// attributes or a `style="width: NNpx"` declaration. Percentages and
        /// non-pixel units yield nil.
        public var displayWidth: Double?
        public var displayHeight: Double?

        public init(
            src: String, alt: String? = nil,
            displayWidth: Double? = nil, displayHeight: Double? = nil
        ) {
            self.src = src
            self.alt = alt
            self.displayWidth = displayWidth
            self.displayHeight = displayHeight
        }
    }

    /// A formatting run over the extracted text, half-open `[start, end)` in
    /// character offsets. Links carry the RAW href from the markup — the EPUB
    /// parser resolves it against the chapter document's location.
    public struct Span: Equatable, Sendable {
        public var start: Int
        public var end: Int
        public var kind: Kind

        public enum Kind: Equatable, Sendable {
            case heading(Int)
            case bold
            case italic
            case blockquote
            case link(href: String)
        }
    }

    /// Everything one pass over a content document yields.
    public struct ExtractionResult: Sendable {
        public var text: String
        public var images: [InlineImageRef]
        /// Document (open-tag) order; spans may nest and overlap.
        public var spans: [Span]
        /// Element id → character offset of the following content.
        public var anchors: [String: Int]
    }

    /// Full-fidelity extraction: text, images, format spans, anchors.
    public static func extract(from html: String) -> ExtractionResult {
        Scanner(html: html).run()
    }

    /// Plain text with paragraph breaks preserved (legacy convenience). Images
    /// are dropped entirely — no placeholder — matching the historical
    /// behavior of this path.
    public static func text(from html: String) -> String {
        Scanner(html: html, includeImages: false).run().text
    }

    /// Like `text(from:)`, but each `<img>` becomes `imagePlaceholder` in the
    /// text, and the images' refs are returned in document order — the k-th
    /// placeholder in the text corresponds to `images[k]`.
    public static func textAndImages(from html: String) -> (text: String, images: [InlineImageRef]) {
        let result = extract(from: html)
        return (result.text, result.images)
    }

    // MARK: - Single-pass scanner

    /// One left-to-right pass over the markup. Text is normalized as it is
    /// emitted (entity decoding, space/tab collapsing, block breaks, edge
    /// trimming), so every recorded offset indexes the final text directly.
    private final class Scanner {
        private let html: String
        /// When false, `<img>` contributes neither a placeholder nor a ref
        /// (the legacy `text(from:)` behavior).
        private let includeImages: Bool
        /// Final text, built as characters so offsets are character offsets.
        private var out: [Character] = []

        // Pending whitespace: emitted lazily before the next content character
        // so runs collapse and trailing whitespace never materializes.
        private var pendingSpace = false
        private var pendingNewline = false
        /// A list-item marker ("• " / "N. ") awaiting the item's first content
        /// character; discarded if the item turns out to be empty.
        private var pendingPrefix: [Character]?

        /// All spans in open order. `start` is nil until the first content
        /// character after the open tag resolves it; nil at the end means the
        /// element never had content and the span is dropped.
        private struct WorkingSpan {
            /// Canonical open-tag key (`b` for b/strong, `i` for i/em, …).
            let tag: String
            let kind: Span.Kind
            var start: Int?
            var end: Int?
        }
        private var working: [WorkingSpan] = []
        /// Indices into `working` of spans not yet closed.
        private var openStack: [Int] = []
        /// Indices into `working` whose `start` awaits the next content char.
        /// A Set: a run of contentless formatting tags (page-map files hold
        /// thousands) must not make membership checks quadratic.
        private var unresolvedStarts: Set<Int> = []

        private var anchors: [String: Int] = [:]
        /// Ids awaiting the next content character for their offset. A Set
        /// for the same reason as `unresolvedStarts` — real page-list files
        /// carry thousands of consecutive empty `id` spans.
        private var unresolvedAnchors: Set<String> = []

        private var images: [InlineImageRef] = []

        /// Open lists, innermost last; `count` is the 1-based item counter.
        private var listStack: [(ordered: Bool, count: Int)] = []

        init(html: String, includeImages: Bool = true) {
            self.html = html
            self.includeImages = includeImages
        }

        func run() -> ExtractionResult {
            var i = html.startIndex
            let end = html.endIndex
            while i < end {
                if html[i] == "<" {
                    if html[i...].hasPrefix("<!--") {
                        let bodyStart = html.index(i, offsetBy: 4)
                        // HTML5 abruptly-closed comments: `<!-->` / `<!--->`.
                        if html[bodyStart...].hasPrefix(">") {
                            i = html.index(after: bodyStart)
                        } else if html[bodyStart...].hasPrefix("->") {
                            i = html.index(bodyStart, offsetBy: 2)
                        } else if let close = html.range(of: "-->", range: bodyStart..<end) {
                            i = close.upperBound
                        } else if let gt = html[bodyStart..<end].firstIndex(of: ">") {
                            // Unterminated comment (typo'd `->` etc. with no
                            // later `-->`): recover at the first `>` — the old
                            // stripping passes did — instead of silently
                            // swallowing the whole rest of the chapter.
                            i = html.index(after: gt)
                        } else {
                            i = end
                        }
                        continue
                    }
                    guard let gt = html[i..<end].firstIndex(of: ">") else {
                        // No closing ">" anywhere: a literal "<" in sloppy text.
                        emitContent("<")
                        i = html.index(after: i)
                        continue
                    }
                    let tagContent = html[html.index(after: i)..<gt]
                    i = html.index(after: gt)
                    handleTag(tagContent, resumeAt: &i)
                } else {
                    let next = html[i..<end].firstIndex(of: "<") ?? end
                    feedText(decodeEntities(String(html[i..<next])))
                    i = next
                }
            }
            return finalize()
        }

        // MARK: Text emission

        /// Route decoded text through the whitespace normalizer: space/tab
        /// become a pending (collapsing) space, newlines a pending paragraph
        /// break, everything else is content.
        private func feedText(_ decoded: String) {
            for ch in decoded {
                switch ch {
                case " ", "\t":
                    pendingSpace = true
                case "\n", "\r":
                    pendingNewline = true
                default:
                    emitContent(ch)
                }
            }
        }

        /// Emit one content character: flush pending whitespace (suppressed at
        /// the very start of the text), flush any list-item marker, resolve
        /// waiting span starts and anchors to the character's offset.
        private func emitContent(_ ch: Character) {
            if out.isEmpty, ch.isWhitespace {
                // Exotic leading whitespace (raw NBSP etc.) — trimmed, like the
                // final edge trim always did.
                pendingSpace = false
                pendingNewline = false
                return
            }
            if pendingNewline {
                if !out.isEmpty { out.append("\n") }
                pendingNewline = false
                pendingSpace = false
            } else if pendingSpace {
                if !out.isEmpty { out.append(" ") }
                pendingSpace = false
            }
            if let prefix = pendingPrefix {
                out.append(contentsOf: prefix)
                pendingPrefix = nil
            }
            if !unresolvedStarts.isEmpty {
                for index in unresolvedStarts { working[index].start = out.count }
                unresolvedStarts.removeAll(keepingCapacity: true)
            }
            if !unresolvedAnchors.isEmpty {
                for id in unresolvedAnchors { anchors[id] = out.count }
                unresolvedAnchors.removeAll(keepingCapacity: true)
            }
            out.append(ch)
        }

        // MARK: Tags

        private func handleTag(_ content: Substring, resumeAt i: inout String.Index) {
            // Doctype, processing instructions, CDATA — non-content markup.
            guard let first = content.first, first != "!", first != "?" else { return }

            var body = content
            var isClosing = false
            if body.hasPrefix("/") {
                isClosing = true
                body = body.dropFirst()
            }
            let selfClosing = body.hasSuffix("/")

            var nameEnd = body.startIndex
            while nameEnd < body.endIndex, !body[nameEnd].isWhitespace, body[nameEnd] != "/" {
                nameEnd = body.index(after: nameEnd)
            }
            let qualified = String(body[..<nameEnd]).lowercased()
            // Namespaced tags (<epub:switch>) match on their local name.
            let name = qualified.split(separator: ":").last.map(String.init) ?? qualified
            guard let head = name.first, head.isLetter else { return }

            if isClosing {
                handleCloseTag(name)
            } else {
                handleOpenTag(
                    name, tagMarkup: "<" + content + ">",
                    hasAttributes: nameEnd < body.endIndex,
                    selfClosing: selfClosing, resumeAt: &i
                )
                if selfClosing { handleSelfClose(name) }
            }
        }

        private func handleOpenTag(
            _ name: String, tagMarkup: String, hasAttributes: Bool,
            selfClosing: Bool, resumeAt i: inout String.Index
        ) {
            // id="…" on ANY element feeds the anchors map (first id wins).
            if hasAttributes, tagMarkup.contains("id"),
               let id = XHTMLTextExtractor.attribute("id", in: tagMarkup), !id.isEmpty,
               anchors[id] == nil {
                unresolvedAnchors.insert(id)
            }

            if XHTMLTextExtractor.nonContentTags.contains(name), !selfClosing {
                skipNonContent(name, resumeAt: &i)
                return
            }

            if name == "img" {
                if includeImages, hasAttributes,
                   let src = XHTMLTextExtractor.attribute("src", in: tagMarkup), !src.isEmpty {
                    images.append(InlineImageRef(
                        src: src,
                        alt: XHTMLTextExtractor.attribute("alt", in: tagMarkup),
                        displayWidth: XHTMLTextExtractor.displaySize("width", in: tagMarkup),
                        displayHeight: XHTMLTextExtractor.displaySize("height", in: tagMarkup)
                    ))
                    emitContent(XHTMLTextExtractor.imagePlaceholder)
                }
                return
            }

            if XHTMLTextExtractor.blockTags.contains(name) {
                pendingNewline = true
            }

            switch name {
            case "ul":
                listStack.append((ordered: false, count: 0))
            case "ol":
                listStack.append((ordered: true, count: 0))
            case "li":
                if listStack.isEmpty {
                    pendingPrefix = Array("• ")
                } else {
                    listStack[listStack.count - 1].count += 1
                    let top = listStack[listStack.count - 1]
                    pendingPrefix = top.ordered ? Array("\(top.count). ") : Array("• ")
                }
            default:
                break
            }

            guard !selfClosing else { return }
            if let (tag, kind) = spanKind(name, tagMarkup: tagMarkup, hasAttributes: hasAttributes) {
                let index = working.count
                working.append(WorkingSpan(tag: tag, kind: kind, start: nil, end: nil))
                openStack.append(index)
                unresolvedStarts.insert(index)
            }
        }

        private func handleCloseTag(_ name: String) {
            switch name {
            case "td", "th":
                // A space between cells keeps rows readable once the markup
                // is gone ("Name Age", not "NameAge"); </tr> makes the line.
                pendingSpace = true
            case "ul", "ol":
                if !listStack.isEmpty { listStack.removeLast() }
                pendingPrefix = nil
            default:
                break
            }
            if XHTMLTextExtractor.blockTags.contains(name) {
                pendingNewline = true
                if name == "li" { pendingPrefix = nil }
            }
            if let key = spanTagKey(name) {
                closeSpan(key)
            }
        }

        /// Effects of `<tag/>`: a self-closed formatting element is
        /// necessarily empty (no span opens), and a self-closed list or item
        /// must not leak list state past itself.
        private func handleSelfClose(_ name: String) {
            switch name {
            case "ul", "ol":
                if !listStack.isEmpty { listStack.removeLast() }
                pendingPrefix = nil
            case "li":
                pendingPrefix = nil
            default:
                break
            }
        }

        // MARK: Spans

        /// The canonical span key for a formatting tag (b/strong share one key
        /// so sloppy `<b>…</strong>` pairs still close), or nil for tags that
        /// don't open spans.
        private func spanTagKey(_ name: String) -> String? {
            switch name {
            case "b", "strong": return "b"
            case "i", "em": return "i"
            case "blockquote": return "blockquote"
            case "a": return "a"
            case "h1", "h2", "h3", "h4", "h5", "h6": return name
            default: return nil
            }
        }

        private func spanKind(
            _ name: String, tagMarkup: String, hasAttributes: Bool
        ) -> (tag: String, kind: Span.Kind)? {
            guard let key = spanTagKey(name) else { return nil }
            switch key {
            case "b": return (key, .bold)
            case "i": return (key, .italic)
            case "blockquote": return (key, .blockquote)
            case "a":
                guard hasAttributes,
                      let href = XHTMLTextExtractor.attribute("href", in: tagMarkup),
                      !href.isEmpty else { return nil }
                return (key, .link(href: href))
            default:
                guard let level = Int(name.dropFirst()), (1...6).contains(level) else { return nil }
                return (key, .heading(level))
            }
        }

        private func closeSpan(_ key: String) {
            var stackPosition = openStack.lastIndex(where: { working[$0].tag == key })
            if stackPosition == nil, key.count == 2, key.hasPrefix("h") {
                // Mismatched heading close (`<h1>…</h2>`): close the most
                // recent open heading of ANY level rather than leaving it
                // open to the end of the document — an unterminated heading
                // span would style the whole rest of the chapter.
                stackPosition = openStack.lastIndex(where: {
                    if case .heading = working[$0].kind { return true }
                    return false
                })
            }
            guard let stackPosition else {
                return // Stray close tag — tolerate.
            }
            let index = openStack.remove(at: stackPosition)
            if unresolvedStarts.remove(index) == nil {
                working[index].end = out.count
            }
            // else: closed before any content — the span stays start-less and
            // is dropped at finalize.
        }

        // MARK: Non-content skipping

        /// Skip everything up to (and including) `</name>`. When the close tag
        /// is missing, skip nothing — the old stripping passes left unclosed
        /// non-content blocks in place, and degrading the same way beats
        /// silently losing the rest of the chapter.
        private func skipNonContent(_ name: String, resumeAt i: inout String.Index) {
            let closeToken = "</" + name
            var search = i
            while search < html.endIndex,
                  let match = html.range(
                      of: closeToken, options: .caseInsensitive, range: search..<html.endIndex
                  ) {
                let after = match.upperBound
                // Boundary check so "</head" doesn't match "</header".
                if after == html.endIndex {
                    i = html.endIndex
                    return
                }
                let boundary = html[after]
                if boundary == ">" || boundary == "/" || boundary.isWhitespace {
                    if let gt = html[after...].firstIndex(of: ">") {
                        i = html.index(after: gt)
                    } else {
                        i = html.endIndex
                    }
                    return
                }
                search = html.index(after: match.lowerBound)
            }
            // No close tag: leave `i` where it is and process the contents.
        }

        // MARK: Finish

        private func finalize() -> ExtractionResult {
            // Unclosed elements end at the document's end.
            for index in openStack where !unresolvedStarts.contains(index) {
                if working[index].end == nil { working[index].end = out.count }
            }
            // Trailing edge trim (leading trim happened during emission).
            while let last = out.last, last.isWhitespace {
                out.removeLast()
            }
            let length = out.count
            var spans: [Span] = []
            spans.reserveCapacity(working.count)
            for span in working {
                guard let start = span.start else { continue }
                let end = min(span.end ?? length, length)
                guard start < end else { continue }
                spans.append(Span(start: start, end: end, kind: span.kind))
            }
            // Ids that never saw content resolve to the end of the text.
            for id in unresolvedAnchors where anchors[id] == nil {
                anchors[id] = length
            }
            for (id, offset) in anchors where offset > length {
                anchors[id] = length
            }
            return ExtractionResult(
                text: String(out), images: images, spans: spans, anchors: anchors
            )
        }

        private func decodeEntities(_ s: String) -> String {
            XHTMLTextExtractor.decodeEntities(s)
        }
    }

    // MARK: - Attributes

    /// Value of an HTML attribute inside a single tag string. The name is
    /// anchored on its left so it can't match as the suffix of another
    /// attribute (asking for `src` must not match `data-src`).
    /// Compiled once per attribute name — `attribute` runs for every tag of a
    /// chapter (id scan), so per-call `String.range(of:.regularExpression)`
    /// compilation dominates extraction time on element-dense files.
    private static let attributeRegexes: [String: NSRegularExpression] = {
        var regexes: [String: NSRegularExpression] = [:]
        for name in ["id", "src", "alt", "href", "style", "width", "height"] {
            regexes[name] = try? NSRegularExpression(
                pattern: "(?<![\\w-])\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')",
                options: [.caseInsensitive]
            )
        }
        return regexes
    }()

    static func attribute(_ name: String, in tag: String) -> String? {
        let ns = tag as NSString
        let match: NSRange
        if let regex = attributeRegexes[name] {
            guard let found = regex.firstMatch(
                in: tag, range: NSRange(location: 0, length: ns.length)
            ) else { return nil }
            match = found.range
        } else {
            guard let range = tag.range(
                of: "(?<![\\w-])\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')",
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            match = NSRange(range, in: tag)
        }
        let pair = ns.substring(with: match)
        guard let quoteStart = pair.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let value = pair[pair.index(after: quoteStart)..<pair.index(before: pair.endIndex)]
        return decodeEntities(String(value))
    }

    /// The intended display size (CSS px) for one dimension of an `<img>` tag.
    /// An inline `style` declaration wins over the presentational attribute
    /// (matching CSS precedence at render time); percentages and non-pixel
    /// units mean "no fixed pixel intent" and yield nil.
    static func displaySize(_ dimension: String, in tagMarkup: String) -> Double? {
        if let style = attribute("style", in: tagMarkup),
           let declared = styleValue(dimension, in: style) {
            return cssPixels(declared)
        }
        if let attr = attribute(dimension, in: tagMarkup) {
            return cssPixels(attr)
        }
        return nil
    }

    /// The raw value of `width:`/`height:` in an inline style string, if
    /// declared. Anchored so `max-width`/`line-height` don't match.
    private static func styleValue(_ property: String, in style: String) -> String? {
        guard let range = style.range(
            of: "(?<![\\w-])\(property)\\s*:\\s*([^;]+)",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let declaration = style[range]
        guard let colon = declaration.firstIndex(of: ":") else { return nil }
        return String(declaration[declaration.index(after: colon)...])
    }

    /// Parse a CSS-pixel measure: "120", "120px", "20.5px". Anything else
    /// (percentages, em/rem, keywords) yields nil.
    private static func cssPixels(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("px") {
            value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, let number = Double(value), number > 0, number.isFinite else {
            return nil
        }
        return number
    }

    // MARK: - Headings (legacy title helper)

    /// First heading (`<h1>`…`<h6>`) text, for use as a chapter title.
    public static func firstHeading(from html: String) -> String? {
        guard let match = html.range(
            of: "<h[1-6][^>]*>(.*?)</h[1-6]>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let inner = html[match]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let title = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Entities

    /// Compiled once — `decodeEntities` runs per text run during scanning.
    private static let entityRegex = try? NSRegularExpression(
        pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);"
    )

    /// Decodes HTML character references — named and numeric — in one
    /// left-to-right pass. Single-pass matters for two reasons: it's linear on
    /// very large chapters (one scan, not one per entity), and it makes
    /// double-escaping correct by construction — `&amp;lt;` decodes the
    /// `&amp;` and then treats the following `lt;` as literal text, yielding
    /// `&lt;` rather than `<`. Unknown references are left intact.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"), let regex = entityRegex else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range(at: 1))
            if token.hasPrefix("#") {
                let digits = token.dropFirst()
                let scalarValue: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits, radix: 10)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    result += String(scalar)
                } else {
                    result += ns.substring(with: match.range)
                }
            } else if let replacement = namedEntities[token] {
                result += replacement
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }

    /// Named HTML entities seen in real EPUBs: the XML five, Latin-1
    /// (typography, symbols, accented letters), and the common HTML 4
    /// typographic set. Zero-width/soft-hyphen entities map to "" and the
    /// space-like entities to a plain space — extracted text is plain prose,
    /// so invisible layout characters only get in the way of search and
    /// highlighting.
    private static let namedEntities: [String: String] = [
        // XML core
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        // Spaces and invisibles
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "shy": "", "zwnj": "", "zwj": "",
        // Dashes, quotes, ellipsis
        "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "sbquo": "‚", "bdquo": "„", "prime": "′", "Prime": "″",
        "lsaquo": "‹", "rsaquo": "›", "laquo": "«", "raquo": "»",
        // Symbols and punctuation
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "minus": "−", "middot": "·",
        "bull": "•", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "sect": "§", "para": "¶", "micro": "µ", "not": "¬",
        "cent": "¢", "pound": "£", "yen": "¥", "euro": "€", "curren": "¤",
        "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³", "ordf": "ª", "ordm": "º",
        "iexcl": "¡", "iquest": "¿", "brvbar": "¦", "uml": "¨",
        "acute": "´", "cedil": "¸", "macr": "¯", "fnof": "ƒ",
        "oline": "‾", "frasl": "⁄", "infin": "∞", "ne": "≠", "le": "≤",
        "ge": "≥", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "harr": "↔",
        // Latin-1 letters, uppercase
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã",
        "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç",
        "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï",
        "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "THORN": "Þ",
        // Latin-1 letters, lowercase
        "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â",
        "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê",
        "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î",
        "iuml": "ï", "eth": "ð", "ntilde": "ñ", "ograve": "ò",
        "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö",
        "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û",
        "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
        // Ligatures and modifiers
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
        "Yuml": "Ÿ", "circ": "ˆ", "tilde": "˜",
    ]
}
