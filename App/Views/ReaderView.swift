import SwiftUI
import ReadrKit

/// Reading view for M1: renders chapter text with selection-based highlight
/// capture, remembers the chapter, and lists highlights. The Readium-backed
/// paginated renderer (reflow, fonts, decorations) replaces the text view within
/// M1; the select-text → Ask panel arrives in M3.
struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @State private var chapterIndex = 0
    @State private var didRestorePosition = false
    @State private var selectedRange: Range<Int>?
    @State private var showHighlights = false
    @State private var noteDraft = ""
    @State private var pendingNoteRange: Range<Int>?
    @State private var askSelection: Selection?
    @State private var showAsk = false

    private var chapter: Chapter? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    private var chapterHighlights: [Range<Int>] {
        guard let chapter else { return [] }
        return model.highlights(for: book)
            .filter { $0.chapterID == chapter.id }
            .map(\.range)
    }

    var body: some View {
        Group {
            if let chapter {
                VStack(spacing: 0) {
                    if let title = chapter.title {
                        Text(title)
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top)
                    }
                    SelectableTextView(
                        text: chapter.text,
                        highlightRanges: chapterHighlights,
                        onSelect: { selectedRange = $0 }
                    )
                    .padding()
                    selectionBar(for: chapter)
                }
            } else {
                ContentUnavailableView("No readable content", systemImage: "doc")
            }
        }
        .navigationTitle(book.metadata.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { chapterIndex = max(0, chapterIndex - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityIdentifier("prevChapter")
                .disabled(chapterIndex == 0)
                Button { chapterIndex = min(book.chapters.count - 1, chapterIndex + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityIdentifier("nextChapter")
                .disabled(chapterIndex >= book.chapters.count - 1)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showHighlights = true } label: {
                    Label("Highlights", systemImage: "highlighter")
                }
            }
        }
        .sheet(isPresented: $showHighlights) {
            HighlightsListView(book: book)
        }
        .sheet(isPresented: $showAsk) {
            AskPanelView(app: model, book: book, selection: askSelection)
                .environmentObject(model)
        }
        .sheet(item: noteSheetItem) { item in
            NoteEditor(text: $noteDraft) {
                if let chapter {
                    model.addHighlight(in: book, chapter: chapter, range: item.range, note: noteDraft)
                }
                noteDraft = ""
                pendingNoteRange = nil
            }
        }
        .onAppear {
            // Restore once; later re-appears (e.g. after dismissing a sheet)
            // must not clobber the chapter the reader navigated to.
            guard !didRestorePosition else { return }
            didRestorePosition = true
            chapterIndex = model.position(for: book)?.chapterIndex ?? 0
        }
        .onChange(of: chapterIndex) { _, newValue in
            selectedRange = nil
            model.savePosition(ReadingPosition(chapterIndex: newValue), for: book)
        }
    }

    @ViewBuilder
    private func selectionBar(for chapter: Chapter) -> some View {
        if let range = selectedRange {
            HStack {
                Button {
                    model.addHighlight(in: book, chapter: chapter, range: range)
                    selectedRange = nil
                } label: { Label("Highlight", systemImage: "highlighter") }
                Button {
                    pendingNoteRange = range
                } label: { Label("Add note", systemImage: "note.text") }
                Button {
                    askSelection = model.makeSelection(in: chapter, range: range)
                    showAsk = true
                } label: { Label("Ask", systemImage: "sparkles") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var noteSheetItem: Binding<RangeItem?> {
        Binding(
            get: { pendingNoteRange.map(RangeItem.init) },
            set: { if $0 == nil { pendingNoteRange = nil } }
        )
    }
}

private struct RangeItem: Identifiable {
    let range: Range<Int>
    var id: String { "\(range.lowerBound)-\(range.upperBound)" }
}

private struct NoteEditor: View {
    @Binding var text: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Note")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(); dismiss() }
                    }
                    ToolbarItem(placement: .cancelAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct HighlightsListView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var showArticle = false

    private var highlights: [Highlight] { model.highlights(for: book) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(highlights) { highlight in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlight.quotedText).italic()
                        if let note = highlight.note, !note.isEmpty {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let items = highlights
                    offsets.map { items[$0] }.forEach { model.removeHighlight($0, in: book) }
                }
            }
            .overlay {
                if highlights.isEmpty {
                    ContentUnavailableView("No highlights yet", systemImage: "highlighter")
                }
            }
            .navigationTitle("Highlights")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showArticle = true
                    } label: {
                        Label("Compose article", systemImage: "doc.text")
                    }
                    .disabled(highlights.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showArticle) {
                ArticleComposeView(
                    book: book,
                    highlights: highlights,
                    resolveProvider: { model.activeProvider() }
                )
            }
        }
    }
}
