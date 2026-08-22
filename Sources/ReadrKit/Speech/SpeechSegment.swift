import Foundation

/// One unit of narration: a sentence-sized slice of a chapter, addressed the
/// same way highlights are — **character** offsets into `Chapter.text`.
///
/// Invariant: `text` is the chapter's characters over `range`, character for
/// character in length — the only substitution ever applied is the
/// length-preserving space-blanking of footnote markers (see
/// `SpeechPlaylist.speakableText(of:)`). Word-boundary callbacks from the
/// speech engine arrive as offsets into `text`, so the reader maps a spoken
/// word back into chapter coordinates by adding `range.lowerBound` — which
/// only holds while the two stay in lockstep.
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
    /// Where the *voice* is, to the word. This is what the page follows, so
    /// that a long sentence spanning a page break turns the page partway
    /// through rather than at its end.
    public var characterOffset: Int
    /// Where the sentence being read *began* — the resume anchor, and the one
    /// to persist.
    ///
    /// These differ only mid-sentence, and conflating them lost a sentence:
    /// a speed change re-speaks from the last word boundary and publishes that
    /// offset, so a reader who changed speed early in a long sentence, stopped,
    /// and pressed Listen again resumed from an anchor *inside* it — and
    /// `seek` takes the first sentence beginning at or after its anchor, so the
    /// rest of that sentence was skipped unheard. Following the voice wants the
    /// word; coming back to it wants the sentence.
    public var sentenceStart: Int

    /// `sentenceStart` defaults to `characterOffset` — correct for every
    /// position that is already at a sentence boundary, which is all of them
    /// except a mid-sentence resume.
    public init(chapterIndex: Int, characterOffset: Int, sentenceStart: Int? = nil) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.sentenceStart = sentenceStart ?? characterOffset
    }
}
