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
final class StreamingLineDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<Data, Error>.Continuation

    private let continuation: Continuation
    private let lock = NSLock()
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
        lock.lock()
        status = http.statusCode
        lock.unlock()
        return true
    }

    /// Yield whatever lines these bytes complete — or hold them as the error
    /// body when the status already said this is not an answer.
    func receive(_ data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if let status, !(200..<300).contains(status) {
            errorBody.append(data)
            lock.unlock()
            return
        }
        let lines = splitter.lines(from: data)
        lock.unlock()
        for line in lines { continuation.yield(line) }
    }

    /// End the stream: a transport failure, the accumulated non-2xx body, or
    /// the final partial line of a body that ended without a newline.
    func complete(with error: Error?) {
        if let error {
            finish(throwing: HTTPError.transport((error as? URLError)?.code ?? .unknown))
            return
        }
        lock.lock()
        let status = self.status
        let body = errorBody
        let tail = splitter.flush()
        lock.unlock()
        if let status {
            guard (200..<300).contains(status) else {
                finish(throwing: HTTPError.status(status, body: String(decoding: body, as: UTF8.self)))
                return
            }
        } else {
            // The task ended without ever reporting a response.
            finish(throwing: HTTPError.nonHTTPResponse)
            return
        }
        if let tail { continuation.yield(tail) }
        finish(throwing: nil)
    }

    /// Finishing twice would be a no-op on the continuation, but the guard
    /// keeps a late `didCompleteWithError` from replacing the real reason a
    /// stream ended (a non-HTTP response cancels the task, which then
    /// reports a cancellation).
    private func finish(throwing error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        continuation.finish(throwing: error)
    }
}
