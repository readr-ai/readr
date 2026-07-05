import SwiftUI
import ReadrKit

@main
struct ReadrApp: App {
    /// One AppModel for every scene: the library window, each reader window,
    /// and Settings all share the same store, caches, and provider manager.
    /// Scenes receive it via `environmentObject` — never a second instance, or
    /// a highlight made in a reader window wouldn't show up in the library's
    /// Highlights & Notes review.
    @StateObject private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            LibraryShellView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)

        // Every book opens in its own window, Apple-Books style. The scene is
        // keyed by Book.ID so `openWindow(value: book.id)` brings an existing
        // window for that book forward instead of spawning a duplicate.
        WindowGroup("Reader", for: Book.ID.self) { $bookID in
            ReaderWindowRoot(bookID: bookID)
                .environmentObject(model)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 780, height: 920)

        Settings {
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 420)
        }
        #else
        WindowGroup {
            LibraryShellView()
                .environmentObject(model)
        }
        #endif
    }
}

#if os(macOS)
/// Resolves a reader window's Book.ID against the live library. The id can
/// stop resolving — the book was deleted while its window was open, or state
/// restoration revived a window for a since-removed book — so show a friendly
/// fallback instead of a blank window.
private struct ReaderWindowRoot: View {
    @EnvironmentObject private var model: AppModel
    let bookID: Book.ID?

    var body: some View {
        if let bookID, let book = model.books.first(where: { $0.id == bookID }) {
            ReaderView(book: book)
        } else {
            ContentUnavailableView(
                "Book Unavailable",
                systemImage: "book.closed",
                description: Text("This book is no longer in your library.")
            )
            .frame(minWidth: 400, minHeight: 300)
        }
    }
}
#endif
