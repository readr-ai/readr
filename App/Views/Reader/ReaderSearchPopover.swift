import SwiftUI
import ReadrKit

/// In-book search UI (⌘F popover): a query field and a result list scanning
/// every chapter. ⏎ jumps to the first hit; clicking a row jumps to that hit.
/// The scan itself is `ReadrKit.BookSearcher`, run off the main actor.
/// Marginalia styling: elevated surface, paper field, hairlines, ink rows
/// with serif snippets.
struct ReaderSearchPopover: View {
    let book: Book
    /// Jump to (chapterIndex, characterOffset). The host closes the popover.
    var onJump: (Int, Int) -> Void

    @State private var query = ""
    @State private var results: [BookSearchResult] = []

    /// Matches the reader's persisted theme so the popover sits on the same
    /// palette as the page.
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Find in book", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.inkColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
                .accessibilityIdentifier("reader.search.field")
                .onSubmit {
                    if let first = results.first {
                        onJump(first.chapterIndex, first.characterOffset)
                    }
                }

            if results.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Search every chapter of this book."
                    : "No matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    Button {
                        onJump(result.chapterIndex, result.characterOffset)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.chapterTitle ?? "Chapter \(result.chapterIndex + 1)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(theme.muted)
                            Text(emphasized(result.snippet))
                                .font(.system(size: 12.5, design: .serif))
                                .foregroundStyle(theme.inkColor)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(theme.line)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                if results.count >= BookSearcher.resultCap {
                    Text("Showing the first \(BookSearcher.resultCap) matches.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 320, idealHeight: 400)
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
        .task(id: query) {
            // Debounce keystrokes — every scan walks the whole book.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            let found = await Self.scan(query, in: book)
            // A newer keystroke restarted the task mid-scan; drop the stale
            // (possibly partial) results — the new task owns `results` now.
            if Task.isCancelled { return }
            results = found
        }
    }

    /// The snippet with the matched term emphasized (bold + iris), so a list
    /// of similar excerpts is scannable — matching Apple Books' bolded hits.
    /// Case/diacritic-insensitive, mirroring `BookSearcher`'s matching.
    private func emphasized(_ snippet: String) -> AttributedString {
        var attributed = AttributedString(snippet)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty,
           let range = attributed.range(
               of: needle, options: [.caseInsensitive, .diacriticInsensitive]
           ) {
            attributed[range].font = .system(size: 12.5, design: .serif).bold()
            attributed[range].foregroundColor = theme.iris
        }
        return attributed
    }

    /// Runs the whole-book scan off the main actor: a non-isolated async
    /// function always hops to the global concurrent executor, so typing stays
    /// responsive while `BookSearcher` walks the chapters (checking task
    /// cancellation between them). `.task(id:)` publishes the results back on
    /// the MainActor above.
    private static func scan(_ query: String, in book: Book) async -> [BookSearchResult] {
        BookSearcher.search(query, in: book)
    }
}
