import Foundation

/// Parses an EPUB (via an `EPUBContainer`) into a `Book`: reads the container
/// pointer to the OPF package document, the spine reading order, the manifest,
/// metadata, and each spine document's text. DRM-protected EPUBs (those with an
/// `encryption.xml`) are rejected. Dependency-free and fully unit-tested; the
/// app target supplies a ZIP-backed container.
public struct EPUBBookParser {
    public init() {}

    public func parse(container: EPUBContainer, fallbackTitle: String) throws -> Book {
        if container.entryExists("META-INF/encryption.xml") {
            throw BookParserError.drmProtected
        }
        guard let containerData = try? container.data(at: "META-INF/container.xml"),
              let opfPath = Self.rootfilePath(from: containerData) else {
            throw BookParserError.corrupted("missing or invalid META-INF/container.xml")
        }
        guard let opfData = try? container.data(at: opfPath) else {
            throw BookParserError.corrupted("missing OPF package document at \(opfPath)")
        }

        let opf = OPF.parse(opfData)
        let baseDir = Self.directory(of: opfPath)

        var chapters: [Chapter] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let href = Self.resolve(base: baseDir, href: item.href)
            guard let data = try? container.data(at: href),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let text = XHTMLTextExtractor.text(from: html)
            guard !text.isEmpty else { continue }
            let title = XHTMLTextExtractor.firstHeading(from: html)
            chapters.append(Chapter(title: title, order: chapters.count, text: text))
        }
        guard !chapters.isEmpty else {
            throw BookParserError.corrupted("no readable content in the spine")
        }

        let toc = chapters.compactMap { chapter in
            chapter.title.map { TOCEntry(title: $0, chapterIndex: chapter.order) }
        }
        let metadata = BookMetadata(
            title: opf.title.isEmpty ? fallbackTitle : opf.title,
            authors: opf.creators,
            language: opf.language,
            tableOfContents: toc
        )
        let fullText = chapters.map(\.text).joined(separator: "\n\n")
        return Book(
            metadata: metadata,
            chapters: chapters,
            estimatedTokenCount: estimateTokens(fullText)
        )
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
}

/// Parsed OPF package document: metadata, manifest (id → href/type), spine order.
struct OPF {
    var title = ""
    var creators: [String] = []
    var language: String?
    var manifest: [String: (href: String, type: String)] = [:]
    var spine: [String] = []

    static func parse(_ data: Data) -> OPF {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.opf
    }
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if rootfilePath == nil, elementName == "rootfile" {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var opf = OPF()
    private var capturing: String?
    private var buffer = ""

    /// Local name without the namespace prefix. XMLParser runs with namespace
    /// processing off, so `<dc:title>` and `<dcterms:title>` both arrive as
    /// qualified names — match on the suffix so any DC prefix works.
    private static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                opf.manifest[id] = (href, attributeDict["media-type"] ?? "")
            }
        case "itemref":
            if let idref = attributeDict["idref"] { opf.spine.append(idref) }
        default:
            switch Self.localName(elementName) {
            case "title", "creator", "language":
                capturing = Self.localName(elementName)
                buffer = ""
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard Self.localName(elementName) == capturing else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch capturing {
        case "title": if opf.title.isEmpty { opf.title = value }
        case "creator": if !value.isEmpty { opf.creators.append(value) }
        case "language": opf.language = value
        default: break
        }
        capturing = nil
    }
}
