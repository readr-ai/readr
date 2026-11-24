import Foundation

/// Turns a PDF's per-page text into `Chapter`s — one per page, in page order.
///
/// The PDF parser itself needs PDFKit and lives in the app; the rule for what
/// its output means lives here so it is tested on CI. Two things it decides:
///
/// - **Every page is a chapter**, text or not. A page without text keeps its
///   slot (empty text) so "Page N" titles, the outline, and saved positions
///   stay aligned with the document. Skipping such pages — the old behaviour —
///   shifted every later page number.
/// - **A book with no text on any page is image-only**: a scanned book, or
///   screenshots exported as a PDF. That is not damage; PDFKit renders the
///   pages fine. The flag lets the app show them and say plainly which
///   features have nothing to work with.
public enum PDFPageChapters {
    public struct Result: Sendable {
        public var chapters: [Chapter]
        /// True when the document has pages and none of them carries text.
        /// An empty document is false: that is a different failure.
        public var isImageOnly: Bool
    }

    /// - Parameter pageTexts: one entry per page, in page order — the text
    ///   PDFKit extracted, or nil when it found none. Whitespace-only text
    ///   counts as none and is stored as empty, so `Chapter.hasText` and the
    ///   flag agree.
    public static func build(fromPageTexts pageTexts: [String?]) -> Result {
        let chapters = pageTexts.enumerated().map { index, pageText in
            let text = normalize(pageText ?? "")
            let hasText = text.contains { !$0.isWhitespace }
            return Chapter(title: "Page \(index + 1)", order: index, text: hasText ? text : "")
        }
        return Result(
            chapters: chapters,
            isImageOnly: !chapters.isEmpty && !chapters.contains(where: \.hasText)
        )
    }
    /// Remove layout-only wraps before offsets are assigned. Paragraph breaks
    /// and real in-line hyphens remain; all downstream narration uses these
    /// same normalized chapter coordinates.
    public static func normalizedOffset(ofCharacter offset: Int, in raw: String) -> Int {
        let units = normalizedUnits(raw)
        return units.firstIndex { $0.source >= max(0, offset) } ?? units.count
    }

    public static func normalizedText(_ raw: String) -> String { normalize(raw) }

    private struct Unit { var character: Character; var source: Int }
    private static func normalize(_ raw: String) -> String { String(normalizedUnits(raw).map(\.character)) }

    private static func normalizedUnits(_ raw: String) -> [Unit] {
        var units = raw.enumerated().compactMap { index, character -> Unit? in
            if character == "\u{00ad}" { return nil }
            return Unit(character: character == "\r\n" || character == "\r" ? "\n" : character, source: index)
        }
        func replace(_ pattern: String, with replacement: String) {
            let text = String(units.map(\.character))
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                let upper = text.distance(from: text.startIndex, to: range.upperBound)
                let source = units[lower].source
                units.replaceSubrange(lower..<upper, with: replacement.map { Unit(character: $0, source: source) })
            }
        }
        replace(#"(?<=[\p{L}])-\n[ \t]*(?=[\p{Ll}])"#, with: "")
        replace(#"[ \t]*\n(?:[ \t]*\n)+[ \t]*"#, with: "\n\n")
        replace(#"(?<!\n)[ \t]*\n[ \t]*(?!\n)"#, with: " ")
        while units.first?.character.isWhitespace == true { units.removeFirst() }
        while units.last?.character.isWhitespace == true { units.removeLast() }
        return units
    }
}
