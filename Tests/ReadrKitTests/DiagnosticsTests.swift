import XCTest
@testable import ReadrKit

/// Diagnostics for in-app bug reports (#41).
///
/// The EPUB rendering bugs this cycle were only caught by manual screenshots
/// and reasoning about the parser — there was nothing a reader could send.
/// This log is what a report attaches.
///
/// Two rules constrain it hard, and both are tested rather than trusted:
/// no book content (readers send reports about books they own, and their
/// reading is theirs), and no secrets (CLAUDE.md — never in logs).
final class DiagnosticsLogTests: XCTestCase {

    private func makeLog(capacity: Int = 200) -> DiagnosticsLog {
        DiagnosticsLog(capacity: capacity)
    }

    // MARK: - Recording

    func testRecordsEventsNewestLast() {
        let log = makeLog()
        log.record(.info, .importer, "import started")
        log.record(.error, .importer, "import failed")

        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.first?.message, "import started")
        XCTAssertEqual(log.entries.last?.level, .error)
        XCTAssertEqual(log.entries.last?.category, .importer)
    }

    /// The rotation: a long session can't grow without bound, and the newest
    /// events are the ones a report needs.
    func testOldestEventsAreDroppedAtCapacity() {
        let log = makeLog(capacity: 3)
        for index in 1...5 { log.record(.info, .reader, "event \(index)") }

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.message), ["event 3", "event 4", "event 5"])
    }

    func testClearEmptiesTheLog() {
        let log = makeLog()
        log.record(.info, .app, "hello")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    /// An error's `diagnosticDescription` is the whole point of the detail
    /// field — the triage string the reader never saw (#48).
    func testRecordingAnErrorKeepsItsDiagnosticDetail() throws {
        let log = makeLog()
        log.record(.error, .provider, "ask failed", error: HTTPError.status(401, body: "bad key"))

        let detail = try XCTUnwrap(log.entries.last?.detail)
        XCTAssertTrue(detail.contains("HTTP 401"), detail)
    }

    // MARK: - Secrets never reach the log

    func testSecretsAreRedactedFromMessages() {
        let log = makeLog()
        log.record(.error, .provider, "sent key sk-proj-AbC123dEf456GhI789jKl0mno")

        let message = log.entries.last?.message ?? ""
        XCTAssertFalse(message.contains("sk-proj-AbC123dEf456GhI789jKl0mno"), message)
        XCTAssertTrue(message.contains("[redacted]"), message)
    }

    func testSecretsAreRedactedFromErrorDetail() {
        let log = makeLog()
        log.record(
            .error, .provider, "rejected",
            error: HTTPError.status(401, body: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345")
        )
        XCTAssertFalse(
            (log.entries.last?.detail ?? "").contains("sk-ant-api03"),
            log.entries.last?.detail ?? ""
        )
    }

    // MARK: - Book content never reaches the log

    /// Messages are capped short. A cap is not a guarantee on its own, which
    /// is why the pipeline call sites log counts and identifiers rather than
    /// text — but it bounds the damage if one ever slips.
    func testMessagesAreTruncated() {
        let log = makeLog()
        log.record(.info, .reader, String(repeating: "prose ", count: 500))

        let message = log.entries.last?.message ?? ""
        XCTAssertLessThanOrEqual(message.count, DiagnosticsLog.maxMessageLength + 1)
    }

    /// The typed helper for a parse failure records *about* the book, never
    /// *from* it.
    func testBookDiagnosticsCarryShapeNotText() throws {
        let log = makeLog()
        let book = Book(
            metadata: BookMetadata(title: "Moby-Dick", authors: ["Herman Melville"]),
            chapters: [Chapter(title: "Loomings", order: 0, text: "Call me Ishmael.")],
            estimatedTokenCount: 4
        )
        log.recordBookOpened(book, format: "epub")

        let entry = try XCTUnwrap(log.entries.last)
        let text = entry.message + (entry.detail ?? "")
        XCTAssertFalse(text.contains("Call me Ishmael"), "book text reached the log: \(text)")
        XCTAssertFalse(text.contains("Moby-Dick"), "the book title is the reader's business: \(text)")
        XCTAssertTrue(text.contains("epub"), text)
        XCTAssertTrue(text.contains("1"), "chapter count is the useful part: \(text)")
    }

    // MARK: - Thread safety

    /// Logging happens from the reader, the parser, and provider streaming —
    /// different threads, no coordination between them.
    func testConcurrentRecordingDoesNotCorruptTheBuffer() {
        let log = makeLog(capacity: 500)
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            log.record(.info, .reader, "event \(index)")
        }
        XCTAssertEqual(log.entries.count, 400)
    }
}

/// The report a reader actually sends.
final class BugReportTests: XCTestCase {

    private let environment = BugReportEnvironment(
        appVersion: "2.15.0",
        build: "42",
        osVersion: "iOS 26.0",
        deviceModel: "iPhone17,1"
    )

    private func makeLog() -> DiagnosticsLog {
        let log = DiagnosticsLog(capacity: 50)
        log.record(.error, .importer, "EPUB parse failed", error: BookParserError.drmProtected)
        return log
    }

    /// Triage starts with "which version, which OS, which device" — a report
    /// without them costs a round trip.
    func testReportCarriesTheEnvironment() {
        let body = BugReportComposer.compose(
            environment: environment, events: makeLog().entries, userDescription: nil
        )
        XCTAssertTrue(body.contains("2.15.0"), body)
        XCTAssertTrue(body.contains("42"), body)
        XCTAssertTrue(body.contains("iOS 26.0"), body)
        XCTAssertTrue(body.contains("iPhone17,1"), body)
    }

    func testReportIncludesRecentDiagnostics() {
        let body = BugReportComposer.compose(
            environment: environment, events: makeLog().entries, userDescription: nil
        )
        XCTAssertTrue(body.contains("EPUB parse failed"), body)
        XCTAssertTrue(body.contains("drmProtected"), body)
    }

    /// The reader's own words lead — the log is supporting evidence.
    func testUserDescriptionLeadsTheReport() throws {
        let body = BugReportComposer.compose(
            environment: environment,
            events: [],
            userDescription: "The last line of every page is cut off."
        )
        let described = try XCTUnwrap(body.range(of: "The last line of every page is cut off."))
        let version = try XCTUnwrap(body.range(of: "2.15.0"))
        XCTAssertTrue(
            described.lowerBound < version.lowerBound,
            "the reader's description must come first:\n\(body)"
        )
    }

    /// An empty log is normal — most reports are filed before anything failed.
    func testReportWithNoEventsStillReads() {
        let body = BugReportComposer.compose(
            environment: environment, events: [], userDescription: nil
        )
        XCTAssertFalse(body.isEmpty)
        XCTAssertTrue(body.localizedCaseInsensitiveContains("no diagnostics"), body)
    }

    /// Belt and braces: the log redacts on write, and the composer redacts
    /// again on the way out. This string is about to leave the device.
    func testComposedReportNeverCarriesASecret() {
        let events = [
            DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: 0),
                category: .provider,
                level: .error,
                message: "raw sk-proj-AbC123dEf456GhI789jKl0mno",
                detail: "Bearer abcdefghijklmnopqrstuvwxyz012345"
            )
        ]
        let body = BugReportComposer.compose(
            environment: environment, events: events, userDescription: nil
        )
        XCTAssertFalse(body.contains("sk-proj-AbC123dEf456GhI789jKl0mno"), body)
        XCTAssertFalse(body.contains("abcdefghijklmnopqrstuvwxyz012345"), body)
    }

    // MARK: - The tracker link

    func testIssueURLCarriesTitleAndBody() throws {
        let url = try XCTUnwrap(
            BugReportComposer.issueURL(body: "pages are clipped & the last line vanishes")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/readr-ai/readr/issues/new")

        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value, BugReportComposer.subject)
        XCTAssertEqual(
            items.first { $0.name == "body" }?.value,
            "pages are clipped & the last line vanishes",
            "the ampersand must survive query encoding"
        )
    }

    /// A URL too long to open is worse than a shortened report.
    func testIssueURLTruncatesAnOverlongBody() throws {
        let url = try XCTUnwrap(
            BugReportComposer.issueURL(body: String(repeating: "x", count: 20_000))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertEqual(body.count, BugReportComposer.maxURLBodyLength)
    }

    // MARK: - Budgeting

    /// Found in review: the description was never budgeted, only the
    /// diagnostics were. A long one ate the whole allowance and the final
    /// truncation took the environment block, the diagnostics header, the
    /// events *and* the "N omitted" notice with it — so triage received a
    /// report with no version, no device and no evidence, and nothing saying
    /// any of it had been dropped.
    func testALongDescriptionCannotStarveTheRestOfTheReport() {
        let log = DiagnosticsLog(capacity: 200)
        for index in 0..<200 {
            log.record(.error, .reader, "a reasonably wordy diagnostic line \(index)")
        }
        let body = BugReportComposer.compose(
            environment: environment,
            events: log.entries,
            userDescription: String(repeating: "verbose ", count: 2_000)
        )

        XCTAssertTrue(body.contains("2.15.0"), "the version must survive")
        XCTAssertTrue(body.contains("iPhone17,1"), "the device must survive")
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("Recent diagnostics"),
            "the diagnostics section must survive"
        )
        XCTAssertLessThanOrEqual(body.count, BugReportComposer.maxReportLength)
    }

    /// And the reader is told their words were cut rather than left to wonder.
    func testAnOverlongDescriptionSaysItWasTruncated() {
        let body = BugReportComposer.compose(
            environment: environment,
            events: [],
            userDescription: String(repeating: "x", count: 10_000)
        )
        XCTAssertTrue(body.localizedCaseInsensitiveContains("truncated"), body)
    }

    /// An ordinary description is untouched.
    func testANormalDescriptionIsNotTruncated() {
        let described = "The last line of every page is cut off in two-page mode."
        let body = BugReportComposer.compose(
            environment: environment, events: [], userDescription: described
        )
        XCTAssertTrue(body.contains(described))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("truncated"))
    }

    /// Mail bodies go into a `mailto:` URL; an unbounded log would blow past
    /// what the OS will open.
    func testReportIsBounded() {
        let log = DiagnosticsLog(capacity: 500)
        for index in 0..<500 {
            log.record(.info, .reader, "a reasonably wordy diagnostic line number \(index)")
        }
        let body = BugReportComposer.compose(
            environment: environment, events: log.entries, userDescription: nil
        )
        XCTAssertLessThanOrEqual(body.count, BugReportComposer.maxReportLength)
    }
}
