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
        "aside", "figure", "figcaption", "table", "caption", "dt", "dd",
        "hr", "pre", "center",
    ]

    /// Container tags whose entire contents are non-content and get dropped.
    /// `rt`/`rp` hold ruby phonetic annotations — keeping them would duplicate
    /// the annotated base text in the extracted prose. `title`/`desc` are the
    /// SVG accessibility elements (the HTML `<title>` already falls inside the
    /// skipped `<head>`), and `<template>` contents are inert by definition.
    private static let nonContentTags: Set<String> = [
        "script", "style", "head", "rt", "rp", "template", "title", "desc",
    ]

    /// HTML void elements (plus SVG `<image>`): they never have a close tag,
    /// so a hidden-region diversion must not wait for one.
    private static let voidTags: Set<String> = [
        "img", "image", "br", "hr", "meta", "link", "input", "col", "area",
        "base", "embed", "source", "track", "wbr",
    ]

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
            case superscript
            case `subscript`
            /// Paragraph-level alignment recovered from inline markup
            /// (`<center>`, `align="…"`, `style="text-align:…"`) or, when a
            /// `CSSStyleResolver` is supplied, from class/element rules.
            case alignment(TextAlignment)
            /// Small-caps run (CSS `font-variant: small-caps`, via class or
            /// element stylesheet rules).
            case smallCaps
        }
    }

    /// A footnote/endnote body diverted out of the main text: the element's
    /// id (the fragment a noteref link resolves to) plus its extracted text,
    /// normalized the same way as the main text.
    public struct ExtractedFootnote: Equatable, Sendable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
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
        /// Note bodies (footnote/endnote asides, `hidden` elements) lifted
        /// OUT of `text`, in document order.
        public var footnotes: [ExtractedFootnote]
    }

    /// Full-fidelity extraction: text, images, format spans, anchors.
    public static func extract(from html: String) -> ExtractionResult {
        Scanner(html: html).run()
    }

    /// Full-fidelity extraction with a stylesheet resolver: class and element
    /// CSS rules additionally contribute italic/bold/inset/alignment/
    /// small-caps spans and hidden-content diversion. With `styles` nil the
    /// behavior is identical to `extract(from:)`.
    public static func extract(
        from html: String, styles: CSSStyleResolver?
    ) -> ExtractionResult {
        Scanner(html: html, styles: styles).run()
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
        /// Optional stylesheet resolver: class/element CSS rules become
        /// format spans and hidden diversions. Nil costs nothing.
        private let styles: CSSStyleResolver?
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
            /// A blockquote fragment reopened by the heading-split rule: it
            /// survives only until its REAL close tag — still open at
            /// document end means the close never came (a genuinely unclosed
            /// quote), and the fragment is dropped rather than styling the
            /// rest of the chapter.
            var reopenedAfterHeading = false
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

        /// An active footnote/hidden region: everything until the matching
        /// close tag of `name` (same-name nesting tracked via `depth`) is
        /// normalized into `out` instead of the main text. `id == nil` means
        /// the content is simply dropped — it was hidden with no note id.
        private struct Diversion {
            let name: String
            var depth: Int
            let id: String?
            var out: [Character] = []
            var pendingSpace = false
            var pendingNewline = false
            /// Active nested HIDDEN region inside the diversion (`hidden`
            /// attribute, display:none / visibility:hidden — inline or via
            /// stylesheet): text is discarded until the region's close tag,
            /// with same-name nesting tracked via `dropDepth`.
            var dropName: String?
            var dropDepth = 0
        }
        private var diversion: Diversion?
        private var footnotes: [ExtractedFootnote] = []

        /// True when the last block break came from a `<br>` with no content
        /// since — a second consecutive `<br>` is a deliberate blank line.
        private var lastBreakWasBr = false
        /// `out.count` at the most recent `<p>` open; unchanged at `</p>`
        /// means the paragraph was explicitly empty (a scene-break blank).
        private var openParagraphStart: Int?
        /// Open `<blockquote>` spans — lets a heading open split them (an
        /// unclosed blockquote must not style the rest of the chapter)
        /// without scanning `openStack` when none is open.
        private var openBlockquoteCount = 0
        /// Indices of split-reopened blockquote spans waiting for their
        /// heading to close before their `start` may resolve — the reopened
        /// fragment must not cover the heading's own text.
        private var pendingReopenStarts: Set<Int> = []
        /// Attribute/stylesheet-driven ("@"-keyed) span bookkeeping: per
        /// element name, a stack with one entry per currently-open element of
        /// that name, recording exactly which span keys (`div@align`,
        /// `span@i`, …) that particular open created — possibly none. The
        /// matching close pops its entry and closes ONLY those keys, so an
        /// inner same-name element that opened no span cannot close an outer
        /// one. Entries are pushed only while the name has @-spans in play
        /// (a key-creating open, or any open while the stack is non-empty),
        /// so style-free documents never touch this at all.
        private var atSpanStacks: [String: [[String]]] = [:]

        init(html: String, includeImages: Bool = true, styles: CSSStyleResolver? = nil) {
            self.html = html
            self.includeImages = includeImages
            self.styles = styles
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

        /// Route decoded text through the whitespace normalizer: ALL source
        /// whitespace — including newlines, which are wrapping, not
        /// structure — becomes a pending (collapsing) space; only tags create
        /// block breaks. A literal U+FFFC is stripped so the placeholder ↔
        /// image pairing cannot desync.
        private func feedText(_ decoded: String) {
            if diversion != nil {
                feedDivertedText(decoded)
                return
            }
            for ch in decoded {
                switch ch {
                // "\r\n" is a single Swift grapheme — list it explicitly.
                case " ", "\t", "\n", "\r", "\r\n":
                    pendingSpace = true
                case XHTMLTextExtractor.imagePlaceholder:
                    break
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
            lastBreakWasBr = false
        }

        /// A visible blank line — a paragraph holding a single NBSP between
        /// two breaks — for deliberate scene breaks (`<p></p>`, `<br><br>`).
        /// A plain `\n\n` would collapse at render time; the NBSP keeps the
        /// blank paragraph visible.
        private func emitBlankLine() {
            guard !out.isEmpty else { return } // a leading blank would be trimmed anyway
            pendingNewline = true
            emitContent("\u{00A0}")
            pendingNewline = true
            pendingSpace = false
        }

        /// `<hr>`: a centered "* * *" scene-break paragraph — the thematic
        /// break stays visible in extracted text.
        private func emitSceneBreak() {
            pendingNewline = true
            let index = working.count
            working.append(WorkingSpan(
                tag: "@hr", kind: .alignment(.center), start: nil, end: nil
            ))
            unresolvedStarts.insert(index)
            for ch in "* * *" { emitContent(ch) }
            working[index].end = out.count
            pendingNewline = true
        }

        // MARK: Diverted (footnote/hidden) emission

        /// `feedText` for an active diversion: same whitespace model, but
        /// into the note's own buffer — nothing reaches the main text.
        /// Inside a nested hidden region the text is discarded entirely.
        private func feedDivertedText(_ decoded: String) {
            guard diversion?.dropName == nil else { return }
            for ch in decoded {
                switch ch {
                case " ", "\t", "\n", "\r", "\r\n":
                    diversion?.pendingSpace = true
                case XHTMLTextExtractor.imagePlaceholder:
                    break
                default:
                    emitDivertedContent(ch)
                }
            }
        }

        private func emitDivertedContent(_ ch: Character) {
            guard diversion != nil else { return }
            if diversion!.out.isEmpty, ch.isWhitespace {
                diversion!.pendingSpace = false
                diversion!.pendingNewline = false
                return
            }
            if diversion!.pendingNewline {
                if !diversion!.out.isEmpty { diversion!.out.append("\n") }
                diversion!.pendingNewline = false
                diversion!.pendingSpace = false
            } else if diversion!.pendingSpace {
                if !diversion!.out.isEmpty { diversion!.out.append(" ") }
                diversion!.pendingSpace = false
            }
            diversion!.out.append(ch)
        }

        /// Close the active diversion: trim, and store the note under the
        /// element's id. No id, or no content → nothing to store (dropped).
        private func endDiversion() {
            guard let ended = diversion else { return }
            diversion = nil
            guard let id = ended.id else { return }
            var text = ended.out
            while let last = text.last, last.isWhitespace { text.removeLast() }
            guard !text.isEmpty else { return }
            footnotes.append(ExtractedFootnote(id: id, text: String(text)))
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

            // <epub:switch>: only the <epub:default> branch is fallback
            // content — <epub:case> branches target specialized renderers
            // (MathML islands etc.) and are skipped whole. The switch and
            // default wrappers themselves are transparent unknown tags.
            if !isClosing, !selfClosing, name == "case" {
                skipNonContent(qualified, resumeAt: &i)
                return
            }

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
            if diversion != nil {
                handleDivertedOpenTag(
                    name, tagMarkup: tagMarkup, hasAttributes: hasAttributes,
                    selfClosing: selfClosing, resumeAt: &i
                )
                return
            }

            // Stylesheet-resolved facts for this element — nil on the fast
            // path (no resolver, or no class/style attribute and no element
            // rule for the name).
            let resolved = resolvedStyle(name, tagMarkup: tagMarkup, hasAttributes: hasAttributes)

            // Footnote/hidden region: epub:type footnote/endnote/rearnote/
            // note, role doc-footnote/doc-endnote, the boolean `hidden`
            // attribute, inline display:none / visibility:hidden, or a
            // class/element stylesheet rule resolving to hidden. All content
            // diverts to the footnote store, keyed by the element's own id
            // (which therefore does NOT enter the anchors map).
            if (hasAttributes && XHTMLTextExtractor.isNoteOrHiddenRegion(tagMarkup))
                || resolved?.hidden == true {
                // Self-closed and void elements (`<img hidden>`) have no
                // contents to divert — drop the element itself outright; a
                // diversion would wait for a close tag that never comes.
                guard !selfClosing, !XHTMLTextExtractor.voidTags.contains(name) else { return }
                let id = XHTMLTextExtractor.attribute("id", in: tagMarkup)
                diversion = Diversion(
                    name: name, depth: 1,
                    id: (id?.isEmpty == false) ? id : nil
                )
                // The enclosing <p> held content — it just went to the note.
                openParagraphStart = nil
                return
            }

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

            if name == "img" || name == "image" {
                if includeImages, hasAttributes, let src = imageSource(name, tagMarkup) {
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

            // The @-span keys THIS open creates; pushed (with the element
            // name) once all sources have contributed, so the matching close
            // tag closes exactly these.
            var atSpanKeys: [String] = []

            if XHTMLTextExtractor.blockTags.contains(name) {
                if name == "br" {
                    if pendingNewline, lastBreakWasBr {
                        // Second consecutive <br>: a deliberate blank line.
                        emitBlankLine()
                    }
                    lastBreakWasBr = true
                } else {
                    lastBreakWasBr = false
                }
                pendingNewline = true
                if name == "p" { openParagraphStart = out.count }
                // Alignment on a block element. A stylesheet-resolved value
                // wins (class/element rules, with any inline text-align
                // already overlaid last inside the resolver); without one,
                // the legacy inline sources (align="…" / style=
                // "text-align:…") apply. br/hr are void — nothing could
                // close them.
                if !selfClosing, name != "br", name != "hr" {
                    var alignment = resolved?.alignment
                    if alignment == nil, hasAttributes, tagMarkup.contains("align") {
                        alignment = XHTMLTextExtractor.inlineAlignment(in: tagMarkup)
                    }
                    if let alignment {
                        let key = name + "@align"
                        let index = working.count
                        working.append(WorkingSpan(
                            tag: key, kind: .alignment(alignment),
                            start: nil, end: nil
                        ))
                        openStack.append(index)
                        unresolvedStarts.insert(index)
                        atSpanKeys.append(key)
                    }
                }
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
            case "hr":
                emitSceneBreak()
            default:
                break
            }

            guard !selfClosing else { return }
            // Class/element stylesheet formatting: spans keyed per element
            // name (the "@align" pattern) so the element's own close tag
            // closes them. `false` facts open nothing — no un-bolding/
            // un-italicizing in v1. Void elements have no close tag and get
            // no spans.
            if let resolved, !XHTMLTextExtractor.voidTags.contains(name) {
                if resolved.italic == true {
                    openCSSSpan(name + "@i", kind: .italic, into: &atSpanKeys)
                }
                if resolved.bold == true {
                    openCSSSpan(name + "@b", kind: .bold, into: &atSpanKeys)
                }
                if resolved.inset == true {
                    openCSSSpan(name + "@q", kind: .blockquote, into: &atSpanKeys)
                }
                if resolved.smallCaps == true {
                    openCSSSpan(name + "@sc", kind: .smallCaps, into: &atSpanKeys)
                }
                // `vertical-align: super/sub` — the footnote-marker pattern
                // (#43): InDesign-produced EPUBs raise note refs with a
                // classed span, not <sup>. `.baseline` opens nothing (it
                // exists to cancel, not to style). A literal <sup>/<sub>
                // already gets its kind from the tag itself — reset sheets
                // routinely declare `sup { vertical-align: super }`, and a
                // second span over the same run would compound the
                // renderer's per-span 0.75× shrink.
                if resolved.verticalAlign == .raised, name != "sup" {
                    openCSSSpan(name + "@sup", kind: .superscript, into: &atSpanKeys)
                } else if resolved.verticalAlign == .lowered, name != "sub" {
                    openCSSSpan(name + "@sub", kind: .subscript, into: &atSpanKeys)
                }
            }
            // Record which @-keyed spans this open created so ITS close tag
            // (and only its close tag) closes them. Opens that created none
            // still push an (empty) entry while same-name @-spans are open —
            // otherwise an inner plain <div> would pop the outer styled
            // div's entry. Nothing is pushed when neither applies, keeping
            // the fast path allocation-free for unstyled documents.
            if !atSpanKeys.isEmpty || atSpanStacks[name] != nil {
                atSpanStacks[name, default: []].append(atSpanKeys)
            }
            if let (tag, kind) = spanKind(name, tagMarkup: tagMarkup, hasAttributes: hasAttributes) {
                if case .heading = kind {
                    // An unclosed <blockquote> must not style the rest of the
                    // chapter — but a heading INSIDE a well-formed blockquote
                    // is legal (epigraphs). A heading therefore SPLITS every
                    // open blockquote span: the content-bearing fragment
                    // ends here, and a fresh fragment reopens for the real
                    // close tag to end (document end stays the last resort,
                    // where reopened-but-never-closed fragments are dropped).
                    if openBlockquoteCount > 0 { splitOpenBlockquotesForHeading() }
                }
                let index = working.count
                working.append(WorkingSpan(tag: tag, kind: kind, start: nil, end: nil))
                openStack.append(index)
                unresolvedStarts.insert(index)
                if tag == "blockquote" { openBlockquoteCount += 1 }
            }
        }

        /// The heading-split rule for open blockquote spans: a fragment with
        /// content ends at the heading and a fresh working span replaces it
        /// on the open stack (same `openBlockquoteCount` — the real
        /// `</blockquote>` still closes it); a fragment with no content yet
        /// simply defers. Either way the reopened span's `start` must not
        /// resolve inside the heading's own text, so it waits in
        /// `pendingReopenStarts` until the heading closes.
        private func splitOpenBlockquotesForHeading() {
            for position in openStack.indices {
                let index = openStack[position]
                guard working[index].tag == "blockquote" else { continue }
                if unresolvedStarts.contains(index) {
                    // No content yet (epigraph shape): keep the same span,
                    // deferring its start past the heading.
                    unresolvedStarts.remove(index)
                    pendingReopenStarts.insert(index)
                    working[index].reopenedAfterHeading = true
                } else if working[index].start != nil {
                    // End the content-bearing fragment; reopen a fresh one.
                    working[index].end = out.count
                    let reopened = working.count
                    working.append(WorkingSpan(
                        tag: "blockquote", kind: .blockquote, start: nil,
                        end: nil, reopenedAfterHeading: true
                    ))
                    openStack[position] = reopened
                    pendingReopenStarts.insert(reopened)
                }
                // else: already deferred by an earlier (still open) heading.
            }
        }

        /// SVG `<image>` refs use href/xlink:href; `<img>` uses src.
        private func imageSource(_ name: String, _ tagMarkup: String) -> String? {
            let src: String?
            if name == "img" {
                src = XHTMLTextExtractor.attribute("src", in: tagMarkup)
            } else {
                src = XHTMLTextExtractor.attribute("href", in: tagMarkup)
                    ?? XHTMLTextExtractor.attribute("xlink:href", in: tagMarkup)
            }
            guard let src, !src.isEmpty else { return nil }
            return src
        }

        /// Open tags inside a diversion: non-content blocks still skip, a
        /// same-name open deepens the region, block boundaries break the
        /// note's paragraphs, and hidden elements (detected exactly like
        /// `handleOpenTag` does) start a nested drop region whose contents
        /// never reach the note. No anchors, spans, images, or list markers.
        private func handleDivertedOpenTag(
            _ name: String, tagMarkup: String, hasAttributes: Bool,
            selfClosing: Bool, resumeAt i: inout String.Index
        ) {
            if XHTMLTextExtractor.nonContentTags.contains(name), !selfClosing {
                skipNonContent(name, resumeAt: &i)
                return
            }
            if diversion!.dropName != nil {
                // Inside the drop region: only depth bookkeeping — the
                // diversion's own name stays balanced so its real close
                // still ends it, and same-name nesting keeps the drop alive.
                guard !selfClosing else { return }
                if name == diversion!.name { diversion!.depth += 1 }
                if name == diversion!.dropName { diversion!.dropDepth += 1 }
                return
            }
            let resolved = resolvedStyle(name, tagMarkup: tagMarkup, hasAttributes: hasAttributes)
            if (hasAttributes && XHTMLTextExtractor.isNoteOrHiddenRegion(tagMarkup))
                || resolved?.hidden == true {
                // Void/self-closed hidden elements have no contents — drop
                // the element itself outright; a drop region would wait for
                // a close tag that never comes.
                guard !selfClosing, !XHTMLTextExtractor.voidTags.contains(name) else { return }
                if name == diversion!.name { diversion!.depth += 1 }
                diversion!.dropName = name
                diversion!.dropDepth = 1
                return
            }
            if name == diversion!.name, !selfClosing {
                diversion!.depth += 1
            }
            if XHTMLTextExtractor.blockTags.contains(name) {
                diversion!.pendingNewline = true
            }
        }

        private func handleCloseTag(_ name: String) {
            if diversion != nil {
                handleDivertedCloseTag(name)
                return
            }
            switch name {
            case "td", "th":
                // A space between cells keeps rows readable once the markup
                // is gone ("Name Age", not "NameAge"); </tr> makes the line.
                pendingSpace = true
            case "ul", "ol":
                if !listStack.isEmpty { listStack.removeLast() }
                pendingPrefix = nil
            case "p":
                // An explicitly empty paragraph (`<p></p>`, `<p>&nbsp;</p>`)
                // is a deliberate blank line (scene break) — keep it visible.
                if let mark = openParagraphStart, out.count == mark {
                    emitBlankLine()
                }
                openParagraphStart = nil
            default:
                break
            }
            if XHTMLTextExtractor.blockTags.contains(name) {
                pendingNewline = true
                if name != "br" { lastBreakWasBr = false }
                if name == "li" { pendingPrefix = nil }
            }
            if !atSpanStacks.isEmpty, atSpanStacks[name] != nil {
                // Pop THIS close's entry and close exactly the @-keyed spans
                // its matching open created (possibly none). Emptied stacks
                // are removed so the open-side membership check stays exact.
                var stack = atSpanStacks.removeValue(forKey: name)!
                let keys = stack.removeLast()
                if !stack.isEmpty { atSpanStacks[name] = stack }
                for key in keys.reversed() { closeSpan(key) }
            }
            if let key = spanTagKey(name) {
                closeSpan(key)
            }
        }

        /// Close tags inside a diversion: the region's own close (at depth
        /// zero) ends it; block boundaries break the note's paragraphs. A
        /// nested hidden drop region absorbs everything until its own close
        /// (same-name nesting honored) — no text, no paragraph breaks.
        private func handleDivertedCloseTag(_ name: String) {
            if diversion!.dropName != nil {
                if name == diversion!.name {
                    diversion!.depth -= 1
                    if diversion!.depth == 0 {
                        // The diversion's real close arrived while the drop
                        // region was still open (unclosed hidden element):
                        // the diversion ends — the drop dies with it.
                        endDiversion()
                        return
                    }
                }
                if name == diversion!.dropName {
                    diversion!.dropDepth -= 1
                    if diversion!.dropDepth == 0 { diversion!.dropName = nil }
                }
                return
            }
            if name == diversion!.name {
                diversion!.depth -= 1
                if diversion!.depth == 0 {
                    endDiversion()
                    return
                }
            }
            if XHTMLTextExtractor.blockTags.contains(name) {
                diversion!.pendingNewline = true
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
            case "p":
                // `<p/>` is an explicitly empty paragraph — a blank line.
                if let mark = openParagraphStart, out.count == mark {
                    emitBlankLine()
                }
                openParagraphStart = nil
            default:
                break
            }
        }

        // MARK: Spans

        /// The stylesheet-resolved facts for an element open tag, or nil on
        /// the fast path: no resolver, or the element carries no class/style
        /// attribute and no element rule exists for its name.
        private func resolvedStyle(
            _ name: String, tagMarkup: String, hasAttributes: Bool
        ) -> ResolvedStyle? {
            guard let styles else { return nil }
            var classAttr: String?
            var inlineStyle: String?
            if hasAttributes {
                if tagMarkup.contains("class") {
                    classAttr = XHTMLTextExtractor.attribute("class", in: tagMarkup)
                }
                if tagMarkup.contains("style") {
                    inlineStyle = XHTMLTextExtractor.attribute("style", in: tagMarkup)
                }
            }
            guard classAttr != nil || inlineStyle != nil || styles.hasElementRule(name) else {
                return nil
            }
            let resolved = styles.style(
                element: name, classAttr: classAttr, inlineStyle: inlineStyle
            )
            return resolved.isEmpty ? nil : resolved
        }

        /// Open one stylesheet-driven span under `key` (element name + kind
        /// suffix), recording the key in the open's @-span entry so exactly
        /// this element's close tag closes it.
        private func openCSSSpan(_ key: String, kind: Span.Kind, into keys: inout [String]) {
            let index = working.count
            working.append(WorkingSpan(tag: key, kind: kind, start: nil, end: nil))
            openStack.append(index)
            unresolvedStarts.insert(index)
            keys.append(key)
        }

        /// The canonical span key for a formatting tag (b/strong share one key
        /// so sloppy `<b>…</strong>` pairs still close), or nil for tags that
        /// don't open spans.
        private func spanTagKey(_ name: String) -> String? {
            switch name {
            case "b", "strong": return "b"
            case "i", "em": return "i"
            case "blockquote": return "blockquote"
            case "a": return "a"
            case "sup", "sub", "center", "th": return name
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
            case "sup": return (key, .superscript)
            case "sub": return (key, .`subscript`)
            case "center": return (key, .alignment(.center))
            case "th": return (key, .bold) // header cells read as emphasized
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
            if working[index].tag == "blockquote" { openBlockquoteCount -= 1 }
            if unresolvedStarts.remove(index) == nil {
                working[index].end = out.count
            }
            // else: closed before any content — the span stays start-less and
            // is dropped at finalize.
            if !pendingReopenStarts.isEmpty {
                // Closed while still deferred (its heading never closed):
                // the fragment stays start-less and is dropped at finalize.
                pendingReopenStarts.remove(index)
            }
            if !pendingReopenStarts.isEmpty, case .heading = working[index].kind {
                // The heading is over: split-reopened blockquote fragments
                // may now start at the next content character.
                unresolvedStarts.formUnion(pendingReopenStarts)
                pendingReopenStarts.removeAll()
            }
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
            // An unclosed footnote/hidden region ends at the document's end.
            endDiversion()
            // Unclosed elements end at the document's end — EXCEPT blockquote
            // fragments reopened after a heading split: still open here means
            // their real close tag never came (a genuinely unclosed quote),
            // and extending them would style the whole chapter tail. Drop
            // them instead.
            for index in openStack where !unresolvedStarts.contains(index) {
                if working[index].end == nil {
                    if working[index].reopenedAfterHeading {
                        working[index].start = nil
                    } else {
                        working[index].end = out.count
                    }
                }
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
                text: String(out), images: images, spans: spans, anchors: anchors,
                footnotes: footnotes
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
        for name in ["id", "src", "alt", "href", "style", "width", "height",
                     "class", "epub:type", "role", "hidden", "align", "xlink:href",
                     "rel"] {
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

    // MARK: - Note / hidden region detection

    /// `epub:type` tokens that mark an element as a NOTE BODY. Word-boundary
    /// semantics via token match: `noteref` (the marker) and the plural
    /// container types (`endnotes` — a visible section) must not match.
    private static let noteEpubTypes: Set<String> = [
        "footnote", "endnote", "rearnote", "note",
    ]
    private static let noteRoles: Set<String> = ["doc-footnote", "doc-endnote"]

    /// True when an open tag starts a footnote/hidden region whose content
    /// belongs in the footnote store (or the void) rather than the main text.
    static func isNoteOrHiddenRegion(_ tagMarkup: String) -> Bool {
        if tagMarkup.contains("epub:type"),
           let type = attribute("epub:type", in: tagMarkup),
           hasToken(of: noteEpubTypes, in: type) {
            return true
        }
        if tagMarkup.contains("role"),
           let role = attribute("role", in: tagMarkup),
           hasToken(of: noteRoles, in: role) {
            return true
        }
        if tagMarkup.contains("hidden"), hasBooleanAttribute("hidden", in: tagMarkup) {
            return true
        }
        if tagMarkup.contains("style"), let style = attribute("style", in: tagMarkup) {
            if let display = styleValue("display", in: style),
               display.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("none") {
                return true
            }
            if let visibility = styleValue("visibility", in: style),
               visibility.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("hidden") {
                return true
            }
        }
        return false
    }

    /// Whitespace-separated token match within an attribute value.
    private static func hasToken(of tokens: Set<String>, in value: String) -> Bool {
        value.lowercased().split(whereSeparator: \.isWhitespace)
            .contains { tokens.contains(String($0)) }
    }

    /// True when the tag carries the boolean attribute `name` — bare
    /// (`<div hidden>`) or valued (`hidden=""`, any value counts per HTML).
    /// Quoted attribute VALUES are blanked before matching so `class="hidden"`
    /// or `href="hidden.xhtml"` never count.
    static func hasBooleanAttribute(_ name: String, in tag: String) -> Bool {
        var unquoted = ""
        unquoted.reserveCapacity(tag.count)
        var quote: Character?
        for ch in tag {
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                unquoted.append(" ")
                continue
            }
            unquoted.append(ch)
        }
        return unquoted.range(
            of: "(?<![\\w-])\(name)(?![\\w-])",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    // MARK: - Inline alignment

    /// Alignment declared inline on a block open tag: `style="text-align:…"`
    /// wins over the presentational `align="…"` attribute (matching CSS
    /// precedence at render time). No stylesheet engine — inline sources only.
    static func inlineAlignment(in tagMarkup: String) -> TextAlignment? {
        if let style = attribute("style", in: tagMarkup),
           let declared = styleValue("text-align", in: style),
           let alignment = alignmentValue(declared) {
            return alignment
        }
        if let attr = attribute("align", in: tagMarkup) {
            return alignmentValue(attr)
        }
        return nil
    }

    /// Parse an alignment keyword ("center", "Right", "left !important");
    /// anything unrecognized yields nil.
    private static func alignmentValue(_ raw: String) -> TextAlignment? {
        guard let keyword = raw.lowercased().split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        return TextAlignment(rawValue: String(keyword))
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

    /// Compiled once — `firstHeading` runs per chapter at import. The
    /// backreference makes `<h1>…</h2>` a non-match (a broken pair must not
    /// swallow markup up to some later close), and dot-matches-newlines lets
    /// headings span source lines.
    private static let headingRegex = try? NSRegularExpression(
        pattern: "<h([1-6])[^>]*>(.*?)</h\\1\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let titleElementRegex = try? NSRegularExpression(
        pattern: "<title[^>]*>(.*?)</title\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// First heading (`<h1>`…`<h6>`) text, for use as a chapter title.
    /// Headings that strip to nothing (decorative images) are skipped; when
    /// no heading yields text, the document's `<title>` is the fallback.
    public static func firstHeading(from html: String) -> String? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let regex = headingRegex {
            for match in regex.matches(in: html, range: range) {
                if let title = titleText(ns.substring(with: match.range(at: 2))) {
                    return title
                }
            }
        }
        if let regex = titleElementRegex,
           let match = regex.firstMatch(in: html, range: range),
           let title = titleText(ns.substring(with: match.range(at: 1))) {
            return title
        }
        return nil
    }

    /// Strip tags, decode entities, collapse whitespace; nil when empty.
    private static func titleText(_ inner: String) -> String? {
        let stripped = inner.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let title = decodeEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                if let value = scalarValue, let mapped = cp1252C1References[value] {
                    // &#128;–&#159; are C1 controls in Unicode, but books
                    // (Word/legacy tool exports) mean the Windows-1252
                    // printables at those byte values (&#146; → ’, &#151; → —).
                    result += mapped
                } else if let value = scalarValue, let scalar = Unicode.Scalar(value) {
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

    /// Numeric character references in the C1 range (decimal 128–159, and
    /// their hex forms), read as Windows-1252 — what the authoring tool
    /// actually meant. Code points 1252 leaves undefined (129, 141, 143,
    /// 144, 157) fall through to literal decoding.
    private static let cp1252C1References: [UInt32: String] = [
        128: "€", 130: "‚", 131: "ƒ", 132: "„", 133: "…", 134: "†",
        135: "‡", 136: "ˆ", 137: "‰", 138: "Š", 139: "‹", 140: "Œ",
        142: "Ž", 145: "‘", 146: "’", 147: "“", 148: "”", 149: "•",
        150: "–", 151: "—", 152: "˜", 153: "™", 154: "š", 155: "›",
        156: "œ", 158: "ž", 159: "Ÿ",
    ]

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
        // Greek letters (HTML 4 set), uppercase
        "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ",
        "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ",
        "Iota": "Ι", "Kappa": "Κ", "Lambda": "Λ", "Mu": "Μ",
        "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π",
        "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ",
        "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω",
        // Greek letters, lowercase (plus the symbol variants)
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π",
        "rho": "ρ", "sigmaf": "ς", "sigma": "σ", "tau": "τ",
        "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "thetasym": "ϑ", "upsih": "ϒ", "piv": "ϖ",
        // Math and symbols (technical publishers)
        "sum": "∑", "prod": "∏", "radic": "√", "int": "∫", "part": "∂",
        "nabla": "∇", "asymp": "≈", "equiv": "≡", "cong": "≅", "sim": "∼",
        "prop": "∝", "lang": "⟨", "rang": "⟩", "lceil": "⌈", "rceil": "⌉",
        "lfloor": "⌊", "rfloor": "⌋", "oplus": "⊕", "otimes": "⊗",
        "perp": "⊥", "ang": "∠", "and": "∧", "or": "∨", "there4": "∴",
        "isin": "∈", "notin": "∉", "ni": "∋", "cap": "∩", "cup": "∪",
        "sub": "⊂", "sup": "⊃", "sube": "⊆", "supe": "⊇", "empty": "∅",
        "forall": "∀", "exist": "∃", "lowast": "∗", "sdot": "⋅",
        "alefsym": "ℵ", "image": "ℑ", "real": "ℜ", "weierp": "℘",
        "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥",
        "diams": "♦", "crarr": "↵",
        "lArr": "⇐", "uArr": "⇑", "rArr": "⇒", "dArr": "⇓", "hArr": "⇔",
    ]
}
