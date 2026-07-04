import SwiftUI
import ReadrKit
import UniformTypeIdentifiers

/// The library shelf (J1): an Apple-Books-style grid of book covers with
/// drag-and-drop import alongside the file importer.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImporting = false
    @State private var showSettings = false

    /// Formats Readr can currently import. EPUB/PDF are accepted here and will be
    /// handled by the Readium parser once that M1 increment lands.
    private var importTypes: [UTType] {
        [.plainText, .epub, .pdf, UTType("net.daringfireball.markdown") ?? .plainText]
    }

    private static let gridColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    // Both directly visible: .secondaryAction collapses into an
                    // overflow menu on iOS, hiding the settings gear.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("AI Providers", systemImage: "gearshape")
                        }
                        .accessibilityLabel("AI providers")
                        Button {
                            isImporting = true
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                        .accessibilityLabel("Import book")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    ProviderSettingsView(app: model)
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: importTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case let .success(urls) = result, let url = urls.first {
                        Task { await model.importBook(at: url) }
                    }
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
        .tint(AppTheme.accent)
    }

    /// The shelf or the empty state, either way a drop target for book files
    /// dragged in from Finder/Files.
    private var content: some View {
        Group {
            if model.books.isEmpty {
                ContentUnavailableView(
                    "Your library is empty",
                    systemImage: "books.vertical",
                    description: Text("Drag a book here, or tap Import — EPUB, PDF, or text.")
                )
            } else {
                bookshelf
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: DroppedBookFile.self) { files, _ in
            Task {
                for file in files {
                    await model.importBook(at: file.url)
                }
            }
            return true
        }
    }

    private var bookshelf: some View {
        ScrollView {
            LazyVGrid(columns: Self.gridColumns, spacing: 28) {
                ForEach(model.books) { book in
                    bookCell(for: book)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func bookCell(for book: Book) -> some View {
        NavigationLink {
            ReaderView(book: book)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                BookCoverView(book: book, coverImage: model.coverImage(for: book))
                Text(book.metadata.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if !book.metadata.authors.isEmpty {
                    Text(book.metadata.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress = readingProgress(for: book) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
    }

    /// Fraction of the book read, based on the saved position's chapter index
    /// (chapter granularity is all the shelf needs). Nil when the book hasn't
    /// been opened yet, which hides the progress bar.
    private func readingProgress(for book: Book) -> Double? {
        guard let position = model.position(for: book) else { return nil }
        let chapterCount = max(book.chapters.count, 1)
        // Chapters *before* the current one are read; merely opening chapter
        // one is 0% (and a just-opened single-chapter book isn't "finished").
        let fraction = Double(position.chapterIndex) / Double(chapterCount)
        guard fraction > 0 else { return nil }
        return min(fraction, 1)
    }
}


/// A file dragged in from Finder/Files. Received as an *imported copy* in our
/// own temp directory: drop-provided `URL`s aren't security-scoped on iOS, so
/// reading them directly fails outside the sandbox — and the provider's inbox
/// copy can vanish before an async import runs.
private struct DroppedBookFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("readr-drop-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
