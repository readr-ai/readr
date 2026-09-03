import Foundation

/// Puts one book in the library the first time Readr runs, so that a fresh
/// install opens onto something readable instead of an empty shelf.
///
/// This exists because the empty state was a dead end for anyone with no
/// ebook already on the device. Apple's App Review hit it on 2026-09-01 and
/// rejected the build under guideline 2.1(a) — "unable to successfully access
/// all or part of the app" — but a reviewer is only the loudest instance of
/// the problem. Someone installing Readr on a new phone lands in the same
/// place: a screen that asks them to import a file they do not have yet.
///
/// The seeding is deliberately timid. It happens once, and only into a
/// library the user has never put anything into. Deleting the sample is a
/// decision, and a decision that gets undone on the next launch is not one.
public enum SampleBookSeeder {

    /// Whether the bundled sample belongs in this library.
    ///
    /// - Parameters:
    ///   - hasSeededBefore: whether seeding has ever run on this install.
    ///     Persisted by the caller, and true even if the book is now gone.
    ///   - hasPersistedLibrary: whether the library has ever been written —
    ///     `LibraryStore.hasPersistedLibrary`. A library the user emptied
    ///     has been written; a fresh install's has not.
    ///   - existingBookCount: books already in the library.
    public static func shouldSeed(
        hasSeededBefore: Bool, hasPersistedLibrary: Bool, existingBookCount: Int
    ) -> Bool {
        !hasSeededBefore && !hasPersistedLibrary && existingBookCount == 0
    }

    /// Runs `importBook` if the sample belongs in `store`, and returns what it
    /// imported. Returns `nil` when seeding was not called for — in which
    /// case `importBook` is never invoked, so no bundled file is opened or
    /// parsed.
    ///
    /// `importBook` is the app's regular import — the same path a file the
    /// user opens takes, so the sample gets its retained source, cover and
    /// added-on date like any other book — and it is responsible for adding
    /// the book to `store`. Errors from it propagate rather than being
    /// swallowed: the caller decides what a broken bundled resource means,
    /// and must record that seeding happened only when a book came back.
    @discardableResult
    public static func seedIfNeeded(
        into store: LibraryStore,
        hasSeededBefore: Bool,
        importBook: () async throws -> Book
    ) async throws -> Book? {
        guard shouldSeed(
            hasSeededBefore: hasSeededBefore,
            hasPersistedLibrary: store.hasPersistedLibrary,
            existingBookCount: store.allBooks().count
        ) else { return nil }
        return try await importBook()
    }
}
