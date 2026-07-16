import SwiftUI
import ReadrKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Unified annotation

/// One reviewable annotation — a text highlight or a native-PDF highlight —
/// unified so the Notes panel, the library review, and the Article studio can
/// render both kinds in a single reading-order list. Highlights must never be
/// trapped inside a book (docs/DESIGN.md, "the wedge").
enum AnnotationItem: Identifiable, Hashable {
    case text(Highlight)
    case pdf(PDFHighlight)

    var id: UUID {
        switch self {
        case .text(let highlight): return highlight.id
        case .pdf(let highlight): return highlight.id
        }
    }

    var quotedText: String {
        switch self {
        case .text(let highlight): return highlight.quotedText
        case .pdf(let highlight): return highlight.quotedText
        }
    }

    var note: String? {
        switch self {
        case .text(let highlight): return highlight.note
        case .pdf(let highlight): return highlight.note
        }
    }

    var color: HighlightColor {
        switch self {
        case .text(let highlight): return highlight.markerColor
        case .pdf(let highlight): return highlight.color
        }
    }

    /// Row caption naming where the annotation lives ("Chapter title" / "Page N").
    func locator(in book: Book) -> String {
        switch self {
        case .text(let highlight):
            if let chapter = book.chapters.first(where: { $0.id == highlight.chapterID }) {
                return chapter.title ?? "Chapter \(chapter.order + 1)"
            }
            return "Unknown chapter"
        case .pdf(let highlight):
            return "Page \(highlight.pageIndex + 1)"
        }
    }

    /// True when the quoted text or the note matches the search query.
    func matches(_ query: String) -> Bool {
        quotedText.localizedCaseInsensitiveContains(query)
            || (note?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// All of a book's annotations in reading order: text highlights by chapter
    /// order then position within the chapter, then PDF highlights by page.
    /// Mirrors `AnnotationMarkdownExporter`'s grouping so review and export agree.
    static func readingOrder(
        book: Book,
        highlights: [Highlight],
        pdfHighlights: [PDFHighlight]
    ) -> [AnnotationItem] {
        let chapterOrder = Dictionary(
            book.chapters.map { ($0.id, $0.order) },
            uniquingKeysWith: { first, _ in first }
        )
        let text = highlights.sorted { lhs, rhs in
            let lo = chapterOrder[lhs.chapterID] ?? Int.max
            let ro = chapterOrder[rhs.chapterID] ?? Int.max
            if lo != ro { return lo < ro }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.createdAt < rhs.createdAt
        }
        let pdf = pdfHighlights.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            return lhs.createdAt < rhs.createdAt
        }
        return text.map(AnnotationItem.text) + pdf.map(AnnotationItem.pdf)
    }
}

// MARK: - Small shared pieces

/// Cross-platform clipboard write ("Copy Markdown", article "Copy").
enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Horizontal row of color-dot toggle chips — "color is meaning", so review
/// filters by it (docs/DESIGN.md). All colors are on by default; tapping a dot
/// toggles that color in/out of the active set. Styled like the annotation
/// menu's dots: 19pt swatches with an ink ring on the selected ones.
struct HighlightColorChips: View {
    @Binding var active: Set<HighlightColor>

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HighlightColor.allCases, id: \.rawValue) { color in
                let isOn = active.contains(color)
                Button {
                    if isOn { active.remove(color) } else { active.insert(color) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(ReadingTheme.markerSwatch(color))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                            .frame(width: 19, height: 19)
                            .opacity(isOn ? 1 : 0.3)
                        if isOn {
                            Circle()
                                .strokeBorder(theme.inkColor.opacity(0.65), lineWidth: 1.5)
                                .frame(width: 25, height: 25)
                        }
                    }
                    // R5: keep the 25pt visual but expand the tappable area to
                    // at least 44×44 on touch (Apple HIG); macOS keeps the
                    // compact hit target since it's pointer-driven.
                    .frame(width: 25, height: 25)
                    .annotationTouchTarget()
                }
                .buttonStyle(.plain)
                .help("Show \(color.displayName.lowercased()) highlights")
                .accessibilityLabel("\(color.displayName) highlights")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

// MARK: - Annotation list

/// Filterable reading-order list of a book's annotations, shared by the Notes
/// panel (reader inspector) and the library "Highlights & Notes" review. Jump
/// callbacks are optional — the library review passes none because there is no
/// open reader to jump into. Rows are the Marginalia highlight cards: paper
/// field, hairline border, a marker-colored spine, serif quote, ❋ note line.
struct AnnotationListView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book
    var onJumpHighlight: ((Highlight) -> Void)? = nil
    var onJumpPDF: ((PDFHighlight) -> Void)? = nil
    /// R2: when a native PDF surface is mounted, recolor/delete of a PDF
    /// highlight must go through the PDF controller so the live PDFKit overlay
    /// is reconciled — updating the store alone leaves stale paint on the page.
    /// Nil (text mode / library review, where no overlay exists) ⇒ fall back to
    /// the model directly, which is correct there.
    var onRecolorPDF: ((PDFHighlight, HighlightColor) -> Void)? = nil
    var onDeletePDF: ((PDFHighlight) -> Void)? = nil

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    @State private var activeColors = Set(HighlightColor.allCases)
    @State private var searchText = ""
    @State private var editingItem: AnnotationItem?

    private var allItems: [AnnotationItem] {
        AnnotationItem.readingOrder(
            book: book,
            highlights: model.highlights(for: book),
            pdfHighlights: model.pdfHighlights(for: book)
        )
    }

    private var filteredItems: [AnnotationItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return allItems.filter { item in
            activeColors.contains(item.color) && (query.isEmpty || item.matches(query))
        }
    }

    var body: some View {
        if allItems.isEmpty {
            ContentUnavailableView {
                Label("No highlights yet", systemImage: "highlighter")
            } description: {
                Text("Select any passage while reading and pick a color — it appears here instantly.")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HighlightColorChips(active: $activeColors)
                searchField
                if filteredItems.isEmpty {
                    // Filters (color chips or search) matched nothing — keep the
                    // controls visible so the reader can widen them again.
                    Text("No matching highlights")
                        .font(.callout)
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .sheet(item: $editingItem) { item in
                NoteEditSheet(item: item) { text in
                    saveNote(text, for: item)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.faint)
            TextField("Search highlights", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.inkColor)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
    }

    private var list: some View {
        List {
            ForEach(filteredItems) { item in
                card(for: item)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .contextMenu { contextMenu(for: item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingItem = item
                        } label: {
                            Label("Edit Note", systemImage: "note.text")
                        }
                        .tint(theme.muted)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Cards

    /// One Marginalia highlight card. The quote is typographically quoted for
    /// display but keeps its raw text as the accessibility label so it remains
    /// findable as its own static text (the UI tests rely on this).
    private func card(for item: AnnotationItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ReadingTheme.markerSwatch(item.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text("\u{201C}\(item.quotedText)\u{201D}")
                    .font(.system(size: 14.5, design: .serif))
                    .lineSpacing(6)
                    .foregroundStyle(theme.inkColor)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(Text(item.quotedText))
                if let note = item.note, !note.isEmpty {
                    // R6/D1: the ❋ note marker is generic chrome, not an AI
                    // moment — it reads muted, keeping Iris reserved for AI.
                    (Text(AppTheme.noteGlyph).foregroundColor(theme.muted)
                        + Text(" ")
                        + Text(note).foregroundColor(theme.muted))
                        .font(.system(size: 12.5))
                        .lineSpacing(4)
                        .padding(.top, 8)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.locator(in: book))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if canJump(to: item) {
                        Button {
                            jump(to: item)
                        } label: {
                            Text("Show in book")
                                .font(.system(size: 11))
                                .underline()
                                .foregroundStyle(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this passage in the book")
                        .accessibilityIdentifier("notes.showInBook")
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 18))
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
    }

    private func canJump(to item: AnnotationItem) -> Bool {
        switch item {
        case .text: return onJumpHighlight != nil
        case .pdf: return onJumpPDF != nil
        }
    }

    private func jump(to item: AnnotationItem) {
        switch item {
        case .text(let highlight): onJumpHighlight?(highlight)
        case .pdf(let highlight): onJumpPDF?(highlight)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func contextMenu(for item: AnnotationItem) -> some View {
        Button {
            editingItem = item
        } label: {
            Label(item.note?.isEmpty == false ? "Edit Note" : "Add Note", systemImage: "note.text")
        }
        Menu {
            ForEach(HighlightColor.allCases, id: \.rawValue) { color in
                Button {
                    recolor(item, to: color)
                } label: {
                    if color == item.color {
                        Label(color.displayName, systemImage: "checkmark")
                    } else {
                        Text(color.displayName)
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        Divider()
        Button(role: .destructive) {
            delete(item)
        } label: {
            Label("Delete Highlight", systemImage: "trash")
        }
    }

    private func recolor(_ item: AnnotationItem, to color: HighlightColor) {
        switch item {
        case .text(var highlight):
            highlight.color = color
            model.updateHighlight(highlight)
        case .pdf(var highlight):
            // R2: route through the controller (which updates the store AND
            // recolors the live overlay) when a PDF surface is mounted; fall
            // back to the store alone where there's no overlay to reconcile.
            if let onRecolorPDF {
                onRecolorPDF(highlight, color)
            } else {
                highlight.color = color
                model.updatePDFHighlight(highlight)
            }
        }
    }

    private func delete(_ item: AnnotationItem) {
        switch item {
        case .text(let highlight):
            model.removeHighlight(highlight, in: book)
        case .pdf(let highlight):
            // R2: route through the controller (which removes the store record
            // AND the live overlay) when a PDF surface is mounted; fall back to
            // the store alone where there's no overlay to reconcile.
            if let onDeletePDF {
                onDeletePDF(highlight)
            } else {
                model.removePDFHighlight(highlight)
            }
        }
    }

    private func saveNote(_ text: String, for item: AnnotationItem) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Saving an empty editor clears the note rather than storing "".
        let note = trimmed.isEmpty ? nil : trimmed
        switch item {
        case .text(var highlight):
            highlight.note = note
            model.updateHighlight(highlight)
        case .pdf(var highlight):
            highlight.note = note
            model.updatePDFHighlight(highlight)
        }
    }
}

// MARK: - Note editor

/// Edits (or adds) the note attached to one annotation. The quote stays
/// visible above the editor so the reader remembers what they're annotating.
private struct NoteEditSheet: View {
    let item: AnnotationItem
    var onSave: (String) -> Void

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(item: AnnotationItem, onSave: @escaping (String) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: item.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("\u{201C}\(item.quotedText)\u{201D}")
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(theme.muted)
                    .lineLimit(3)
                    .accessibilityLabel(Text(item.quotedText))
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(theme.inkColor)
                    .padding(6)
                    .frame(minHeight: 120)
                    .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
            }
            .padding()
            .background(theme.elevated)
            .navigationTitle("Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}
