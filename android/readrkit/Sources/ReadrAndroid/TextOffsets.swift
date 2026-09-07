import Foundation

/// Offsets cross the bridge as UTF-16 code units — what a Kotlin `String`
/// indexes and what Compose's text layout reports — and live in the kit as
/// `Character` offsets into `Chapter.text`, which is what positions,
/// highlights and format spans count. The two agree on ASCII and drift apart
/// at the first accent or emoji, so every offset is converted here, with the
/// chapter text in hand, rather than trusted across the boundary.
enum TextOffsets {
  /// UTF-16 offset of the character at `offset`; clamps to the text.
  static func utf16Offset(ofCharacter offset: Int, in text: String) -> Int {
    guard offset > 0 else { return 0 }
    guard let index = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else {
      return text.utf16.count
    }
    return text.utf16.distance(from: text.utf16.startIndex, to: index)
  }

  /// Character offset of the UTF-16 offset; a code unit inside a grapheme
  /// rounds down to the character that contains it. Clamps to the text.
  static func characterOffset(ofUTF16 offset: Int, in text: String) -> Int {
    guard offset > 0 else { return 0 }
    let clamped = min(offset, text.utf16.count)
    let index = String.Index(utf16Offset: clamped, in: text)
    return text.distance(from: text.startIndex, to: index)
  }
}

/// One pass over a text for converting many character offsets (format
/// spans, anchors) without re-walking the string for each.
struct UTF16OffsetTable {
  /// `utf16[i]` is the UTF-16 offset of character `i`; the last entry is the
  /// UTF-16 length.
  private let utf16: [Int]

  init(_ text: String) {
    var table: [Int] = []
    table.reserveCapacity(text.count + 1)
    var running = 0
    for character in text {
      table.append(running)
      running += character.utf16.count
    }
    table.append(running)
    utf16 = table
  }

  var characterCount: Int { utf16.count - 1 }
  var utf16Count: Int { utf16[utf16.count - 1] }

  func utf16Offset(ofCharacter offset: Int) -> Int {
    utf16[max(0, min(offset, characterCount))]
  }
}
