import Foundation

/// One thing that happened, recorded for a bug report (#41).
public struct DiagnosticEvent: Sendable, Equatable {

    /// Which part of the pipeline spoke. Coarse on purpose — this is for
    /// sorting a report at a glance, not for querying.
    public enum Category: String, Sendable, Equatable {
        case importer, reader, provider, index, app
    }

    public enum Level: String, Sendable, Equatable {
        case info, warning, error
    }

    public var timestamp: Date
    public var category: Category
    public var level: Level
    /// What happened, in one short line. Never book text — see `DiagnosticsLog`.
    public var message: String
    /// Triage detail, typically an error's `diagnosticDescription`.
    public var detail: String?

    public init(
        timestamp: Date,
        category: Category,
        level: Level,
        message: String,
        detail: String? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.detail = detail
    }
}

/// A bounded, in-memory record of recent events, attached to bug reports.
///
/// **In memory only, for the session.** Nothing is written to disk. Readers
/// file reports about books they own and questions they asked, and a log on
/// disk is a file that outlives the reason it existed — so the rotation here
/// is a ring buffer that dies with the process. The cost is that a crash takes
/// the log with it; a reader who relaunches and reports still sends something
/// useful because the failure usually reproduces.
///
/// Two invariants, both tested in `DiagnosticsTests`:
///
/// - **No book content.** Call sites record shape — chapter counts, formats,
///   identifiers — never text. `recordBookOpened(_:format:)` is the pattern.
/// - **No secrets.** Every message and detail is passed through
///   `HTTPError.redactingSecrets(in:)` on the way in. Providers echo rejected
///   keys back in their errors (CLAUDE.md — secrets never in logs).
public final class DiagnosticsLog: @unchecked Sendable {

    /// The session log. Injectable elsewhere so tests never share state.
    public static let shared = DiagnosticsLog()

    /// Messages are one line about one event; anything longer is a sign that
    /// content leaked in, so it's clipped rather than trusted.
    public static let maxMessageLength = 300

    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [DiagnosticEvent] = []
    /// An optional tap that sees every sanitized event as it's recorded — the
    /// app installs `DiagnosticsFileSink` here so a device build's evidence
    /// survives past this in-memory ring buffer. Forward-only: a sink
    /// installed mid-session never sees what was recorded before it.
    private var _sink: ((DiagnosticEvent) -> Void)?

    public var sink: ((DiagnosticEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    /// When this session's log began. `BugReportComposer.evidence` uses it
    /// to split the file sink's read-back into "earlier sessions" (kept) and
    /// "this session" (already in the buffer, so dropped from the file side).
    public let sessionStart: Date

    public init(capacity: Int = 200, sessionStart: Date = Date()) {
        self.capacity = max(1, capacity)
        self.sessionStart = sessionStart
        buffer.reserveCapacity(self.capacity)
    }

    /// Events oldest first — reading order for a report.
    public var entries: [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func record(_ event: DiagnosticEvent) {
        var safe = event
        safe.message = Self.sanitize(event.message)
        safe.detail = event.detail.map(Self.sanitize)

        lock.lock()
        buffer.append(safe)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        // Captured under the lock, but invoked after it's released: a sink
        // that calls back into `record` (a file write failure logging
        // itself, say) must not deadlock against this same lock.
        let currentSink = _sink
        lock.unlock()

        currentSink?(safe)
    }

    /// The call-site shorthand. `error` contributes its `diagnosticDescription`
    /// — the triage string the reader never sees.
    public func record(
        _ level: DiagnosticEvent.Level,
        _ category: DiagnosticEvent.Category,
        _ message: String,
        error: Error? = nil,
        timestamp: Date = Date()
    ) {
        record(DiagnosticEvent(
            timestamp: timestamp,
            category: category,
            level: level,
            message: message,
            detail: error?.diagnosticDescription
        ))
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Typed call sites
    //
    // Helpers exist so the pipeline can't casually interpolate book text into
    // a log line. Each records the *shape* of what happened.

    /// A book opened successfully: how it parsed, not what it says.
    public func recordBookOpened(_ book: Book, format: String) {
        record(
            .info, .reader,
            "opened \(format) book: \(book.chapters.count) chapters, ~\(book.estimatedTokenCount) tokens"
        )
    }

    /// An import failed. Named by file extension — never the filename, which
    /// is usually the title and author.
    public func recordImportFailure(fileExtension: String, error: Error) {
        record(.error, .importer, "import failed for .\(fileExtension) file", error: error)
    }

    /// A question failed. The question itself is the reader's, so only the
    /// provider and routing tier are recorded.
    public func recordAskFailure(provider: String, tier: String, error: Error) {
        record(.error, .provider, "ask failed via \(provider) (\(tier) tier)", error: error)
    }

    private static func sanitize(_ text: String) -> String {
        let redacted = HTTPError.redactingSecrets(in: text)
        guard redacted.count > maxMessageLength else { return redacted }
        return String(redacted.prefix(maxMessageLength)) + "…"
    }
}
