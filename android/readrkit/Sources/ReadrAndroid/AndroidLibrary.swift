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
    self.coverPath = coverPath
    sourceFilename = book.sourceFilename
  }
}

struct ChapterSummary: Codable {
  var index: Int
  var title: String
  var characterCount: Int
}

struct PositionSummary: Codable {
  var chapterIndex: Int
  var characterOffset: Int
}

/// The Android app's library: ReadrKit's `FileLibraryStore` plus the on-disk
/// layout the iOS app uses (originals under `Books/`, covers under `Covers/`),
/// rooted at the app's files directory. One instance per process.
public final class AndroidLibrary {
  private let root: URL
  private let store: FileLibraryStore
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  private var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
  private var coversDirectory: URL { root.appendingPathComponent("Covers", isDirectory: true) }
  private var seededMarker: URL { root.appendingPathComponent(".sample-seeded") }

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
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var book = try PlainTextBookParser().parse(data: data, title: title)
    book.sourceFilename = try retainOriginal(path, bookID: book.id, ext: "txt")
    try store.add(book)
    return try summaryJSON(book)
  }

  /// Import an EPUB that Kotlin has unzipped into `extractedDirectory`;
  /// `originalPath` is the .epub itself, kept under Books/.
  public func importEPUB(_ extractedDirectory: String, originalPath: String, fallbackTitle: String) async throws -> String {
    let container = DirectoryEPUBContainer(directory: extractedDirectory)
    var book = try EPUBBookParser().parse(container: container, fallbackTitle: fallbackTitle)
    book.sourceFilename = try retainOriginal(originalPath, bookID: book.id, ext: "epub")
    try store.add(book)
    return try summaryJSON(book)
  }

  /// Seed the bundled sample book on a first launch, mirroring the iOS app.
  /// Returns the summary JSON, or "" when nothing was seeded.
  public func seedSampleIfNeeded(_ extractedDirectory: String, originalPath: String) async throws -> String {
    let hasSeeded = FileManager.default.fileExists(atPath: seededMarker.path)
    let seeded = try await SampleBookSeeder.seedIfNeeded(into: store, hasSeededBefore: hasSeeded) {
      let container = DirectoryEPUBContainer(directory: extractedDirectory)
      var book = try EPUBBookParser().parse(container: container, fallbackTitle: "Alice's Adventures in Wonderland")
      book.sourceFilename = try retainOriginal(originalPath, bookID: book.id, ext: "epub")
      try store.add(book)
      return book
    }
    try? Data().write(to: seededMarker)
    guard let seeded else { return "" }
    return try summaryJSON(seeded)
  }

  // MARK: Reading

  public func booksJSON() -> String {
    let summaries = store.allBooks().map { BookSummary($0, coverPath: coverPath(for: $0)) }
    return (try? String(data: encoder.encode(summaries), encoding: .utf8)) ?? "[]"
  }

  public func chaptersJSON(_ bookID: String) throws -> String {
    let book = try book(bookID)
    let chapters = book.chapters.enumerated().map { index, chapter in
      ChapterSummary(
        index: index,
        title: chapter.title ?? book.tocTitle(forChapterIndex: index) ?? Book.fallbackChapterTitle(number: index + 1),
        characterCount: chapter.text.count)
    }
    return String(decoding: try encoder.encode(chapters), as: UTF8.self)
  }

  public func chapterText(_ bookID: String, index: Int64) throws -> String {
    let book = try book(bookID)
    guard book.chapters.indices.contains(Int(index)) else { throw AndroidBridgeError.invalidChapter(Int(index)) }
    return book.chapters[Int(index)].text
  }

  public func savePosition(_ bookID: String, chapterIndex: Int64, characterOffset: Int64) throws {
    let book = try book(bookID)
    try store.savePosition(
      ReadingPosition(chapterIndex: Int(chapterIndex), characterOffset: Int(characterOffset)), for: book.id)
  }

  /// JSON `{"chapterIndex":n,"characterOffset":m}`, or "" when unread.
  public func positionJSON(_ bookID: String) -> String {
    guard let id = UUID(uuidString: bookID), let p = store.position(for: id) else { return "" }
    let summary = PositionSummary(chapterIndex: p.chapterIndex, characterOffset: p.characterOffset)
    return (try? String(data: encoder.encode(summary), encoding: .utf8)) ?? ""
  }

  public func removeBook(_ bookID: String) throws {
    let book = try book(bookID)
    try store.removeBook(id: book.id)
    if let name = book.sourceFilename {
      try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(name))
    }
    try? FileManager.default.removeItem(at: coverURL(for: book.id))
  }

  // MARK: Helpers

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

  /// Writes the cover bytes once and returns the path; nil without artwork.
  private func coverPath(for book: Book) -> String? {
    guard let data = book.coverImageData, !data.isEmpty else { return nil }
    let url = coverURL(for: book.id)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? data.write(to: url)
    }
    return url.path
  }

  private func summaryJSON(_ book: Book) throws -> String {
    String(decoding: try encoder.encode(BookSummary(book, coverPath: coverPath(for: book))), as: UTF8.self)
  }
}
