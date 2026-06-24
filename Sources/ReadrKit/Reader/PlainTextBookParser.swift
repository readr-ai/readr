import Foundation

/// Parses plain-text and Markdown files into a `Book`, splitting chapters on
/// Markdown headings (`# ` / `## `). This is the dependency-free parser that CI
/// can exercise end-to-end; EPUB/PDF parsing is provided by the Readium-backed
/// parser in the app target (Apple platforms only).
public struct PlainTextBookParser: BookParser {
    public init() {}

    private static let extensions: Set<String> = ["txt", "text", "md", "markdown"]

    public func canParse(_ url: URL) -> Bool {
        Self.extensions.contains(url.pathExtension.lowercased())
    }

    public func parse(_ url: URL) async throws -> Book {
        let data = try Data(contentsOf: url)
        let title = url.deletingPathExtension().lastPathComponent
        return try parse(data: data, title: title)
    }

    /// Testable core: parse raw bytes with a known title.
    public func parse(data: Data, title: String) throws -> Book {
        guard !data.isEmpty else { throw BookParserError.corrupted("file is empty") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BookParserError.corrupted("file is not valid UTF-8 text")
        }
        let chapters = Self.splitChapters(text)
        guard !chapters.isEmpty else { throw BookParserError.corrupted("no readable text") }

        let toc = chapters.enumerated().compactMap { index, chapter -> TOCEntry? in
            chapter.title.map { TOCEntry(title: $0, chapterIndex: index) }
        }
        let metadata = BookMetadata(title: title, tableOfContents: toc)
        return Book(
            metadata: metadata,
            chapters: chapters,
            estimatedTokenCount: estimateTokens(text)
        )
    }

    /// Split into chapters on Markdown `# ` / `## ` headings. Text with no
    /// headings becomes a single untitled chapter.
    static func splitChapters(_ text: String) -> [Chapter] {
        var chapters: [Chapter] = []
        var currentTitle: String?
        var buffer: [String] = []
        var order = 0

        func flush() {
            let body = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentTitle != nil || !body.isEmpty {
                chapters.append(Chapter(title: currentTitle, order: order, text: body))
                order += 1
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: .newlines) {
            if let title = headingTitle(line) {
                flush()
                currentTitle = title
            } else {
                buffer.append(line)
            }
        }
        flush()
        return chapters
    }

    static func headingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("## ") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
