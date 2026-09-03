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
    /// True when the source has no text layer at all — a scanned PDF, or
    /// screenshots exported as one. The pages still render natively, but
    /// every text feature (Ask, Listen, search, highlights, the Reading
    /// view) has nothing to work with, and the app says so. Optional so
    /// libraries persisted before this field still decode; nil means the
    /// book has text.
    public var isImageOnly: Bool?

    public init(
        title: String,
        authors: [String] = [],
        language: String? = nil,
        publisher: String? = nil,
        tableOfContents: [TOCEntry] = [],
        isFixedLayout: Bool? = nil,
        isImageOnly: Bool? = nil
    ) {
        self.title = title
        self.authors = authors
        self.language = language
        self.publisher = publisher
        self.tableOfContents = tableOfContents
        self.isFixedLayout = isFixedLayout
        self.isImageOnly = isImageOnly
    }
}

public struct TOCEntry: Hashable, Sendable, Codable {
    public var title: String
    public var chapterIndex: Int
    public var children: [TOCEntry]
    /// Element id within the target chapter (the `#fragment` of the TOC
    /// href), for jumps inside a document that holds several TOC entries.
    /// Optional so libraries persisted before this field still decode.
    public var fragment: String?

    public init(
        title: String, chapterIndex: Int, children: [TOCEntry] = [],
        fragment: String? = nil
    ) {
        self.title = title
        self.chapterIndex = chapterIndex
        self.children = children
        self.fragment = fragment
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
    /// Footnote/endnote bodies lifted OUT of `text` (EPUB 3
    /// `epub:type="footnote|endnote|rearnote|note"` asides, `hidden`
    /// elements), keyed by element id for popup display at the matching
    /// noteref link. Optional so libraries persisted before this field
    /// still decode.
    public var footnotes: [Footnote]?
    /// False when the spine marks this document `linear="no"` (notes files,
    /// answer keys): reachable via links but skipped by continuous reading
    /// order. Optional so libraries persisted before this field still
    /// decode; nil means linear.
    public var isLinear: Bool?

    public init(
        id: UUID = UUID(),
        title: String?,
        order: Int,
        text: String,
        images: [ChapterImage]? = nil,
        formatSpans: [FormatSpan]? = nil,
        sourcePath: String? = nil,
        anchors: [String: Int]? = nil,
        footnotes: [Footnote]? = nil,
        isLinear: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.text = text
        self.images = images
        self.formatSpans = formatSpans
        self.sourcePath = sourcePath
        self.anchors = anchors
        self.footnotes = footnotes
        self.isLinear = isLinear
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, order, text, images, formatSpans, sourcePath
        case anchors, footnotes, isLinear
        /// Colour spans, split out so a build predating them still decodes the
        /// rest — see `FormatSpan.postdatesV1SpanVocabulary`.
        case colorSpans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        order = try container.decode(Int.self, forKey: .order)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([ChapterImage].self, forKey: .images)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        anchors = try container.decodeIfPresent([String: Int].self, forKey: .anchors)
        footnotes = try container.decodeIfPresent([Footnote].self, forKey: .footnotes)
        isLinear = try container.decodeIfPresent(Bool.self, forKey: .isLinear)

        let legacy = try container.decodeIfPresent([FormatSpan].self, forKey: .formatSpans)
        // Tolerated rather than required: a *future* build may add span kinds
        // this one has never heard of, and losing the colours it doesn't
        // understand beats losing the reader's whole library.
        let colors = try? container.decodeIfPresent([FormatSpan].self, forKey: .colorSpans)
        let combined = (legacy ?? []) + (colors ?? [])
        formatSpans = combined.isEmpty ? nil : combined
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(order, forKey: .order)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(anchors, forKey: .anchors)
        try container.encodeIfPresent(footnotes, forKey: .footnotes)
        try container.encodeIfPresent(isLinear, forKey: .isLinear)

        let spans = formatSpans ?? []
        let legacy = spans.filter { !$0.postdatesV1SpanVocabulary }
        let colors = spans.filter(\.postdatesV1SpanVocabulary)
        try container.encodeIfPresent(legacy.isEmpty ? nil : legacy, forKey: .formatSpans)
        try container.encodeIfPresent(colors.isEmpty ? nil : colors, forKey: .colorSpans)
    }
}

/// A footnote/endnote body extracted out of the reading flow, shown as a
/// popup when its matching noteref link is activated.
public struct Footnote: Hashable, Sendable, Codable {
    /// The source element's id — the fragment a noteref link resolves to.
    public var id: String
    /// The note's extracted text (same normalization as `Chapter.text`).
    public var text: String
    /// Formatting runs with offsets into `text`. Optional.
    public var formatSpans: [FormatSpan]?

    public init(id: String, text: String, formatSpans: [FormatSpan]? = nil) {
        self.id = id
        self.text = text
        self.formatSpans = formatSpans
    }

    // MARK: Codable

    // Same split as `Chapter` — a note body can carry colour spans too.
    private enum CodingKeys: String, CodingKey {
        case id, text, formatSpans, colorSpans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        let legacy = try container.decodeIfPresent([FormatSpan].self, forKey: .formatSpans)
        let colors = try? container.decodeIfPresent([FormatSpan].self, forKey: .colorSpans)
        let combined = (legacy ?? []) + (colors ?? [])
        formatSpans = combined.isEmpty ? nil : combined
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        let spans = formatSpans ?? []
        let legacy = spans.filter { !$0.postdatesV1SpanVocabulary }
        let colors = spans.filter(\.postdatesV1SpanVocabulary)
        try container.encodeIfPresent(legacy.isEmpty ? nil : legacy, forKey: .formatSpans)
        try container.encodeIfPresent(colors.isEmpty ? nil : colors, forKey: .colorSpans)
    }
}

/// Paragraph-level text alignment recovered from markup or styles. `left`
/// and `justify` matter as explicit overrides of the reader's default
/// (justified body text).
public enum TextAlignment: String, Hashable, Sendable, Codable {
    case left, center, right, justify
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
        /// Raised small text (`<sup>`) — footnote markers, exponents.
        case superscript
        /// Lowered small text (`<sub>`) — chemical formulas.
        case `subscript`
        /// Paragraph-level alignment override. The renderer snaps this (and
        /// all paragraph-level kinds) outward to whole-paragraph boundaries.
        case alignment(TextAlignment)
        /// Small-caps run (CSS `font-variant: small-caps`).
        case smallCaps
        /// A run the book's stylesheet paints a background behind (#47).
        /// Carries the declared colour; the renderer supplies a legible ink.
        case highlighted(CSSColor)
        /// A run the book's stylesheet colours (#47). Kept by the renderer
        /// only where it stays readable against the reader's theme.
        case colored(CSSColor)
    }

    public init(start: Int, end: Int, kind: Kind) {
        self.start = start
        self.end = end
        self.kind = kind
    }

    /// Whether this span's kind postdates the persisted v1 span vocabulary.
    ///
    /// Swift's synthesized enum `Codable` writes the case name as the key and
    /// refuses anything it doesn't recognise, so a build that predates a case
    /// cannot decode a library containing one — and `FileLibraryStore` treats a
    /// failed decode as corruption, moving `library.json` aside and starting
    /// empty. Adding `highlighted`/`colored` to `Kind` therefore made a
    /// downgrade (a tester rolling back a TestFlight build) wipe the shelf.
    ///
    /// `Chapter` and `Footnote` keep these out of the `formatSpans` array and
    /// persist them under a separate optional key instead — unknown keys are
    /// ignored by `Codable`, which is how every other field added to this file
    /// stayed safe. See `Chapter.encode(to:)`.
    var postdatesV1SpanVocabulary: Bool {
        switch kind {
        case .highlighted, .colored: return true
        default: return false
        }
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
