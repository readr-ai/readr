import Foundation
import ReadrKit

/// A `Highlight` flattened for Kotlin: the chapter as an index into
/// `book.chapters` (the kit stores a chapter UUID, which means nothing on the
/// other side of the bridge) and the range in UTF-16 code units.
struct HighlightSummary: Codable {
  var id: String
  var chapterIndex: Int
  var utf16Start: Int
  var utf16End: Int
  var quotedText: String
  var note: String?
  var color: String
  var createdAt: String

  init(_ highlight: Highlight, chapterIndex: Int, offsets: UTF16OffsetTable) {
    id = highlight.id.uuidString
    self.chapterIndex = chapterIndex
    utf16Start = offsets.utf16Offset(ofCharacter: highlight.range.lowerBound)
    utf16End = offsets.utf16Offset(ofCharacter: highlight.range.upperBound)
    quotedText = highlight.quotedText
    note = highlight.note
    color = highlight.markerColor.rawValue
    createdAt = AnnotationDates.string(from: highlight.createdAt)
  }
}

/// A text `Bookmark` flattened for Kotlin, offset in UTF-16. PDF-page
/// bookmarks have no text anchor and never cross this bridge.
struct BookmarkSummary: Codable {
  var id: String
  var chapterIndex: Int
  var utf16Offset: Int
  var snippet: String
  var createdAt: String

  init(_ bookmark: Bookmark, offsets: UTF16OffsetTable) {
    id = bookmark.id.uuidString
    chapterIndex = bookmark.chapterIndex
    utf16Offset = offsets.utf16Offset(ofCharacter: bookmark.characterOffset)
    snippet = bookmark.snippet
    createdAt = AnnotationDates.string(from: bookmark.createdAt)
  }
}

/// Timestamps cross as ISO-8601 with fractional seconds — the one shape
/// `java.time.Instant` parses without a custom pattern, and precise enough
/// that two highlights made in the same second still sort.
enum AnnotationDates {
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func string(from date: Date) -> String {
    formatter.string(from: date)
  }
}

extension AndroidLibrary {

  // MARK: Highlights

  /// Every text highlight in the book, in reading order: chapter, then where
  /// the highlight starts, then when it was made. A highlight whose chapter
  /// is no longer in the book (re-imported shorter) is skipped rather than
  /// reported at a wrong place.
  public func highlightsJSON(_ bookID: String) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      var indexOfChapter: [UUID: Int] = [:]
      for (index, chapter) in book.chapters.enumerated() { indexOfChapter[chapter.id] = index }
      let ordered = store.highlights(for: book.id)
        .compactMap { highlight -> (Highlight, Int)? in
          guard let index = indexOfChapter[highlight.chapterID] else { return nil }
          return (highlight, index)
        }
        .sorted { a, b in
          if a.1 != b.1 { return a.1 < b.1 }
          if a.0.range.lowerBound != b.0.range.lowerBound { return a.0.range.lowerBound < b.0.range.lowerBound }
          return a.0.createdAt < b.0.createdAt
        }
      // Sorted by chapter first, so the offset-table cache is hit for every
      // highlight after the first in each chapter.
      let summaries = ordered.map { highlight, index in
        HighlightSummary(highlight, chapterIndex: index, offsets: offsetTables.table(for: book, chapterIndex: index))
      }
      return String(decoding: try Self.encoder().encode(summaries), as: UTF8.self)
    }
  }

  /// Highlights `utf16Start..<utf16End` of the chapter and returns the new
  /// highlight. Both ends round *down* to the character containing them: a
  /// UTF-16 offset that lands inside a surrogate pair or a combining sequence
  /// belongs to that character, and the kit anchors highlights to whole
  /// characters. An empty range (or one that collapses to empty when it
  /// rounds) throws the kit's `HighlightError.emptySelection`, which reaches
  /// Kotlin as its reader-facing sentence. `note` "" means no note.
  public func addHighlight(
    _ bookID: String, chapterIndex: Int64, utf16Start: Int64, utf16End: Int64, color: String, note: String
  ) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapter = try chapter(book, chapterIndex)
      guard let markerColor = HighlightColor(rawValue: color) else {
        throw AndroidBridgeError.unknownHighlightColor(color)
      }
      let offsets = offsetTables.table(for: book, chapterIndex: Int(chapterIndex))
      let start = offsets.characterOffset(ofUTF16: Int(utf16Start))
      let end = offsets.characterOffset(ofUTF16: Int(utf16End))
      guard start < end else { throw HighlightError.emptySelection }
      var highlight = try HighlightService().makeHighlight(
        in: book, chapter: chapter, range: start..<end,
        note: note.isEmpty ? nil : note, createdAt: Date())
      highlight.color = markerColor
      try store.addHighlight(highlight)
      let summary = HighlightSummary(highlight, chapterIndex: Int(chapterIndex), offsets: offsets)
      return String(decoding: try Self.encoder().encode(summary), as: UTF8.self)
    }
  }

  /// Recolours a highlight and sets (or, with "", clears) its note.
  public func updateHighlight(_ highlightID: String, color: String, note: String) throws {
    try readerFacing {
      guard let markerColor = HighlightColor(rawValue: color) else {
        throw AndroidBridgeError.unknownHighlightColor(color)
      }
      guard let highlight = findHighlight(highlightID) else {
        throw AndroidBridgeError.unknownHighlight(highlightID)
      }
      var updated = HighlightService().setNote(note.isEmpty ? nil : note, on: highlight)
      updated.color = markerColor
      try store.updateHighlight(updated)
    }
  }

  /// Removes a highlight. Removing one that is already gone succeeds — two
  /// taps on the same delete button are not an error worth showing.
  public func removeHighlight(_ highlightID: String) throws {
    try readerFacing {
      guard let uuid = UUID(uuidString: highlightID) else {
        throw AndroidBridgeError.unknownHighlight(highlightID)
      }
      try store.removeHighlight(id: uuid)
    }
  }

  // MARK: Bookmarks

  /// The book's text bookmarks, sorted by chapter then offset. Bookmarks made
  /// in native PDF mode (page-anchored, by another platform sharing the
  /// library) have no text offset and are skipped, as are any left pointing
  /// past the end of a re-imported book.
  public func bookmarksJSON(_ bookID: String) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let ordered = store.bookmarks(for: book.id)
        .filter { $0.pdfPageIndex == nil && book.chapters.indices.contains($0.chapterIndex) }
        .sorted { a, b in
          if a.chapterIndex != b.chapterIndex { return a.chapterIndex < b.chapterIndex }
          if a.characterOffset != b.characterOffset { return a.characterOffset < b.characterOffset }
          return a.createdAt < b.createdAt
        }
      let summaries = ordered.map {
        BookmarkSummary($0, offsets: offsetTables.table(for: book, chapterIndex: $0.chapterIndex))
      }
      return String(decoding: try Self.encoder().encode(summaries), as: UTF8.self)
    }
  }

  /// Bookmarks the chapter at `utf16Offset` (rounded down to the character
  /// containing it) and returns the new bookmark, snippet included.
  public func addBookmark(_ bookID: String, chapterIndex: Int64, utf16Offset: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapter = try chapter(book, chapterIndex)
      let offsets = offsetTables.table(for: book, chapterIndex: Int(chapterIndex))
      let characterOffset = offsets.characterOffset(ofUTF16: Int(utf16Offset))
      let bookmark = Bookmark(
        bookID: book.id,
        chapterIndex: Int(chapterIndex),
        characterOffset: characterOffset,
        snippet: Self.snippet(of: chapter.text, at: characterOffset),
        createdAt: Date())
      try store.addBookmark(bookmark)
      return String(decoding: try Self.encoder().encode(BookmarkSummary(bookmark, offsets: offsets)), as: UTF8.self)
    }
  }

  /// Removes a bookmark; removing one already gone succeeds.
  public func removeBookmark(_ bookmarkID: String) throws {
    try readerFacing {
      guard let uuid = UUID(uuidString: bookmarkID) else {
        throw AndroidBridgeError.unknownBookmark(bookmarkID)
      }
      try store.removeBookmark(id: uuid)
    }
  }

  // MARK: Helpers

  /// ~60 characters of context starting at the bookmarked position, the same
  /// snippet the Apple reader stores. Sliced with `String.Index`:
  /// materialising `Array(text)` would copy the whole chapter for 60
  /// characters of it.
  static func snippet(of text: String, at offset: Int, length: Int = 60) -> String {
    guard let start = text.index(text.startIndex, offsetBy: max(0, offset), limitedBy: text.endIndex),
          start < text.endIndex else { return "" }
    return String(text[start...].prefix(length))
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// The stored highlight with this id, wherever it lives. The store keys
  /// highlights by book and `updateHighlight` needs the whole record back, so
  /// an edit starts by finding it.
  private func findHighlight(_ id: String) -> Highlight? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    for book in store.allBooks() {
      if let match = store.highlights(for: book.id).first(where: { $0.id == uuid }) { return match }
    }
    return nil
  }
}
