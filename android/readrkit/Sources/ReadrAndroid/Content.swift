import Foundation
import ReadrKit

/// An inline image flattened for Kotlin. `utf16Offset` is where the U+FFFC
/// placeholder sits in the chapter text as Kotlin indexes it — the character
/// the reader draws the picture over. `archivePath` is an entry inside the
/// book's retained original, which Kotlin opens itself: image bytes never
/// cross the bridge (a chapter of plates would be megabytes of JSON).
///
/// `displayWidth`/`displayHeight` are the source markup's pixel intent in CSS
/// pixels, and are absent far more often than not — a reader that assumes
/// them would lay most books out at the wrong size.
struct ChapterImageSummary: Codable {
  var utf16Offset: Int
  var archivePath: String
  var alt: String?
  var displayWidth: Double?
  var displayHeight: Double?

  init?(_ image: ChapterImage, offsets: UTF16OffsetTable) {
    guard image.offset >= 0, image.offset < offsets.characterCount else { return nil }
    utf16Offset = offsets.utf16Offset(ofCharacter: image.offset)
    archivePath = image.archivePath
    alt = image.alt
    displayWidth = image.displayWidth
    displayHeight = image.displayHeight
  }
}

/// A footnote lifted out of the reading flow, as the popup shows it: the
/// fragment a noteref points at, and the note's text. The note's own format
/// spans stay behind — the sheet sets a note as one plain paragraph, and a
/// second offset system on the far side of the bridge would earn nothing.
struct FootnoteSummary: Codable {
  var id: String
  var text: String
}

extension AndroidLibrary {

  /// The chapter's inline images, in reading order, offsets in UTF-16. An
  /// image whose placeholder is no longer in the text (a library written by a
  /// build that anchored them differently) is dropped rather than reported at
  /// an offset that indexes nothing.
  public func chapterImagesJSON(_ bookID: String, index: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapter = try chapter(book, index)
      let offsets = offsetTables.table(for: book, chapterIndex: Int(index))
      let images = (chapter.images ?? [])
        .sorted { $0.offset < $1.offset }
        .compactMap { ChapterImageSummary($0, offsets: offsets) }
      return String(decoding: try Self.encoder().encode(images), as: UTF8.self)
    }
  }

  /// The chapter's lifted footnotes. Empty for most books — only a noteref
  /// that the parser could follow to a note body puts one here.
  public func chapterFootnotesJSON(_ bookID: String, index: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let chapter = try chapter(book, index)
      let notes = (chapter.footnotes ?? []).map { FootnoteSummary(id: $0.id, text: $0.text) }
      return String(decoding: try Self.encoder().encode(notes), as: UTF8.self)
    }
  }
}
