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
    public mutating func segments(inChapter index: Int) -> [SpeechSegment] {
        guard book.chapters.indices.contains(index) else { return [] }
        if let cached = cache[index] { return cached }
        let built = segmenter.segments(of: book.chapters[index], chapterIndex: index)
        cache[index] = built
        return built
    }

    // MARK: - Moving

    /// Place the cursor at the first segment at or after `characterOffset` in
    /// `index` — the entry point for "read from here", whether *here* is the
    /// visible page, a chapter picked from the Contents list, or a selection.
    ///
    /// A chapter with nothing left to read (empty, image-only, or an offset
    /// past its last sentence) rolls forward into the next one that has
    /// something to say. Returns nil only when the rest of the book is silent.
    @discardableResult
    public mutating func seek(toChapter index: Int, characterOffset: Int = 0) -> SpeechSegment? {
        guard book.chapters.indices.contains(index) else { return nil }
        let segments = self.segments(inChapter: index)
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
