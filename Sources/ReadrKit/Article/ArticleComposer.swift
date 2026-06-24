import Foundation

/// A composed article generated from a reader's highlights and notes.
public struct Article: Sendable, Hashable {
    public var title: String
    public var markdown: String

    public init(title: String, markdown: String) {
        self.title = title
        self.markdown = markdown
    }
}

public enum ArticleComposerError: Error, Sendable, Equatable {
    /// There were no highlights to compose from — the UI should guide the reader
    /// to highlight something first. No LLM call is made.
    case noHighlights
}

/// Turns a set of highlights + notes into a coherent, editable article,
/// grounded in the book's context.
public protocol ArticleComposer: Sendable {
    func compose(
        from highlights: [Highlight],
        in book: Book,
        provider: LLMProvider
    ) async throws -> Article
}

/// Default LLM-backed composer. Orders highlights by **reading position**
/// (chapter order, then position within the chapter), feeds them with book
/// context, and asks the model for a structured Markdown article.
public struct LLMArticleComposer: ArticleComposer {
    public init() {}

    public func compose(
        from highlights: [Highlight],
        in book: Book,
        provider: LLMProvider
    ) async throws -> Article {
        var markdown = ""
        for try await delta in composeStreaming(from: highlights, in: book, provider: provider) {
            markdown += delta
        }
        return Article(title: "Notes on \(book.metadata.title)", markdown: markdown)
    }

    /// Streams the article's Markdown text deltas as the provider produces them.
    ///
    /// Guards against empty highlights (finishes throwing `.noHighlights` without
    /// making an LLM call), builds the same prompt as `compose`, and forwards the
    /// provider's text deltas. This is the single code path; `compose` simply
    /// accumulates the stream into a full `Article`.
    public func composeStreaming(
        from highlights: [Highlight],
        in book: Book,
        provider: LLMProvider
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard !highlights.isEmpty else {
                continuation.finish(throwing: ArticleComposerError.noHighlights)
                return
            }

            let prompt = Self.buildPrompt(highlights: highlights, book: book)
            let request = ChatRequest(
                messages: [.init(role: .user, content: prompt)],
                maxOutputTokens: 2048
            )

            let task = Task {
                do {
                    for try await chunk in provider.stream(request) {
                        continuation.yield(chunk.textDelta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt (exposed for testing)

    /// Highlights sorted into reading order: chapter order, then character
    /// position within the chapter, then capture time as a stable tiebreak.
    static func orderedHighlights(_ highlights: [Highlight], in book: Book) -> [Highlight] {
        let chapterOrder = Dictionary(
            book.chapters.map { ($0.id, $0.order) },
            uniquingKeysWith: { first, _ in first }
        )
        return highlights.sorted { lhs, rhs in
            let lo = chapterOrder[lhs.chapterID] ?? Int.max
            let ro = chapterOrder[rhs.chapterID] ?? Int.max
            if lo != ro { return lo < ro }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    static func buildPrompt(highlights: [Highlight], book: Book) -> String {
        let bullets = orderedHighlights(highlights, in: book).map { highlight -> String in
            // Collapse internal newlines so each highlight stays a single bullet.
            var line = "- \"\(singleLine(highlight.quotedText))\""
            if let rawNote = highlight.note {
                let note = singleLine(rawNote)
                if !note.isEmpty { line += " — note: \(note)" }
            }
            return line
        }.joined(separator: "\n")

        let authors = book.metadata.authors.joined(separator: ", ")
        let attribution = authors.isEmpty ? "" : " by \(authors)"
        return """
        Compose a coherent, well-structured article in Markdown from the reader's \
        highlights and notes below, taken from "\(book.metadata.title)"\(attribution). \
        Keep the highlights in the given (reading) order, weave them into a narrative \
        with headings, preserve the reader's intent, and keep all quotations accurate.

        Highlights and notes (in reading order):
        \(bullets)
        """
    }

    /// Collapse all internal whitespace/newlines to single spaces.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
