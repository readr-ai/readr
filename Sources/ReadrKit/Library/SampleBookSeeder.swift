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
    ///   - existingBookCount: books already in the library.
    public static func shouldSeed(hasSeededBefore: Bool, existingBookCount: Int) -> Bool {
        !hasSeededBefore && existingBookCount == 0
    }

    /// Adds the sample to `store` if it belongs there, and returns it.
    /// Returns `nil` when seeding was not called for — in which case
    /// `makeBook` is never invoked, so no bundled file is opened or parsed.
    ///
    /// Errors from `makeBook` propagate rather than being swallowed: the
    /// caller decides what a broken bundled resource means, and the library
    /// is left untouched either way.
    @discardableResult
    public static func seedIfNeeded(
        into store: LibraryStore,
        hasSeededBefore: Bool,
        makeBook: () throws -> Book
    ) throws -> Book? {
        guard shouldSeed(
            hasSeededBefore: hasSeededBefore,
            existingBookCount: store.allBooks().count
        ) else { return nil }
        let book = try makeBook()
        try store.add(book)
        return book
    }
}
