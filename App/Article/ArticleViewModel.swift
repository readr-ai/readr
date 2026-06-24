import Foundation
import ReadrKit

/// Composes an article from a book's highlights via the active LLM provider, and
/// holds the editable Markdown result.
@MainActor
final class ArticleViewModel: ObservableObject {
    @Published var markdown = ""
    @Published var title = "Article"
    @Published var isComposing = false
    @Published var errorMessage: String?

    let hasHighlights: Bool

    private let book: Book
    private let highlights: [Highlight]
    /// Resolved at compose time so a provider configured/changed while the sheet
    /// is open is picked up.
    private let resolveProvider: () -> LLMProvider?
    private let composer = LLMArticleComposer()

    init(book: Book, highlights: [Highlight], resolveProvider: @escaping () -> LLMProvider?) {
        self.book = book
        self.highlights = highlights
        self.resolveProvider = resolveProvider
        self.hasHighlights = !highlights.isEmpty
    }

    func compose() async {
        // Don't recompose over an existing (possibly edited) article.
        guard markdown.isEmpty, !isComposing else { return }
        guard hasHighlights else {
            errorMessage = "Highlight something first to compose an article."
            return
        }
        guard let provider = resolveProvider() else {
            errorMessage = "Connect an AI provider in settings to compose articles."
            return
        }
        isComposing = true
        errorMessage = nil
        title = "Notes on \(book.metadata.title)"
        defer { isComposing = false }
        do {
            // Append deltas live so the editor fills in as the article streams.
            for try await delta in composer.composeStreaming(
                from: highlights, in: book, provider: provider
            ) {
                markdown += delta
            }
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Reset any partial whitespace-only output so the empty state shows.
                markdown = ""
                errorMessage = "The model returned an empty article. Try again."
                return
            }
        } catch ArticleComposerError.noHighlights {
            markdown = ""
            errorMessage = "Highlight something first to compose an article."
        } catch {
            markdown = ""
            errorMessage = error.localizedDescription
        }
    }
}
