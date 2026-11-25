import Foundation

/// Cancellation-aware FIFO ownership for a process-wide inference resource.
/// Tokens make releasing a stale owner harmless. No vendor or UI dependencies.
public actor AsyncResourceGate {
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<UUID, Error>)] = []
    public init() {}
    public var waitingCount: Int { waiters.count }

    public func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if owner == nil { owner = id; return id }
        let token: UUID = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do { try Task.checkCancellation(); return token }
        catch { release(token); throw error }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    public func release(_ token: UUID) {
        guard owner == token else { return }
        if waiters.isEmpty { owner = nil }
        else { let (next, continuation) = waiters.removeFirst(); owner = next; continuation.resume(returning: next) }
    }
}
