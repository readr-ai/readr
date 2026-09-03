import XCTest
@testable import ReadrKit

/// The "where am I" line under a Recap: which chapter the reader is in, how
/// many there are, and how far through the book they've got. Counts linear
/// chapters only — a notes appendix the reader never pages through is not a
/// chapter they are "on" — and measures progress by characters, the same unit
/// the frontier is in.
final class ReadingPositionSummaryTests: XCTestCase {

    private func makeBook(chapters: [Chapter]) -> Book {
        Book(
            metadata: BookMetadata(title: "Test Book"),
            chapters: chapters,
            estimatedTokenCount: 100
        )
    }

    /// Four chapters of 100 characters each, in reading order.
    private func fourChapters() -> Book {
        makeBook(chapters: [
            Chapter(title: "Loomings", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "The Carpet-Bag", order: 1, text: String(repeating: "b", count: 100)),
            Chapter(title: "The Whale", order: 2, text: String(repeating: "c", count: 100)),
            Chapter(title: "Epilogue", order: 3, text: String(repeating: "d", count: 100)),
        ])
    }

    // MARK: - From a cached table

    /// The summary built from a `ReadingLengthTable` is the summary built
    /// from the book — the table is the same measurement, taken once.
    func testACachedTableGivesTheSameSummary() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "Notes", order: 1, text: String(repeating: "n", count: 100), isLinear: false),
            Chapter(title: nil, order: 2, text: String(repeating: "b", count: 100)),
        ])
        let table = ReadingLengthTable(book: book)
        for frontier in [
            ReadingFrontier(chapterIndex: 0, characterOffset: 25),
            ReadingFrontier(chapterIndex: 1, characterOffset: 50),
            ReadingFrontier(chapterIndex: 2, characterOffset: 50),
            ReadingFrontier(chapterIndex: 7, characterOffset: 0),
        ] {
            XCTAssertEqual(
                ReadingPositionSummary(book: book, frontier: frontier, lengths: table),
                ReadingPositionSummary(book: book, frontier: frontier),
                "frontier \(frontier)"
            )
        }
        let position = ReadingPosition(chapterIndex: 2, characterOffset: 50)
        XCTAssertEqual(
            ReadingPositionSummary(book: book, position: position, lengths: table),
            ReadingPositionSummary(book: book, position: position)
        )
    }

    // MARK: - Chapter N of M

    func testCountsTheChapterTheReaderIsInFromOne() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 0)
        )
        XCTAssertEqual(summary?.chapterNumber, 3)
        XCTAssertEqual(summary?.chapterCount, 4)
        XCTAssertEqual(summary?.chapterLine, "Chapter 3 of 4")
    }

    func testUsesTheChaptersOwnTitle() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 0)
        )
        XCTAssertEqual(summary?.chapterTitle, "The Whale")
    }

    func testFallsBackToChapterNWhenTheChapterHasNoTitle() {
        let book = makeBook(chapters: [
            Chapter(title: nil, order: 0, text: "aaaa"),
            Chapter(title: "   ", order: 1, text: "bbbb"),
        ])
        let first = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0))
        let second = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(first?.chapterTitle, "Chapter 1")
        XCTAssertEqual(second?.chapterTitle, "Chapter 2", "a blank title is no title")
    }

    /// A spine document with no title of its own belongs to the nearest TOC
    /// section before it — the same rule the reader's header uses.
    func testFallsBackToTheNearestTOCTitleBeforeChapterN() {
        var book = makeBook(chapters: [
            Chapter(title: nil, order: 0, text: "aaaa"),
            Chapter(title: nil, order: 1, text: "bbbb"),
            Chapter(title: nil, order: 2, text: "cccc"),
        ])
        book.metadata.tableOfContents = [
            TOCEntry(title: "Part One", chapterIndex: 0),
            TOCEntry(title: "Part Two", chapterIndex: 2),
        ]
        let mid = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0))
        let last = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 0))
        XCTAssertEqual(mid?.chapterTitle, "Part One")
        XCTAssertEqual(last?.chapterTitle, "Part Two")
    }

    /// Chapters are ordered by `order`, not by array position — the frontier
    /// index is a reading-order index, same as `ReadingFrontier`.
    func testFollowsReadingOrderNotArrayOrder() {
        let book = makeBook(chapters: [
            Chapter(title: "Second", order: 1, text: "SECOND"),
            Chapter(title: "First", order: 0, text: "FIRST"),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0))
        XCTAssertEqual(summary?.chapterTitle, "First")
        XCTAssertEqual(summary?.chapterNumber, 1)
    }

    // MARK: - Linear chapters only

    func testNonLinearChaptersAreLeftOutOfTheCount() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "Notes", order: 1, text: String(repeating: "n", count: 100), isLinear: false),
            Chapter(title: "Two", order: 2, text: String(repeating: "b", count: 100)),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 0))
        XCTAssertEqual(summary?.chapterNumber, 2)
        XCTAssertEqual(summary?.chapterCount, 2)
        XCTAssertEqual(summary?.chapterTitle, "Two")
    }

    /// Standing in a notes file counts as the last linear chapter passed —
    /// the reader followed a link out of it and will come back to it.
    func testStandingInANonLinearChapterCountsAsTheLastLinearChapterPassed() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "Notes", order: 1, text: String(repeating: "n", count: 100), isLinear: false),
            Chapter(title: "Two", order: 2, text: String(repeating: "b", count: 100)),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 50))
        XCTAssertEqual(summary?.chapterNumber, 1)
        XCTAssertEqual(summary?.chapterTitle, "One")
        XCTAssertEqual(summary?.percent, 50, "the notes file's text is not part of the book's length")
    }

    func testNonLinearTextDoesNotStretchThePercentDenominator() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "Two", order: 1, text: String(repeating: "b", count: 100)),
            Chapter(title: "Notes", order: 2, text: String(repeating: "n", count: 10_000), isLinear: false),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(summary?.percent, 50)
    }

    // MARK: - Percent

    func testPercentAtTheVeryStartIsZero() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0)
        )
        XCTAssertEqual(summary?.percent, 0)
    }

    func testPercentCountsEarlierChaptersAndTheOffsetIntoTheCurrentOne() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 25)
        )
        XCTAssertEqual(summary?.percent, 31, "100 + 25 of 400 characters, rounded")
    }

    func testPercentRoundsRatherThanTruncates() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 3)),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 2))
        XCTAssertEqual(summary?.percent, 67)
    }

    func testAnOffsetPastTheChapterEndIsClamped() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 10_000)
        )
        XCTAssertEqual(summary?.percent, 25)
        XCTAssertEqual(summary?.chapterNumber, 1)
    }

    func testANegativeOffsetIsClampedToTheChapterStart() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 1, characterOffset: -40)
        )
        XCTAssertEqual(summary?.percent, 25)
    }

    func testAFrontierPastTheLastChapterIsTheEndOfTheBook() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 99, characterOffset: 0)
        )
        XCTAssertEqual(summary?.percent, 100)
        XCTAssertEqual(summary?.chapterNumber, 4)
        XCTAssertEqual(summary?.chapterTitle, "Epilogue")
    }

    func testANegativeChapterIndexIsTheStartOfTheBook() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: -3, characterOffset: 500)
        )
        XCTAssertEqual(summary?.chapterNumber, 1)
        XCTAssertEqual(summary?.percent, 25, "the offset still applies, clamped to the first chapter")
    }

    // MARK: - Degenerate books

    func testAnEmptyBookHasNoSummary() {
        XCTAssertNil(ReadingPositionSummary(
            book: makeBook(chapters: []), frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0)
        ))
    }

    func testABookOfOnlyNonLinearChaptersHasNoSummary() {
        let book = makeBook(chapters: [
            Chapter(title: "Notes", order: 0, text: "nnnn", isLinear: false),
        ])
        XCTAssertNil(ReadingPositionSummary(
            book: book, frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0)
        ))
    }

    /// A picture book: chapters that are all images and no text. There is
    /// nothing to measure by, so progress falls back to whole chapters.
    func testImageOnlyChaptersFallBackToChapterCountForPercent() {
        let book = makeBook(chapters: [
            Chapter(title: "Plate I", order: 0, text: ""),
            Chapter(title: "Plate II", order: 1, text: ""),
            Chapter(title: "Plate III", order: 2, text: ""),
            Chapter(title: "Plate IV", order: 3, text: ""),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(summary?.chapterLine, "Chapter 2 of 4")
        XCTAssertEqual(summary?.percent, 25, "one of four chapters is behind the reader")
    }

    func testAnEmptyChapterAmongTextChaptersContributesNothingToPercent() {
        let book = makeBook(chapters: [
            Chapter(title: "One", order: 0, text: String(repeating: "a", count: 100)),
            Chapter(title: "Plate", order: 1, text: ""),
            Chapter(title: "Two", order: 2, text: String(repeating: "b", count: 100)),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 999))
        XCTAssertEqual(summary?.percent, 50)
        XCTAssertEqual(summary?.chapterNumber, 2)
    }

    // MARK: - The caption

    func testCaptionJoinsChapterPercentAndTitleWithMiddleDots() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), frontier: ReadingFrontier(chapterIndex: 2, characterOffset: 24)
        )
        XCTAssertEqual(summary?.caption, "Chapter 3 of 4 \u{00B7} 56% \u{00B7} The Whale")
    }

    /// "Chapter 2 of 4 · 25% · Chapter 2" says the same thing twice.
    func testCaptionDropsAFallbackTitleThatWouldRepeatTheChapterNumber() {
        let book = makeBook(chapters: [
            Chapter(title: nil, order: 0, text: "aaaa"),
            Chapter(title: nil, order: 1, text: "bbbb"),
        ])
        let summary = ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(summary?.caption, "Chapter 2 of 2 \u{00B7} 50%")
    }

    // MARK: - From a saved position

    func testBuildsFromAReadingPosition() {
        let summary = ReadingPositionSummary(
            book: fourChapters(), position: ReadingPosition(chapterIndex: 3, characterOffset: 50)
        )
        XCTAssertEqual(summary?.chapterLine, "Chapter 4 of 4")
        XCTAssertEqual(summary?.percent, 88)
    }
}
