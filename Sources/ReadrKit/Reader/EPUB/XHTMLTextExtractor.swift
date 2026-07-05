import Foundation

/// Extracts readable plain text from an EPUB XHTML content document. Tolerant of
/// minor markup quirks (uses scanning/regex rather than strict XML parsing) so a
/// slightly malformed chapter still yields text.
public enum XHTMLTextExtractor {

    private static let blockTags = [
        "p", "div", "br", "li", "tr", "section", "article", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
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

        public init(src: String, alt: String? = nil) {
            self.src = src
            self.alt = alt
        }
    }

    /// Like `text(from:)`, but each `<img>` becomes `imagePlaceholder` in the
    /// text, and the images' `src`/`alt` are returned in document order — the
    /// k-th placeholder in the text corresponds to `images[k]`.
    public static func textAndImages(from html: String) -> (text: String, images: [InlineImageRef]) {
        var images: [InlineImageRef] = []
        var s = ""
        var remainder = Substring(html)
        // Replace every <img ...> with the placeholder, collecting srcs in order.
        while let match = remainder.range(of: "<img\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s += remainder[remainder.startIndex..<match.lowerBound]
            let tag = String(remainder[match])
            if let src = attribute("src", in: tag), !src.isEmpty {
                images.append(InlineImageRef(src: src, alt: attribute("alt", in: tag)))
                s.append(imagePlaceholder)
            }
            remainder = remainder[match.upperBound...]
        }
        s += remainder
        return (text(from: s), images)
    }

    /// Value of an HTML attribute inside a single tag string.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(
            of: "\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let pair = tag[range]
        guard let quoteStart = pair.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let value = pair[pair.index(after: quoteStart)..<pair.index(before: pair.endIndex)]
        return decodeEntities(String(value))
    }

    /// Plain text with paragraph breaks preserved.
    public static func text(from html: String) -> String {
        var s = html
        // Drop non-content blocks entirely.
        for tag in ["script", "style", "head"] {
            s = remove(tag: tag, in: s)
        }
        // Turn block-level boundaries into newlines.
        for tag in blockTags {
            s = s.replacingOccurrences(
                of: "</\(tag)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(
                of: "<\(tag)(\\s[^>]*)?/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        // Strip all remaining tags, decode entities, normalize whitespace.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    // MARK: - Helpers

    private static func remove(tag: String, in s: String) -> String {
        s.replacingOccurrences(
            of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>",
            with: "",
            options: .regularExpression
        )
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        // All entities except `&amp;`. These can be applied in any order.
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—",
                     "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                     "&ldquo;": "“", "&rdquo;": "”"]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#123; and &#x1F600;
        out = replaceNumericEntities(out)
        // `&amp;` MUST be decoded last so escaped sequences like `&amp;lt;` decode
        // to the literal text `&lt;` rather than being double-decoded to `<`.
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    private static func replaceNumericEntities(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                result += String(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }
}
