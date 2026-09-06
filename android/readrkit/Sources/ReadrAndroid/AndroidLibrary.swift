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
        ChapterSummary(index: index, title: book.chapterDisplayTitle(index), characterCount: book.chapters[index].text.count)
      }
      return String(decoding: try Self.encoder().encode(chapters), as: UTF8.self)
    }
  }

  public func chapterText(_ bookID: String, index: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      guard book.chapters.indices.contains(Int(index)) else { throw AndroidBridgeError.invalidChapter(Int(index)) }
      return book.chapters[Int(index)].text
    }
  }

  /// Saves the chapter and character offset; a PDF page already stored for
  /// the book (by another platform sharing the file) is carried over.
  public func savePosition(_ bookID: String, chapterIndex: Int64, characterOffset: Int64) throws {
    try readerFacing {
      let book = try book(bookID)
      let existing = store.position(for: book.id)
      try store.savePosition(
        ReadingPosition(chapterIndex: Int(chapterIndex), characterOffset: Int(characterOffset), pdfPageIndex: existing?.pdfPageIndex),
        for: book.id)
    }
  }

  /// The kit's `ReadingPosition` as JSON, or "" when the book is unread.
  public func positionJSON(_ bookID: String) throws -> String {
    try readerFacing {
      guard let id = UUID(uuidString: bookID), let position = store.position(for: id) else { return "" }
      return String(decoding: try Self.encoder().encode(position), as: UTF8.self)
    }
  }

  public func removeBook(_ bookID: String) throws {
    try readerFacing {
      let book = try book(bookID)
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
