import Foundation
import ReadrKit
#if os(iOS)
import UIKit

/// All process-global MLX operations share ownership, including CPU compilation
/// switches. GPU users additionally require foreground admission after waiting.
actor MLXGPULease {
    static let shared = MLXGPULease()
    private let gate = AsyncResourceGate()
    nonisolated private let foreground = MLXForegroundFlag()
    private init() {}
    nonisolated var isForeground: Bool { foreground.isForeground }
    func acquire() async throws -> UUID {
        // Initialize the observed state before first admission, rather than
        // racing a fire-and-forget main-actor initialization on the first Ask.
        await MainActor.run { foreground.installIfNeeded() }
        return try await gate.acquire()
    }
    func release(_ token: UUID) async { await gate.release(token) }
    func withLease<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let token = try await acquire()
        do {
            try Task.checkCancellation()
            guard isForeground else { throw MLXGPULeaseError.backgrounded }
            let value = try await body()
            await gate.release(token)
            return value
        } catch { await gate.release(token); throw error }
    }
}
enum MLXGPULeaseError: Error { case backgrounded }
private final class MLXForegroundFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false // fail closed until the main actor observes state
    var isForeground: Bool { lock.withLock { value } }
    private var installed = false
    @MainActor func installIfNeeded() {
        guard !installed else { return }
        installed = true
        self.set(UIApplication.shared.applicationState == .active)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(true) }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.set(false) }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.set(false) }
    }
    private func set(_ foreground: Bool) { lock.withLock { value = foreground } }
}
#endif
