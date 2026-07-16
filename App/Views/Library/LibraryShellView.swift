import SwiftUI
import ReadrKit

/// Sidebar destinations for the library window.
enum LibrarySidebarItem: Hashable {
    case home, allBooks, books, pdfs, finished, notes
}

/// The v2 shell: a NavigationSplitView with a source-list sidebar (Home, the
/// library shelves, and the notes review) and a detail pane that swaps between
/// Home, filtered grids, and Highlights & Notes. Import, provider settings,
/// the import-failure alert, the drop target, and the open-book action all
/// live here so every subscreen shares one implementation of each.
///
/// Styled in the Marginalia design language: the whole shell reads the shared
/// reading theme ("readingTheme", the reader's key) so chrome always matches
/// the page — warm surfaces, hairlines, quiet sans chrome, serif wordmark.
struct LibraryShellView: View {
    @EnvironmentObject private var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    /// Start on Home so a collapsed (iPhone) split view lands on content, not
    /// the bare sidebar list.
    @State private var selection: LibrarySidebarItem? = .home
    /// R4: the book the per-book "Highlights & Notes" context menu invoked, so
    /// the review opens on that book rather than the first annotated one. Starts
    /// nil — the review then defaults to the first annotated book — and the
    /// review also falls back to the first book whenever this id no longer names
    /// an annotated book (e.g. after that book is deleted).
    @State private var selectedNotesBookID: UUID?
    @State private var query = ""
    @State private var isImporting = false
    @State private var showSettings = false
    #if os(iOS)
    /// iOS/compact: the reader is pushed onto the detail stack rather than
    /// opened in its own window.
    @State private var readingBook: Book?
    #endif

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background(theme.background)
        // R8: accept dragged-in book files everywhere the shell claims — the
        // sidebar and every detail screen, not just the empty state. Attached
        // once at the split-view root so a single handler covers both columns
        // (no per-screen duplication / double-handling).
        .dropDestination(for: DroppedBookFile.self) { files, _ in
            Task {
                for file in files {
                    await model.importBook(at: file.url)
                }
            }
            return true
        }
        // R6/D1: generic chrome (back chevron, split-view controls) reads the
        // neutral ink token — Iris stays reserved for AI moments only.
        .tint(theme.inkColor)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: LibraryImport.types,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.importBook(at: url) }
            }
        }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView(app: model)
                .environmentObject(model)
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { model.importError != nil },
                set: { if !$0 { model.importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.importError = nil }
        } message: {
            Text(model.importError ?? "")
        }
        // Informational sibling of the import-failure alert: the import
        // worked, but the book needs a caveat (fixed-layout shown as text).
        .alert(
            "About this book",
            isPresented: Binding(
                get: { model.importNotice != nil },
                set: { if !$0 { model.importNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.importNotice = nil }
        } message: {
            Text(model.importNotice ?? "")
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        #if os(macOS)
        sidebarList
            .searchable(text: $query, placement: .sidebar, prompt: "Title or author")
            .navigationSplitViewColumnWidth(206)
        #else
        sidebarList
            .searchable(text: $query, prompt: "Title or author")
        #endif
    }

    #if os(macOS)
    /// Marginalia sidebar: quiet text rows with right-aligned faint counts,
    /// serif wordmark up top, provider/privacy footer pinned to the bottom.
    /// A plain VStack of buttons drives the same `selection` state the old
    /// List did — the detail pane is always visible on macOS, so no List
    /// navigation semantics are lost.
    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("Readr")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.inkColor)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                navRow("Home", item: .home, id: "sidebar.home")
                sectionLabel("Library")
                navRow("All Books", item: .allBooks, count: model.books.count, id: "sidebar.allBooks")
                navRow("Books", item: .books, count: epubCount, id: "sidebar.books")
                navRow("PDFs", item: .pdfs, count: pdfCount, id: "sidebar.pdfs")
                navRow("Finished", item: .finished, count: finishedCount, id: "sidebar.finished")
                sectionLabel("Notes")
                navRow("Highlights & Notes", item: .notes, count: annotationCount, id: "sidebar.notes")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        .background(theme.background)
        .navigationTitle("Readr")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(theme.faint)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    private func navRow(
        _ title: String,
        item: LibrarySidebarItem,
        count: Int? = nil,
        id: String
    ) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.inkColor : theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.paper : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }
    #else
    /// iOS keeps the native List(selection:) so collapsed-width navigation
    /// (tap row → push detail) stays exactly as the system implements it;
    /// counts arrive as badges and surfaces take the reading theme.
    private var sidebarList: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(LibrarySidebarItem.home)
                .accessibilityIdentifier("sidebar.home")
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .badge(model.books.count)
                    .tag(LibrarySidebarItem.allBooks)
                    .accessibilityIdentifier("sidebar.allBooks")
                Label("Books", systemImage: "book")
                    .badge(epubCount)
                    .tag(LibrarySidebarItem.books)
                    .accessibilityIdentifier("sidebar.books")
                Label("PDFs", systemImage: "doc.text")
                    .badge(pdfCount)
                    .tag(LibrarySidebarItem.pdfs)
                    .accessibilityIdentifier("sidebar.pdfs")
                Label("Finished", systemImage: "checkmark.circle")
                    .badge(finishedCount)
                    .tag(LibrarySidebarItem.finished)
                    .accessibilityIdentifier("sidebar.finished")
            }
            Section("Notes") {
                Label("Highlights & Notes", systemImage: "highlighter")
                    .badge(annotationCount)
                    .tag(LibrarySidebarItem.notes)
                    .accessibilityIdentifier("sidebar.notes")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        .navigationTitle("Readr")
    }
    #endif

    /// The pinned sidebar footer: active model on the first line, the privacy
    /// promise faint below, over a top hairline (the design's provider pill).
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(providerLine)
                .foregroundStyle(theme.muted)
            Text("No telemetry · keys in Keychain")
                .foregroundStyle(theme.faint)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 22 = the sidebar rows' section inset + text padding — 10 alone
        // hugged the window edge and clipped the first character.
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            theme.line.frame(height: 1)
        }
        .background(theme.background)
    }

    /// "Local model" / the provider's name when one is connected and usable,
    /// otherwise the quiet nudge.
    private var providerLine: String {
        guard model.activeProvider() != nil,
              let kind = model.providerManager.selection?.kind else {
            return "No model connected"
        }
        switch kind {
        case .local: return "Local model"
        case .anthropic: return "Claude"
        case .openAI: return "ChatGPT"
        }
    }

    // MARK: Sidebar counts

    private var pdfCount: Int {
        model.books.filter { model.isPDF($0) }.count
    }

    private var epubCount: Int {
        model.books.count - pdfCount
    }

    private var finishedCount: Int {
        model.books.filter { model.bookState(for: $0)?.isFinished == true }.count
    }

    private var annotationCount: Int {
        model.books.reduce(0) {
            $0 + model.highlights(for: $1).count + model.pdfHighlights(for: $1).count
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        #if os(iOS)
        NavigationStack {
            detailContent
                .navigationDestination(item: $readingBook) { book in
                    ReaderView(book: book)
                }
        }
        #else
        detailContent
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            switch selection ?? .home {
            case .home:
                // Typing in the sidebar search while on Home switches to
                // search results — otherwise the query would appear to do
                // nothing until the user also clicked a library section.
                if trimmedQuery.isEmpty {
                    HomeView(
                        openBook: open,
                        isImporting: $isImporting,
                        showSettings: $showSettings
                    )
                } else {
                    grid(title: "Results", books: model.books)
                }
            case .allBooks:
                grid(title: "All Books", books: model.books)
            case .books:
                grid(title: "Books", books: model.books.filter { !model.isPDF($0) })
            case .pdfs:
                grid(title: "PDFs", books: model.books.filter { model.isPDF($0) })
            case .finished:
                grid(
                    title: "Finished",
                    books: model.books.filter { model.bookState(for: $0)?.isFinished == true }
                )
            case .notes:
                LibraryNotesView(selectedBookID: $selectedNotesBookID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        // R8: the drop target now lives at the NavigationSplitView root (see
        // `body`) so drag-drop import works over the sidebar too, not just this
        // detail area. Kept there as a single handler to avoid double-handling.
    }

    private func grid(title: String, books: [Book]) -> LibraryGridView {
        LibraryGridView(
            title: title,
            books: searchFiltered(books),
            query: trimmedQuery,
            openBook: open,
            showNotes: { book in
                selectedNotesBookID = book.id
                selection = .notes
            },
            isImporting: $isImporting,
            showSettings: $showSettings
        )
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Books matching the sidebar search, case-insensitively against title and
    /// authors; the input list unchanged when the query is empty.
    private func searchFiltered(_ books: [Book]) -> [Book] {
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return books }
        return books.filter { book in
            book.metadata.title.localizedCaseInsensitiveContains(trimmed)
                || book.metadata.authors.contains {
                    $0.localizedCaseInsensitiveContains(trimmed)
                }
        }
    }

    // MARK: Open

    /// The one way a book opens from the library: its own window on macOS, a
    /// push on iOS. Records `lastOpenedAt` up front so Home's Continue Reading
    /// reflects the open even before the reader view finishes appearing (the
    /// reader also records it — double-recording is harmless).
    private func open(_ book: Book) {
        model.markOpened(book)
        #if os(macOS)
        openWindow(value: book.id)
        #else
        readingBook = book
        #endif
    }
}
