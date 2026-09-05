import XCTest
@testable import ReadrKit

/// A device build has no way to read `DiagnosticsLog`'s in-memory ring buffer
/// except the in-app bug report — this sink writes each event to a file too,
/// so `xcrun devicectl` can pull it straight off the app container between
/// sessions or after a crash (docs/DEVICE-SMOKE-TEST.md).
final class DiagnosticsFileSinkTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsFileSinkTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private var logURL: URL { directory.appendingPathComponent("readr.log") }
    private var rotatedURL: URL { directory.appendingPathComponent("readr.log.1") }

    private func makeEvent(
        message: String = "opened epub book: 12 chapters",
        level: DiagnosticEvent.Level = .info,
        category: DiagnosticEvent.Category = .reader,
        detail: String? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_735_000_000)
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: timestamp, category: category, level: level, message: message, detail: detail
        )
    }

    private func readLines(at url: URL) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Reading back

    /// The bug report used to be composed from the in-memory ring buffer
    /// alone, so a report filed after a crash-and-relaunch carried only the
    /// new session's "launched" line — the evidence sat in this file, unread.
    func testEventsReadBackRoundTripWhatWasWritten() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        let written = [
            makeEvent(message: "opened epub book: 12 chapters", level: .info, category: .reader,
                      timestamp: Date(timeIntervalSince1970: 1_735_000_000)),
            makeEvent(message: "ask failed via anthropic (cloud tier)", level: .error,
                      category: .provider, detail: "HTTP 529: overloaded — try again",
                      timestamp: Date(timeIntervalSince1970: 1_735_000_007)),
        ]
        written.forEach(sink.write)

        XCTAssertEqual(sink.readBack(), written)
    }

    func testReadBackReturnsTheRotatedGenerationFirst() {
        // Two ~44-byte lines fit; the third write rotates the first two out.
        let sink = DiagnosticsFileSink(fileURL: logURL, maxBytes: 100)
        let events = (1...3).map { index in
            makeEvent(message: "event \(index)", timestamp: Date(timeIntervalSince1970: 1_735_000_000 + Double(index)))
        }
        events.forEach(sink.write)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path), "precondition: rotated")

        XCTAssertEqual(sink.readBack().map(\.message), ["event 1", "event 2", "event 3"])
    }

    func testReadBackSkipsLinesItCannotParse() throws {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(message: "good line"))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not a diagnostics line at all\n\n[garbage] nope\n".utf8))
        try handle.close()
        sink.write(makeEvent(message: "another good line"))

        XCTAssertEqual(sink.readBack().map(\.message), ["good line", "another good line"])
    }

    func testReadBackWithNoFileIsEmpty() {
        XCTAssertEqual(DiagnosticsFileSink(fileURL: logURL).readBack(), [])
    }

    // MARK: - Writing

    func testWritesOneLinePerEvent() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(message: "first"))
        sink.write(makeEvent(message: "second"))

        let lines = readLines(at: logURL)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("first"), lines[0])
        XCTAssertTrue(lines[1].contains("second"), lines[1])
    }

    func testLineCarriesTimestampLevelCategoryAndMessage() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(
            message: "ask failed via anthropic (cloud tier)", level: .error, category: .provider,
            timestamp: Date(timeIntervalSince1970: 1_735_000_000)
        ))

        let line = readLines(at: logURL).first ?? ""
        XCTAssertTrue(line.contains("2024-12-24T00:26:40Z"), line)
        XCTAssertTrue(line.contains("ERROR"), line)
        XCTAssertTrue(line.contains("provider"), line)
        XCTAssertTrue(line.contains("ask failed via anthropic (cloud tier)"), line)
    }

    func testAppendsAnErrorDescriptionWhenPresent() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(message: "import failed for .epub file", detail: "HTTP 401: bad key"))

        let line = readLines(at: logURL).first ?? ""
        XCTAssertTrue(line.contains("HTTP 401: bad key"), line)
    }

    func testMessageIsTruncatedTo200CharactersInTheLine() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(message: String(repeating: "x", count: 250)))

        let line = readLines(at: logURL).first ?? ""
        // "x" * 200 plus the ellipsis marker, well short of the untruncated
        // 250 — and the line as a whole stays close to that bound rather
        // than growing with the raw message.
        XCTAssertTrue(line.contains(String(repeating: "x", count: 200)), line)
        XCTAssertFalse(line.contains(String(repeating: "x", count: 201)), line)
    }

    /// A detail with embedded newlines (a multi-line HTTP body) must not
    /// split one event across two physical lines — a reader of the raw file
    /// counts lines to count events.
    func testMultilineDetailStaysOnOneLine() {
        let sink = DiagnosticsFileSink(fileURL: logURL)
        sink.write(makeEvent(message: "ask failed", detail: "line one\nline two\r\nline three"))

        let lines = readLines(at: logURL)
        XCTAssertEqual(lines.count, 1, "one event must be one line: \(lines)")
        XCTAssertTrue(lines[0].contains("line one line two line three"), lines[0])
    }

    func testCreatesTheParentDirectoryIfMissing() {
        let nested = directory
            .appendingPathComponent("Diagnostics")
            .appendingPathComponent("readr.log")
        let sink = DiagnosticsFileSink(fileURL: nested)
        sink.write(makeEvent())

        XCTAssertEqual(readLines(at: nested).count, 1)
    }

    // MARK: - Rotation

    func testRotatesToADotOneSiblingPastTheCap() {
        // Each line is comfortably more than 20 bytes, so a 100-byte cap
        // rotates after a handful of events.
        let sink = DiagnosticsFileSink(fileURL: logURL, maxBytes: 100)
        for index in 1...20 { sink.write(makeEvent(message: "event \(index)")) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotatedURL.path),
            "a sink past its cap should have rotated to a .1 sibling"
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let currentSize = attributes?[.size] as? Int
        XCTAssertNotNil(currentSize)
        XCTAssertLessThanOrEqual(
            currentSize ?? .max, 100 + 200, "the live file should stay near the cap"
        )
    }

    func testTheNewestEventsSurviveRotationInTheCurrentFile() {
        let sink = DiagnosticsFileSink(fileURL: logURL, maxBytes: 100)
        for index in 1...20 { sink.write(makeEvent(message: "event \(index)")) }

        let currentLines = readLines(at: logURL)
        XCTAssertTrue(
            currentLines.last?.contains("event 20") ?? false,
            "the live file should end with the newest event: \(currentLines)"
        )
    }

    /// "A single rotation" — one backup generation, never a `.2`. Rotating
    /// twice overwrites the `.1` rather than chaining another file.
    func testRotationNeverProducesMoreThanOneBackupGeneration() {
        let sink = DiagnosticsFileSink(fileURL: logURL, maxBytes: 100)
        for index in 1...60 { sink.write(makeEvent(message: "event \(index)")) }

        let secondGeneration = directory.appendingPathComponent("readr.log.2")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secondGeneration.path),
            "rotation must not chain past .1"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
    }

    // MARK: - Robustness

    /// A sink whose target directory can't be created (a bad path) must
    /// swallow the failure — installed on `DiagnosticsLog`'s recording path,
    /// it must never be the reason an event fails to record.
    func testWritingNeverThrowsEvenWhenTheTargetIsUnusable() {
        // A file component in the middle of the path makes every URL under
        // it impossible to create as a directory.
        let blocked = directory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: blocked.path, contents: Data("x".utf8))
        let unusable = blocked.appendingPathComponent("readr.log")

        let sink = DiagnosticsFileSink(fileURL: unusable)
        sink.write(makeEvent())
        // No crash, no thrown error reaching the caller — that's the whole
        // assertion.
    }
}
