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

    public init(
        title: String,
        authors: [String] = [],
        language: String? = nil,
        publisher: String? = nil,
        tableOfContents: [TOCEntry] = []
    ) {
        self.title = title
        self.authors = authors
        self.language = language
        self.publisher = publisher
        self.tableOfContents = tableOfContents
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

    public init(
        id: UUID = UUID(),
        title: String?,
        order: Int,
        text: String,
        images: [ChapterImage]? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.text = text
        self.images = images
    }
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

    public init(offset: Int, archivePath: String, alt: String? = nil) {
        self.offset = offset
        self.archivePath = archivePath
        self.alt = alt
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
