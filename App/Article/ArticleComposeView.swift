import SwiftUI
import ReadrKit

/// Composes an article from the book's highlights, shows it in an editable
/// Markdown editor, and lets the reader export/share it. (J6)
struct ArticleComposeView: View {
    @StateObject private var model: ArticleViewModel
    @Environment(\.dismiss) private var dismiss

    init(book: Book, highlights: [Highlight], resolveProvider: @escaping () -> LLMProvider?) {
        _model = StateObject(wrappedValue: ArticleViewModel(
            book: book, highlights: highlights, resolveProvider: resolveProvider
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        // Only export a finished article (not a half-streamed one).
                        if !model.isComposing && !model.markdown.isEmpty {
                            ShareLink(item: model.markdown) {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .cancelAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await model.compose() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isComposing {
            // While streaming, show the text read-only so user edits can't
            // interleave with (or be wiped by) incoming deltas.
            ScrollView {
                Text(model.markdown.isEmpty ? "Composing your article…" : model.markdown)
                    .font(.body)
                    .foregroundStyle(model.markdown.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if !model.markdown.isEmpty {
            // Streaming done — now editable.
            TextEditor(text: $model.markdown)
                .font(.body)
                .padding()
        } else {
            // No article yet: show the error (if any) plus a way to (re)compose.
            ContentUnavailableView {
                Label("Compose an article", systemImage: "doc.text")
            } description: {
                Text(model.errorMessage ?? "Turn your highlights and notes into an article.")
            } actions: {
                if model.hasHighlights {
                    Button("Compose") { Task { await model.compose() } }
                }
            }
        }
    }
}
