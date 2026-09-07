import Foundation
import ReadrKit

/// An EPUB whose entries Kotlin has already unzipped into a directory
/// (`java.util.zip`, with the same per-entry and cumulative caps as
/// `EPUBExtractionLimits`). Paths are archive paths relative to the root; a
/// path that escapes the directory is treated as missing.
struct DirectoryEPUBContainer: EPUBContainer {
  let root: URL
  let extractionBudget = EPUBExtractionBudget()

  init(directory: String) {
    root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
  }

  private func url(for path: String) -> URL? {
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/") else { return nil }
    return candidate
  }

  func entryExists(_ path: String) -> Bool {
    guard let url = url(for: path) else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  func data(at path: String) throws -> Data {
    guard let url = url(for: path), entryExists(path) else {
      throw BookParserError.corrupted("missing entry: \(path)")
    }
    let data = try Data(contentsOf: url)
    try extractionBudget.accountChunk(entryPath: path, entryBytesSoFar: 0, chunkBytes: data.count)
    return data
  }
}
