#if canImport(ZIPFoundation)
import Foundation
import ZIPFoundation
import ReadrKit

/// ZIP-backed `EPUBContainer` using ZIPFoundation. All EPUB parsing logic lives
/// in `ReadrKit.EPUBBookParser`; this only supplies entry bytes from the archive.
struct ZipEPUBContainer: EPUBContainer {
    private let archive: Archive
    let extractionBudget: EPUBExtractionBudget

    init(url: URL, extractionBudget: EPUBExtractionBudget = EPUBExtractionBudget()) throws {
        self.archive = try Archive(url: url, accessMode: .read)
        self.extractionBudget = extractionBudget
    }

    func entryExists(_ path: String) -> Bool {
        archive[path] != nil
    }

    func data(at path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw BookParserError.corrupted("missing entry: \(path)")
        }
        // Stream the entry in chunks, enforcing the per-entry and cumulative
        // decompressed-size caps as each chunk arrives. A hostile, highly
        // compressible entry aborts before its bytes accumulate in memory.
        var data = Data()
        var entryBytes = 0
        _ = try archive.extract(entry) { chunk in
            entryBytes = try extractionBudget.accountChunk(
                entryPath: path, entryBytesSoFar: entryBytes, chunkBytes: chunk.count
            )
            data.append(chunk)
        }
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
            // The reader sees "corrupted"; triage needs the ZIP layer's own
            // reason, which used to be discarded here. It rides in the error's
            // detail — recorded once, by `importBook`'s `recordImportFailure`
            // — as a type and a code, never the description: ZIPFoundation's
            // errors carry the file path, and the filename is usually the
            // title and author.
            let underlying = error as NSError
            throw BookParserError.corrupted(
                "could not open EPUB archive (\(underlying.domain) \(underlying.code))"
            )
        }
        return try EPUBBookParser().parse(
            container: container,
            fallbackTitle: url.deletingPathExtension().lastPathComponent
        )
    }
}
#endif
