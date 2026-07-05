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
struct LibraryShellView: View {
    @EnvironmentObject private var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// Start on Home so a collapsed (iPhone) split view lands on content, not
    /// the bare sidebar list.
    @State private var selection: LibrarySidebarItem? = .home
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
        .tint(AppTheme.accent)
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
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        #if os(macOS)
        sidebarList
            .searchable(text: $query, placement: .sidebar, prompt: "Title or author")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        #else
        sidebarList
            .searchable(text: $query, prompt: "Title or author")
        #endif
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(LibrarySidebarItem.home)
                .accessibilityIdentifier("sidebar.home")
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .tag(LibrarySidebarItem.allBooks)
                    .accessibilityIdentifier("sidebar.allBooks")
                Label("Books", systemImage: "book")
                    .tag(LibrarySidebarItem.books)
                    .accessibilityIdentifier("sidebar.books")
                Label("PDFs", systemImage: "doc.text")
                    .tag(LibrarySidebarItem.pdfs)
                    .accessibilityIdentifier("sidebar.pdfs")
                Label("Finished", systemImage: "checkmark.circle")
                    .tag(LibrarySidebarItem.finished)
                    .accessibilityIdentifier("sidebar.finished")
            }
            Section("Notes") {
                Label("Highlights & Notes", systemImage: "highlighter")
                    .tag(LibrarySidebarItem.notes)
                    .accessibilityIdentifier("sidebar.notes")
            }
        }
        .navigationTitle("Readr")
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
                LibraryNotesView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole detail area accepts book files dragged in from
        // Finder/Files — on every screen, not just the empty state.
        .dropDestination(for: DroppedBookFile.self) { files, _ in
            Task {
                for file in files {
                    await model.importBook(at: file.url)
                }
            }
            return true
        }
    }

    private func grid(title: String, books: [Book]) -> LibraryGridView {
        LibraryGridView(
            title: title,
            books: searchFiltered(books),
            query: trimmedQuery,
            openBook: open,
            showNotes: { selection = .notes },
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
