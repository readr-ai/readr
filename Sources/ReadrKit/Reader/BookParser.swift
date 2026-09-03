import Foundation

public enum BookFormat: Sendable {
    case epub
    case pdf
}

public enum BookParserError: Error, Sendable {
    case unsupportedFormat
    case drmProtected
    case corrupted(String)
}

/// Turns a source file (EPUB or PDF) into a format-agnostic `Book`.
///
/// The default implementation will wrap the Readium Swift toolkit. DRM-protected
/// files are rejected with `.drmProtected` — Readr only handles books you own
/// in a DRM-free form.
public protocol BookParser: Sendable {
    func canParse(_ url: URL) -> Bool
    func parse(_ url: URL) async throws -> Book
}

/// Rough token estimate (~4 chars/token) used at import time so the context
/// router can decide whole-book vs. retrieval before any provider is attached.
public func estimateTokens(_ text: String) -> Int {
    estimateTokens(characterCount: text.count)
}

/// The same estimate from a character count that has already been taken —
/// so a scoped question can be budgeted from `ReadingLengthTable` without
/// assembling the text it would send.
public func estimateTokens(characterCount: Int) -> Int {
    max(1, characterCount / 4)
}
