import Foundation
#if canImport(FoundationXML)
import FoundationXML // XMLParser lives here in swift-corelibs-foundation (Linux)
#endif

/// Parses an EPUB (via an `EPUBContainer`) into a `Book`: reads the container
/// pointer to the OPF package document, the spine reading order, the manifest,
/// metadata, and each spine document's text. DRM-protected EPUBs (those with an
/// `encryption.xml`) are rejected. Dependency-free and fully unit-tested; the
/// app target supplies a ZIP-backed container.
public struct EPUBBookParser {
    /// Maximum number of spine items honored. A hostile package can declare
    /// hundreds of thousands of itemrefs to exhaust memory/CPU before any
    /// entry is even extracted; reject the book past this ceiling.
    public static let maxSpineItems = 2000

    public init() {}

    public func parse(container: EPUBContainer, fallbackTitle: String) throws -> Book {
        if container.entryExists("META-INF/encryption.xml"),
           Self.declaresDRM(encryptionXML: try Self.optionalData(container, at: "META-INF/encryption.xml")) {
            throw BookParserError.drmProtected
        }
        guard let containerData = try Self.optionalData(container, at: "META-INF/container.xml"),
              let rawOPFPath = Self.rootfilePath(from: containerData) else {
            throw BookParserError.corrupted("missing or invalid META-INF/container.xml")
        }
        // Real-world container.xml full-paths show up with backslash
        // separators and leading "./" — normalize before the archive lookup.
        let opfPath = Self.resolve(
            base: "", href: rawOPFPath.replacingOccurrences(of: "\\", with: "/")
        )
        guard let opfData = try Self.optionalData(container, at: opfPath) else {
            throw BookParserError.corrupted("missing OPF package document at \(opfPath)")
        }

        let opf = OPF.parse(opfData)
        let baseDir = Self.directory(of: opfPath)

        // Non-linear spine items (linear="no": endnotes, answer keys) keep
        // their spine POSITION — links into them still land where expected —
        // and are flagged `isLinear = false` so continuous reading order
        // skips them. The EPUB 3 nav document, when it sits in the spine, is
        // an in-book TOC page and is non-linear regardless.
        guard opf.spineItems.count <= Self.maxSpineItems else {
            throw EPUBParseError.tooManySpineItems(count: opf.spineItems.count, limit: Self.maxSpineItems)
        }
        var chapters: [Chapter] = []
        var chapterIndexByPath: [String: Int] = [:]
        var styleCache = StylesheetCache()
        for entry in opf.spineItems {
            guard let itemID = opf.manifestID(for: entry.idref),
                  let item = opf.manifest[itemID] else { continue }
            let href = Self.resolve(base: baseDir, href: item.href)
            // Two itemrefs resolving to the same content document (duplicate
            // idrefs, or distinct manifest items sharing an href) must emit
            // ONE chapter — the first occurrence wins.
            guard chapterIndexByPath[href] == nil else { continue }
            guard let data = try Self.optionalData(container, at: href),
                  let html = Self.decodeText(data) else { continue }
            // Image, link, AND stylesheet hrefs are relative to the content
            // document, not the OPF.
            let documentDir = Self.directory(of: href)
            let styles = try Self.styleResolver(
                for: html, documentDir: documentDir, container: container,
                cache: &styleCache
            )
            let extraction = XHTMLTextExtractor.extract(from: html, styles: styles)
            let text = extraction.text
            let footnotes = extraction.footnotes.map { Footnote(id: $0.id, text: $0.text) }
            // A document whose entire content was diverted to footnotes (a
            // hidden-notes file) keeps its chapter — noteref links resolve
            // into it — but a truly empty document is still skipped.
            guard !text.isEmpty || !footnotes.isEmpty else { continue }
            let title = XHTMLTextExtractor.firstHeading(from: html)
            let images = Self.chapterImages(
                in: text, refs: extraction.images, documentDir: documentDir
            )
            let spans = Self.formatSpans(
                from: extraction.spans, documentPath: href, documentDir: documentDir
            )
            let isLinear = entry.linear && !opf.navItemIDs.contains(itemID)
            chapterIndexByPath[href] = chapters.count
            chapters.append(Chapter(
                title: title, order: chapters.count, text: text,
                images: images.isEmpty ? nil : images,
                formatSpans: spans.isEmpty ? nil : spans,
                sourcePath: href,
                anchors: extraction.anchors.isEmpty ? nil : extraction.anchors,
                footnotes: footnotes.isEmpty ? nil : footnotes,
                isLinear: isLinear ? nil : false
            ))
        }
        guard !chapters.isEmpty else {
            throw BookParserError.corrupted("no readable content in the spine")
        }

        // TOC: the package's declared navigation (EPUB 3 nav doc preferred,
        // EPUB 2 NCX fallback); chapter headings only when neither yields
        // anything.
        let declaredTOC = try Self.tableOfContents(
            opf: opf, baseDir: baseDir, container: container,
            chapterIndexByPath: chapterIndexByPath
        )
        let toc = declaredTOC.isEmpty
            ? Self.headingFallbackTOC(chapters: chapters)
            : declaredTOC

        let isFixedLayout = try opf.isFixedLayout || Self.appleFixedLayoutDeclared(in: container)
        let metadata = BookMetadata(
            title: opf.title.isEmpty ? fallbackTitle : opf.title,
            authors: opf.creators,
            language: opf.language,
            tableOfContents: toc,
            isFixedLayout: isFixedLayout ? true : nil
        )
        let fullText = chapters.map(\.text).joined(separator: "\n\n")
        return Book(
            metadata: metadata,
            chapters: chapters,
            estimatedTokenCount: estimateTokens(fullText),
            coverImageData: try Self.coverImageData(opf: opf, baseDir: baseDir, container: container)
        )
    }

    // MARK: - Cap-aware entry reads

    /// Read an optional archive entry, distinguishing two failure modes:
    ///
    /// - A genuinely missing/unreadable **non-security** entry (e.g. a
    ///   legitimately absent optional resource) yields `nil`, letting callers
    ///   skip it — the prior `try?` behavior.
    /// - An `EPUBParseError` (per-entry cap, cumulative cap, spine-count
    ///   ceiling) is a security limit and is **rethrown** so a hostile archive
    ///   aborts the whole parse instead of importing partially.
    ///
    /// Using this everywhere content bytes are read means no code path can
    /// swallow a zip-bomb cap violation via `try?`.
    static func optionalData(_ container: EPUBContainer, at path: String) throws -> Data? {
        do {
            return try container.data(at: path)
        } catch let error as EPUBParseError {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: - DRM vs font obfuscation

    /// Algorithms that only obfuscate embedded fonts — not DRM. Standard
    /// InDesign/publisher exports declare these in encryption.xml, and the
    /// book text itself is fully readable.
    private static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// True when encryption.xml declares actual DRM. An encryption.xml whose
    /// every declared algorithm is font obfuscation is not DRM; anything
    /// else — unreadable XML, no algorithms, or an unknown algorithm —
    /// conservatively counts as DRM.
    static func declaresDRM(encryptionXML data: Data?) -> Bool {
        guard let data, let xml = decodeText(data) else { return true }
        var algorithms: [String] = []
        var remainder = Substring(xml)
        while let match = remainder.range(
            of: "\\bAlgorithm\\s*=\\s*[\"'][^\"']*[\"']",
            options: [.regularExpression, .caseInsensitive]
        ) {
            let declaration = remainder[match]
            remainder = remainder[match.upperBound...]
            guard let quote = declaration.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
                continue
            }
            algorithms.append(String(
                declaration[declaration.index(after: quote)..<declaration.index(before: declaration.endIndex)]
            ))
        }
        guard !algorithms.isEmpty else { return true }
        return !algorithms.allSatisfy { fontObfuscationAlgorithms.contains($0) }
    }

    // MARK: - Text decoding

    /// Decode a package/content document's bytes: UTF-16 with BOM, UTF-8
    /// (with or without BOM), the encoding declared in the XML prolog, and
    /// Latin-1 as the last resort — a chapter should degrade, not vanish,
    /// when its encoding is unusual.
    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        func withoutBOM(_ s: String) -> String {
            s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        let head = [UInt8](data.prefix(2))
        if head.count == 2 {
            if head[0] == 0xFF, head[1] == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian).map(withoutBOM)
            }
            if head[0] == 0xFE, head[1] == 0xFF {
                return String(data: data, encoding: .utf16BigEndian).map(withoutBOM)
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return withoutBOM(utf8)
        }
        if let declared = Self.declaredEncoding(in: data),
           let decoded = String(data: data, encoding: declared) {
            return decoded
        }
        // Latin-1 maps every byte, so this never fails — mojibake for exotic
        // encodings beats silently dropping the chapter.
        return String(data: data, encoding: .isoLatin1)
    }

    /// The `encoding="…"` named in an XML prolog, mapped to the encodings we
    /// can decode. Only consulted when the bytes are not valid UTF-8.
    private static func declaredEncoding(in data: Data) -> String.Encoding? {
        // The prolog sits in the first line; Latin-1 always decodes bytes.
        guard let head = String(data: data.prefix(256), encoding: .isoLatin1),
              let range = head.range(
                  of: "encoding\\s*=\\s*[\"'][^\"']+[\"']",
                  options: [.regularExpression, .caseInsensitive]
              ) else { return nil }
        let declaration = head[range]
        guard let quote = declaration.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return nil
        }
        let name = declaration[declaration.index(after: quote)..<declaration.index(before: declaration.endIndex)]
            .lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "iso8859-1", "latin-1", "latin1": return .isoLatin1
        case "windows-1252", "cp-1252", "cp1252": return .windowsCP1252
        case "us-ascii", "ascii": return .ascii
        case "utf-16", "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        default: return nil
        }
    }

    // MARK: - Fixed layout (FXL)

    /// Legacy Apple fixed-layout declaration (pre-dating the EPUB 3
    /// `rendition:layout` vocabulary): `META-INF/com.apple.ibooks.display-
    /// options.xml` containing `<option name="fixed-layout">true</option>`.
    static func appleFixedLayoutDeclared(in container: EPUBContainer) throws -> Bool {
        guard let data = try optionalData(container, at: "META-INF/com.apple.ibooks.display-options.xml"),
              let xml = decodeText(data) else { return false }
        return xml.range(
            of: "<option[^>]*name\\s*=\\s*[\"']fixed-layout[\"'][^>]*>\\s*true\\s*</option>",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    // MARK: - Stylesheets

    /// Per-book stylesheet cache: sheet text per archive path (each sheet is
    /// fetched and decoded once, unreadable paths remembered), and one
    /// composed resolver per unique ordered sheet set (each set is parsed
    /// once; chapters sharing it — the overwhelmingly common case — reuse
    /// the parse).
    struct StylesheetCache {
        var sheetText: [String: String] = [:]
        var unreadable: Set<String> = []
        var resolverBySheetSet: [String: CSSStyleResolver] = [:]
    }

    /// Compiled once — the link pre-pass runs per spine document.
    private static let linkTagRegex = try? NSRegularExpression(
        pattern: "<link\\b[^>]*>", options: [.caseInsensitive]
    )
    private static let styleBlockRegex = try? NSRegularExpression(
        pattern: "<style\\b[^>]*>(.*?)</style\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Hrefs of the document's applied stylesheets — `<link>` tags whose
    /// `rel` tokens include `stylesheet` (attribute order-independent, both
    /// quote styles) — in document order. Alternate stylesheets are not
    /// applied by default and are skipped. Raw hrefs; the caller resolves
    /// them against the document directory.
    static func stylesheetHrefs(in html: String) -> [String] {
        guard html.range(of: "<link", options: .caseInsensitive) != nil,
              let regex = linkTagRegex else { return [] }
        let ns = html as NSString
        var hrefs: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let rel = XHTMLTextExtractor.attribute("rel", in: tag) else { continue }
            let tokens = rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.contains("stylesheet"), !tokens.contains("alternate"),
                  let href = XHTMLTextExtractor.attribute("href", in: tag),
                  !href.isEmpty else { continue }
            hrefs.append(href)
        }
        return hrefs
    }

    /// Contents of the document's `<style>` blocks, in document order.
    static func styleBlocks(in html: String) -> [String] {
        guard html.range(of: "<style", options: .caseInsensitive) != nil,
              let regex = styleBlockRegex else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    /// The composed stylesheet resolver for one spine document: its linked
    /// sheets in document order, then its `<style>` blocks (cascade order).
    /// Nil when the document references no styles at all — the extractor's
    /// zero-cost fast path. Only link-referenced sheets are ever fetched;
    /// manifest CSS nothing points at is never read. A missing or unreadable
    /// sheet is skipped (styles are enhancement), but an `EPUBParseError`
    /// (zip-bomb cap) propagates as everywhere else.
    static func styleResolver(
        for html: String, documentDir: String, container: EPUBContainer,
        cache: inout StylesheetCache
    ) throws -> CSSStyleResolver? {
        let hrefs = stylesheetHrefs(in: html)
        let blocks = styleBlocks(in: html)
        guard !hrefs.isEmpty || !blocks.isEmpty else { return nil }
        var paths: [String] = []
        for rawHref in hrefs {
            let path = resolve(base: documentDir, href: rawHref)
            guard !path.isEmpty, !cache.unreadable.contains(path) else { continue }
            if cache.sheetText[path] == nil {
                if let data = try optionalData(container, at: path),
                   let css = decodeText(data) {
                    cache.sheetText[path] = css
                } else {
                    cache.unreadable.insert(path)
                    continue
                }
            }
            paths.append(path)
        }
        guard !paths.isEmpty || !blocks.isEmpty else { return nil }
        let setKey = paths.joined(separator: "\u{0}")
        var resolver: CSSStyleResolver
        if let cached = cache.resolverBySheetSet[setKey] {
            resolver = cached
        } else {
            resolver = CSSStyleResolver(sheets: paths.compactMap { cache.sheetText[$0] })
            cache.resolverBySheetSet[setKey] = resolver
        }
        // `<style>` blocks are document-specific — layered on a copy, the
        // cached sheet-set resolver stays clean for the next chapter.
        for block in blocks { resolver.add(sheet: block) }
        return resolver
    }

    // MARK: - Inline images

    /// Pair the k-th U+FFFC placeholder in `text` with the k-th extracted image
    /// ref, resolving each src against the content document's directory.
    static func chapterImages(
        in text: String,
        refs: [XHTMLTextExtractor.InlineImageRef],
        documentDir: String
    ) -> [ChapterImage] {
        guard !refs.isEmpty else { return [] }
        var images: [ChapterImage] = []
        var refIndex = 0
        for (offset, character) in text.enumerated() {
            guard character == XHTMLTextExtractor.imagePlaceholder else { continue }
            guard refIndex < refs.count else { break }
            let ref = refs[refIndex]
            refIndex += 1
            images.append(ChapterImage(
                offset: offset,
                archivePath: resolve(base: documentDir, href: ref.src),
                alt: ref.alt,
                displayWidth: ref.displayWidth,
                displayHeight: ref.displayHeight
            ))
        }
        return images
    }

    // MARK: - Format spans

    /// Map extractor spans (raw hrefs) to model spans (resolved link targets).
    static func formatSpans(
        from raw: [XHTMLTextExtractor.Span], documentPath: String, documentDir: String
    ) -> [FormatSpan] {
        raw.map { span in
            let kind: FormatSpan.Kind
            switch span.kind {
            case .heading(let level): kind = .heading(level)
            case .bold: kind = .bold
            case .italic: kind = .italic
            case .blockquote: kind = .blockquote
            case .superscript: kind = .superscript
            case .`subscript`: kind = .`subscript`
            case .alignment(let alignment): kind = .alignment(alignment)
            case .smallCaps: kind = .smallCaps
            case .link(let href):
                kind = .link(linkTarget(
                    href: href, documentPath: documentPath, documentDir: documentDir
                ))
            }
            return FormatSpan(start: span.start, end: span.end, kind: kind)
        }
    }

    /// Resolve a raw content-document href to a link target. Hrefs that leave
    /// the book — any RFC 3986 scheme (`https:`, `mailto:`, `tel:`, `data:`)
    /// or a protocol-relative `//host/...` — stay external verbatim;
    /// everything else resolves relative to the chapter document's directory,
    /// with any `#fragment` split off (percent-decoded, matching how
    /// `resolve` decodes the path half — anchor ids come from raw markup). A
    /// bare fragment (`#x`) targets the chapter's own document.
    static func linkTarget(
        href: String, documentPath: String, documentDir: String
    ) -> LinkTarget {
        if href.hasPrefix("//") || hasURIScheme(href) {
            return .external(url: href)
        }
        let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? ""
        let rawFragment = pieces.count > 1 ? String(pieces[1]) : nil
        let path = rawPath.isEmpty ? documentPath : resolve(base: documentDir, href: rawPath)
        let fragment = rawFragment.flatMap { raw -> String? in
            guard !raw.isEmpty else { return nil }
            return raw.removingPercentEncoding ?? raw
        }
        return .internalDoc(path: path, fragment: fragment)
    }

    /// Whether `href` starts with an RFC 3986 scheme
    /// (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"`). A colon can only
    /// appear this way in a valid relative EPUB href, so scheme ⇒ external.
    private static func hasURIScheme(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }

    // MARK: - Cover image

    /// Loads the cover artwork declared in the OPF, if any. Prefers the EPUB3
    /// `properties="cover-image"` manifest item, falling back to the EPUB2
    /// `<meta name="cover" content="…"/>` reference. Never throws — a missing
    /// or unreadable cover just yields nil. A cap violation (`EPUBParseError`),
    /// however, propagates so a hostile archive cannot slip an over-cap entry
    /// past the parse via the cover lookup.
    static func coverImageData(opf: OPF, baseDir: String, container: EPUBContainer) throws -> Data? {
        for id in [opf.coverItemID, opf.metaCoverID].compactMap({ $0 }) {
            guard let item = opf.manifest[id],
                  isImage(mediaType: item.type, href: item.href) else { continue }
            let path = resolve(base: baseDir, href: item.href)
            if let data = try optionalData(container, at: path), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// True when the manifest item plausibly refers to an image: media-type
    /// starts with `image/`, or — when the media-type is absent — the href has
    /// a well-known image file extension.
    private static func isImage(mediaType: String, href: String) -> Bool {
        if !mediaType.isEmpty {
            return mediaType.hasPrefix("image/")
        }
        let lower = (href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href)
            .lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { lower.hasSuffix($0) }
    }

    // MARK: - Path helpers

    static func directory(of path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        if !components.isEmpty { components.removeLast() }
        return components.joined(separator: "/")
    }

    /// Resolve a manifest href (relative to the OPF directory), handling `.`/`..`
    /// and dropping any fragment.
    static func resolve(base: String, href: String) -> String {
        let raw = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        // OPF hrefs are URI-encoded; ZIP entry names are not, so percent-decode
        // (e.g. "chapter%201.xhtml" → "chapter 1.xhtml") before looking them up.
        let withoutFragment = raw.removingPercentEncoding ?? raw
        var components = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in withoutFragment.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        return components.joined(separator: "/")
    }

    static func rootfilePath(from containerXML: Data) -> String? {
        let delegate = ContainerXMLDelegate()
        let parser = XMLParser(data: containerXML)
        parser.delegate = delegate
        parser.parse()
        return delegate.rootfilePath
    }

    // MARK: - Table of contents

    /// One declared-TOC source's outcome: the surviving entries plus how
    /// many candidate entries the source attempted vs actually resolved to
    /// parsed chapters — the accept/fall-through decision needs the ratio.
    struct TOCSource {
        var entries: [TOCEntry] = []
        var attempted = 0
        var resolved = 0
        /// A source is trusted only when it resolved at least half of what
        /// it attempted (and something at all). A mostly-broken nav/NCX —
        /// stale hrefs, or an XML parse aborted early by an undeclared
        /// entity — must fall through to the next source instead of
        /// shipping a near-empty Contents list; a source with most of its
        /// entries intact still beats whatever comes after it.
        var isAcceptable: Bool { resolved > 0 && resolved * 2 >= attempted }
    }

    /// The package's declared TOC: the EPUB 3 nav document when the manifest
    /// declares one, else the EPUB 2 NCX — each accepted only when it
    /// resolves at least half of the entries it attempted. Returns [] when
    /// no source is acceptable — the caller falls back to chapter headings.
    static func tableOfContents(
        opf: OPF, baseDir: String, container: EPUBContainer,
        chapterIndexByPath: [String: Int]
    ) throws -> [TOCEntry] {
        let lowercasedIndex = lowercasedChapterIndex(chapterIndexByPath)
        if let navID = opf.navItemID, let item = opf.manifest[navID] {
            let navPath = resolve(base: baseDir, href: item.href)
            if let data = try optionalData(container, at: navPath),
               let html = decodeText(data) {
                let source = navDocumentTOC(
                    html: html, navPath: navPath,
                    chapterIndexByPath: chapterIndexByPath,
                    lowercasedIndex: lowercasedIndex
                )
                if source.isAcceptable { return source.entries }
            }
        }
        if let ncxID = opf.ncxItemID, let item = opf.manifest[ncxID] {
            let ncxPath = resolve(base: baseDir, href: item.href)
            if let data = try optionalData(container, at: ncxPath) {
                let source = ncxTOC(
                    data: data, ncxDir: directory(of: ncxPath),
                    chapterIndexByPath: chapterIndexByPath,
                    lowercasedIndex: lowercasedIndex
                )
                if source.isAcceptable { return source.entries }
            }
        }
        return []
    }

    /// Fallback TOC when no declared source survives: one entry per LINEAR
    /// chapter — the chapter's heading when it has one, else "Section N"
    /// (1-based position in this list) — so heading-less books still get a
    /// complete Contents list. Non-linear chapters (notes files, in-spine
    /// nav pages) stay out of Contents.
    static func headingFallbackTOC(chapters: [Chapter]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for chapter in chapters where chapter.isLinear != false {
            entries.append(TOCEntry(
                title: chapter.title ?? "Section \(entries.count + 1)",
                chapterIndex: chapter.order
            ))
        }
        return entries
    }

    /// Case-folded chapter index for sloppy books whose TOC hrefs mismatch
    /// the manifest's case. On (pathological) case-insensitive collisions
    /// the earliest chapter wins, deterministically.
    static func lowercasedChapterIndex(_ index: [String: Int]) -> [String: Int] {
        var lowered: [String: Int] = [:]
        for (path, chapterIndex) in index {
            let key = path.lowercased()
            if let existing = lowered[key], existing <= chapterIndex { continue }
            lowered[key] = chapterIndex
        }
        return lowered
    }

    /// Resolve one TOC href/src to its chapter index and jump fragment.
    ///
    /// - A fragment-only href (`#ch4`) targets the document containing the
    ///   TOC itself: `ownDocumentPath` for a nav document. The NCX passes
    ///   nil there — a fragment-only `content src` is malformed, so the
    ///   entry is dropped.
    /// - A leading `/` is container-root-relative: resolved WITHOUT
    ///   prepending the TOC document's directory.
    /// - The lookup is exact first, then case-insensitive; `resolve` already
    ///   percent-decodes the path half.
    /// - The fragment is percent-decoded, matching `Chapter.anchors` ids
    ///   (which come from raw markup).
    static func tocTarget(
        href: String, baseDir: String, ownDocumentPath: String?,
        chapterIndexByPath: [String: Int], lowercasedIndex: [String: Int]
    ) -> (chapterIndex: Int, fragment: String?)? {
        let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? ""
        let fragment = (pieces.count > 1 ? String(pieces[1]) : nil).flatMap { raw -> String? in
            guard !raw.isEmpty else { return nil }
            return raw.removingPercentEncoding ?? raw
        }
        let path: String
        if rawPath.isEmpty {
            guard let ownDocumentPath else { return nil }
            path = ownDocumentPath
        } else if rawPath.hasPrefix("/") {
            path = resolve(base: "", href: String(rawPath.dropFirst()))
        } else {
            path = resolve(base: baseDir, href: rawPath)
        }
        guard let index = chapterIndexByPath[path] ?? lowercasedIndex[path.lowercased()] else {
            return nil
        }
        return (index, fragment)
    }

    /// Exact-duplicate key for TOC entries: only entries identical in
    /// chapter, fragment, AND title collapse; distinct sections of one
    /// document all survive.
    private static func tocDuplicateKey(
        _ target: (chapterIndex: Int, fragment: String?), title: String
    ) -> String {
        "\(target.chapterIndex)\u{0}\(target.fragment ?? "\u{1}")\u{0}\(title)"
    }

    /// The `<nav>` element holding the book's TOC: the first nav whose
    /// `epub:type` tokens include `toc` or whose `role` tokens include
    /// `doc-toc` (token match — `epub:type="no-toc"` must NOT qualify, which
    /// a `\btoc\b` regex got wrong at the hyphen); else the first nav that
    /// is NOT a landmarks/page-list nav; only then the first nav at all.
    static func tocNavBlock(in html: String) -> Substring? {
        var firstNav: Substring?
        var firstNonAuxiliaryNav: Substring?
        var remainder = Substring(html)
        while let match = remainder.range(of: "(?is)<nav\\b[^>]*>.*?</nav>", options: .regularExpression) {
            let block = remainder[match]
            remainder = remainder[match.upperBound...]
            guard let tagEnd = block.firstIndex(of: ">") else { continue }
            let tag = String(block[...tagEnd])
            let typeTokens = attributeTokens("epub:type", in: tag)
            if typeTokens.contains("toc") || attributeTokens("role", in: tag).contains("doc-toc") {
                return block
            }
            if firstNav == nil { firstNav = block }
            if firstNonAuxiliaryNav == nil, !typeTokens.contains("landmarks"),
               !typeTokens.contains("page-list") {
                firstNonAuxiliaryNav = block
            }
        }
        return firstNonAuxiliaryNav ?? firstNav
    }

    /// Whitespace-separated tokens of a tag attribute's value, lowercased.
    private static func attributeTokens(_ name: String, in tag: String) -> Set<String> {
        guard let value = XHTMLTextExtractor.attribute(name, in: tag) else { return [] }
        return Set(value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// EPUB 3 navigation document: the anchors inside the TOC `<nav>`, in
    /// document order. Regex-based like the text extractor — nav docs are
    /// XHTML with HTML entities (`&nbsp;`) that would abort a strict XML
    /// parse. Every entry is kept (books legitimately pack several
    /// chapters/sections into one XHTML file), with its fragment for
    /// in-document jumps; only exact duplicates collapse. Entries whose
    /// target isn't a parsed chapter are dropped (but still counted, so a
    /// mostly-broken nav fails the acceptance ratio).
    static func navDocumentTOC(
        html: String, navPath: String, chapterIndexByPath: [String: Int],
        lowercasedIndex: [String: Int]
    ) -> TOCSource {
        guard let block = tocNavBlock(in: html) else { return TOCSource() }
        let navDir = directory(of: navPath)
        var source = TOCSource()
        var seen = Set<String>()
        var remainder = block
        while let match = remainder.range(of: "(?is)<a\\b[^>]*>.*?</a>", options: .regularExpression) {
            let anchor = String(remainder[match])
            remainder = remainder[match.upperBound...]
            guard let tagEnd = anchor.firstIndex(of: ">") else { continue }
            let href = XHTMLTextExtractor.attribute("href", in: String(anchor[...tagEnd]))
            let title = anchor[anchor.index(after: tagEnd)...]
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let cleanTitle = XHTMLTextExtractor.decodeEntities(title)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let href, !href.isEmpty, !cleanTitle.isEmpty else { continue }
            source.attempted += 1
            guard let target = tocTarget(
                href: href, baseDir: navDir, ownDocumentPath: navPath,
                chapterIndexByPath: chapterIndexByPath, lowercasedIndex: lowercasedIndex
            ) else { continue }
            source.resolved += 1
            guard seen.insert(tocDuplicateKey(target, title: cleanTitle)).inserted else { continue }
            source.entries.append(TOCEntry(
                title: cleanTitle, chapterIndex: target.chapterIndex,
                fragment: target.fragment
            ))
        }
        return source
    }

    /// EPUB 2 NCX: navMap navPoints in document order, nesting flattened.
    /// Every navPoint is kept, with its (percent-decoded) fragment; only
    /// exact duplicates collapse. An NCX whose XML parse aborts mid-document
    /// (e.g. an undeclared `&nbsp;` entity) simply yields the points parsed
    /// before the abort — the shared acceptance ratio in `tableOfContents`
    /// decides whether that partial TOC still beats the next source.
    static func ncxTOC(
        data: Data, ncxDir: String, chapterIndexByPath: [String: Int],
        lowercasedIndex: [String: Int]
    ) -> TOCSource {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var source = TOCSource()
        var seen = Set<String>()
        for point in delegate.points {
            let title = point.title
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let src = point.src, !src.isEmpty else { continue }
            source.attempted += 1
            guard let target = tocTarget(
                href: src, baseDir: ncxDir, ownDocumentPath: nil,
                chapterIndexByPath: chapterIndexByPath, lowercasedIndex: lowercasedIndex
            ) else { continue }
            source.resolved += 1
            guard seen.insert(tocDuplicateKey(target, title: title)).inserted else { continue }
            source.entries.append(TOCEntry(
                title: title, chapterIndex: target.chapterIndex, fragment: target.fragment
            ))
        }
        return source
    }
}

/// Parsed OPF package document: metadata, manifest (id → href/type), spine order.
struct OPF {
    var title = ""
    var creators: [String] = []
    var language: String?
    var manifest: [String: (href: String, type: String)] = [:]
    /// Spine reading order; `linear` is false for `linear="no"` itemrefs
    /// (auxiliary content outside the main flow).
    var spineItems: [(idref: String, linear: Bool)] = []
    /// Manifest id of the EPUB3 cover item (`properties="cover-image"`).
    var coverItemID: String?
    /// Manifest id referenced by the EPUB2 `<meta name="cover" content="…"/>`.
    var metaCoverID: String?
    /// Manifest id of the EPUB3 navigation document (`properties="nav"`).
    var navItemID: String?
    /// ALL manifest ids carrying the `nav` property — an in-spine nav doc is
    /// non-linear whichever declaration order the manifest used.
    var navItemIDs: Set<String> = []
    /// Manifest id named by `<spine toc="…">` (the EPUB2 NCX).
    var spineTocID: String?
    /// True when the package declares pre-paginated (fixed) layout — the
    /// book-level `<meta property="rendition:layout">pre-paginated</meta>`
    /// or any spine item's `rendition:layout-pre-paginated` override.
    var isFixedLayout = false

    /// Manifest id for a spine idref. IDs are case-sensitive per spec, but
    /// sloppy real-world books mismatch case between spine and manifest —
    /// fall back to a case-insensitive match rather than dropping the chapter.
    func manifestID(for idref: String) -> String? {
        if manifest[idref] != nil { return idref }
        let lowered = idref.lowercased()
        return manifest.first { $0.key.lowercased() == lowered }?.key
    }

    /// The NCX manifest id: the spine's `toc` attribute when it resolves,
    /// else the first manifest item with the NCX media type.
    var ncxItemID: String? {
        if let id = spineTocID, manifest[id] != nil { return id }
        return manifest.first { $0.value.type == "application/x-dtbncx+xml" }?.key
    }

    static func parse(_ data: Data) -> OPF {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.opf
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    /// First rootfile carrying the EPUB package media-type.
    private var packagePath: String?
    /// First rootfile of any media-type — fallback for sloppy containers.
    private var firstPath: String?

    var rootfilePath: String? { packagePath ?? firstPath }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        guard elementName == "rootfile" || elementName.hasSuffix(":rootfile"),
              let path = attributeDict["full-path"], !path.isEmpty else { return }
        if firstPath == nil { firstPath = path }
        if packagePath == nil,
           attributeDict["media-type"] == "application/oebps-package+xml" {
            packagePath = path
        }
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var opf = OPF()
    /// Semantic key of the text run being captured ("title", "creator",
    /// "language", or "rendition:layout").
    private var capturing: String?
    /// Element local name whose end tag closes the capture (differs from
    /// `capturing` for `<meta property="rendition:layout">…</meta>`).
    private var capturingElement: String?
    private var buffer = ""

    /// Local name without the namespace prefix. XMLParser runs with namespace
    /// processing off, so `<dc:title>` and `<opf:itemref>` both arrive as
    /// qualified names — match on the suffix so any prefix works.
    private static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch Self.localName(elementName) {
        case "item":
            // Duplicate manifest ids: the first declaration wins.
            if let id = attributeDict["id"], let href = attributeDict["href"],
               opf.manifest[id] == nil {
                opf.manifest[id] = (href, attributeDict["media-type"] ?? "")
                let properties = (attributeDict["properties"] ?? "")
                    .split(whereSeparator: \.isWhitespace).map(String.init)
                if opf.coverItemID == nil, properties.contains("cover-image") {
                    opf.coverItemID = id
                }
                if properties.contains("nav") {
                    opf.navItemIDs.insert(id)
                    if opf.navItemID == nil { opf.navItemID = id }
                }
            }
        case "spine":
            opf.spineTocID = attributeDict["toc"]
        case "itemref":
            if let idref = attributeDict["idref"] {
                let linear = attributeDict["linear"]?.lowercased() != "no"
                opf.spineItems.append((idref: idref, linear: linear))
                if let properties = attributeDict["properties"],
                   properties.split(whereSeparator: \.isWhitespace)
                       .contains("rendition:layout-pre-paginated") {
                    opf.isFixedLayout = true
                }
            }
        case "meta":
            // EPUB2 cover convention: <meta name="cover" content="ITEM_ID"/>.
            if opf.metaCoverID == nil,
               attributeDict["name"] == "cover",
               let content = attributeDict["content"],
               !content.isEmpty {
                opf.metaCoverID = content
            }
            // EPUB3 rendition vocabulary: the layout value is text content.
            if attributeDict["property"] == "rendition:layout" {
                capturing = "rendition:layout"
                capturingElement = "meta"
                buffer = ""
            }
        case "title", "creator", "language":
            capturing = Self.localName(elementName)
            capturingElement = capturing
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard Self.localName(elementName) == capturingElement else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch capturing {
        case "title": if opf.title.isEmpty { opf.title = value }
        case "creator": if !value.isEmpty { opf.creators.append(value) }
        case "language": opf.language = value.isEmpty ? nil : value
        case "rendition:layout": if value == "pre-paginated" { opf.isFixedLayout = true }
        default: break
        }
        capturing = nil
        capturingElement = nil
    }
}

/// Collects NCX navMap navPoints — label text and content src — in document
/// order, flattening nesting.
private final class NCXDelegate: NSObject, XMLParserDelegate {
    struct NavPoint {
        var title = ""
        var src: String?
    }

    var points: [NavPoint] = []
    /// Indices into `points` for the currently open (nested) navPoints.
    private var openPoints: [Int] = []
    private var inNavLabel = false
    private var capturingText = false
    private var buffer = ""

    private static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch Self.localName(elementName) {
        case "navPoint":
            points.append(NavPoint())
            openPoints.append(points.count - 1)
        case "navLabel":
            inNavLabel = !openPoints.isEmpty
        case "text":
            // First navLabel of the innermost open navPoint wins.
            if inNavLabel, let top = openPoints.last, points[top].title.isEmpty {
                capturingText = true
                buffer = ""
            }
        case "content":
            if let top = openPoints.last, points[top].src == nil {
                points[top].src = attributeDict["src"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingText { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch Self.localName(elementName) {
        case "navPoint":
            if !openPoints.isEmpty { openPoints.removeLast() }
        case "navLabel":
            inNavLabel = false
        case "text":
            if capturingText, let top = openPoints.last {
                points[top].title = buffer
            }
            capturingText = false
        default:
            break
        }
    }
}
