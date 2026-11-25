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
        func horizontal(_ character: Character) -> Bool { character == " " || character == "\t" }
        // Join only a lowercase continuation of a letter-hyphen line wrap.
        // Scan once: neither regex backtracking nor shifting array suffixes is
        // bounded for untrusted pages containing long whitespace/wrap runs.
        var joined: [Unit] = []
        joined.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            if units[index].character == "-", index > 0, units[index - 1].character.isLetter,
               index + 1 < units.count, units[index + 1].character == "\n" {
                var next = index + 2
                while next < units.count && horizontal(units[next].character) { next += 1 }
                if next < units.count, units[next].character.isLowercase {
                    index = next
                    continue
                }
            }
            joined.append(units[index])
            index += 1
        }
        units = []
        units.reserveCapacity(joined.count)
        index = 0
        while index < joined.count {
            let start = index
            var newlines = 0
            while index < joined.count && (horizontal(joined[index].character) || joined[index].character == "\n") {
                if joined[index].character == "\n" { newlines += 1 }
                index += 1
            }
            if index == start {
                units.append(joined[index]); index += 1
            } else if newlines == 0 {
                units.append(contentsOf: joined[start..<index])
            } else {
                let source = joined[start].source
                units.append(Unit(character: newlines == 1 ? " " : "\n", source: source))
                if newlines > 1 { units.append(Unit(character: "\n", source: source)) }
            }
        }
        guard let first = units.firstIndex(where: { !$0.character.isWhitespace }),
              let last = units.lastIndex(where: { !$0.character.isWhitespace }) else { return [] }
        return Array(units[first...last])
    }
}
