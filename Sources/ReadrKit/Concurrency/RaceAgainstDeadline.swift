import Foundation

/// `raceAgainstDeadline` gave up waiting: the work ran past `seconds`.
public struct DeadlineExceeded: Error, Equatable, Sendable, LocalizedError {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "Timed out after \(seconds)s"
    }
}

/// The first of `work` or a deadline to finish wins; the caller is resumed
/// exactly once, and the loser is left running.
///
/// This is deliberately NOT a task group: a group awaits every child before
/// it returns, so when the work cannot be cancelled (an MLX synthesis has no
/// mid-graph cancellation) a group-based timeout changes nothing — the
/// caller still waits for the work. Here `work` runs in its own unstructured
/// task; if it loses, its result is dropped on the floor and it keeps running
/// to completion on its own. A deadline that loses is cancelled.
public func raceAgainstDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.arm(continuation)
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            // A cancelled sleep returns early; only a deadline that actually
            // elapsed may resume the caller.
            guard !Task.isCancelled else { return }
            gate.resume(.failure(DeadlineExceeded(seconds: seconds)))
        }
        Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            if gate.resume(result) {
                deadline.cancel()
            }
        }
    }
}

/// A continuation that can be resumed at most once, from any thread.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func arm(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// True if this call was the one that resumed the caller.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}
