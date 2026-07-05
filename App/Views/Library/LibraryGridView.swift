import SwiftUI
import ReadrKit

/// The bookshelf: an adaptive grid of covers with hover states (macOS),
/// hairline progress marks, PDF/Finished badges, a sort menu, and the per-book
/// context menu. The book list arrives already search-filtered from the shell;
/// this view only sorts and renders it.
///
/// Marginalia styling: a serif shelf-name header with the Import…/settings
/// buttons in the content (not the system toolbar), flat covers over the
/// theme background, and a 2px hairline progress track under every jacket.
struct LibraryGridView: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let books: [Book]
    /// The active sidebar search (empty when not searching) — used only to
    /// pick the right empty state.
    let query: String
    let openBook: (Book) -> Void
    /// Switches the shell's sidebar selection to Highlights & Notes.
    let showNotes: () -> Void
    @Binding var isImporting: Bool
    @Binding var showSettings: Bool

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    @AppStorage("librarySortOrder") private var sortRaw = LibrarySort.recent.rawValue
    @State private var hoveredBookID: Book.ID?
    /// Book whose Article Studio sheet is open (`sheet(item:)` drives it).
    @State private var articleBook: Book?
    /// Book awaiting delete confirmation.
    @State private var bookPendingDelete: Book?

    /// Design grid: minmax(158px, 1fr) with 26px column gaps.
    private static let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 220), spacing: 26)
    ]

    var body: some View {
        main
        .sheet(item: $articleBook) { book in
            ArticleStudioView(book: book)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Delete this book?",
            isPresented: Binding(
                get: { bookPendingDelete != nil },
                set: { if !$0 { bookPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: bookPendingDelete
        ) { book in
            Button("Delete \u{201C}\(book.metadata.title)\u{201D}", role: .destructive) {
                model.removeBook(book)
            }
            Button("Cancel", role: .cancel) {}
        } message: { book in
            Text("This removes \u{201C}\(book.metadata.title)\u{201D} and all of its highlights, notes, and bookmarks. This can\u{2019}t be undone.")
        }
    }

    @ViewBuilder
    private var main: some View {
        #if os(iOS)
        // Inline: the serif in-content header is the screen title; a large
        // nav-bar title would duplicate it.
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if books.isEmpty {
                emptyView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .background(theme.background)
        .navigationTitle(title)
    }

    // MARK: Header

    /// Serif shelf name on the left; sort, settings, and the bordered Import…
    /// button on the right (the design's header row).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkColor)
                .lineLimit(1)
            Spacer(minLength: 12)
            sortMenu
            LibraryHeaderButtons(
                isImporting: $isImporting,
                showSettings: $showSettings,
                theme: theme
            )
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.label).tag(sort.rawValue)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.muted)
                .padding(6)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Sort the library")
        .accessibilityLabel("Sort")
        .accessibilityIdentifier("library.sort")
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 30) {
                ForEach(sortedBooks) { book in
                    cell(for: book)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
    }

    /// `books` in the user's chosen order. Recent reuses the model's
    /// recently-added ordering (import time) rather than re-deriving it here,
    /// so Home's row and the grid can never disagree about "recent".
    private var sortedBooks: [Book] {
        switch LibrarySort(rawValue: sortRaw) ?? .recent {
        case .recent:
            let visible = Set(books.map(\.id))
            return model.recentlyAdded.filter { visible.contains($0.id) }
        case .title:
            return books.sorted {
                $0.metadata.title.localizedCaseInsensitiveCompare($1.metadata.title)
                    == .orderedAscending
            }
        case .author:
            return books.sorted {
                let a = $0.metadata.authors.first ?? ""
                let b = $1.metadata.authors.first ?? ""
                if a.localizedCaseInsensitiveCompare(b) != .orderedSame {
                    return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
                return $0.metadata.title.localizedCaseInsensitiveCompare($1.metadata.title)
                    == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if query.isEmpty {
            ContentUnavailableView(
                "Nothing here yet",
                systemImage: "books.vertical",
                description: Text("Use Import, or drag EPUB, PDF, or text files into the window.")
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: Cells

    private func cell(for book: Book) -> some View {
        let base = Button {
            openBook(book)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                cover(for: book)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.metadata.title)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.inkColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if !book.metadata.authors.isEmpty {
                        Text(book.metadata.authors.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                }
                LibraryProgressHairline(
                    fraction: LibraryProgress.fraction(
                        for: book, position: model.position(for: book)
                    ),
                    isFinished: model.bookState(for: book)?.isFinished == true,
                    theme: theme
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
        .contextMenu { contextMenuItems(for: book) }

        #if os(macOS)
        return base.onHover { hovering in
            // Only clear the id we own: hovering a neighbor sets it first, and
            // our delayed exit callback must not wipe the neighbor's state.
            if hovering {
                hoveredBookID = book.id
            } else if hoveredBookID == book.id {
                hoveredBookID = nil
            }
        }
        #else
        return base
        #endif
    }

    /// The jacket plus its overlays: PDF/Finished badges and the macOS hover
    /// treatment — a quiet 3pt lift with a slightly deeper shadow (the
    /// design's translateY(-3), .18s ease).
    private func cover(for book: Book) -> some View {
        let isHovered = hoveredBookID == book.id
        return BookCoverView(book: book, coverImage: model.coverImage(for: book))
            .overlay(alignment: .topLeading) {
                if model.isPDF(book) {
                    Text("PDF")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.bookState(for: book)?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.title3)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .padding(6)
                        .accessibilityLabel("Finished")
                }
            }
            .offset(y: isHovered ? -3 : 0)
            .shadow(color: .black.opacity(isHovered ? 0.20 : 0.0), radius: 14, x: 0, y: 10)
            .animation(.easeOut(duration: 0.18), value: isHovered)
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenuItems(for book: Book) -> some View {
        Button {
            openBook(book)
        } label: {
            Label("Open", systemImage: "book")
        }
        #if os(macOS)
        // Open already targets a window on macOS; this stays for parity with
        // the design spec's menu (and reads clearly for window-first users).
        Button {
            model.markOpened(book)
            openWindow(value: book.id)
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        #endif
        Divider()
        if model.bookState(for: book)?.isFinished == true {
            Button {
                model.setFinished(false, for: book)
            } label: {
                Label("Mark as Still Reading", systemImage: "arrow.uturn.backward.circle")
            }
        } else {
            Button {
                model.setFinished(true, for: book)
            } label: {
                Label("Mark as Finished", systemImage: "checkmark.circle")
            }
        }
        Button {
            showNotes()
        } label: {
            Label("Highlights & Notes", systemImage: "highlighter")
        }
        Button {
            articleBook = book
        } label: {
            Label("Create Article\u{2026}", systemImage: "doc.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            bookPendingDelete = book
        } label: {
            Label("Delete Book\u{2026}", systemImage: "trash")
        }
    }
}
