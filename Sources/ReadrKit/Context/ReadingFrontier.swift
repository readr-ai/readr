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

    /// This frontier moved forward, if it has to be, to cover `range` in the
    /// same chapter. A passage the reader has selected is in front of them,
    /// so it has been read whatever the page-top anchor says — "explain this
    /// passage" must never treat the passage itself as unread. Never moves
    /// backwards: a selection higher on the page leaves the frontier alone.
    public func extended(toInclude range: Range<Int>) -> ReadingFrontier {
        ReadingFrontier(
            chapterIndex: chapterIndex,
            characterOffset: max(characterOffset, range.upperBound)
        )
    }
}

/// The end of what a reader has read, and where in the book it begins.
///
/// The "read so far" fallback sends this to the model as one passage, and the
/// citation beside the answer has to point somewhere the app can open — so
/// the text and its position are produced together, by the walk that knows
/// which chapter the tail actually reached back into.
public struct ReadTail: Sendable, Equatable {
    /// The text itself; chapter pieces joined the way `textRead(upTo:)`
    /// joins them.
    public var text: String
    /// Reading-order index of the chapter `text` begins in.
    public var chapterIndex: Int
    /// Character offset into that chapter's text where `text` begins.
    public var characterOffset: Int

    public init(text: String, chapterIndex: Int, characterOffset: Int) {
        self.text = text
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }
}

/// What a question may draw on: the whole book, or only what the reader has
/// read. A named choice, made at every call site — there is no default, so
/// no path can drift into sending the whole book by omission.
public enum ReadingScope: Sendable, Hashable {
    /// Every chapter. The right scope for a PDF page (no reading position)
    /// or for a reader who asks for it explicitly.
    case wholeBook
    /// Only the text before the frontier; the spoiler guard rides along.
    case upTo(ReadingFrontier)

    /// The frontier, when the scope has one.
    public var frontier: ReadingFrontier? {
        switch self {
        case .wholeBook: return nil
        case let .upTo(frontier): return frontier
        }
    }

    /// True when answers are held to what the reader has read.
    public var isScoped: Bool { frontier != nil }
}

public extension Book {
    /// Chapters in reading order.
    var chaptersInReadingOrder: [Chapter] {
        chapters.sorted { $0.order < $1.order }
    }

    /// The text the reader has actually seen: every chapter before the
    /// frontier in full, and the frontier chapter up to the offset. Offsets
    /// past the chapter end are clamped; a frontier past the last chapter is
    /// the whole book; a frontier before the first chapter is the start of
    /// the first one.
    func textRead(upTo frontier: ReadingFrontier) -> String {
        let ordered = chaptersInReadingOrder
        guard frontier.chapterIndex < ordered.count else { return fullText }
        let index = max(0, frontier.chapterIndex)
        var parts: [String] = ordered.prefix(index).map(\.text)
        let current = ordered[index].text
        let cut = max(0, min(frontier.characterOffset, current.count))
        let prefix = String(current.prefix(cut))
        if !prefix.isEmpty { parts.append(prefix) }
        return parts.joined(separator: "\n\n")
    }

    /// The last `maxCharacters` of `textRead(upTo:)`, assembled from the end
    /// so the rest of what was read is never materialized. Chapter pieces
    /// are joined the way `textRead(upTo:)` joins them.
    func textRead(upTo frontier: ReadingFrontier, lastCharacters maxCharacters: Int) -> String {
        readTail(upTo: frontier, lastCharacters: maxCharacters).text
    }

    /// The same tail, and where in the book it starts.
    ///
    /// The location is the tail's OWN start, not the frontier's: a 2,000
    /// character tail read from fifty characters into chapter three begins in
    /// chapter two, and a citation that says chapter three at offset −1,950
    /// opens the book in the wrong place. A frontier past the last chapter
    /// means the whole book has been read, and is located at the end of the
    /// last chapter rather than in a chapter that isn't there.
    func readTail(upTo frontier: ReadingFrontier, lastCharacters maxCharacters: Int) -> ReadTail {
        let ordered = chaptersInReadingOrder
        guard !ordered.isEmpty else { return ReadTail(text: "", chapterIndex: 0, characterOffset: 0) }
        let index = min(max(0, frontier.chapterIndex), ordered.count - 1)
        let current = ordered[index].text
        let cut = frontier.chapterIndex >= ordered.count
            ? current.count
            : max(0, min(frontier.characterOffset, current.count))
        guard maxCharacters > 0 else {
            return ReadTail(text: "", chapterIndex: index, characterOffset: cut)
        }

        var pieces: [String] = []
        var remaining = maxCharacters
        // Where the earliest piece so far begins. Each step back rewrites it,
        // so what survives is the start of the chapter the tail opens in.
        var start = (chapterIndex: index, characterOffset: cut)
        let piece = String(current.prefix(cut).suffix(min(cut, remaining)))
        if !piece.isEmpty {
            pieces.append(piece)
            remaining -= piece.count
            start.characterOffset = cut - piece.count
        }
        var earlier = index - 1
        while remaining > 0, earlier >= 0 {
            let text = ordered[earlier].text
            let piece = String(text.suffix(remaining))
            if !piece.isEmpty {
                pieces.append(piece)
                remaining -= piece.count
                start = (earlier, text.count - piece.count)
            }
            earlier -= 1
        }
        return ReadTail(
            text: pieces.reversed().joined(separator: "\n\n"),
            chapterIndex: start.chapterIndex,
            characterOffset: start.characterOffset
        )
    }

    /// Whether the frontier sits at or past the end of its chapter — i.e. the
    /// reader has finished that chapter, so all of it is safe to surface.
    func hasFinishedChapter(at frontier: ReadingFrontier) -> Bool {
        let ordered = chaptersInReadingOrder
        guard frontier.chapterIndex < ordered.count else { return true }
        let index = max(0, frontier.chapterIndex)
        return frontier.characterOffset >= ordered[index].text.count
    }
}
