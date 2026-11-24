import Foundation
import ReadrKit

#if os(iOS)
import MLX
import MLXLLM
import MLXLMCommon

/// A language model Readr downloaded and runs itself on the MLX runtime —
/// the way to ask a book without a key on an iPhone that can't run Apple's
/// on-device model (iOS 17–25, or hardware without Apple Intelligence), and
/// an optional larger tier (Qwen3.5 4B) on 12 GB+ hardware.
///
/// iOS only: the Mac app doesn't link MLX (its Metal shaders need the
/// separately downloaded Metal toolchain on CI), and Macs have Ollama. Every
/// GPU graph goes through `MLXGPULease`, shared with Readr Voice.
final class MLXLLMProvider: LLMProvider, OnDeviceReadinessReporting, @unchecked Sendable {

    let info: ProviderInfo
    private let spec: DownloadedModelSpec?

    /// Headroom for the estimate's error inside the context budget.
    static let windowMargin = 256

    init(info: ProviderInfo) {
        self.info = info
        self.spec = DownloadedModelCatalog.spec(for: info.modelID)
    }

    // MARK: Readiness

    /// Whether this device can run any downloaded model at all: a Metal GPU
    /// (not the Simulator), enough memory for the smallest model. Computed
    /// once — neither changes for the life of the process.
    static let isSupportedDevice: Bool = MLXRuntimeAvailability.hasMetalGPU
        && !DownloadedModelCatalog.models(forPhysicalMemory: MLXLLMProvider.physicalMemory).isEmpty

    static var physicalMemory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// Whether this particular model fits this device.
    private var fitsThisDevice: Bool {
        guard let spec else { return false }
        return Self.isSupportedDevice && spec.minimumPhysicalMemory <= Self.physicalMemory
    }

    func readiness() async -> OnDeviceReadiness {
        guard let spec, Self.isSupportedDevice else {
            return .unsupported(reason: "This device can't run a downloaded model. Connect a cloud provider to ask questions.")
        }
        guard fitsThisDevice else {
            return .unsupported(reason: "\(spec.displayName) needs more memory than this device has. Pick the smaller model.")
        }
        // The disk check needs no actor; the in-flight state does.
        let state = await MainActor.run { MLXModelStore.shared.state(for: spec.repository) }
        switch state {
        case .downloaded:
            return .ready
        case .deleting:
            return .unavailable(reason: "This model is being removed.")
        case .downloading:
            return .unavailable(reason: "\(spec.displayName) is still downloading.")
        case .notDownloaded:
            return .unavailable(reason: "Download \(spec.displayName) (\(spec.downloadSizeDescription)) in Settings → AI Providers.")
        case .failed(let message):
            return .unavailable(reason: message)
        }
    }

    func countTokens(_ text: String) throws -> Int {
        TokenCounter.estimate(text)
    }

    // MARK: Generating

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let use = ModelGenerationUse()
            let task = Task {
                defer { use.finish() }
                do {
                    guard let spec = self.spec, self.fitsThisDevice else {
                        throw OnDeviceModelError.unavailable(
                            "This device can't run \(self.spec?.displayName ?? "that model"). Pick another provider in Settings → AI Providers."
                        )
                    }
                    guard MLXModelStore.snapshotIsComplete(for: spec.repository, in: .default) else {
                        throw OnDeviceModelError.unavailable(
                            "Download \(spec.displayName) (\(spec.downloadSizeDescription)) in Settings → AI Providers first."
                        )
                    }
                    try await MLXModelStore.shared.register(use, repository: spec.repository)
                    defer { Task { @MainActor in MLXModelStore.shared.finished(use, repository: spec.repository) } }
                    let container = try await MLXModelStore.shared.container(for: spec.repository)
                    let plan = try await SmallModelPrompt.plan(request: request, window: self.info.contextBudget) { instructions, prompt in
                        await Self.classifierReply(instructions: instructions, prompt: prompt, container: container)
                    }
                    try await MLXGPULease.shared.withLease {
                        let session = ChatSession(
                            container,
                            instructions: plan.instructions,
                            generateParameters: GenerateParameters(
                                maxTokens: plan.answerTokens, temperature: 0.5, topP: 0.9, repetitionPenalty: 1.1
                            ),
                            // Qwen3.5's template opens a <think> block unless
                            // told not to; the reasoning would eat the answer.
                            additionalContext: ["enable_thinking": false]
                        )
                        var shown = SnapshotAnswerStream(source: plan.copiedSentenceSource)
                        var content = ""
                        var judgedCount = 0
                        for try await chunk in session.streamResponse(to: plan.prompt) {
                            try Task.checkCancellation()
                            guard MLXGPULease.shared.isForeground else { throw MLXGPULeaseError.backgrounded }
                            content += chunk
                            // Judge at sentence boundaries (or every so often
                            // for prose without them), not on every token.
                            if chunk.contains(where: { ".!?\n".contains($0) }) || content.count - judgedCount > 160 {
                                judgedCount = content.count
                                let step = shown.advance(to: content)
                                if !step.delta.isEmpty { continuation.yield(ChatChunk(textDelta: step.delta)) }
                                if step.isLooping { break }
                            }
                        }
                        let settled = shown.advance(to: content)
                        if !settled.delta.isEmpty { continuation.yield(ChatChunk(textDelta: settled.delta)) }
                        let tail = shown.finish()
                        if !tail.delta.isEmpty { continuation.yield(ChatChunk(textDelta: tail.delta)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            use.attach(task)
            continuation.onTermination = { _ in use.cancel() }
        }
    }

    /// The off-topic router, on the same model: one short greedy call.
    static func classifierReply(instructions: String, prompt: String, container: ModelContainer) async -> String {
        do {
            return try await MLXGPULease.shared.withLease {
                let session = ChatSession(
                    container,
                    instructions: instructions,
                    generateParameters: GenerateParameters(maxTokens: 4, temperature: 0),
                    additionalContext: ["enable_thinking": false]
                )
                return try await session.respond(to: prompt)
            }
        } catch {
            return ""
        }
    }

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError || error is OnDeviceModelError { return error }
        if error is SmallModelPrompt.DoesNotFit { return OnDeviceModelError.tooLong }
        if error is MLXGPULeaseError {
            return OnDeviceModelError.unavailable("The answer stopped because Readr went into the background. Ask again.")
        }
        DiagnosticsLog.shared.record(.error, .provider, "downloaded model: generation failed", error: error)
        return OnDeviceModelError.other(String(String(describing: error).prefix(300)))
    }
}

/// "Can MLX run here at all" — a Metal GPU, and not the Simulator — for
/// every MLX user in the app, so neither the speech engine nor the language
/// model has to borrow the other's flag.
enum MLXRuntimeAvailability {
    static let hasMetalGPU: Bool = MLXKokoroSpeechEngine.isAvailableOnThisDevice
}
#endif
