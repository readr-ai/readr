import Foundation

/// Read-only access to the entries inside an EPUB (a ZIP archive). The zip
/// reading itself lives in the app target (`ZipEPUBContainer`, via ZIPFoundation)
/// so the parsing logic here stays dependency-free and unit-testable through
/// `InMemoryEPUBContainer`.
public protocol EPUBContainer {
    func entryExists(_ path: String) -> Bool
    func data(at path: String) throws -> Data
}

/// In-memory container for tests: a map of archive path → bytes.
public struct InMemoryEPUBContainer: EPUBContainer {
    private let entries: [String: Data]

    public init(entries: [String: Data]) {
        self.entries = entries
    }

    /// Convenience for fixtures expressed as strings.
    public init(textEntries: [String: String]) {
        self.entries = textEntries.mapValues { Data($0.utf8) }
    }

    public func entryExists(_ path: String) -> Bool {
        entries[path] != nil
    }

    public func data(at path: String) throws -> Data {
        guard let data = entries[path] else {
            throw BookParserError.corrupted("missing entry: \(path)")
        }
        return data
    }
}
