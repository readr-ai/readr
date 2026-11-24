import Foundation

/// Offsets cross the bridge as UTF-16 code units — what a Kotlin `String`
/// indexes and what Compose's text layout reports — and live in the kit as
/// `Character` offsets into `Chapter.text`, which is what positions,
/// highlights and format spans count. The two agree on ASCII and drift apart
/// at the first accent or emoji, so every offset is converted through one of
/// these tables, built with one pass over the chapter and cached by the
/// facade, rather than trusted across the boundary.
struct UTF16OffsetTable {
  /// `utf16[i]` is the UTF-16 offset of character `i`; the last entry is the
  /// UTF-16 length.
  private let utf16: [Int32]

  init(_ text: String) {
    var table: [Int32] = []
    table.reserveCapacity(text.utf16.count / 2 + 1)
    var running: Int32 = 0
    for character in text {
      table.append(running)
      running += Int32(character.utf16.count)
    }
    table.append(running)
    utf16 = table
  }

  var characterCount: Int { utf16.count - 1 }
  var utf16Count: Int { Int(utf16[utf16.count - 1]) }

  /// UTF-16 offset of the character at `offset`; clamps to the text.
  func utf16Offset(ofCharacter offset: Int) -> Int {
    Int(utf16[max(0, min(offset, characterCount))])
  }

  /// Character offset of a UTF-16 offset; a code unit inside a grapheme
  /// rounds down to the character that contains it. Clamps to the text.
  func characterOffset(ofUTF16 offset: Int) -> Int {
    let target = Int32(max(0, min(offset, utf16Count)))
    var low = 0
    var high = characterCount
    while low < high {
      let mid = (low + high + 1) / 2
      if utf16[mid] <= target { low = mid } else { high = mid - 1 }
    }
    return low
  }
}
