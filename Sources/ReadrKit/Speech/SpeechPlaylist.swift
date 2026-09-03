import Foundation

/// A cursor over a book's narratable text: which sentence is being read, and
/// what comes next once it ends.
///
/// Chapters are segmented lazily and cached, so starting narration in the
/// middle of a 900-page book costs one chapter's worth of work rather than the
/// whole book's. Continuous playback follows the same reading order the reader
/// pages through — spine entries marked `linear="no"` (notes documents, answer
/// keys) are skipped, exactly as `ReaderView`'s next/previous chapter moves
/// skip them — but a reader who *opens* such a chapter and presses Listen is
/// narrated from there: `seek` honours any chapter, only auto-advance filters.
public struct SpeechPlaylist: Sendable {
    public let book: Book

    private let segmenter: SpeechSegmenter
    private var cache: [Int: [SpeechSegment]] = [:]
    private var cursor: Cursor?

    private struct Cursor: Hashable, Sendable {
        var chapter: Int
        var segment: Int
    }

    public init(book: Book, segmenter: SpeechSegmenter = SpeechSegmenter()) {
        self.book = book
        self.segmenter = segmenter
    }

    // MARK: - Reading

    /// The segment the cursor is on, or nil before the first `seek`.
    public var current: SpeechSegment? {
        guard let cursor, let segments = cache[cursor.chapter],
              segments.indices.contains(cursor.segment) else { return nil }
        return segments[cursor.segment]
    }

    /// The reading position of `current`, for the reader to follow.
    public var position: NarrationPosition? {
        current.map {
            NarrationPosition(chapterIndex: $0.chapterIndex, characterOffset: $0.range.lowerBound)
        }
    }

    /// How far through the current chapter narration is, 0...1 (0 with no
    /// cursor). Cheap — the chapter it reports on is already segmented.
    public var chapterProgress: Double {
        guard let cursor, let segments = cache[cursor.chapter], !segments.isEmpty else {
            return 0
        }
        return Double(cursor.segment + 1) / Double(segments.count)
    }

    /// Segments of one chapter, built on first use and cached thereafter.
    ///
    /// Footnote markers are muted before segmentation: the chapter text keeps
    /// noteref digits inline (with a `.superscript`/`.subscript` span saying
    /// what the markup raised), and a voice reading "ended.12" says "ended
    /// point twelve" — worse, the digits sit hard against the period, so the
    /// segmenter can't even end the sentence there. Markers become spaces,
    /// which fixes both, and because the substitution preserves length every
    /// segment range stays a true chapter coordinate.
    public mutating func segments(inChapter index: Int) -> [SpeechSegment] {
        guard book.chapters.indices.contains(index) else { return [] }
        if let cached = cache[index] { return cached }
        let chapter = book.chapters[index]
        let built = segmenter.segments(
            ofChapterText: Self.speakableText(of: chapter), chapterIndex: index
        )
        cache[index] = built
        return built
    }

    /// The chapter's text with unspeakable marker runs blanked to spaces —
    /// same length, so offsets into it are offsets into `Chapter.text`.
    ///
    /// Muted: superscript/subscript runs containing no letters (footnote
    /// digits, daggers, asterisks) that don't hang off a word. Two things
    /// survive deliberately: a raised run *with* letters — the "st" of "1st",
    /// a spelled-out note — is prose; and a letterless run glued to a letter
    /// or digit — the ₂ of CO₂, the ² of mc² — is content whose muting would
    /// silently drop meaning (the span kinds' own docs name chemical formulas
    /// and exponents). A marker after a word's *punctuation* ("ended.12") is
    /// the noteref pattern and is muted. The cost: a marker jammed directly
    /// against its word with no punctuation is spoken — the old behavior —
    /// which reads wrong but loses nothing.
    static func speakableText(of chapter: Chapter) -> String {
        // One predicate, applied once: the raised runs are filtered up front,
        // which is also the fast path — a chapter with emphasis spans but no
        // raised runs must not pay for a character-array round trip.
        let raised = (chapter.formatSpans ?? []).filter {
            switch $0.kind {
            case .superscript, .subscript: return true
            default: return false
            }
        }
        guard !raised.isEmpty else { return chapter.text }
        var characters = Array(chapter.text)
        for span in raised {
            let lower = max(0, span.start)
            let upper = min(characters.count, span.end)
            guard lower < upper else { continue }
            let run = characters[lower..<upper]
            guard !run.contains(where: { $0.isLetter }) else { continue }
            if lower > 0, characters[lower - 1].isLetter || characters[lower - 1].isNumber {
                continue
            }
            for position in lower..<upper where !characters[position].isNewline {
                characters[position] = " "
            }
        }
        return String(characters)
    }

    /// The sentences that would follow `current` in continuous playback —
    /// the same walk `advance()` takes, non-linear chapters skipped — up to
    /// `limit` of them, without moving the cursor. Empty before the first
    /// `seek`. Chapters walked into are segmented and stay cached, so the
    /// eventual `advance()` into them is free.
    public mutating func upcomingSegments(limit: Int) -> [SpeechSegment] {
        guard limit > 0, cursor != nil else { return [] }
        // A copy walks ahead; only its cache comes back.
        var probe = self
        var upcoming: [SpeechSegment] = []
        while upcoming.count < limit, let next = probe.advance() {
            upcoming.append(next)
        }
        cache = probe.cache
        return upcoming
    }

    // MARK: - Moving

    /// Place the cursor at the first sentence that *begins* at or after
    /// `characterOffset` — the entry point for "read from here", whether *here*
    /// is the visible page, a chapter picked from the Contents list, or a
    /// selection.
    ///
    /// Begins-after, not contains. The anchor a reader presses Listen on is the
    /// top of the visible page, and the sentence spanning that boundary started
    /// on the page *before* it. Starting there read correctly but dragged the
    /// page backwards to follow the voice — on a device it looked like Listen
    /// had thrown the reader back a spread, and with a fixture whose paragraphs
    /// were identical it looked like it had restarted the chapter. The cost is
    /// that a sentence straddling the page break is skipped rather than
    /// half-read; the promise is "the first sentence of the page in front of
    /// you", and that is the sentence that keeps it.
    ///
    /// The fallback covers an anchor inside the chapter's final sentence, where
    /// nothing begins later: that sentence is still the right answer. A chapter
    /// with nothing left to read at all (empty, image-only, or an offset past
    /// its end) rolls forward into the next one with something to say. Returns
    /// nil only when the rest of the book is silent.
    @discardableResult
    public mutating func seek(toChapter index: Int, characterOffset: Int = 0) -> SpeechSegment? {
        guard book.chapters.indices.contains(index) else { return nil }
        let segments = self.segments(inChapter: index)
        if let position = segments.firstIndex(where: { $0.range.lowerBound >= characterOffset }) {
            cursor = Cursor(chapter: index, segment: position)
            return current
        }
        if let position = segments.firstIndex(where: { $0.range.upperBound > characterOffset }) {
            cursor = Cursor(chapter: index, segment: position)
            return current
        }
        return moveToChapter(after: index)
    }

    /// The next sentence, crossing into the next linear chapter at a chapter
    /// end. Nil at the end of the book, leaving the cursor on the last
    /// sentence so it stays the resume point.
    @discardableResult
    public mutating func advance() -> SpeechSegment? {
        guard let cursor else { return nil }
        let segments = self.segments(inChapter: cursor.chapter)
        if segments.indices.contains(cursor.segment + 1) {
            self.cursor = Cursor(chapter: cursor.chapter, segment: cursor.segment + 1)
            return current
        }
        return moveToChapter(after: cursor.chapter)
    }

    /// The previous sentence, crossing back into the previous linear chapter's
    /// last sentence at a chapter start. Nil at the start of the book.
    @discardableResult
    public mutating func rewind() -> SpeechSegment? {
        guard let cursor else { return nil }
        if cursor.segment > 0 {
            self.cursor = Cursor(chapter: cursor.chapter, segment: cursor.segment - 1)
            return current
        }
        return moveToChapter(before: cursor.chapter, landingOnLastSegment: true)
    }

    /// Skip to the first sentence of the next linear chapter.
    @discardableResult
    public mutating func advanceToNextChapter() -> SpeechSegment? {
        guard let cursor else { return nil }
        return moveToChapter(after: cursor.chapter)
    }

    /// Previous-chapter control, the way a track control behaves: restart this
    /// chapter when narration is already past its first sentence, otherwise
    /// step back to the previous chapter.
    @discardableResult
    public mutating func rewindToChapterStart() -> SpeechSegment? {
        guard let cursor else { return nil }
        if cursor.segment > 0 {
            self.cursor = Cursor(chapter: cursor.chapter, segment: 0)
            return current
        }
        return moveToChapter(before: cursor.chapter, landingOnLastSegment: false)
    }

    // MARK: - Chapter walking

    /// First segment of the next chapter that is both linear and narratable.
    /// Leaves the cursor untouched when there is none.
    private mutating func moveToChapter(after index: Int) -> SpeechSegment? {
        var candidate = index + 1
        while book.chapters.indices.contains(candidate) {
            if book.chapters[candidate].isLinear != false,
               !segments(inChapter: candidate).isEmpty {
                cursor = Cursor(chapter: candidate, segment: 0)
                return current
            }
            candidate += 1
        }
        return nil
    }

    private mutating func moveToChapter(
        before index: Int, landingOnLastSegment: Bool
    ) -> SpeechSegment? {
        var candidate = index - 1
        while book.chapters.indices.contains(candidate) {
            if book.chapters[candidate].isLinear != false {
                let segments = self.segments(inChapter: candidate)
                if !segments.isEmpty {
                    cursor = Cursor(
                        chapter: candidate,
                        segment: landingOnLastSegment ? segments.count - 1 : 0
                    )
                    return current
                }
            }
            candidate -= 1
        }
        return nil
    }
}
