import SwiftUI
import ReadrKit

/// The Article studio — the design's Compose screen (docs/DESIGN.md): pick
/// highlights (all pre-checked, color-filterable) → optional direction →
/// Compose (streams onto the page) → editable draft → Copy / Share / export
/// `.md`. Entry points: the Notes panel CTA, the library "Highlights & Notes"
/// section, and the book context menu.
struct ArticleStudioView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @StateObject private var article: ArticleViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    /// Picker state. Selection is per annotation id; the color chips narrow
    /// both what's LISTED and what COMPOSES, so the article never quietly
    /// includes items the reader filtered out of sight.
    @State private var selectedIDs: Set<UUID> = []
    @State private var activeColors = Set(HighlightColor.allCases)
    @State private var didPreselect = false
    @State private var guidance = ""
    @State private var showExporter = false
    @State private var showProviders = false

    /// The design's direction placeholder — one line, tone/angle/length.
    private static let directionPlaceholder =
        "Optional direction — tone, angle, length… e.g. \u{201C}make it personal, 500 words\u{201D}"

    init(book: Book) {
        self.book = book
        _article = StateObject(wrappedValue: ArticleViewModel(book: book))
    }

    private var allItems: [AnnotationItem] {
        AnnotationItem.readingOrder(
            book: book,
            highlights: model.highlights(for: book),
            pdfHighlights: model.pdfHighlights(for: book)
        )
    }

    private var visibleItems: [AnnotationItem] {
        allItems.filter { activeColors.contains($0.color) }
    }

    private var composeSelection: [AnnotationItem] {
        visibleItems.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            content
                .background(theme.background)
                .navigationTitle(article.markdown.isEmpty ? "Article Studio" : article.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
                .fileExporter(
                    isPresented: $showExporter,
                    document: MarkdownDocument(text: article.markdown),
                    contentType: MarkdownDocument.markdownType,
                    defaultFilename: exportFilename
                ) { result in
                    if case .failure(let error) = result {
                        article.errorMessage = error.localizedDescription
                    }
                }
        }
        .onAppear {
            // Pre-check everything exactly once; later model changes (deletes,
            // recolors) must not silently re-check what the reader unchecked.
            guard !didPreselect else { return }
            didPreselect = true
            selectedIDs = Set(allItems.map(\.id))
        }
        .onDisappear { article.cancelComposing() }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 540, idealHeight: 640)
        #endif
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        if article.isComposing {
            // While streaming, the text stays read-only so user edits can't
            // interleave with (or be wiped by) incoming deltas. It streams
            // straight onto the page: serif on paper, 640pt measure.
            ScrollView {
                Text(article.markdown.isEmpty ? "Composing your article…" : article.markdown)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(11)
                    .foregroundStyle(article.markdown.isEmpty ? theme.muted : theme.inkColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 44)
            }
            .background(theme.paper)
        } else if !article.markdown.isEmpty {
            editor
        } else if allItems.isEmpty {
            // R7: the studio is reachable with zero highlights (the Create
            // Article CTA is always enabled) — this is tappable guidance, not
            // a dead end. Copy matches the create-article-empty mockup.
            // Checked before the no-provider case so opening the studio from an
            // un-highlighted book always lands on this guidance (there's
            // nothing to compose regardless of the provider).
            ContentUnavailableView {
                Label("Highlight something first", systemImage: "highlighter")
            } description: {
                Text("The studio turns your highlights into an article. Open the book, select a passage, and pick a color — it lands here instantly.")
            }
            .accessibilityIdentifier("article.noHighlights")
        } else if model.activeProvider() == nil {
            noProvider
        } else {
            picker
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Text(AppTheme.aiGlyph)
                    .foregroundStyle(theme.iris)
                Text("New article")
                    .foregroundStyle(theme.inkColor)
            }
            .font(.callout.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
        }
        if !article.isComposing && !article.markdown.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    startCompose()
                } label: {
                    quietAction("↻ Regenerate")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate")
                .help("Compose again from the same highlights (replaces this text)")
                Button {
                    showExporter = true
                } label: {
                    quietAction("Markdown")
                }
                .buttonStyle(.plain)
                .help("Save the article as a Markdown file")
                Button {
                    Pasteboard.copy(article.markdown)
                } label: {
                    quietAction("Copy")
                }
                .buttonStyle(.plain)
                .help("Copy the article as Markdown")
                ShareLink(item: article.markdown) {
                    quietAction("Share…")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Quiet hairline-bordered action chrome for the top bar.
    private func quietAction(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.muted)
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
            .contentShape(Rectangle())
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Create an article from your notes")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(theme.inkColor)
                Text(book.metadata.title)
                    .font(.footnote)
                    .foregroundStyle(theme.muted)
            }

            HStack(spacing: 12) {
                HighlightColorChips(active: $activeColors)
                Spacer()
                Text("\(composeSelection.count) of \(visibleItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.faint)
                Button {
                    selectedIDs.formUnion(visibleItems.map(\.id))
                } label: {
                    Text("All")
                        .font(.caption)
                        .underline()
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                Button {
                    selectedIDs.subtract(visibleItems.map(\.id))
                } label: {
                    Text("None")
                        .font(.caption)
                        .underline()
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
            }

            List {
                ForEach(visibleItems) { item in
                    pickerRow(item)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Text(AppTheme.aiGlyph)
                    .font(.callout)
                    .foregroundStyle(theme.iris)
                TextField(Self.directionPlaceholder, text: $guidance)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(theme.inkColor)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(theme.paper, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line, lineWidth: 1))
            }

            if let error = article.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(action: startCompose) {
                HStack(spacing: 7) {
                    Text(AppTheme.aiGlyph)
                    Text("Compose")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.background)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
                .opacity(composeSelection.isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(composeSelection.isEmpty)
            .accessibilityIdentifier("article.compose")
            .accessibilityLabel("Compose")
        }
        .padding()
    }

    /// A highlight card (marker spine, serif quote, ❋ note) with a leading
    /// checkbox — the studio's pickable version of the notes-list card.
    private func pickerRow(_ item: AnnotationItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.inkColor : theme.faint)
                    .padding(.top, 2)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ReadingTheme.markerSwatch(item.color))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\u{201C}\(item.quotedText)\u{201D}")
                        .font(.system(.subheadline, design: .serif))
                        .lineSpacing(5)
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(Text(item.quotedText))
                    if let note = item.note, !note.isEmpty {
                        // R6/D1: ❋ note marker is generic chrome — muted, not
                        // Iris (which stays reserved for AI moments).
                        (Text(AppTheme.noteGlyph).foregroundColor(theme.muted)
                            + Text(" ")
                            + Text(note).foregroundColor(theme.muted))
                            .font(.footnote)
                            .lineLimit(2)
                    }
                    Text(item.locator(in: book))
                        .font(.caption)
                        .foregroundStyle(theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Editor

    /// Editable draft on the page: the ✦ direction row up top (rewrite with
    /// new guidance), then a chrome-less serif editor on paper.
    private var editor: some View {
        VStack(spacing: 0) {
            directionRow
            TextEditor(text: $article.markdown)
                .font(.system(.body, design: .serif))
                .scrollContentBackground(.hidden)
                .foregroundStyle(theme.inkColor)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            if let error = article.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
            }
        }
        .background(theme.paper)
    }

    /// ✦ + optional direction + Rewrite — the existing guidance field and
    /// Recompose action wearing the design's row.
    private var directionRow: some View {
        HStack(spacing: 10) {
            Text(AppTheme.aiGlyph)
                .font(.callout)
                .foregroundStyle(theme.iris)
            TextField(Self.directionPlaceholder, text: $guidance)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(theme.inkColor)
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(theme.paper, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line, lineWidth: 1))
                .onSubmit(startCompose)
            Button(action: startCompose) {
                Text("Rewrite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Compose again with this direction (replaces this text)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    // MARK: Provider empty state

    private var noProvider: some View {
        ContentUnavailableView {
            Label("No AI provider connected", systemImage: "sparkles")
        } description: {
            // A6: derive the connection paths from what this build actually
            // exposes (no "sign in" while OAuth is hidden; no "pick a local
            // model" on iOS) so the copy never advertises a dead end.
            Text(SettingsModel.setupGuidance(toDo: "compose articles from your highlights"))
        } actions: {
            Button {
                showProviders = true
            } label: {
                Text("Open AI Providers")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showProviders) {
            ProviderSettingsView(app: model)
                .environmentObject(model)
        }
    }

    // MARK: Compose

    private func startCompose() {
        article.startComposing(
            highlights: composeSelection.map(Self.composerHighlight(for:)),
            guidance: guidance,
            provider: { await model.refreshedActiveProvider() }
        )
    }

    /// The composer only understands text `Highlight`s, so PDF annotations are
    /// bridged into synthetic ones: an unknown chapterID sorts them after the
    /// text highlights and `range.lowerBound = pageIndex` keeps them in page
    /// order — matching the reading order shown in the picker (see
    /// `LLMArticleComposer.orderedHighlights`).
    private static func composerHighlight(for item: AnnotationItem) -> Highlight {
        switch item {
        case .text(let highlight):
            return highlight
        case .pdf(let highlight):
            return Highlight(
                id: highlight.id,
                bookID: highlight.bookID,
                chapterID: highlight.id, // deliberately not a real chapter
                range: highlight.pageIndex..<(highlight.pageIndex + 1),
                quotedText: highlight.quotedText,
                note: highlight.note,
                createdAt: highlight.createdAt,
                color: highlight.color
            )
        }
    }

    // MARK: Export

    /// "/" and ":" break save panels/Finder; anything else in a title is fine.
    private var exportFilename: String {
        let safeTitle = book.metadata.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        return "Notes on \(safeTitle)"
    }
}
