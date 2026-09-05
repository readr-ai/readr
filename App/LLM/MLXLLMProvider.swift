import Foundation
import ReadrKit

#if os(iOS)
import MLX
import MLXLLM
import MLXLMCommon

/// A language model Readr downloaded and runs itself on the MLX runtime —
/// the way to ask a book without a key on an iPhone that can't run Apple's
/// on-device model (iOS 17–25, or hardware without Apple Intelligence), and
/// the stronger model (Qwen3.5 4B) where it fits.
///
/// iOS only: the Mac app doesn't link MLX (its Metal shaders need the
/// separately downloaded Metal toolchain on CI), and Macs have Ollama.
final class MLXLLMProvider: LLMProvider, OnDeviceReadinessReporting, @unchecked Sendable {

    let info: ProviderInfo
    private let spec: DownloadedModelSpec?

    /// Headroom for the estimate's error inside the context budget.
    static let windowMargin = 256
    static let minimumAnswerTokens = 150
    static let maxQuestionTokens = 400

    init(info: ProviderInfo) {
        self.info = info
        self.spec = DownloadedModelCatalog.spec(for: info.modelID)
    }

    // MARK: Readiness

    /// Whether this device can run any downloaded model at all: a Metal GPU
    /// (not the Simulator), enough memory for the smallest model.
    static var isSupportedDevice: Bool {
        MLXKokoroSpeechEngine.isAvailableOnThisDevice
            && !DownloadedModelCatalog.models(forPhysicalMemory: Int64(ProcessInfo.processInfo.physicalMemory)).isEmpty
    }

    func readiness() async -> OnDeviceReadiness {
        guard Self.isSupportedDevice, let spec else {
            return .unsupported(reason: "This device can't run a downloaded model. Connect a cloud provider to ask questions.")
        }
        guard spec.minimumPhysicalMemory <= Int64(ProcessInfo.processInfo.physicalMemory) else {
            return .unsupported(reason: "\(spec.displayName) needs more memory than this device has. Pick the smaller model.")
        }
        let state = await MainActor.run { MLXModelStore.shared.state(for: spec.repository) }
        switch state {
        case .downloaded:
            return .ready
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
            let task = Task {
                do {
                    guard let spec = self.spec else { throw MLXModelError.invalidRepository(self.info.modelID) }
                    guard Self.isSupportedDevice else { throw MLXModelError.unsupportedDevice }
                    let downloaded = await MainActor.run { MLXModelStore.shared.isDownloaded(spec.repository) }
                    guard downloaded else { throw MLXModelError.notDownloaded }

                    var (instructions, rawPrompt) = LocalPromptShaping.split(request)
                    let isQuestion = rawPrompt.contains(AdaptiveContextStrategy.passagesHeader)
                    if isQuestion {
                        instructions += "\n\n" + LocalPromptShaping.questionStyle
                        rawPrompt += LocalPromptShaping.answerCue
                    }
                    let budget = spec.contextBudget
                    let fixed = TokenCounter.estimate(instructions) + Self.windowMargin
                    let prompt = RetrievalPromptTrimmer.fit(
                        rawPrompt, budget: budget - fixed - Self.minimumAnswerTokens, measure: { TokenCounter.estimate($0) }
                    )
                    let room = budget - fixed - TokenCounter.estimate(prompt)
                    guard room >= Self.minimumAnswerTokens else { throw OnDeviceModelError.tooLong }
                    let answer = min(request.maxOutputTokens, room, isQuestion ? Self.maxQuestionTokens : .max)

                    let container = try await MLXModelStore.shared.container(for: spec.repository)
                    let session = ChatSession(
                        container,
                        instructions: instructions,
                        generateParameters: GenerateParameters(
                            maxTokens: answer, temperature: 0.5, topP: 0.9, repetitionPenalty: 1.1
                        )
                    )
                    var shown = ShownAnswer(source: isQuestion ? prompt : "")
                    var content = ""
                    for try await chunk in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        content += chunk
                        guard shown.observe(content, into: continuation) else { break }
                    }
                    shown.finish(content, into: continuation)
                    continuation.finish()
                } catch {
                    if error is CancellationError || error is MLXModelError || error is OnDeviceModelError {
                        continuation.finish(throwing: error)
                    } else {
                        DiagnosticsLog.shared.record(.error, .provider, "downloaded model: generation failed", error: error)
                        continuation.finish(throwing: OnDeviceModelError.other(String(String(describing: error).prefix(300))))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
