import Foundation
import ReadrKit

/// One in-book match flattened for Kotlin: where it is (chapter index and a
/// UTF-16 offset into that chapter's text) and the line to show for it. The
/// title is the one the kit found on the chapter, which some books do not
/// have — Kotlin falls back to the chapter list it already holds.
struct SearchHit: Codable {
  var id: Int
  var chapterIndex: Int
  var chapterTitle: String?
  var utf16Offset: Int
  var snippet: String
}

extension AndroidLibrary {

  /// Every match for `query` in the book, in reading order, capped at
  /// `limit`. Case-insensitive, and an empty or blank query matches nothing
  /// rather than everything — the kit's `BookSearcher` decides both, so the
  /// Android reader and the Apple one find the same passages.
  ///
  /// Offsets come back in UTF-16, converted per chapter. Results are in
  /// reading order, so the run of hits in one chapter converts against one
  /// table: the first builds it and the rest hit the cache.
  public func searchJSON(_ bookID: String, query: String, limit: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let hits = BookSearcher.search(query, in: book, limit: Int(limit)).map { result in
        SearchHit(
          id: result.id,
          chapterIndex: result.chapterIndex,
          chapterTitle: result.chapterTitle,
          utf16Offset: offsetTables
            .table(for: book, chapterIndex: result.chapterIndex)
            .utf16Offset(ofCharacter: result.characterOffset),
          snippet: result.snippet)
      }
      return String(decoding: try Self.encoder().encode(hits), as: UTF8.self)
    }
  }
}
