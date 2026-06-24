import Foundation

/// A single Server-Sent Events payload, already classified.
public enum SSEEvent: Sendable, Equatable {
    /// A `data:` line carrying a (non-terminal) payload string.
    case data(String)
    /// The terminal `data: [DONE]` sentinel.
    case done
}

/// Stateless, pure SSE line parser.
///
/// Each element emitted by `HTTPClient.stream` is already exactly one line
/// (the transport splits on newlines), so parsing is a pure per-line mapping
/// with no buffering required.
public struct SSEParser: Sendable {
    public init() {}

    /// Map one SSE line to an event, or `nil` when the line carries no event
    /// (blank lines and `:`-comments).
    public static func parseLine(_ line: String) -> SSEEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Blank line (event boundary) — nothing to emit.
        if trimmed.isEmpty { return nil }
        // Comment line.
        if trimmed.hasPrefix(":") { return nil }

        guard trimmed.hasPrefix("data:") else { return nil }

        // Strip the `data:` prefix and a single optional leading space.
        var payload = String(trimmed.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }

        if payload == "[DONE]" { return .done }
        return .data(payload)
    }

    /// Convenience overload accepting raw `Data` (utf8).
    public static func parseLine(_ line: Data) -> SSEEvent? {
        guard let string = String(data: line, encoding: .utf8) else { return nil }
        return parseLine(string)
    }
}
