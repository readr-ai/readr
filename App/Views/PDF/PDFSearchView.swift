import SwiftUI

#if canImport(PDFKit)

/// Find-in-PDF popover: query field + capped result list. Typing re-runs the
/// (synchronous, 200-result-capped) `findString` search after a short pause;
/// `.task(id:)` cancels the previous keystroke's sleep, so only the settled
/// query searches. Match paint on the pages is cleared when the popover goes.
struct PDFSearchView: View {
    let controller: PDFReaderController
    /// Jump to the tapped hit's page. The host closes the popover so the
    /// document is revealed — mirroring `ReaderSearchPopover`'s `onJump`.
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [PDFReaderController.SearchResult] = []
    @FocusState private var fieldFocused: Bool

    /// Matches the reader's persisted theme so the PDF find popover sits on the
    /// same Marginalia palette as the page — not system materials that read as
    /// stark white/gray chrome on sepia and dark (mirrors `ReaderSearchPopover`).
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search this PDF", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.inkColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
                .focused($fieldFocused)
                .onSubmit {
                    // ⏎ jumps to the first hit, matching the text reader.
                    if let first = results.first {
                        controller.jump(to: first)
                    }
                }
                .accessibilityIdentifier("pdf.search.field")

            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .padding(12)
        .frame(width: 360, height: 420)
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
        .onAppear { fieldFocused = true }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            results = controller.search(query)
        }
        .onDisappear { controller.clearSearch() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            ContentUnavailableView.search(text: query)
        } else {
            Text("Find every mention across the PDF.")
                .font(.callout)
                .foregroundStyle(theme.muted)
                .frame(maxHeight: .infinity)
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { result in
                    Button {
                        controller.jump(to: result)
                        onDismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("p. \(result.pageNumber)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(theme.muted)
                                .frame(width: 44, alignment: .leading)
                            Text(result.snippet)
                                .font(.system(size: 13, design: .serif))
                                .foregroundStyle(theme.inkColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pdf.search.result")
                    Divider().overlay(theme.line)
                }
            }
        }
    }
}
#endif
