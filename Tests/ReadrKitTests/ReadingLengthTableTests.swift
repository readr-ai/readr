import XCTest
@testable import ReadrKit

/// Chapter lengths measured once and read many times: the counts behind the
/// "Chapter N of M · P%" line, the "~N min left" estimate and the scoped
/// token budget must agree with the text they stand in for.
final class ReadingLengthTableTests: XCTestCase {

    private func makeBook() -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book"),
            chapters: [
                Chapter(title: "One", order: 0, text: "one two three four"),          // 18 chars, 4 words
                Chapter(title: "Notes", order: 1, text: "n1 n2", isLinear: false),    // 5 chars, 2 words
                Chapter(title: "Two", order: 2, text: "five six"),                    // 8 chars, 2 words
            ],
            estimatedTokenCount: 10
        )
    }

    func testMeasuresEveryChapterInReadingOrder() {
        let table = ReadingLengthTable(book: makeBook())
        XCTAssertEqual(table.entries.map(\.characters), [18, 5, 8])
        XCTAssertEqual(table.entries.map(\.words), [4, 2, 2])
        XCTAssertEqual(table.entries.map(\.isLinear), [true, false, true])
        XCTAssertEqual(table.chapterCount, 3)
        XCTAssertEqual(table.linearChapterCount, 2)
        XCTAssertEqual(table.totalLinearCharacters, 26, "the notes file is not part of the book's length")
    }

    func testFollowsReadingOrderNotArrayOrder() {
        let book = Book(
            metadata: BookMetadata(title: "Shuffled"),
            chapters: [
                Chapter(title: "Second", order: 1, text: "SECOND!"),
                Chapter(title: "First", order: 0, text: "FIRST"),
            ],
            estimatedTokenCount: 10
        )
        XCTAssertEqual(ReadingLengthTable(book: book).entries.map(\.characters), [5, 7])
    }

    /// `charactersRead` is what `textRead(upTo:)` would be, less the joins.
    func testCharactersReadMatchesTheTextRead() {
        let book = makeBook()
        let table = ReadingLengthTable(book: book)
        for frontier in [
            ReadingFrontier(chapterIndex: 0, characterOffset: 0),
            ReadingFrontier(chapterIndex: 0, characterOffset: 7),
            ReadingFrontier(chapterIndex: 1, characterOffset: 3),
            ReadingFrontier(chapterIndex: 2, characterOffset: 1_000),
            ReadingFrontier(chapterIndex: 9, characterOffset: 0),
            ReadingFrontier(chapterIndex: -2, characterOffset: 4),
        ] {
            let text = book.textRead(upTo: frontier)
            let joins = max(0, text.components(separatedBy: "\n\n").count - 1) * 2
            XCTAssertEqual(
                table.charactersRead(upTo: frontier), text.count - joins,
                "frontier \(frontier) — text read: \(text.debugDescription)"
            )
        }
    }

    func testLinearCharactersReadSkipsNonLinearChapters() {
        let table = ReadingLengthTable(book: makeBook())
        XCTAssertEqual(table.linearCharactersRead(upTo: ReadingFrontier(chapterIndex: 1, characterOffset: 3)), 18)
        XCTAssertEqual(table.linearCharactersRead(upTo: ReadingFrontier(chapterIndex: 2, characterOffset: 3)), 21)
        XCTAssertEqual(table.linearCharactersRead(upTo: ReadingFrontier(chapterIndex: 5, characterOffset: 0)), 26)
    }

    func testOffsetIsClampedIntoTheChapterAndFullPastTheEnd() {
        let table = ReadingLengthTable(book: makeBook())
        XCTAssertEqual(table.offset(at: ReadingFrontier(chapterIndex: 0, characterOffset: -4)), 0)
        XCTAssertEqual(table.offset(at: ReadingFrontier(chapterIndex: 0, characterOffset: 99)), 18)
        XCTAssertEqual(table.offset(at: ReadingFrontier(chapterIndex: 7, characterOffset: 0)), 8)
    }

    func testAnEmptyBookMeasuresNothing() {
        let table = ReadingLengthTable(book: Book(metadata: BookMetadata(title: "E"), chapters: [], estimatedTokenCount: 1))
        XCTAssertTrue(table.entries.isEmpty)
        XCTAssertEqual(table.charactersRead(upTo: ReadingFrontier(chapterIndex: 0, characterOffset: 5)), 0)
        XCTAssertEqual(table.offset(at: ReadingFrontier(chapterIndex: 0, characterOffset: 5)), 0)
    }

    // MARK: - The cache

    func testCacheMeasuresABookOnceAndForgetsItOnInvalidate() {
        let cache = ReadingLengthCache()
        let book = makeBook()
        let first = cache.table(for: book)
        var changed = book
        changed.chapters[0].text = "rewritten"
        XCTAssertEqual(cache.table(for: changed), first, "the same id is served from the cache")
        cache.invalidate(bookID: book.id)
        XCTAssertNotEqual(cache.table(for: changed), first, "invalidation re-measures")
    }

    // MARK: - Minutes left from the table

    func testMinutesLeftFromTheTableTracksTheCharactersAhead() {
        let words = Array(repeating: "word", count: 480).joined(separator: " ")
        let book = Book(
            metadata: BookMetadata(title: "T"),
            chapters: [Chapter(title: "One", order: 0, text: words)],
            estimatedTokenCount: 1
        )
        let table = ReadingLengthTable(book: book)
        let estimator = ReadingTimeEstimator()
        XCTAssertEqual(estimator.minutesLeft(in: table, at: ReadingFrontier(chapterIndex: 0, characterOffset: 0)), 2)
        XCTAssertEqual(
            estimator.minutesLeft(in: table, at: ReadingFrontier(chapterIndex: 0, characterOffset: words.count / 2)),
            estimator.minutesLeft(inChapterText: words, fromCharacterOffset: words.count / 2)
        )
        XCTAssertEqual(estimator.minutesLeft(in: table, at: ReadingFrontier(chapterIndex: 0, characterOffset: words.count)), 0)
        XCTAssertEqual(estimator.minutesLeft(in: table, at: ReadingFrontier(chapterIndex: 4, characterOffset: 0)), 0, "past the end")
    }

    func testMinutesLeftIsZeroForAnEmptyChapter() {
        let table = ReadingLengthTable(entries: [.init(characters: 0, words: 0, isLinear: true)])
        XCTAssertEqual(ReadingTimeEstimator().minutesLeft(in: table, at: ReadingFrontier(chapterIndex: 0, characterOffset: 0)), 0)
    }
}
