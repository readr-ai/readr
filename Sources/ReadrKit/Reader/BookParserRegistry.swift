import Foundation

/// Picks the right `BookParser` for a file and surfaces a clear error when none
/// applies. The reader UI imports through this, never a concrete parser.
public struct BookParserRegistry: Sendable {
    private let parsers: [any BookParser]

    public init(parsers: [any BookParser]) {
        self.parsers = parsers
    }

    /// The default registry. The app target extends this with the Readium-backed
    /// EPUB/PDF parser (Apple platforms only).
    public static var standard: BookParserRegistry {
        BookParserRegistry(parsers: [PlainTextBookParser()])
    }

    public func canParse(_ url: URL) -> Bool {
        parsers.contains { $0.canParse(url) }
    }

    public func parse(_ url: URL) async throws -> Book {
        guard let parser = parsers.first(where: { $0.canParse(url) }) else {
            throw BookParserError.unsupportedFormat
        }
        return try await parser.parse(url)
    }
}
