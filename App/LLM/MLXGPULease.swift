import Foundation
import ReadrKit

#if os(iOS)
import UIKit

/// The one rule every MLX user in the process must follow: one Metal graph
/// at a time, and none while the app is not in the foreground. A C++
/// exception from inside Metal's completion handler is uncatchable
/// (mlx-swift#274, #407), and two graphs racing — or one in flight as the
/// GPU is taken away at background entry — is how it happens. Readr Voice
/// enforced this privately inside its own engine; the downloaded language
/// model is a second MLX user, so the gate lives here and both go through
/// it: the speech engine around each GPU synthesis, the language model
/// around its load and its whole generation.
///
/// Admission is a plain FIFO. Readr Voice's own per-purpose ordering
/// (playback ahead of prefetch) still happens inside its actor before it
/// reaches this gate, so it loses nothing.
actor MLXGPULease {

    static let shared = MLXGPULease()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Foreground state, written by lifecycle notifications on the main
    /// thread and read from anywhere.
    nonisolated private let foreground = ForegroundFlag()

    private init() {
        foreground.install()
    }

    nonisolated var isForeground: Bool { foreground.isForeground }

    /// Wait for the GPU, then for the foreground. Cancellation while waiting
    /// hands the lease straight on.
    func acquire() async throws {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` holding the lease; the lease is released however `body`
    /// ends. Throws `MLXGPULeaseError.backgrounded` rather than starting GPU
    /// work with the app off screen.
    func withLease<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        guard isForeground else { throw MLXGPULeaseError.backgrounded }
        return try await body()
    }
}

enum MLXGPULeaseError: Error {
    case backgrounded
}

/// `isForeground` as a value any thread may read. Installed once; the
/// lifecycle observers (main thread) are the only writers.
private final class ForegroundFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var isForeground: Bool { lock.withLock { value } }

    func install() {
        Task { @MainActor in
            self.set(UIApplication.shared.applicationState == .active)
            let center = NotificationCenter.default
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(true) }
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(false) }
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.set(false) }
        }
    }

    private func set(_ foreground: Bool) {
        lock.withLock { value = foreground }
    }
}
#endif
