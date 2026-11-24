import Foundation

/// Turns a stream of byte chunks into complete lines.
///
/// The SSE parser is handed exactly one line at a time, and bytes off the
/// wire respect no such boundary: a line — or a single multi-byte character —
/// routinely straddles two chunks. Everything past the last terminator is
/// held back until the next chunk arrives, so nothing is ever decoded in
/// halves.
///
/// All three of the spec's terminators end a line: LF, CR, and CRLF, which
/// counts as one even when the chunk boundary falls between the two bytes. A
/// bare CR is not a rarity to be tidied up at flush time — some proxies and
/// at least one provider's gateway emit it as the line ending — and treating
/// it as ordinary content ran two events together.
///
/// Each chunk is scanned only over its own bytes: what came before was
/// scanned when it arrived, and consumed bytes are dropped from the front of
/// the buffer rather than copied into a new one.
struct LineSplitter {
    private var buffer: [UInt8] = []
    /// Bytes at the front of `buffer` already looked at. Only what a chunk
    /// adds is ever searched.
    private var scanned = 0
    /// A CR has ended a line and an LF immediately after it belongs to the
    /// same terminator — even when it arrives in the next chunk.
    private var pendingLineFeed = false

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// A line that never ends. Providers stream events of a few hundred
    /// bytes; a megabyte without a terminator is a wedged connection or a
    /// body that is not SSE at all, and buffering it without limit is how a
    /// stream turns into a memory leak.
    static let maximumBufferedBytes = 1024 * 1024

    /// One line grew past `maximumBufferedBytes` without ever ending.
    struct LineTooLong: Error, Equatable {
        var bufferedBytes: Int
    }

    /// The lines `data` completes. Blank lines are kept — in SSE a blank line
    /// is what ends an event, not noise.
    ///
    /// - Throws: `LineTooLong` once the unterminated remainder passes the
    ///   ceiling. The lines completed before that point are lost with it;
    ///   the stream is over either way.
    mutating func lines(from data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var lines: [Data] = []
        var start = 0
        var index = scanned
        while index < buffer.count {
            switch buffer[index] {
            case Self.lineFeed:
                index += 1
                if pendingLineFeed, start == index - 1 {
                    // The second half of a CRLF whose CR already ended a line.
                    pendingLineFeed = false
                    start = index
                    continue
                }
                pendingLineFeed = false
                lines.append(Data(buffer[start..<(index - 1)]))
                start = index
            case Self.carriageReturn:
                pendingLineFeed = true
                index += 1
                lines.append(Data(buffer[start..<(index - 1)]))
                start = index
            default:
                pendingLineFeed = false
                index += 1
            }
        }
        buffer.removeSubrange(0..<start)
        scanned = buffer.count
        guard buffer.count <= Self.maximumBufferedBytes else {
            throw LineTooLong(bufferedBytes: buffer.count)
        }
        return lines
    }

    /// The last line of a body that did not end in a terminator. Nil when the
    /// bytes ran out on a line boundary — an empty final line is not a line.
    mutating func flush() -> Data? {
        defer {
            buffer.removeAll()
            scanned = 0
            pendingLineFeed = false
        }
        guard !buffer.isEmpty else { return nil }
        return Data(buffer)
    }
}
