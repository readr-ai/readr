import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One delegate-owning `URLSession` per `URLSessionHTTPClient`, shared by
/// every stream that client opens.
///
/// A `URLSession`'s delegate can only be set when the session is built, so
/// the streaming path cannot use the injected session and has to build its
/// own from that session's configuration. It used to build — and immediately
/// invalidate — a fresh one per request, which meant a new connection pool,
/// TLS handshake and set of background threads for every question a reader
/// asked. One session, built on the first stream, keeps the pool warm and
/// costs nothing when nothing streams.
///
/// A session has one delegate and this client has many concurrent streams, so
/// the delegate here is a dispatcher: it holds a `StreamingLineDelegate` per
/// task identifier and hands each callback to the one that task belongs to.
/// All the behaviour still lives in `StreamingLineDelegate`, where the tests
/// drive it directly.
final class StreamingSession: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let dispatcher = StreamingTaskDispatcher()
    private let lock = NSLock()
    private var built: URLSession?

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    deinit {
        // The session retains its delegate until it is invalidated, and the
        // delegate is what keeps this object's task table alive. Nothing is
        // streaming by now — the client is gone — so let both go.
        built?.finishTasksAndInvalidate()
    }

    /// A task on the shared session whose callbacks reach `delegate`.
    /// Registered before it is returned, so the caller's `resume()` can never
    /// outrun the registration.
    func dataTask(for request: URLRequest, delegate: StreamingLineDelegate) -> URLSessionDataTask {
        let task = session().dataTask(with: request)
        dispatcher.register(delegate, for: task.taskIdentifier)
        return task
    }

    /// The session, built on first use.
    private func session() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let built { return built }
        let session = URLSession(
            configuration: configuration, delegate: dispatcher, delegateQueue: nil
        )
        built = session
        return session
    }
}

/// Routes a shared session's data-task callbacks to the per-stream delegate
/// that owns each task.
///
/// Task identifiers are unique within a session and reused only after a task
/// completes, and a task is dropped from the table the moment it does — so an
/// identifier never names two live streams.
final class StreamingTaskDispatcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var delegates: [Int: StreamingLineDelegate] = [:]

    func register(_ delegate: StreamingLineDelegate, for taskIdentifier: Int) {
        lock.lock()
        delegates[taskIdentifier] = delegate
        lock.unlock()
    }

    func delegate(for taskIdentifier: Int) -> StreamingLineDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return delegates[taskIdentifier]
    }

    @discardableResult
    func removeDelegate(for taskIdentifier: Int) -> StreamingLineDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return delegates.removeValue(forKey: taskIdentifier)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // No delegate means the stream this task belonged to is already over;
        // there is nobody left to hand the body to.
        guard let delegate = delegate(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(delegate.receive(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        delegate(for: dataTask.taskIdentifier)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        removeDelegate(for: task.taskIdentifier)?.complete(with: error)
    }
}
