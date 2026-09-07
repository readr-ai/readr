import Foundation
import ReadrKit

/// What the shelf shows for a book. Encoded as JSON across the bridge.
struct BookSummary: Codable {
  var id: String
  var title: String
  var authors: [String]
  var language: String?
  var chapterCount: Int
  var estimatedTokenCount: Int
  var isImageOnly: Bool
  var isFixedLayout: Bool
  /// Absolute path of the extracted cover image, or nil for a placeholder.
  var coverPath: String?
  var sourceFilename: String?

  init(_ book: Book, coverPath: String?) {
    id = book.id.uuidString
    title = book.metadata.title
    authors = book.metadata.authors
    language = book.metadata.language
    chapterCount = book.chapters.count
    estimatedTokenCount = book.estimatedTokenCount
    isImageOnly = book.metadata.isImageOnly ?? false
    isFixedLayout = book.metadata.isFixedLayout ?? false
    self.coverPath = coverPath
    sourceFilename = book.sourceFilename
  }
}

struct ChapterSummary: Codable {
  var index: Int
  var title: String
  var characterCount: Int
  /// False for spine documents marked `linear="no"`; continuous reading
  /// skips them.
  var isLinear: Bool
}

/// A `FormatSpan` with UTF-16 offsets, flattened for Kotlin. `kind` is one
/// of heading, bold, italic, blockquote, link, superscript, subscript,
/// alignment, smallCaps, highlighted, colored; the optional fields carry the
/// payload of the kinds that have one.
struct LayoutSpan: Codable {
  var start: Int
  var end: Int
  var kind: String
  var level: Int?
  var alignment: String?
  var url: String?
  var linkPath: String?
  var linkFragment: String?

  init?(_ span: FormatSpan, offsets: UTF16OffsetTable) {
    start = offsets.utf16Offset(ofCharacter: span.start)
    end = offsets.utf16Offset(ofCharacter: span.end)
    guard start < end else { return nil }
    switch span.kind {
    case .heading(let level): kind = "heading"; self.level = level
    case .bold: kind = "bold"
    case .italic: kind = "italic"
    case .blockquote: kind = "blockquote"
    case .link(let target):
      kind = "link"
      switch target {
      case .external(let url): self.url = url
      case .internalDoc(let path, let fragment): linkPath = path; linkFragment = fragment
      }
    case .superscript: kind = "superscript"
    case .subscript: kind = "subscript"
    case .alignment(let alignment): kind = "alignment"; self.alignment = alignment.rawValue
    case .smallCaps: kind = "smallCaps"
    case .highlighted: kind = "highlighted"
    case .colored: kind = "colored"
    }
  }
}

/// Everything the reader needs to lay a chapter out besides its text, with
/// every offset in UTF-16. Title and linearity travel with `ChapterSummary`.
struct ChapterLayout: Codable {
  var index: Int
  var utf16Length: Int
  var spans: [LayoutSpan]
  /// Element id → UTF-16 offset, for TOC fragments and internal links.
  var anchors: [String: Int]
}

/// One row of the Contents sheet.
struct ContentsRow: Codable {
  var id: Int
  var title: String
  var chapterIndex: Int
  var depth: Int
  /// UTF-16 offset the row jumps to (its fragment resolved, else 0).
  var utf16Offset: Int
}

struct Contents: Codable {
  var rows: [ContentsRow]
  /// True when the book has no table of contents and the rows are the spine.
  var isFallback: Bool
}

/// The kit's `ReadingPosition` plus the same offset in UTF-16.
struct PositionSummary: Codable {
  var chapterIndex: Int
  var characterOffset: Int
  var pdfPageIndex: Int?
  var utf16Offset: Int
}

/// An error whose `description` — what jextract hands Java as the exception
/// message — is ReadrKit's reader-facing sentence, not a Swift case name.
struct ReaderFacingError: Error, CustomStringConvertible {
  let description: String
  let diagnostic: String
  init(_ error: Error) {
    description = error.readerFacingMessage
    diagnostic = String(describing: error)
  }
}

/// Runs `body`, converting any thrown error into a `ReaderFacingError`.
func readerFacing<T>(_ body: () throws -> T) throws -> T {
  do { return try body() } catch let error as ReaderFacingError { throw error } catch { throw ReaderFacingError(error) }
}

func readerFacing<T>(_ body: () async throws -> T) async throws -> T {
  do { return try await body() } catch let error as ReaderFacingError { throw error } catch { throw ReaderFacingError(error) }
}

/// Kit constants Kotlin must agree with before the kit sees the bytes.
public final class KitLimits {
  public static func epubPerEntryByteCap() -> Int64 { Int64(EPUBExtractionLimits.perEntryByteCap) }
  public static func epubCumulativeByteCap() -> Int64 { Int64(EPUBExtractionLimits.cumulativeByteCap) }
}

/// The Android app's library: ReadrKit's `FileLibraryStore` plus the on-disk
/// layout the iOS app uses (originals under `Books/`, covers under `Covers/`),
/// rooted at the app's files directory. One instance per process; the store
/// itself is lock-protected, so the sync methods may be called from any
/// thread and the async ones from Swift's executor.
public final class AndroidLibrary {
  private let root: URL
  private let store: FileLibraryStore
  /// Offset tables for the chapters in play, keyed by book + chapter. A
  /// position save, a contents build and a layout all convert against the
  /// same table instead of re-walking the chapter each time.
  private let offsetTables = OffsetTableCache()

  private var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
  private var coversDirectory: URL { root.appendingPathComponent("Covers", isDirectory: true) }
  private var seededMarker: URL { root.appendingPathComponent(".sample-seeded") }

  private static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }

  public init(rootDirectory: String) {
    root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    let fm = FileManager.default
    for dir in [root, root.appendingPathComponent("Books"), root.appendingPathComponent("Covers")] {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    store = FileLibraryStore(fileURL: root.appendingPathComponent("library.json"))
  }

  public func kitDescription() -> String {
    "ReadrKit on \(ProcessInfo.processInfo.operatingSystemVersionString)"
  }

  // MARK: Import

  /// Import a plain-text or Markdown file. `path` is a readable local copy
  /// (Kotlin copies the SAF stream into the cache first).
  public func importPlainText(_ path: String, title: String) async throws -> String {
    try await readerFacing {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let book = try PlainTextBookParser().parse(data: data, title: title)
      return try add(book, original: path, ext: "txt")
    }
  }

  /// Import an EPUB that Kotlin has unzipped into `extractedDirectory`;
  /// `originalPath` is the .epub itself, kept under Books/.
  public func importEPUB(_ extractedDirectory: String, originalPath: String, fallbackTitle: String) async throws -> String {
    try await readerFacing {
      let container = DirectoryEPUBContainer(directory: extractedDirectory)
      let book = try EPUBBookParser().parse(container: container, fallbackTitle: fallbackTitle)
      return try add(book, original: originalPath, ext: "epub")
    }
  }

  /// Whether a first launch should seed the bundled sample — asked before
  /// Kotlin stages the asset, so an established library never unzips it.
  public func needsSampleSeed() -> Bool {
    SampleBookSeeder.shouldSeed(
      hasSeededBefore: FileManager.default.fileExists(atPath: seededMarker.path),
      hasPersistedLibrary: store.hasPersistedLibrary,
      existingBookCount: store.allBooks().count)
  }

  /// Seed the bundled sample book on a first launch, mirroring the iOS app:
  /// the marker is written only when a book actually came back. Returns the
  /// summary JSON, or "" when nothing was seeded.
  public func seedSampleIfNeeded(_ extractedDirectory: String, originalPath: String) async throws -> String {
    try await readerFacing {
      let hasSeeded = FileManager.default.fileExists(atPath: seededMarker.path)
      var summary = ""
      let seeded = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: hasSeeded) {
        let container = DirectoryEPUBContainer(directory: extractedDirectory)
        let book = try EPUBBookParser().parse(container: container, fallbackTitle: "Alice's Adventures in Wonderland")
        summary = try add(book, original: originalPath, ext: "epub")
        return book
      }
      if seeded != nil { try Data().write(to: seededMarker) }
      return summary
    }
  }

  // MARK: Reading

  public func booksJSON() throws -> String {
    try readerFacing {
      let summaries = store.allBooks().map { BookSummary($0, coverPath: coverPath(for: $0.id)) }
      return String(decoding: try Self.encoder().encode(summaries), as: UTF8.self)
    }
  }

  public func chaptersJSON(_ bookID: String) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapters = book.chapters.indices.map { index in
        ChapterSummary(
          index: index, title: book.chapterDisplayTitle(index),
          characterCount: book.chapters[index].text.count,
          isLinear: book.chapters[index].isLinear ?? true)
      }
      return String(decoding: try Self.encoder().encode(chapters), as: UTF8.self)
    }
  }

  public func chapterText(_ bookID: String, index: Int64) throws -> String {
    try readerFacing {
      return try chapter(try book(bookID), index).text
    }
  }

  /// Format spans, anchors and linearity for a chapter, offsets in UTF-16.
  public func chapterLayoutJSON(_ bookID: String, index: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapter = try chapter(book, index)
      let offsets = offsetTables.table(for: book, chapterIndex: Int(index))
      let layout = ChapterLayout(
        index: Int(index),
        utf16Length: offsets.utf16Count,
        spans: (chapter.formatSpans ?? []).compactMap { LayoutSpan($0, offsets: offsets) },
        anchors: (chapter.anchors ?? [:]).mapValues { offsets.utf16Offset(ofCharacter: $0) })
      return String(decoding: try Self.encoder().encode(layout), as: UTF8.self)
    }
  }

  /// The Contents rows: the book's table of contents flattened depth-first
  /// (parents before children), or one row per chapter when it has none —
  /// the same choice the Apple reader makes.
  public func contentsJSON(_ bookID: String) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      var rows: [ContentsRow] = []
      func walk(_ entries: [TOCEntry], depth: Int) {
        for entry in entries {
          if book.chapters.indices.contains(entry.chapterIndex) {
            let chapter = book.chapters[entry.chapterIndex]
            let characterOffset = entry.fragment.flatMap { chapter.anchors?[$0] } ?? 0
            let utf16Offset = characterOffset == 0
              ? 0
              : offsetTables.table(for: book, chapterIndex: entry.chapterIndex).utf16Offset(ofCharacter: characterOffset)
            rows.append(ContentsRow(
              id: rows.count,
              title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines),
              chapterIndex: entry.chapterIndex,
              depth: depth,
              utf16Offset: utf16Offset))
          }
          walk(entry.children, depth: depth + 1)
        }
      }
      walk(book.metadata.tableOfContents, depth: 0)
      let isFallback = rows.isEmpty
      if isFallback {
        rows = book.chapters.indices.map { index in
          ContentsRow(id: index, title: book.chapterDisplayTitle(index), chapterIndex: index, depth: 0, utf16Offset: 0)
        }
      }
      return String(decoding: try Self.encoder().encode(Contents(rows: rows, isFallback: isFallback)), as: UTF8.self)
    }
  }

  /// Saves the chapter and the UTF-16 offset the reader is at, stored as
  /// the kit's character offset; a PDF page already stored for the book (by
  /// another platform sharing the file) is carried over.
  public func savePosition(_ bookID: String, chapterIndex: Int64, utf16Offset: Int64) throws {
    try readerFacing {
      let book = try book(bookID)
      _ = try chapter(book, chapterIndex)
      let existing = store.position(for: book.id)
      try store.savePosition(
        ReadingPosition(
          chapterIndex: Int(chapterIndex),
          characterOffset: offsetTables.table(for: book, chapterIndex: Int(chapterIndex)).characterOffset(ofUTF16: Int(utf16Offset)),
          pdfPageIndex: existing?.pdfPageIndex),
        for: book.id)
    }
  }

  /// The saved position with its offset in both coordinate systems, or ""
  /// when the book is unread. A chapter index that no longer exists (the
  /// book was re-imported shorter) reports offset 0 rather than failing.
  public func positionJSON(_ bookID: String) throws -> String {
    try readerFacing {
      guard let id = UUID(uuidString: bookID), let position = store.position(for: id) else { return "" }
      let book = try book(bookID)
      let utf16Offset = book.chapters.indices.contains(position.chapterIndex)
        ? offsetTables.table(for: book, chapterIndex: position.chapterIndex).utf16Offset(ofCharacter: position.characterOffset)
        : 0
      let summary = PositionSummary(
        chapterIndex: position.chapterIndex,
        characterOffset: position.characterOffset,
        pdfPageIndex: position.pdfPageIndex,
        utf16Offset: utf16Offset)
      return String(decoding: try Self.encoder().encode(summary), as: UTF8.self)
    }
  }

  public func removeBook(_ bookID: String) throws {
    try readerFacing {
      let book = try book(bookID)
      offsetTables.forget(book.id)
      try store.removeBook(id: book.id)
      if let name = book.sourceFilename {
        try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(name))
      }
      try? FileManager.default.removeItem(at: coverURL(for: book.id))
    }
  }

  // MARK: Helpers

  /// Files the cover, retains the original, and adds the book to the store —
  /// without the cover bytes, which would otherwise be re-serialised into
  /// library.json on every position save (the iOS app does the same).
  private func add(_ parsed: Book, original: String, ext: String) throws -> String {
    var book = parsed
    if let data = book.coverImageData, !data.isEmpty {
      try data.write(to: coverURL(for: book.id))
    }
    book.coverImageData = nil
    book.sourceFilename = try retainOriginal(original, bookID: book.id, ext: ext)
    try store.add(book)
    return String(decoding: try Self.encoder().encode(BookSummary(book, coverPath: coverPath(for: book.id))), as: UTF8.self)
  }

  private func chapter(_ book: Book, _ index: Int64) throws -> Chapter {
    guard index >= 0, index < Int64(book.chapters.count) else { throw AndroidBridgeError.invalidChapter(Int(index)) }
    return book.chapters[Int(index)]
  }

  private func book(_ id: String) throws -> Book {
    guard let uuid = UUID(uuidString: id), let book = store.book(id: uuid) else {
      throw AndroidBridgeError.unknownBook(id)
    }
    return book
  }

  private func retainOriginal(_ path: String, bookID: UUID, ext: String) throws -> String {
    let name = "\(bookID.uuidString).\(ext)"
    let destination = booksDirectory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
    return name
  }

  private func coverURL(for id: UUID) -> URL {
    coversDirectory.appendingPathComponent("\(id.uuidString).img")
  }

  private func coverPath(for id: UUID) -> String? {
    let url = coverURL(for: id)
    return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
  }
}

/// A small LRU of `UTF16OffsetTable`s. Chapter text only changes with the
/// book's identity (a re-import is a new UUID), so book id + chapter index is
/// a sound key.
final class OffsetTableCache {
  private struct Key: Hashable { let book: UUID; let chapter: Int }
  private let lock = NSLock()
  private var tables: [Key: UTF16OffsetTable] = [:]
  private var order: [Key] = []
  private let capacity = 4

  func table(for book: Book, chapterIndex: Int) -> UTF16OffsetTable {
    let key = Key(book: book.id, chapter: chapterIndex)
    lock.lock(); defer { lock.unlock() }
    if let table = tables[key] {
      order.removeAll { $0 == key }
      order.append(key)
      return table
    }
    let table = UTF16OffsetTable(book.chapters[chapterIndex].text)
    tables[key] = table
    order.append(key)
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      tables[oldest] = nil
    }
    return table
  }

  func forget(_ bookID: UUID) {
    lock.lock(); defer { lock.unlock() }
    order.removeAll { $0.book == bookID }
    tables = tables.filter { $0.key.book != bookID }
  }
}
