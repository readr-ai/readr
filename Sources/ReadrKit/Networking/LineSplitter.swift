import Foundation

/// Turns a stream of byte chunks into complete lines.
///
/// The SSE parser is handed exactly one line at a time, and bytes off the
/// wire respect no such boundary: a line — or a single multi-byte character —
/// routinely straddles two chunks. Everything past the last newline is held
/// back until the next chunk arrives, so nothing is ever decoded in halves.
struct LineSplitter {
    private var buffer = Data()

    private static let newline: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// The lines `data` completes. Blank lines are kept — in SSE a blank line
    /// is what ends an event, not noise.
    mutating func lines(from data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let terminator = buffer[start...].firstIndex(of: Self.newline) {
            lines.append(Self.strippingCarriageReturn(buffer[start..<terminator]))
            start = buffer.index(after: terminator)
        }
        buffer = Data(buffer[start...])
        return lines
    }

    /// The last line of a body that did not end in a newline. Nil when the
    /// bytes ran out on a line boundary — an empty final line is not a line.
    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let line = Self.strippingCarriageReturn(buffer[...])
        buffer = Data()
        return line
    }

    /// CRLF is one terminator, so the CR belongs to neither line.
    private static func strippingCarriageReturn(_ slice: Data.SubSequence) -> Data {
        guard slice.last == carriageReturn else { return Data(slice) }
        return Data(slice.dropLast())
    }
}
