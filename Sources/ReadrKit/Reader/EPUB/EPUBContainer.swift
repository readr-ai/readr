import Foundation

/// Failures raised while extracting bytes from a (potentially hostile) EPUB
/// archive. These guard against "zip-bomb" style inputs — archives that are
/// small on disk but expand to gigabytes — by capping how much a single entry,
/// and the archive as a whole, may inflate to during extraction.
public enum EPUBParseError: Error, Equatable, Sendable {
    /// A single entry's decompressed size exceeded the per-entry byte cap.
    case entryTooLarge(path: String, limit: Int)
    /// The cumulative decompressed size across all extracted entries exceeded
    /// the archive-wide byte cap.
    case cumulativeSizeExceeded(limit: Int)
    /// The package spine declared more items than the reading-order ceiling.
    case tooManySpineItems(count: Int, limit: Int)
}

/// Extraction size ceilings applied to every `EPUBContainer`. Named so tests
/// and callers can reference the exact documented values.
public enum EPUBExtractionLimits {
    /// Maximum decompressed size of any single archive entry: 64 MB.
    public static let perEntryByteCap = 64 * 1024 * 1024
    /// Maximum cumulative decompressed size across all extracted entries: 512 MB.
    public static let cumulativeByteCap = 512 * 1024 * 1024
}

/// Tracks how many decompressed bytes a container has produced so far and
/// enforces the per-entry and cumulative caps as bytes stream in. A single
/// instance is shared across all extractions of one archive so the cumulative
/// total accrues across entries. A reference type so the running total is
/// shared even when the owning container is a value type.
public final class EPUBExtractionBudget {
    public let perEntryByteCap: Int
    public let cumulativeByteCap: Int
    /// Total decompressed bytes accounted across every entry so far.
    public private(set) var cumulativeBytes = 0

    public init(
        perEntryByteCap: Int = EPUBExtractionLimits.perEntryByteCap,
        cumulativeByteCap: Int = EPUBExtractionLimits.cumulativeByteCap
    ) {
        self.perEntryByteCap = perEntryByteCap
        self.cumulativeByteCap = cumulativeByteCap
    }

    /// Account for a chunk of `chunkBytes` about to be appended to an entry that
    /// already holds `entryBytesSoFar` decompressed bytes. Throws before the
    /// chunk is appended when it would push the entry over the per-entry cap or
    /// the archive over the cumulative cap. Returns the entry's new running
    /// byte total so streaming callers can carry it into the next chunk.
    @discardableResult
    public func accountChunk(entryPath: String, entryBytesSoFar: Int, chunkBytes: Int) throws -> Int {
        let entryTotal = entryBytesSoFar + chunkBytes
        if entryTotal > perEntryByteCap {
            throw EPUBParseError.entryTooLarge(path: entryPath, limit: perEntryByteCap)
        }
        if cumulativeBytes + chunkBytes > cumulativeByteCap {
            throw EPUBParseError.cumulativeSizeExceeded(limit: cumulativeByteCap)
        }
        cumulativeBytes += chunkBytes
        return entryTotal
    }
}

/// Read-only access to the entries inside an EPUB (a ZIP archive). The zip
/// reading itself lives in the app target (`ZipEPUBContainer`, via ZIPFoundation)
/// so the parsing logic here stays dependency-free and unit-testable through
/// `InMemoryEPUBContainer`.
///
/// Extraction is capped: implementations enforce `extractionBudget` while
/// appending bytes so a hostile, highly-compressible archive can't exhaust
/// memory. The budget is shared across all `data(at:)` calls for one archive,
/// so the cumulative cap spans the whole book.
public protocol EPUBContainer {
    /// Size ceilings enforced by `data(at:)`; shared across extractions so the
    /// cumulative total accrues across entries.
    var extractionBudget: EPUBExtractionBudget { get }

    func entryExists(_ path: String) -> Bool
    func data(at path: String) throws -> Data
}

/// In-memory container for tests: a map of archive path → bytes.
public struct InMemoryEPUBContainer: EPUBContainer {
    private let entries: [String: Data]
    public let extractionBudget: EPUBExtractionBudget

    public init(entries: [String: Data], extractionBudget: EPUBExtractionBudget = EPUBExtractionBudget()) {
        self.entries = entries
        self.extractionBudget = extractionBudget
    }

    /// Convenience for fixtures expressed as strings.
    public init(textEntries: [String: String], extractionBudget: EPUBExtractionBudget = EPUBExtractionBudget()) {
        self.entries = textEntries.mapValues { Data($0.utf8) }
        self.extractionBudget = extractionBudget
    }

    public func entryExists(_ path: String) -> Bool {
        entries[path] != nil
    }

    public func data(at path: String) throws -> Data {
        guard let data = entries[path] else {
            throw BookParserError.corrupted("missing entry: \(path)")
        }
        // Mirror the streaming impl's cap enforcement: the whole entry is a
        // single "chunk" here since its size is already known.
        try extractionBudget.accountChunk(entryPath: path, entryBytesSoFar: 0, chunkBytes: data.count)
        return data
    }
}
