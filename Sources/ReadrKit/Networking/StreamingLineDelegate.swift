import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Feeds an `AsyncThrowingStream` of complete lines from a `URLSession` data
/// task's delegate callbacks.
///
/// This is how token streaming works on swift-corelibs-foundation, which has
/// no `URLSession.bytes`: the data delegate is its only incremental-bytes
/// API. The type is compiled on every platform, not only the one that uses
/// it, so its behaviour is unit-testable on the development machine — the
/// callbacks below are pure functions of the response and bytes handed to
/// them, and the tests call them directly.
///
/// A non-2xx body is accumulated rather than streamed: the provider's error
/// JSON is the one useful thing in it, and `HTTPError.status` carries it
/// through to the reader's error sentence.
///
/// One task's callbacks are delivered one at a time, in order, on the
/// session's delegate queue — so this state needs no lock. The only flag that
/// outlives a single callback is `isFinished`, and it is there to keep the
/// FIRST reason a stream ended, not to make the state thread-safe.
final class StreamingLineDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation

    private let continuation: Continuation
    private var splitter = LineSplitter()
    private var status: Int?
    private var errorBody = Data()
    private var isFinished = false

    init(continuation: Continuation) {
        self.continuation = continuation
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(receive(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(with: error)
    }

    // MARK: - The behaviour itself

    /// Record the status. False when the reply wasn't HTTP at all, which ends
    /// the stream here rather than reading a body nobody can parse.
    @discardableResult
    func receive(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            finish(throwing: HTTPError.nonHTTPResponse)
            return false
        }
        status = http.statusCode
        return true
    }

    /// Yield whatever lines these bytes complete — or hold them as the error
    /// body when the status already said this is not an answer.
    func receive(_ data: Data) {
        if let status, !(200..<300).contains(status) {
            HTTPErrorBody.append(data, to: &errorBody)
            return
        }
        do {
            for line in try splitter.lines(from: data) { continuation.yield(line) }
        } catch {
            // A line that never ends: the body is not the event stream it
            // claimed to be, which is a bad reply and not a reader's problem.
            finish(throwing: HTTPError.transport(.badServerResponse))
        }
    }

    /// End the stream: the status the provider gave, a transport failure, or
    /// the final partial line of a body that ended without a terminator.
    func complete(with error: Error?) {
        // A rejected request often has its connection dropped right after the
        // error body. The status is why the stream ended; the drop that
        // followed it is a symptom, and reporting it instead cost the reader
        // the one sentence saying their key was refused.
        if let status, !(200..<300).contains(status) {
            finish(throwing: HTTPError.status(status, body: String(decoding: errorBody, as: UTF8.self)))
            return
        }
        if let error {
            finish(throwing: HTTPError.transport((error as? URLError)?.code ?? .unknown))
            return
        }
        // The task ended without ever reporting a response.
        guard status != nil else {
            finish(throwing: HTTPError.nonHTTPResponse)
            return
        }
        if let tail = splitter.flush() { continuation.yield(tail) }
        finish(throwing: nil)
    }

    /// Finishing twice would be a no-op on the continuation, but the guard
    /// keeps a late `didCompleteWithError` from replacing the real reason a
    /// stream ended (a non-HTTP response cancels the task, which then
    /// reports a cancellation).
    private func finish(throwing error: Error?) {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish(throwing: error)
    }
}
