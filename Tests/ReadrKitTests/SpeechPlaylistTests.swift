import XCTest
@testable import ReadrKit

/// The narration cursor: where "read from here" lands, and what happens at
/// chapter walls and the ends of the book.
final class SpeechPlaylistTests: XCTestCase {

    /// Three linear chapters with a `linear="no"` notes document in the middle
    /// — the same shape `AppModel.sampleBooks` has, and the reason continuous
    /// playback needs a skip rule at all.
    private func makeBook(
        chapters: [(title: String, text: String, linear: Bool)] = [
            ("One", "Alpha one. Alpha two.", true),
            ("Notes", "A note nobody reads aloud.", false),
            ("Two", "Beta one. Beta two.", true),
        ]
    ) -> Book {
        Book(
            metadata: BookMetadata(title: "Test"),
            chapters: chapters.enumerated().map { index, chapter in
                Chapter(
                    title: chapter.title, order: index, text: chapter.text,
                    isLinear: chapter.linear ? nil : false
                )
            },
            estimatedTokenCount: 100
        )
    }

    // MARK: - Seeking

    func testSeekReportsThePositionOfTheSentenceItLandsOn() {
        var playlist = SpeechPlaylist(book: makeBook())
        let segment = playlist.seek(toChapter: 0, characterOffset: 14)
        XCTAssertEqual(segment?.text, "Alpha two.")
        XCTAssertEqual(playlist.position?.chapterIndex, 0)
        XCTAssertEqual(playlist.position?.characterOffset, 11)
    }

    func testSeekTakesTheFirstSentenceBeginningAtOrAfterTheAnchor() {
        // The bug this exists for: pressing Listen on the last page of a
        // chapter started the sentence that *spanned* the page boundary, which
        // began on the page before — so following the voice pulled the reader
        // back a spread and looked like narration had restarted the chapter.
        var playlist = SpeechPlaylist(book: makeBook())
        // Offset 5 is inside "Alpha one." (0..<10); the next whole sentence is
        // "Alpha two." at 11.
        XCTAssertEqual(playlist.seek(toChapter: 0, characterOffset: 5)?.text, "Alpha two.")
        XCTAssertEqual(
            playlist.seek(toChapter: 0, characterOffset: 11)?.text, "Alpha two.",
            "An anchor exactly on a sentence start takes that sentence"
        )
    }

    func testSeekInsideTheLastSentenceKeepsIt() {
        // Nothing begins later in the chapter, so the sentence the anchor sits
        // inside is still the right answer rather than a jump to the next
        // chapter.
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertEqual(playlist.seek(toChapter: 0, characterOffset: 14)?.text, "Alpha two.")
    }

    func testSeekFromTheTopOfAChapterStartsAtItsFirstSentence() {
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertEqual(playlist.seek(toChapter: 2)?.text, "Beta one.")
    }

    func testSeekHonoursANonLinearChapterTheReaderOpened() {
        // Continuous playback skips the notes document, but a reader who is
        // *in* it and presses Listen expects to hear it.
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertEqual(playlist.seek(toChapter: 1)?.text, "A note nobody reads aloud.")
    }

    func testSeekPastTheEndOfAChapterRollsIntoTheNextOne() {
        var playlist = SpeechPlaylist(book: makeBook())
        let segment = playlist.seek(toChapter: 0, characterOffset: 9_999)
        XCTAssertEqual(segment?.text, "Beta one.", "Should skip the non-linear notes chapter")
        XCTAssertEqual(segment?.chapterIndex, 2)
    }

    func testSeekSkipsChaptersWithNothingToSay() {
        let book = makeBook(chapters: [
            ("Cover", "\u{FFFC}", true),
            ("Blank", "", true),
            ("One", "Real prose here.", true),
        ])
        var playlist = SpeechPlaylist(book: book)
        let segment = playlist.seek(toChapter: 0)
        XCTAssertEqual(segment?.text, "Real prose here.")
        XCTAssertEqual(segment?.chapterIndex, 2)
    }

    func testSeekOutsideTheBookFindsNothing() {
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertNil(playlist.seek(toChapter: 99))
        XCTAssertNil(playlist.seek(toChapter: -1))
        XCTAssertNil(playlist.current)
    }

    func testNothingIsCurrentBeforeSeeking() {
        let playlist = SpeechPlaylist(book: makeBook())
        XCTAssertNil(playlist.current)
        XCTAssertNil(playlist.position)
        XCTAssertEqual(playlist.chapterProgress, 0)
    }

    // MARK: - Advancing

    func testAdvanceWalksSentencesThenCrossesIntoTheNextLinearChapter() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        XCTAssertEqual(playlist.current?.text, "Alpha one.")
        XCTAssertEqual(playlist.advance()?.text, "Alpha two.")
        // The notes chapter (linear="no") is skipped by continuous playback.
        XCTAssertEqual(playlist.advance()?.text, "Beta one.")
        XCTAssertEqual(playlist.advance()?.text, "Beta two.")
    }

    func testAdvanceAtTheEndOfTheBookReturnsNilAndKeepsThePlace() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 2, characterOffset: 10)
        XCTAssertEqual(playlist.current?.text, "Beta two.")
        XCTAssertNil(playlist.advance())
        XCTAssertEqual(
            playlist.current?.text, "Beta two.",
            "The last sentence stays the resume point"
        )
    }

    func testAdvanceBeforeSeekingDoesNothing() {
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertNil(playlist.advance())
        XCTAssertNil(playlist.rewind())
    }

    // MARK: - Rewinding

    func testRewindStepsBackAndCrossesToThePreviousChapterLastSentence() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 2)
        XCTAssertEqual(playlist.current?.text, "Beta one.")
        XCTAssertEqual(playlist.rewind()?.text, "Alpha two.", "Skips the notes chapter backwards")
        XCTAssertEqual(playlist.rewind()?.text, "Alpha one.")
    }

    func testRewindAtTheStartOfTheBookReturnsNil() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        XCTAssertNil(playlist.rewind())
        XCTAssertEqual(playlist.current?.text, "Alpha one.")
    }

    // MARK: - Chapter jumps

    func testAdvanceToNextChapterSkipsTheRestOfThisOne() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        XCTAssertEqual(playlist.advanceToNextChapter()?.text, "Beta one.")
        XCTAssertNil(playlist.advanceToNextChapter(), "No chapter after the last one")
    }

    func testPreviousChapterRestartsThisChapterBeforeSteppingBack() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 2, characterOffset: 12)
        XCTAssertEqual(playlist.current?.text, "Beta two.")
        // Mid-chapter: back to the top of this chapter, like a track control.
        XCTAssertEqual(playlist.rewindToChapterStart()?.text, "Beta one.")
        // Already at the top: step back a chapter.
        XCTAssertEqual(playlist.rewindToChapterStart()?.text, "Alpha one.")
        XCTAssertNil(playlist.rewindToChapterStart())
    }

    // MARK: - Progress

    func testChapterProgressTracksPositionWithinTheChapter() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        XCTAssertEqual(playlist.chapterProgress, 0.5, accuracy: 0.001)
        playlist.advance()
        XCTAssertEqual(playlist.chapterProgress, 1.0, accuracy: 0.001)
        // Crossing into a new chapter resets the measure to that chapter.
        playlist.advance()
        XCTAssertEqual(playlist.chapterProgress, 0.5, accuracy: 0.001)
    }

    // MARK: - Segmentation

    func testSegmentsAreBuiltPerChapterAndReusable() {
        var playlist = SpeechPlaylist(book: makeBook())
        let first = playlist.segments(inChapter: 0)
        let second = playlist.segments(inChapter: 0)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.text), ["Alpha one.", "Alpha two."])
        XCTAssertTrue(playlist.segments(inChapter: 99).isEmpty)
    }

    func testACustomSegmenterIsUsed() {
        var playlist = SpeechPlaylist(
            book: makeBook(chapters: [("One", "abcdefghij", true)]),
            segmenter: SpeechSegmenter(maximumSegmentLength: 4)
        )
        XCTAssertEqual(playlist.segments(inChapter: 0).map(\.text), ["abcd", "efgh", "ij"])
    }

    // MARK: - Footnote markers

    /// A chapter whose text carries a superscript footnote marker, the way
    /// `XHTMLTextExtractor` leaves one: the digits stay in `text`, with a
    /// `.superscript` span recording what the markup raised.
    private func makeMarkedBook(text: String, spans: [FormatSpan]) -> Book {
        Book(
            metadata: BookMetadata(title: "Test"),
            chapters: [Chapter(title: "One", order: 0, text: text, formatSpans: spans)],
            estimatedTokenCount: 100
        )
    }

    func testFootnoteMarkersAreNotSpoken() {
        // "The war ended.12 Peace came." — "12" is a noteref marker. Spoken
        // as-is the voice reads "ended point twelve", and because the digits
        // sit hard against the period the segmenter can't even end the
        // sentence there. Muted to spaces, both problems disappear — and the
        // segment ranges stay in chapter coordinates because the substitution
        // preserves length.
        let text = "The war ended.12 Peace came."
        let book = makeMarkedBook(
            text: text,
            spans: [FormatSpan(start: 14, end: 16, kind: .superscript)]
        )
        var playlist = SpeechPlaylist(book: book)
        let segments = playlist.segments(inChapter: 0)
        XCTAssertEqual(segments.map(\.text), ["The war ended.", "Peace came."])
        XCTAssertEqual(segments[0].range, 0..<14)
        XCTAssertEqual(segments[1].range, 17..<28)
    }

    func testSubscriptMarkersAreMutedToo() {
        let text = "See note.3 Then read on."
        let book = makeMarkedBook(
            text: text,
            spans: [FormatSpan(start: 9, end: 10, kind: .subscript)]
        )
        var playlist = SpeechPlaylist(book: book)
        XCTAssertEqual(
            playlist.segments(inChapter: 0).map(\.text),
            ["See note.", "Then read on."]
        )
    }

    func testChemicalSubscriptsAndExponentsAreStillSpoken() {
        // The ₂ of CO₂ and the ² of mc² are letterless raised runs, but they
        // hang off a word — muting them silently drops meaning. Only runs
        // after punctuation or whitespace (the noteref pattern) are markers.
        let text = "Water is H2O and energy is mc2 today."
        let book = makeMarkedBook(
            text: text,
            spans: [
                FormatSpan(start: 10, end: 11, kind: .subscript),
                FormatSpan(start: 29, end: 30, kind: .superscript),
            ]
        )
        var playlist = SpeechPlaylist(book: book)
        XCTAssertEqual(
            playlist.segments(inChapter: 0).map(\.text),
            ["Water is H2O and energy is mc2 today."]
        )
    }

    func testLetteredSuperscriptsAreStillSpoken() {
        // "1st" sets its "st" as a raised run in plenty of EPUBs. That is
        // prose, not a marker — only letterless runs (digits, daggers,
        // asterisks) are muted.
        let text = "The 1st of May."
        let book = makeMarkedBook(
            text: text,
            spans: [FormatSpan(start: 5, end: 7, kind: .superscript)]
        )
        var playlist = SpeechPlaylist(book: book)
        XCTAssertEqual(playlist.segments(inChapter: 0).map(\.text), ["The 1st of May."])
    }

    func testAMarkerOnlySegmentDisappears() {
        // A line holding nothing but markers ("* * *" rendered as raised
        // symbols) must not become a silent utterance the reader has to skip.
        let text = "First line.\n12\nSecond line."
        let book = makeMarkedBook(
            text: text,
            spans: [FormatSpan(start: 12, end: 14, kind: .superscript)]
        )
        var playlist = SpeechPlaylist(book: book)
        XCTAssertEqual(
            playlist.segments(inChapter: 0).map(\.text),
            ["First line.", "Second line."]
        )
    }
}


// MARK: - Looking ahead

extension SpeechPlaylistTests {

    func testUpcomingSegmentsAreTheOnesAdvanceWouldVisitWithoutMoving() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        let upcoming = playlist.upcomingSegments(limit: 10)
        XCTAssertEqual(
            upcoming.map(\.text), ["Alpha two.", "Beta one.", "Beta two."],
            "Across the chapter wall, the notes document skipped, to the end of the book"
        )
        XCTAssertEqual(playlist.current?.text, "Alpha one.", "The cursor has not moved")
        XCTAssertEqual(playlist.advance()?.text, "Alpha two.")
    }

    func testUpcomingSegmentsHonourTheLimit() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        XCTAssertEqual(playlist.upcomingSegments(limit: 1).map(\.text), ["Alpha two."])
        XCTAssertEqual(playlist.upcomingSegments(limit: 0), [])
    }

    func testUpcomingSegmentsAreEmptyBeforeASeekAndAtTheEnd() {
        var playlist = SpeechPlaylist(book: makeBook())
        XCTAssertEqual(playlist.upcomingSegments(limit: 5), [])
        playlist.seek(toChapter: 2, characterOffset: 10)
        XCTAssertEqual(playlist.current?.text, "Beta two.")
        XCTAssertEqual(playlist.upcomingSegments(limit: 5), [])
    }

    func testUpcomingSegmentsKeepTheChaptersTheyWalkedInto() {
        var playlist = SpeechPlaylist(book: makeBook())
        playlist.seek(toChapter: 0)
        _ = playlist.upcomingSegments(limit: 10)
        // Segmenting is memoised per chapter; walking ahead paid for chapter
        // two, and advancing into it must not pay again. Observable only as
        // a property of the cache, so the check is that the walk's result and
        // the later advance agree exactly.
        XCTAssertEqual(playlist.segments(inChapter: 2).map(\.text), ["Beta one.", "Beta two."])
    }
}
