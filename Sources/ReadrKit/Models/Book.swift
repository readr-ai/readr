import Foundation

/// A parsed book, independent of its source format (EPUB, PDF, ...).
public struct Book: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var metadata: BookMetadata
    public var chapters: [Chapter]
    /// Approximate token count of the full text, computed once at import and
    /// used by `ContextStrategy` to choose whole-book vs. retrieval.
    public var estimatedTokenCount: Int
    /// Cover artwork (PNG/JPEG bytes) extracted at import — from the EPUB
    /// manifest or a PDF first-page thumbnail. Nil → the UI shows a generated
    /// placeholder cover.
    public var coverImageData: Data?
    /// File name of the retained original inside the app's Books directory
    /// (e.g. `<uuid>.pdf`) — enables native rendering of the source document.
    public var sourceFilename: String?

    public init(
        id: UUID = UUID(),
        metadata: BookMetadata,
        chapters: [Chapter],
        estimatedTokenCount: Int,
        coverImageData: Data? = nil,
        sourceFilename: String? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.chapters = chapters
        self.estimatedTokenCount = estimatedTokenCount
        self.coverImageData = coverImageData
        self.sourceFilename = sourceFilename
    }

    /// Full plain text, chapters joined in reading order.
    public var fullText: String {
        chapters.map(\.text).joined(separator: "\n\n")
    }
}

public struct BookMetadata: Hashable, Sendable, Codable {
    public var title: String
    public var authors: [String]
    public var language: String?
    public var publisher: String?
    /// Table of contents, always injected as part of the query anchor.
    public var tableOfContents: [TOCEntry]
    /// True when the EPUB declares pre-paginated (fixed) layout —
    /// `rendition:layout` in the OPF or the legacy Apple display options.
    /// Readr extracts such books as text; the flag lets the app say so.
    /// Optional so libraries persisted before this field still decode;
    /// nil means reflowable.
    public var isFixedLayout: Bool?

    public init(
        title: String,
        authors: [String] = [],
        language: String? = nil,
        publisher: String? = nil,
        tableOfContents: [TOCEntry] = [],
        isFixedLayout: Bool? = nil
    ) {
        self.title = title
        self.authors = authors
        self.language = language
        self.publisher = publisher
        self.tableOfContents = tableOfContents
        self.isFixedLayout = isFixedLayout
    }
}

public struct TOCEntry: Hashable, Sendable, Codable {
    public var title: String
    public var chapterIndex: Int
    public var children: [TOCEntry]

    public init(title: String, chapterIndex: Int, children: [TOCEntry] = []) {
        self.title = title
        self.chapterIndex = chapterIndex
        self.children = children
    }
}

public struct Chapter: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var title: String?
    public var order: Int
    public var text: String
    /// Inline images, each anchored to a U+FFFC placeholder in `text`.
    /// Optional so libraries persisted before this field still decode.
    public var images: [ChapterImage]?
    /// Formatting recovered from the source markup (headings, emphasis,
    /// blockquotes, links), with character offsets into `text`. Optional so
    /// libraries persisted before this field still decode.
    public var formatSpans: [FormatSpan]?
    /// Archive path of the spine content document this chapter came from
    /// (e.g. `OEBPS/text/ch1.xhtml`) — the base for resolving internal links.
    /// Optional so libraries persisted before this field still decode.
    public var sourcePath: String?
    /// Element `id` → character offset into `text`, for fragment navigation
    /// (`chapter.xhtml#note3`). First occurrence of an id wins. Optional so
    /// libraries persisted before this field still decode.
    public var anchors: [String: Int]?

    public init(
        id: UUID = UUID(),
        title: String?,
        order: Int,
        text: String,
        images: [ChapterImage]? = nil,
        formatSpans: [FormatSpan]? = nil,
        sourcePath: String? = nil,
        anchors: [String: Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.text = text
        self.images = images
        self.formatSpans = formatSpans
        self.sourcePath = sourcePath
        self.anchors = anchors
    }
}

/// A run of formatting over `Chapter.text`, expressed as a half-open character
/// range `[start, end)`. Spans may nest and overlap (e.g. bold inside italic).
public struct FormatSpan: Hashable, Sendable, Codable {
    /// Character offset (into `Chapter.text`) where the run begins.
    public var start: Int
    /// Character offset one past the last character of the run.
    public var end: Int
    public var kind: Kind

    public enum Kind: Hashable, Sendable, Codable {
        /// Heading with its level, 1...6.
        case heading(Int)
        case bold
        case italic
        case blockquote
        case link(LinkTarget)
    }

    public init(start: Int, end: Int, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

/// Where a link in chapter text points.
public enum LinkTarget: Hashable, Sendable, Codable {
    /// A link out of the book (http/https/mailto/…), kept verbatim.
    case external(url: String)
    /// A link into the book: the resolved archive path of the target content
    /// document plus an optional fragment (element id, without the `#`).
    case internalDoc(path: String, fragment: String?)
}

/// An inline image within a chapter: where it sits in the text and where its
/// bytes live inside the book's retained source archive.
public struct ChapterImage: Hashable, Sendable, Codable {
    /// Character offset of the U+FFFC placeholder in `Chapter.text`.
    public var offset: Int
    /// Entry path inside the source archive (already resolved, e.g.
    /// `OEBPS/images/fig1.jpg`).
    public var archivePath: String
    public var alt: String?
    /// Intended display width/height in CSS pixels, from the source markup's
    /// `width=`/`height=` attributes or an inline `style="width: NNpx"`.
    /// Percentages and non-pixel units yield nil (no fixed pixel intent).
    /// Optional so libraries persisted before these fields still decode.
    public var displayWidth: Double?
    public var displayHeight: Double?

    public init(
        offset: Int,
        archivePath: String,
        alt: String? = nil,
        displayWidth: Double? = nil,
        displayHeight: Double? = nil
    ) {
        self.offset = offset
        self.archivePath = archivePath
        self.alt = alt
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

/// Highlight marker colors. Color carries meaning for the reader and is
/// filterable at review/export time (see docs/DESIGN.md).
public enum HighlightColor: String, CaseIterable, Hashable, Sendable, Codable {
    case yellow, green, blue, pink, purple

    public var displayName: String { rawValue.capitalized }
}

/// A reader's highlight, anchored to a text range.
public struct Highlight: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var bookID: UUID
    public var chapterID: UUID
    /// Character range within the chapter text.
    public var range: Range<Int>
    public var quotedText: String
    public var note: String?
    public var createdAt: Date
    /// Marker color. Optional so pre-v2 libraries decode; nil means yellow.
    public var color: HighlightColor?

    /// The effective marker color (yellow for legacy highlights).
    public var markerColor: HighlightColor { color ?? .yellow }

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        range: Range<Int>,
        quotedText: String,
        note: String? = nil,
        createdAt: Date,
        color: HighlightColor? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.range = range
        self.quotedText = quotedText
        self.note = note
        self.createdAt = createdAt
        self.color = color
    }
}
