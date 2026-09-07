import XCTest
@testable import ReadrKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Token streaming on the Foundation that has no `URLSession.bytes`.
///
/// The Linux/Android transport assembles lines from a data delegate's byte
/// callbacks, so both halves are pinned here without a network: the splitter
/// on the boundaries bytes actually arrive on, and the delegate on the three
/// endings a stream can have (clean, non-2xx, transport failure).
final class HTTPStreamingTests: XCTestCase {

    // MARK: - LineSplitter

    private func text(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The lines a chunk completes, as strings. `lines(from:)` throws only on
    /// the buffer ceiling, which has its own test.
    private func split(_ splitter: inout LineSplitter, _ chunk: String) throws -> [String] {
        text(try splitter.lines(from: Data(chunk.utf8)))
    }

    func testSplitsOnLFAndCRLFAlike() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(
            try split(&splitter, "data: one\r\ndata: two\n\r\n"),
            ["data: one", "data: two", ""]
        )
        XCTAssertNil(splitter.flush(), "the body ended on a line boundary")
    }

    /// The SSE spec gives a line three endings, and a bare CR is one of them.
    /// Held as ordinary content it ran two events into one line.
    func testABareCarriageReturnEndsALine() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(try split(&splitter, "data: a\rdata: b\r"), ["data: a", "data: b"])
        XCTAssertNil(splitter.flush(), "nothing follows the last terminator")
    }

    /// A CR is a terminator whichever byte follows it; an LF that does is the
    /// other half of the same one, and does not open an empty line.
    func testACRLFSplitAcrossTwoChunksIsOneTerminator() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(try split(&splitter, "data: a\r"), ["data: a"])
        XCTAssertEqual(try split(&splitter, "\ndata: b\n"), ["data: b"])
        XCTAssertNil(splitter.flush())
    }

    /// A body ending on a terminator has no last line, whichever terminator
    /// it was. The trailing CR ends a blank line — an event boundary, kept
    /// like any other blank line — and leaves nothing behind it; the old
    /// splitter held the CR back and flushed it as an empty final line.
    func testABodyEndingOnACarriageReturnFlushesNothing() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(try split(&splitter, "done\n\r"), ["done", ""])
        XCTAssertNil(splitter.flush())
    }

    /// A provider that never terminates a line — a wedged connection, or a
    /// body that was never an event stream — is a failure, not something to
    /// buffer until the app runs out of memory.
    func testALineThatNeverEndsIsRefusedAtTheCeiling() {
        var splitter = LineSplitter()
        let chunk = Data(repeating: 0x61, count: LineSplitter.maximumBufferedBytes / 2)
        XCTAssertNoThrow(try splitter.lines(from: chunk))
        XCTAssertNoThrow(try splitter.lines(from: chunk), "exactly at the ceiling is still fine")
        XCTAssertThrowsError(try splitter.lines(from: Data("a".utf8))) { error in
            XCTAssertEqual(
                error as? LineSplitter.LineTooLong,
                LineSplitter.LineTooLong(bufferedBytes: LineSplitter.maximumBufferedBytes + 1)
            )
        }
    }

    /// A blank line ends an SSE event, so it is a line like any other.
    func testBlankLinesSurvive() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(try split(&splitter, "a\n\n\nb\n"), ["a", "", "", "b"])
    }

    func testALineSplitAcrossTwoChunksArrivesWhole() throws {
        var splitter = LineSplitter()
        XCTAssertTrue(try split(&splitter, "data: hel").isEmpty)
        XCTAssertEqual(try split(&splitter, "lo\n"), ["data: hello"])
    }

    /// The chunk boundary lands inside a three-byte character. Decoding each
    /// chunk on its own would produce two replacement characters; the buffer
    /// is what keeps the em dash an em dash.
    func testAMultibyteCharacterSplitAcrossChunksArrivesWhole() throws {
        let bytes = Array("a — b\n".utf8)
        let emDashStart = try XCTUnwrap(bytes.firstIndex(of: 0xE2))
        var splitter = LineSplitter()

        XCTAssertTrue(try splitter.lines(from: Data(bytes[..<(emDashStart + 1)])).isEmpty)
        let lines = try splitter.lines(from: Data(bytes[(emDashStart + 1)...]))

        XCTAssertEqual(text(lines), ["a — b"])
    }

    func testABodyWithNoTrailingNewlineFlushesItsLastLine() throws {
        var splitter = LineSplitter()
        XCTAssertEqual(try split(&splitter, "first\nsecond"), ["first"])
        XCTAssertEqual(splitter.flush().map { String(decoding: $0, as: UTF8.self) }, "second")
        XCTAssertNil(splitter.flush(), "the buffer is spent")
    }

    func testAnEmptyFinalLineIsNotALine() throws {
        var splitter = LineSplitter()
        _ = try splitter.lines(from: Data("only\n".utf8))
        XCTAssertNil(splitter.flush())
    }

    // MARK: - StreamingLineDelegate

    private func makeTask() -> URLSessionDataTask {
        // Never resumed — the delegate callbacks are driven by hand below, so
        // this is only the argument they take.
        URLSession.shared.dataTask(
            with: URLRequest(url: URL(string: "https://example.invalid/v1/messages")!)
        )
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/v1/messages")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
    }

    /// Everything a stream yielded before it ended, however it ended.
    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async -> [String] {
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(String(decoding: line, as: UTF8.self)) }
        } catch {}
        return lines
    }

    /// Drive a delegate with a script and collect what the stream produced.
    private func run(
        _ script: (StreamingLineDelegate, URLSession, URLSessionDataTask) -> Void
    ) async -> (lines: [String], error: Error?) {
        let session = URLSession.shared
        let task = makeTask()
        var delegate: StreamingLineDelegate?
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            delegate = StreamingLineDelegate(continuation: continuation)
        }
        script(delegate!, session, task)

        var lines: [String] = []
        do {
            for try await line in stream { lines.append(String(decoding: line, as: UTF8.self)) }
            return (lines, nil)
        } catch {
            return (lines, error)
        }
    }

    func testASuccessfulStreamYieldsItsLines() async {
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(200)) { _ in }
            delegate.urlSession(session, dataTask: task, didReceive: Data("data: a\n\ndata:".utf8))
            delegate.urlSession(session, dataTask: task, didReceive: Data(" b\n".utf8))
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        }

        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines, ["data: a", "", "data: b"])
    }

    /// The bytes after the last newline are still an SSE line; providers that
    /// end on `data: [DONE]` without a trailing newline depend on it.
    func testTheFinalPartialLineIsFlushedAtCompletion() async {
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(200)) { _ in }
            delegate.urlSession(session, dataTask: task, didReceive: Data("data: [DONE]".utf8))
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        }

        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines, ["data: [DONE]"])
    }

    /// A rejected key answers 401 with a JSON body. That body is the only
    /// place the provider says which key it rejected and why, so it must
    /// reach `HTTPError.status` rather than being streamed as content.
    func testARejectedRequestFinishesWithItsStatusAndBody() async {
        let body = #"{"error":{"message":"Incorrect API key provided."}}"#
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(401)) { _ in }
            delegate.urlSession(session, dataTask: task, didReceive: Data(body.utf8))
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        }

        XCTAssertTrue(result.lines.isEmpty, "an error body is not answer text")
        XCTAssertEqual(result.error as? HTTPError, .status(401, body: body))
        XCTAssertEqual(
            (result.error as? HTTPError)?.errorDescription,
            "Your API key was rejected. Check it in Settings → AI Providers."
                + " The provider said: Incorrect API key provided."
        )
    }

    func testATransportFailureMapsToTransport() async {
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(200)) { _ in }
            delegate.urlSession(session, dataTask: task, didReceive: Data("data: a\n".utf8))
            delegate.urlSession(
                session, task: task, didCompleteWithError: URLError(.networkConnectionLost)
            )
        }

        XCTAssertEqual(result.lines, ["data: a"], "what arrived before the drop still counts")
        XCTAssertEqual(result.error as? HTTPError, .transport(.networkConnectionLost))
    }

    /// A provider that rejects a request usually drops the connection right
    /// after its error body. The status is why the stream ended; the drop
    /// that followed it is a symptom, and reporting the symptom cost the
    /// reader the one sentence naming the real problem.
    func testAStatusOutranksTheTransportFailureThatFollowedIt() async {
        let body = #"{"error":{"message":"Incorrect API key provided."}}"#
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(401)) { _ in }
            delegate.urlSession(session, dataTask: task, didReceive: Data(body.utf8))
            delegate.urlSession(
                session, task: task, didCompleteWithError: URLError(.networkConnectionLost)
            )
        }

        XCTAssertEqual(result.error as? HTTPError, .status(401, body: body))
    }

    /// A gateway answering a rejected request with a megabyte of HTML is not
    /// something to hold in memory and write into a bug report. The first
    /// 8 KB carry the provider's message; the rest is dropped as it arrives.
    func testAHugeErrorBodyIsTruncatedToTheCap() async {
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(500)) { _ in }
            for _ in 0..<16 {
                delegate.urlSession(
                    session, dataTask: task,
                    didReceive: Data(repeating: 0x78, count: 64 * 1024)
                )
            }
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        }

        guard case let .status(code, body)? = result.error as? HTTPError else {
            return XCTFail("expected a status error, got \(String(describing: result.error))")
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(body.count, HTTPErrorBody.maximumBytes)
    }

    /// The cap itself, where both streaming paths read it from.
    func testTheErrorBodyCapStopsAtTheCeiling() {
        var body = Data()
        HTTPErrorBody.append(Data(repeating: 0x61, count: 100), to: &body)
        XCTAssertEqual(body.count, 100, "a small body is kept whole")

        HTTPErrorBody.append(Data(repeating: 0x62, count: 1_000_000), to: &body)
        XCTAssertEqual(body.count, HTTPErrorBody.maximumBytes)
        XCTAssertTrue(body.starts(with: Data(repeating: 0x61, count: 100)), "the front survives")

        HTTPErrorBody.append(Data(repeating: 0x63, count: 10), to: &body)
        XCTAssertEqual(body.count, HTTPErrorBody.maximumBytes, "a full body takes nothing more")
    }

    /// A body that is not an event stream at all — no terminator in a
    /// megabyte — ends the stream rather than buffering forever.
    func testABodyWithNoLineTerminatorEndsTheStream() async {
        let result = await run { delegate, session, task in
            delegate.urlSession(session, dataTask: task, didReceive: self.response(200)) { _ in }
            for _ in 0..<3 {
                delegate.urlSession(
                    session, dataTask: task,
                    didReceive: Data(repeating: 0x61, count: LineSplitter.maximumBufferedBytes / 2)
                )
            }
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
        }

        XCTAssertEqual(result.error as? HTTPError, .transport(.badServerResponse))
    }

    // MARK: - One session, many streams

    /// The shared session has one delegate and the client has many streams,
    /// so callbacks are routed by task identifier. Two streams in flight must
    /// not read each other's lines.
    func testTheDispatcherRoutesEachTasksBytesToItsOwnStream() async {
        let dispatcher = StreamingTaskDispatcher()
        let session = URLSession.shared
        let first = makeTask()
        let second = makeTask()

        var firstDelegate: StreamingLineDelegate?
        let firstStream = AsyncThrowingStream<Data, Error> { firstDelegate = StreamingLineDelegate(continuation: $0) }
        var secondDelegate: StreamingLineDelegate?
        let secondStream = AsyncThrowingStream<Data, Error> { secondDelegate = StreamingLineDelegate(continuation: $0) }
        dispatcher.register(firstDelegate!, for: first.taskIdentifier)
        dispatcher.register(secondDelegate!, for: second.taskIdentifier)

        dispatcher.urlSession(session, dataTask: first, didReceive: response(200)) { _ in }
        dispatcher.urlSession(session, dataTask: second, didReceive: response(200)) { _ in }
        dispatcher.urlSession(session, dataTask: second, didReceive: Data("second\n".utf8))
        dispatcher.urlSession(session, dataTask: first, didReceive: Data("first\n".utf8))
        dispatcher.urlSession(session, task: second, didCompleteWithError: nil)
        dispatcher.urlSession(session, task: first, didCompleteWithError: nil)

        let firstLines = await collect(firstStream)
        let secondLines = await collect(secondStream)

        XCTAssertEqual(firstLines, ["first"])
        XCTAssertEqual(secondLines, ["second"])
        XCTAssertNil(
            dispatcher.delegate(for: first.taskIdentifier),
            "a finished task is dropped, so its identifier can be reused"
        )
        XCTAssertNil(dispatcher.delegate(for: second.taskIdentifier))
    }

    /// A proxy or captive portal that answers with something that isn't HTTP.
    func testANonHTTPResponseEndsTheStream() async {
        let result = await run { delegate, session, task in
            let plain = URLResponse(
                url: URL(string: "https://example.invalid/v1/messages")!,
                mimeType: nil, expectedContentLength: 0, textEncodingName: nil
            )
            delegate.urlSession(session, dataTask: task, didReceive: plain) { disposition in
                XCTAssertEqual(disposition, .cancel)
            }
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        }

        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(
            result.error as? HTTPError, .nonHTTPResponse,
            "the cancellation the refusal itself caused must not replace the reason"
        )
    }
}
