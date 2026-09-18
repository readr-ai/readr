import SwiftUI
import ReadrKit

@main
struct ReadrApp: App {
    #if os(macOS)
    /// Only for window-frame repair (see `WindowFrameFitter`). Attached at the
    /// app level rather than as a view modifier on purpose: a representable in
    /// a `WindowGroup`'s content — and a `setFrame` during `viewDidMoveToWindow`
    /// — left windows created but never ordered on screen.
    @NSApplicationDelegateAdaptor(ReadrAppDelegate.self) private var appDelegate
    #endif

    /// One AppModel for every scene: the library window, each reader window,
    /// and Settings all share the same store, caches, and provider manager.
    /// Scenes receive it via `environmentObject` — never a second instance, or
    /// a highlight made in a reader window wouldn't show up in the library's
    /// Highlights & Notes review.
    ///
    /// The first-run sample book is seeded unless a UI-test launch owns the
    /// library: `-uiTestEmptyLibrary` asserts the empty-library guidance,
    /// which is still a real state (the user deletes everything), and
    /// `-uiTestSeed` supplies its own fixtures. Decided here, at the entry
    /// point, so the model itself never reads launch arguments for it and
    /// tests and previews pass their own answer.
    @StateObject private var model = AppModel(
        seedsSampleBook: !ProcessInfo.processInfo.arguments.contains("-uiTestEmptyLibrary")
            && !ProcessInfo.processInfo.arguments.contains("-uiTestSeed")
    )

    /// The reading theme also decides the SYSTEM color scheme of every window.
    /// Readr paints its own paper surfaces, so the OS appearance must follow
    /// the theme — otherwise a dark-mode Mac renders system-styled pieces
    /// (title bars, empty states, `.primary` text, popover chrome) in white on
    /// our light paper. Paper/Sepia pin light; Dark pins dark.
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue

    private var colorScheme: ColorScheme {
        (ReadingTheme(rawValue: themeRaw) ?? .paper) == .night ? .dark : .light
    }

    /// The library window's content, shared by both platform scene layouts so
    /// behavior attached here (like open-URL import) can't drift between them.
    /// `.onOpenURL` makes Readr an open-with target end to end: Finder
    /// double-click / "Open With" on macOS, Files/Mail/Safari "open in" on
    /// iOS (the document types are declared in project.yml). `importBook`
    /// handles the security-scoped access and copies the file, so opening
    /// in place is safe.
    private var libraryWindowContent: some View {
        LibraryShellView()
            .environmentObject(model)
            .preferredColorScheme(colorScheme)
            .onOpenURL { url in
                Task { await model.importBook(at: url) }
            }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            libraryWindowContent
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)

        // Every book opens in its own window, Apple-Books style. The scene is
        // keyed by Book.ID so `openWindow(value: book.id)` brings an existing
        // window for that book forward instead of spawning a duplicate.
        WindowGroup("Reader", for: Book.ID.self) { $bookID in
            ReaderWindowRoot(bookID: bookID)
                .environmentObject(model)
                .preferredColorScheme(colorScheme)
        }
        .windowToolbarStyle(.unifiedCompact)
        // Fits comfortably on a 13-inch Mac with the Dock and menu bar still
        // visible. Readers can grow it or enter full screen, but a first open
        // must not put the Ask composer below the desktop.
        .defaultSize(width: 780, height: 720)

        Settings {
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .frame(minWidth: 480, minHeight: 420)
                .preferredColorScheme(colorScheme)
        }
        #else
        WindowGroup {
            libraryWindowContent
        }
        #endif
    }
}

#if os(macOS)
/// Repairs window frames that macOS restored off the desktop.
///
/// The hook is "a window came forward", not "the app launched": that is after
/// the saved frame has been applied *and* after layout, it covers a reader
/// window opened hours into the session, and it touches nothing during window
/// creation — which is where the first attempt at this broke things.
final class ReadrAppDelegate: NSObject, NSApplicationDelegate {
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            WindowFrameFitter.fit(window)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
#endif

#if os(macOS)
/// Resolves a reader window's Book.ID against the live library. The id can
/// stop resolving — the book was deleted while its window was open, or state
/// restoration revived a window for a since-removed book — so show a friendly
/// fallback instead of a blank window.
private struct ReaderWindowRoot: View {
    @EnvironmentObject private var model: AppModel
    let bookID: Book.ID?

    var body: some View {
        Group {
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
        // Value-keyed SwiftUI windows otherwise inherit a zoom-only green
        // button and an over-tall content minimum from the reader hierarchy.
        .background(ReaderWindowConfigurator())
    }
}
#endif
