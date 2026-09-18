import SwiftUI

#if os(macOS)
import AppKit

/// The Knowledge tab: every answer the reader saved, newest first, with the
/// links between them.
///
/// A list, not a document browser — the files live in the Finder and are meant
/// to be read there too (Obsidian, `grep`, a backup), so this tab's job is to
/// show what has been saved, let the reader re-read it without leaving the
/// book, follow a `[[link]]` to the notes that share a subject, and get out of
/// the way.
///
/// The list re-reads the folder whenever a save, a rename or a delete says it
/// changed (`KnowledgeBaseStore.changedNotification`) and on appearance, so a
/// note dropped in from outside shows up the next time the tab is opened.
/// Nothing is cached between appearances: the folder is the source of truth,
/// and it is small enough that re-reading it is cheaper than keeping a cache
/// honest — the reader may be editing these files while Readr is open.
struct KnowledgePanel: View {
    let theme: ReadingTheme

    @State private var index = KnowledgeBaseStore.Index()
    @State private var expandedPath: String?
    /// A `[[term]]` the reader tapped: the list narrows to the notes that
    /// mention it. This is what a link does here — a note does not have to
    /// exist under that name for its mentions to be worth finding.
    @State private var filterTerm: String?
    @State private var pendingDelete: KnowledgeBaseStore.Entry?

    private let store = KnowledgeBaseStore()

    /// What the list shows: everything, or the notes a tapped link points at.
    private var visibleNotes: [KnowledgeBaseStore.Entry] {
        guard let filterTerm else { return index.notes }
        return index.notes(referencing: filterTerm)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !index.notes.isEmpty {
                header
            }
            if let filterTerm {
                filterBar(filterTerm)
            }
            if visibleNotes.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.background)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: KnowledgeBaseStore.changedNotification)) { _ in
            reload()
        }
        .alert(
            "Delete this note?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                try? store.delete(entry)
                if expandedPath == entry.path { expandedPath = nil }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(entry.url.lastPathComponent + "\n\nThe file is deleted from the knowledge base folder.")
        }
    }

    // MARK: - Chrome

    /// How many, and where they are — the folder is the reader's, so the tab
    /// never hides it: one click opens it in the Finder.
    private var header: some View {
        HStack(spacing: 8) {
            Text("\(index.notes.count) note\(index.notes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(theme.muted)
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.root])
            } label: {
                Label("Open folder", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(theme.muted)
            }
            .buttonStyle(.plain)
            .help(store.folderPath)
            .accessibilityIdentifier("knowledge.openFolder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    /// What the current filter is, and the way out of it.
    private func filterBar(_ term: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 10))
            Text("[[\(term)]]")
                .font(.caption)
                .lineLimit(1)
            Text("· \(visibleNotes.count)")
                .font(.caption2)
                .foregroundStyle(theme.faint)
            Spacer(minLength: 0)
            Button {
                filterTerm = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Show all notes")
            .accessibilityIdentifier("knowledge.clearFilter")
        }
        .foregroundStyle(theme.iris)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.elevated)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        .accessibilityIdentifier("knowledge.filterBar")
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleNotes) { entry in
                    row(entry)
                    theme.line.frame(height: 1)
                }
            }
        }
        // Deleting an expanded note can shrink the document by thousands of
        // points. AppKit otherwise preserves the old NSScrollView offset,
        // leaving the viewport below the new document so the tab looks blank
        // until it is recreated by switching away and back. A changed set of
        // file paths is exactly a changed document: rebuild this one scroll
        // view and start it at a valid offset.
        .id(visibleNotes.map(\.path))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("knowledge.list")
    }

    private func row(_ entry: KnowledgeBaseStore.Entry) -> some View {
        let isExpanded = expandedPath == entry.path
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    expandedPath = isExpanded ? nil : entry.path
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // The dated content summary, and the original question
                    // under it, so the reader can find what they asked without
                    // opening the file.
                    Text(entry.title)
                        .font(.callout)
                        .foregroundStyle(theme.inkColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.title != entry.question {
                        Text(entry.question)
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                    }
                    Text(caption(entry))
                        .font(.caption2)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.row")
            .accessibilityLabel(entry.title)

            if isExpanded {
                if !entry.tags.isEmpty {
                    tagRow(entry.tags)
                }
                AnswerMarkdownView(markdown: entry.body, theme: theme)
                if !entry.links.isEmpty {
                    linkRow("Links to", terms: entry.links)
                }
                let back = index.mentioned(by: entry)
                if !back.isEmpty {
                    linkRow("Linked from", terms: back.map(\.title))
                }
                actions(entry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func tagRow(_ tags: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(theme.muted)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("knowledge.tags")
    }

    /// One row of `[[links]]`, each tappable: tapping narrows the list to the
    /// notes on that subject — the pair to the "Linked from" row below it.
    private func linkRow(_ label: String, terms: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.faint)
            FlowRow(spacing: 6) {
                ForEach(terms, id: \.self) { term in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            filterTerm = term
                            expandedPath = nil
                        }
                    } label: {
                        Text("[[\(term)]]")
                            .font(.caption)
                            .foregroundStyle(theme.iris)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the notes about \(term)")
                }
            }
        }
        .accessibilityIdentifier("knowledge.\(label)")
    }

    private func actions(_ entry: KnowledgeBaseStore.Entry) -> some View {
        HStack(spacing: 14) {
            Button("Show in Finder") { KnowledgeBaseStore.reveal(entry) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.muted)
            Button("Delete") { pendingDelete = entry }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// "The Whale · Chapter 12 · 17 Sep 2026" — book first (that is how the
    /// reader files their own reading), then where in it, then when.
    private func caption(_ entry: KnowledgeBaseStore.Entry) -> String {
        var parts = [entry.displayBook]
        if let chapter = entry.chapter, !chapter.isEmpty { parts.append(chapter) }
        if let saved = entry.savedAt { parts.append(Self.dateFormatter.string(from: saved)) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: filterTerm == nil ? "books.vertical" : "link.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(theme.faint)
            Text(filterTerm == nil ? "No saved notes yet" : "Nothing links there yet")
                .font(.callout)
                .foregroundStyle(theme.inkColor)
            Text(
                filterTerm == nil
                    ? "Save an answer to keep it — it lands in a folder of Markdown files you can read in any editor."
                    : "No note mentions that name. Clear the filter to see everything again."
            )
            .font(.caption)
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if filterTerm == nil {
                Button("Open folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.root])
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.background)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(theme.inkColor, in: Capsule())
                .padding(.top, 2)
                .accessibilityIdentifier("knowledge.openFolder.empty")
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("knowledge.empty")
    }

    /// Re-read the folder. A filter is deliberately kept even when nothing
    /// matches any more: the empty state then says what the filter is and how
    /// to clear it, which beats silently showing something else than the reader
    /// asked for.
    private func reload() {
        let refreshed = store.index()
        if let expandedPath,
           !refreshed.notes.contains(where: { $0.path == expandedPath }) {
            self.expandedPath = nil
        }
        index = refreshed
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// A `[[link]]` chip list that wraps onto as many lines as it needs. SwiftUI
/// has `Layout` for this in principle; an `HStack` of chips inside a scrolling
/// 280–480pt column overflows instead, so the terms are chunked by hand.
private struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        // A plain HStack with wrapping is not available before a custom Layout
        // is written; the links in one note are a handful of short names, so
        // two-or-three per line is enough structure.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
    }
}
#endif
