import Foundation

/// Turns a book's annotations into clean, portable Markdown — the antidote to
/// Apple Books' locked-in highlights. Quotes become blockquotes, notes follow
/// them, and everything is grouped by chapter (text highlights) or page (PDF
/// highlights) in reading order.
public struct AnnotationMarkdownExporter: Sendable {
    public init() {}

    /// Markdown for a book's annotations. Either list may be empty; returns
    /// nil when both are (nothing to export).
    public func markdown(
        book: Book,
        highlights: [Highlight],
        pdfHighlights: [PDFHighlight] = []
    ) -> String? {
        guard !highlights.isEmpty || !pdfHighlights.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("# Highlights — \(book.metadata.title)")
        if !book.metadata.authors.isEmpty {
            lines.append("")
            lines.append("by \(book.metadata.authors.joined(separator: ", "))")
        }

        // Text highlights, grouped by chapter in reading order.
        let chapterOrder = Dictionary(
            uniqueKeysWithValues: book.chapters.map { ($0.id, $0.order) }
        )
        let byChapter = Dictionary(grouping: highlights, by: \.chapterID)
        let orderedChapterIDs = byChapter.keys.sorted {
            (chapterOrder[$0] ?? .max, $0.uuidString) < (chapterOrder[$1] ?? .max, $1.uuidString)
        }
        for chapterID in orderedChapterIDs {
            guard let items = byChapter[chapterID], !items.isEmpty else { continue }
            let chapter = book.chapters.first { $0.id == chapterID }
            let title = chapter?.title
                ?? chapter.map { "Chapter \($0.order + 1)" }
                ?? "Unknown chapter"
            lines.append("")
            lines.append("## \(title)")
            for highlight in items.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                lines.append("")
                lines.append(contentsOf: entry(
                    quote: highlight.quotedText,
                    color: highlight.markerColor,
                    note: highlight.note
                ))
            }
        }

        // PDF highlights, grouped by page.
        if !pdfHighlights.isEmpty {
            let byPage = Dictionary(grouping: pdfHighlights, by: \.pageIndex)
            for page in byPage.keys.sorted() {
                guard let items = byPage[page], !items.isEmpty else { continue }
                lines.append("")
                lines.append("## Page \(page + 1)")
                for highlight in items.sorted(by: { $0.createdAt < $1.createdAt }) {
                    lines.append("")
                    lines.append(contentsOf: entry(
                        quote: highlight.quotedText,
                        color: highlight.color,
                        note: highlight.note
                    ))
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// One annotation: a blockquote (multi-line safe), the color label, and
    /// the note if present.
    private func entry(quote: String, color: HighlightColor, note: String?) -> [String] {
        var lines = quote
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
        var meta = "— *\(color.displayName)*"
        if let note, !note.isEmpty {
            meta += " · Note: \(note)"
        }
        lines.append(">")
        lines.append("> \(meta)")
        return lines
    }
}
