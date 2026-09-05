import Foundation

/// Appends `DiagnosticsLog` events to a file, one line per event, so a
/// device build's diagnostics survive past the in-memory ring buffer and can
/// be pulled off without going through the in-app bug report.
///
/// `DiagnosticsLog` stays in-memory by design — see its doc comment — this
/// is an opt-in tap the app installs alongside it:
///
/// ```swift
/// let fileSink = DiagnosticsFileSink(fileURL: logURL)
/// DiagnosticsLog.shared.sink = { [fileSink] event in fileSink.write(event) }
/// ```
///
/// On a device the file lives under the app's own container, so it can be
/// fetched with `xcrun devicectl` between sessions or after a crash — see
/// `docs/DEVICE-SMOKE-TEST.md` for the exact commands.
///
/// Capped at ~1MB with a single rotation: past the cap the current file is
/// moved to a `.1` sibling (replacing whatever was there) and a fresh file
/// starts. One backup generation is enough to catch a bug report window —
/// this is not an archive, and it never chains a `.2`.
public final class DiagnosticsFileSink: @unchecked Sendable {

    /// ~1MB: enough for hours of session diagnostics, small enough to attach
    /// or copy off a device without thinking about it.
    public static let defaultMaxBytes = 1_000_000

    /// A file line's message is trimmed harder than the in-memory cap
    /// (`DiagnosticsLog.maxMessageLength`, 300) — the file is read on a
    /// terminal or in a text editor, one line per event, and a message this
    /// long is already a sign something is off rather than useful detail.
    public static let maxLineMessageLength = 200

    public let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL,
        maxBytes: Int = DiagnosticsFileSink.defaultMaxBytes,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        // Appended to the whole last path component (not swapped in as the
        // extension), so "readr.log" rotates to "readr.log.1" rather than
        // "readr.1.log" — a sibling, as the name says.
        self.rotatedURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        self.maxBytes = max(1, maxBytes)
        self.fileManager = fileManager
    }

    /// Append one line for `event`. Best-effort: a write failure (a full
    /// disk, an unwritable path) is swallowed rather than thrown — installed
    /// on `DiagnosticsLog`'s recording path, this must never be the reason
    /// an event fails to record.
    public func write(_ event: DiagnosticEvent) {
        let line = Self.line(for: event)
        lock.lock()
        defer { lock.unlock() }
        appendLocked(line)
    }

    // MARK: - Formatting

    /// The line format's fixed parts, shared by the writer and the parser so
    /// they cannot drift: `[timestamp] LEVEL category: message<TAB>detail`.
    /// A tab, because `oneLine` guarantees neither field contains one — an
    /// em-dash, the old separator, turns up in prose on both sides ("HTTP
    /// 529: overloaded — try again") and made the split ambiguous. Lines
    /// written before the change still parse (`legacyDetailSeparator`).
    /// Timestamps are whole seconds (`.withInternetDateTime`); anything that
    /// compares them to live `Date`s must floor first.
    static let detailSeparator = "\t"
    static let legacyDetailSeparator = " \u{2014} "

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `[timestamp] LEVEL category: message<TAB>detail`, always exactly one
    /// physical line: a detail carrying a newline (a multi-line HTTP body,
    /// say) is collapsed rather than allowed to split one event across two
    /// lines a reader of the raw file would count as two events.
    static func line(for event: DiagnosticEvent) -> String {
        let timestamp = timestampFormatter.string(from: event.timestamp)
        var message = event.message
        if message.count > maxLineMessageLength {
            message = String(message.prefix(maxLineMessageLength)) + "\u{2026}"
        }
        var line = "[\(timestamp)] \(event.level.rawValue.uppercased()) "
            + "\(event.category.rawValue): \(oneLine(message))"
        if let detail = event.detail, !detail.isEmpty {
            line += detailSeparator + oneLine(detail)
        }
        return line
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: - Reading back

    /// Every event the file still holds, oldest first: the rotated `.1`
    /// generation, then the current file. This is how a bug report filed
    /// after a crash-and-relaunch gets the evidence from before the crash —
    /// the in-memory log died with the process, the file did not.
    ///
    /// Best-effort, like writing: a missing file is an empty list and a line
    /// that doesn't parse (a partial write at the moment of a crash, say) is
    /// skipped rather than failing the whole read.
    public func readBack() -> [DiagnosticEvent] {
        // Only the file reads sit under the lock — the parse is the expensive
        // half, and a writer blocked behind it would stall whatever was
        // logging (a speech-engine failure path, say) for the duration.
        let contents = withContents { $0 }
        return contents.flatMap { text -> [DiagnosticEvent] in
            text.split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { Self.event(from: String($0)) }
        }
    }

    /// A copy of the whole log — the rotated generation, then the current
    /// one — in a temporary file, for a share sheet. A copy because the sink
    /// keeps appending and may rotate while the sheet is up, and both
    /// generations because the report reads both; a "full log" that carried
    /// less than the report would be the wrong label. Nil when there is
    /// nothing to share or the copy couldn't be written.
    public func snapshotForSharing(
        to directory: URL = FileManager.default.temporaryDirectory,
        filename: String = "readr-diagnostics.log"
    ) -> URL? {
        let joined = withContents { $0 }.joined()
        guard !joined.isEmpty else { return nil }
        let url = directory.appendingPathComponent(filename)
        do {
            try joined.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// The two generations' text, oldest first, read under the lock.
    private func withContents<T>(_ body: ([String]) -> T) -> T {
        lock.lock()
        let texts = [rotatedURL, fileURL].compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        lock.unlock()
        return body(texts)
    }

    /// The inverse of `line(for:)`. The detail separator is the first
    /// ` — ` in the line, so a message that itself contains one would be
    /// split early; messages are short shape descriptions and don't.
    static func event(from line: String) -> DiagnosticEvent? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        guard let timestamp = timestampFormatter.date(from: stamp) else { return nil }
        let rest = line[line.index(after: close)...].drop(while: { $0 == " " })
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let level = DiagnosticEvent.Level(rawValue: parts[0].lowercased()),
              parts[1].hasSuffix(":"),
              let category = DiagnosticEvent.Category(rawValue: String(parts[1].dropLast()))
        else { return nil }
        let body = String(parts[2])
        if let range = body.range(of: detailSeparator) ?? body.range(of: legacyDetailSeparator) {
            return DiagnosticEvent(
                timestamp: timestamp, category: category, level: level,
                message: String(body[..<range.lowerBound]),
                detail: String(body[range.upperBound...])
            )
        }
        return DiagnosticEvent(timestamp: timestamp, category: category, level: level, message: body)
    }

    // MARK: - File I/O

    private func appendLocked(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try ensureParentDirectoryExists()
            if let currentSize = try? currentFileSize(), currentSize + data.count > maxBytes {
                rotateLocked()
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics writing is best-effort — see `write(_:)`.
        }
    }

    private func currentFileSize() throws -> Int {
        guard fileManager.fileExists(atPath: fileURL.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? Int) ?? 0
    }

    private func ensureParentDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Move the current file to the `.1` sibling, replacing whatever was
    /// there — one backup generation, never a chain of them.
    private func rotateLocked() {
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedURL)
    }
}
