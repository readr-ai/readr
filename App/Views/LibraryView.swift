import SwiftUI
import ReadrKit
import UniformTypeIdentifiers

/// The library shelf: import books and open them. (J1)
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isImporting = false
    @State private var showSettings = false

    /// Formats Readr can currently import. EPUB/PDF are accepted here and will be
    /// handled by the Readium parser once that M1 increment lands.
    private var importTypes: [UTType] {
        [.plainText, .epub, .pdf, UTType("net.daringfireball.markdown") ?? .plainText]
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.books.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "books.vertical",
                        description: Text("Import an EPUB, PDF, or text file to start reading.")
                    )
                } else {
                    List(model.books) { book in
                        NavigationLink {
                            ReaderView(book: book)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.metadata.title).font(.headline)
                                if !book.metadata.authors.isEmpty {
                                    Text(book.metadata.authors.joined(separator: ", "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Readr")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .accessibilityLabel("Import book")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("AI Providers", systemImage: "gearshape")
                    }
                    .accessibilityLabel("AI providers")
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
    }
}
