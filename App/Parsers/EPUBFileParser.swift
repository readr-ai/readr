#if canImport(ZIPFoundation)
import Foundation
import ZIPFoundation
import ReadrKit

/// ZIP-backed `EPUBContainer` using ZIPFoundation. All EPUB parsing logic lives
/// in `ReadrKit.EPUBBookParser`; this only supplies entry bytes from the archive.
struct ZipEPUBContainer: EPUBContainer {
    private let archive: Archive

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
    }

    func entryExists(_ path: String) -> Bool {
        archive[path] != nil
    }

    func data(at path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw BookParserError.corrupted("missing entry: \(path)")
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }
}

/// Imports `.epub` files by opening a ZIP container and delegating to the tested
/// `EPUBBookParser`.
struct EPUBFileParser: BookParser {
    func canParse(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "epub"
    }

    func parse(_ url: URL) async throws -> Book {
        let container: ZipEPUBContainer
        do {
            container = try ZipEPUBContainer(url: url)
        } catch {
            throw BookParserError.corrupted("could not open EPUB archive")
        }
        return try EPUBBookParser().parse(
            container: container,
            fallbackTitle: url.deletingPathExtension().lastPathComponent
        )
    }
}
#endif
