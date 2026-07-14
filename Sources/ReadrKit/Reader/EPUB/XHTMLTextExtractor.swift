import Foundation

/// Extracts readable plain text from an EPUB XHTML content document. Tolerant of
/// minor markup quirks (uses scanning/regex rather than strict XML parsing) so a
/// slightly malformed chapter still yields text.
public enum XHTMLTextExtractor {

    private static let blockTags = [
        "p", "div", "br", "li", "tr", "section", "article", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// Container tags whose entire contents are non-content and get dropped.
    /// `rt`/`rp` hold ruby phonetic annotations — keeping them would duplicate
    /// the annotated base text in the extracted prose.
    private static let nonContentTags = ["script", "style", "head", "rt", "rp"]

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
        // Drop non-content blocks BEFORE scanning for <img>: an image inside
        // <script>/<style>/<head> must yield neither a placeholder nor a ref.
        // (Scanning first and letting `text(from:)` strip the blocks later
        // would delete those placeholders but keep their refs, pairing the
        // k-th surviving placeholder with the wrong `images[k]`.)
        var pruned = html
        for tag in nonContentTags {
            pruned = remove(tag: tag, in: pruned)
        }
        var images: [InlineImageRef] = []
        var s = ""
        var remainder = Substring(pruned)
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

    /// Value of an HTML attribute inside a single tag string. The name is
    /// anchored on its left so it can't match as the suffix of another
    /// attribute (asking for `src` must not match `data-src`).
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(
            of: "(?<![\\w-])\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')",
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
        // Drop non-content blocks entirely. (Also done up front by
        // `textAndImages`; repeating here keeps this legacy path complete on
        // its own.)
        for tag in nonContentTags {
            s = remove(tag: tag, in: s)
        }
        // Table cells: a space between cells keeps rows readable once the
        // markup is gone ("Name Age" instead of "NameAge"); `tr` below turns
        // each row into its own line.
        s = s.replacingOccurrences(
            of: "</t[dh]\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
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

    /// Decodes HTML character references — named and numeric — in one
    /// left-to-right pass. Single-pass matters for two reasons: it's linear on
    /// very large chapters (one scan, not one per entity), and it makes
    /// double-escaping correct by construction — `&amp;lt;` decodes the
    /// `&amp;` and then treats the following `lt;` as literal text, yielding
    /// `&lt;` rather than `<`. Unknown references are left intact.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"),
              let regex = try? NSRegularExpression(
                  pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);"
              ) else { return s }
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
