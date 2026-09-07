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

    func testSplitsOnLFAndCRLFAlike() {
        var splitter = LineSplitter()
        let lines = splitter.lines(from: Data("data: one\r\ndata: two\n\r\n".utf8))
        XCTAssertEqual(text(lines), ["data: one", "data: two", ""])
        XCTAssertNil(splitter.flush(), "the body ended on a line boundary")
    }

    /// A blank line ends an SSE event, so it is a line like any other.
    func testBlankLinesSurvive() {
        var splitter = LineSplitter()
        XCTAssertEqual(text(splitter.lines(from: Data("a\n\n\nb\n".utf8))), ["a", "", "", "b"])
    }

    func testALineSplitAcrossTwoChunksArrivesWhole() {
        var splitter = LineSplitter()
        XCTAssertTrue(splitter.lines(from: Data("data: hel".utf8)).isEmpty)
        XCTAssertEqual(text(splitter.lines(from: Data("lo\n".utf8))), ["data: hello"])
    }

    /// The chunk boundary lands inside a three-byte character. Decoding each
    /// chunk on its own would produce two replacement characters; the buffer
    /// is what keeps the em dash an em dash.
    func testAMultibyteCharacterSplitAcrossChunksArrivesWhole() {
        let bytes = Array("a — b\n".utf8)
        let emDashStart = try! XCTUnwrap(bytes.firstIndex(of: 0xE2))
        var splitter = LineSplitter()

        XCTAssertTrue(splitter.lines(from: Data(bytes[..<(emDashStart + 1)])).isEmpty)
        let lines = splitter.lines(from: Data(bytes[(emDashStart + 1)...]))

        XCTAssertEqual(text(lines), ["a — b"])
    }

    func testABodyWithNoTrailingNewlineFlushesItsLastLine() {
        var splitter = LineSplitter()
        XCTAssertEqual(text(splitter.lines(from: Data("first\nsecond".utf8))), ["first"])
        XCTAssertEqual(splitter.flush().map { String(decoding: $0, as: UTF8.self) }, "second")
        XCTAssertNil(splitter.flush(), "the buffer is spent")
    }

    func testAnEmptyFinalLineIsNotALine() {
        var splitter = LineSplitter()
        _ = splitter.lines(from: Data("only\n".utf8))
        XCTAssertNil(splitter.flush())
    }

    func testACarriageReturnBeforeTheEndIsStrippedToo() {
        var splitter = LineSplitter()
        _ = splitter.lines(from: Data("kept\r\ntail\r".utf8))
        XCTAssertEqual(splitter.flush().map { String(decoding: $0, as: UTF8.self) }, "tail")
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
