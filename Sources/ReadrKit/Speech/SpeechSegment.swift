import Foundation

/// One unit of narration: a sentence-sized slice of a chapter, addressed the
/// same way highlights are — **character** offsets into `Chapter.text`.
///
/// Invariant: `text` is exactly the chapter's characters over `range`, with no
/// substitution or trimming applied after the fact. Word-boundary callbacks
/// from the speech engine arrive as offsets into `text`, so the reader maps a
/// spoken word back into chapter coordinates by adding `range.lowerBound` —
/// which only holds while the two stay in lockstep.
public struct SpeechSegment: Hashable, Sendable {
    /// Index into `Book.chapters`.
    public var chapterIndex: Int
    /// Character range within that chapter's text.
    public var range: Range<Int>
    /// The text handed to the speech engine.
    public var text: String

    public init(chapterIndex: Int, range: Range<Int>, text: String) {
        self.chapterIndex = chapterIndex
        self.range = range
        self.text = text
    }
}

/// Where narration currently is, in the reader's own coordinates — the reader
/// follows this to keep the visible page under the voice.
public struct NarrationPosition: Hashable, Sendable {
    public var chapterIndex: Int
    public var characterOffset: Int

    public init(chapterIndex: Int, characterOffset: Int) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }
}
