import Foundation

/// How far the reader has got: a chapter in reading order and a character
/// offset inside it. Everything before it has been read; everything after it
/// has not — and must not reach the model.
///
/// This is what makes "recap what I've read so far, no spoilers" an honest
/// feature rather than a hope. Without a frontier, Ask sends the whole book,
/// and a recap question is a spoiler waiting to happen.
public struct ReadingFrontier: Sendable, Hashable, Codable {
    /// Reading-order index into the book's chapters (sorted by `Chapter.order`).
    public var chapterIndex: Int
    /// Characters of `chapters[chapterIndex].text` the reader has passed.
    public var characterOffset: Int

    public init(chapterIndex: Int, characterOffset: Int) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }

    /// The reader's saved position is the frontier by definition.
    public init(_ position: ReadingPosition) {
        self.init(chapterIndex: position.chapterIndex, characterOffset: position.characterOffset)
    }
}

public extension Book {
    /// Chapters in reading order.
    var chaptersInReadingOrder: [Chapter] {
        chapters.sorted { $0.order < $1.order }
    }

    /// The text the reader has actually seen: every chapter before the
    /// frontier in full, and the frontier chapter up to the offset. Offsets
    /// past the chapter end are clamped; a frontier past the last chapter is
    /// the whole book.
    func textRead(upTo frontier: ReadingFrontier) -> String {
        let ordered = chaptersInReadingOrder
        guard frontier.chapterIndex < ordered.count else { return fullText }
        var parts: [String] = ordered.prefix(frontier.chapterIndex).map(\.text)
        let current = ordered[frontier.chapterIndex].text
        let cut = max(0, min(frontier.characterOffset, current.count))
        let prefix = String(current.prefix(cut))
        if !prefix.isEmpty { parts.append(prefix) }
        return parts.joined(separator: "\n\n")
    }

    /// Whether the frontier sits at or past the end of its chapter — i.e. the
    /// reader has finished that chapter, so all of it is safe to surface.
    func hasFinishedChapter(at frontier: ReadingFrontier) -> Bool {
        let ordered = chaptersInReadingOrder
        guard frontier.chapterIndex < ordered.count else { return true }
        return frontier.characterOffset >= ordered[frontier.chapterIndex].text.count
    }
}
