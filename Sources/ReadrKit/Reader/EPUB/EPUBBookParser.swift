import Foundation

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

        // Non-linear spine items (linear="no": endnotes, answer keys) leave
        // the main reading flow but keep their content — appended after the
        // linear chapters rather than interleaved or dropped.
        let orderedSpine = opf.spineItems.filter { $0.linear } + opf.spineItems.filter { !$0.linear }
        guard orderedSpine.count <= Self.maxSpineItems else {
            throw EPUBParseError.tooManySpineItems(count: orderedSpine.count, limit: Self.maxSpineItems)
        }
        var chapters: [Chapter] = []
        var chapterIndexByPath: [String: Int] = [:]
        for entry in orderedSpine {
            guard let item = opf.manifestItem(for: entry.idref) else { continue }
            let href = Self.resolve(base: baseDir, href: item.href)
            guard let data = try Self.optionalData(container, at: href),
                  let html = Self.decodeText(data) else { continue }
            let (text, imageRefs) = XHTMLTextExtractor.textAndImages(from: html)
            guard !text.isEmpty else { continue }
            let title = XHTMLTextExtractor.firstHeading(from: html)
            // Image srcs are relative to the content document, not the OPF.
            let images = Self.chapterImages(
                in: text, refs: imageRefs, documentDir: Self.directory(of: href)
            )
            if chapterIndexByPath[href] == nil {
                chapterIndexByPath[href] = chapters.count
            }
            chapters.append(Chapter(
                title: title, order: chapters.count, text: text,
                images: images.isEmpty ? nil : images
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
            ? chapters.compactMap { chapter in
                chapter.title.map { TOCEntry(title: $0, chapterIndex: chapter.order) }
            }
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
                alt: ref.alt
            ))
        }
        return images
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

    /// The package's declared TOC: the EPUB 3 nav document when the manifest
    /// declares one, else the EPUB 2 NCX. Returns [] when neither exists or
    /// yields entries — the caller falls back to chapter headings.
    static func tableOfContents(
        opf: OPF, baseDir: String, container: EPUBContainer,
        chapterIndexByPath: [String: Int]
    ) throws -> [TOCEntry] {
        if let navID = opf.navItemID, let item = opf.manifest[navID] {
            let navPath = resolve(base: baseDir, href: item.href)
            if let data = try optionalData(container, at: navPath),
               let html = decodeText(data) {
                let entries = navDocumentTOC(
                    html: html, navDir: directory(of: navPath),
                    chapterIndexByPath: chapterIndexByPath
                )
                if !entries.isEmpty { return entries }
            }
        }
        if let ncxID = opf.ncxItemID, let item = opf.manifest[ncxID] {
            let ncxPath = resolve(base: baseDir, href: item.href)
            if let data = try optionalData(container, at: ncxPath) {
                let entries = ncxTOC(
                    data: data, ncxDir: directory(of: ncxPath),
                    chapterIndexByPath: chapterIndexByPath
                )
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    /// EPUB 3 navigation document: the anchors inside `<nav epub:type="toc">`
    /// (or `role="doc-toc"`), in document order. Regex-based like the text
    /// extractor — nav docs are XHTML with HTML entities (`&nbsp;`) that
    /// would abort a strict XML parse. Entries pointing at fragments of the
    /// same spine document collapse to one entry per chapter; entries whose
    /// target isn't a parsed chapter are dropped.
    static func navDocumentTOC(
        html: String, navDir: String, chapterIndexByPath: [String: Int]
    ) -> [TOCEntry] {
        let tocNav =
            "(?is)<nav\\b[^>]*(?:epub:type|role)\\s*=\\s*[\"'][^\"']*\\btoc\\b[^\"']*[\"'][^>]*>.*?</nav>"
        let anyNav = "(?is)<nav\\b[^>]*>.*?</nav>"
        let block: Substring
        if let range = html.range(of: tocNav, options: .regularExpression) {
            block = html[range]
        } else if let range = html.range(of: anyNav, options: .regularExpression) {
            block = html[range]
        } else {
            return []
        }
        var entries: [TOCEntry] = []
        var seenChapters = Set<Int>()
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
            guard let href, !href.isEmpty, !cleanTitle.isEmpty,
                  let index = chapterIndexByPath[resolve(base: navDir, href: href)],
                  !seenChapters.contains(index) else { continue }
            seenChapters.insert(index)
            entries.append(TOCEntry(title: cleanTitle, chapterIndex: index))
        }
        return entries
    }

    /// EPUB 2 NCX: navMap navPoints in document order, nesting flattened.
    static func ncxTOC(
        data: Data, ncxDir: String, chapterIndexByPath: [String: Int]
    ) -> [TOCEntry] {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var entries: [TOCEntry] = []
        var seenChapters = Set<Int>()
        for point in delegate.points {
            let title = point.title
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let src = point.src,
                  let index = chapterIndexByPath[resolve(base: ncxDir, href: src)],
                  !seenChapters.contains(index) else { continue }
            seenChapters.insert(index)
            entries.append(TOCEntry(title: title, chapterIndex: index))
        }
        return entries
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
    /// Manifest id named by `<spine toc="…">` (the EPUB2 NCX).
    var spineTocID: String?
    /// True when the package declares pre-paginated (fixed) layout — the
    /// book-level `<meta property="rendition:layout">pre-paginated</meta>`
    /// or any spine item's `rendition:layout-pre-paginated` override.
    var isFixedLayout = false

    /// Manifest item for a spine idref. IDs are case-sensitive per spec, but
    /// sloppy real-world books mismatch case between spine and manifest —
    /// fall back to a case-insensitive match rather than dropping the chapter.
    func manifestItem(for idref: String) -> (href: String, type: String)? {
        if let item = manifest[idref] { return item }
        let lowered = idref.lowercased()
        return manifest.first { $0.key.lowercased() == lowered }?.value
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
                if opf.navItemID == nil, properties.contains("nav") {
                    opf.navItemID = id
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
