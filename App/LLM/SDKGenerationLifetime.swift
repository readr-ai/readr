import Foundation

/// The stream may terminate before its external SDK worker releases resources.
/// Keep ownership until the worker acknowledges cancellation and actually ends.
enum SDKGenerationLifetime {
    static func run<T>(_ worker: Task<Void, Never>, body: () async throws -> T) async throws -> T {
        do {
            let result = try await withTaskCancellationHandler(operation: body, onCancel: { worker.cancel() })
            worker.cancel()
            await worker.value
            return result
        } catch {
            worker.cancel()
            await worker.value
            throw error
        }
    }
}
