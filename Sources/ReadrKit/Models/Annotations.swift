import Foundation

/// A saved place in a book. Text books anchor to chapter + character offset;
/// PDFs (read natively) anchor to a page index.
public struct Bookmark: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var bookID: UUID
    public var chapterIndex: Int
    public var characterOffset: Int
    /// Non-nil when the bookmark was made in native PDF mode.
    public var pdfPageIndex: Int?
    /// A short excerpt shown in the bookmarks list ("Page 12 — 'It was a…'").
    public var snippet: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterIndex: Int = 0,
        characterOffset: Int = 0,
        pdfPageIndex: Int? = nil,
        snippet: String = "",
        createdAt: Date
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.pdfPageIndex = pdfPageIndex
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

/// A rectangle in PDF page space (origin bottom-left, points). Mirrors CGRect
/// without importing CoreGraphics so ReadrKit builds on any Swift platform.
public struct PDFRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A highlight made in native PDF mode. Stored in Readr's own library — the
/// PDF file itself is never mutated — and re-created as PDFKit annotation
/// overlays when the document loads. Page-space rects are stable across zoom
/// and window size.
public struct PDFHighlight: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var bookID: UUID
    /// Zero-based page index.
    public var pageIndex: Int
    /// One rect per selected line, in page space.
    public var lineRects: [PDFRect]
    public var quotedText: String
    public var color: HighlightColor
    public var note: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        pageIndex: Int,
        lineRects: [PDFRect],
        quotedText: String,
        color: HighlightColor = .yellow,
        note: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.lineRects = lineRects
        self.quotedText = quotedText
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }
}

/// Per-book lifecycle state driving Home ("Continue Reading" ordering) and the
/// Finished shelf. All fields optional so existing libraries decode.
public struct BookState: Hashable, Sendable, Codable {
    public var addedAt: Date?
    public var lastOpenedAt: Date?
    public var finishedAt: Date?

    public var isFinished: Bool { finishedAt != nil }

    public init(addedAt: Date? = nil, lastOpenedAt: Date? = nil, finishedAt: Date? = nil) {
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.finishedAt = finishedAt
    }
}
