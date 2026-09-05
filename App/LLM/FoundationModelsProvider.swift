import Foundation
import ReadrKit

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

/// The system's on-device language model — Apple's FoundationModels framework
/// (iOS/macOS 26+, on Apple Intelligence hardware). No key, no account, no
/// download, no network: the answer to readers who can't get an API key.
///
/// Its window is 4,096 tokens *including* the answer, so `ProviderCatalog`
/// gives it a small retrieval-tier budget and the provider trims what's left
/// to fit. It runs the request off the main thread; readiness is read on the
/// spot, since the OS can turn it off (Apple Intelligence disabled) or have it
/// mid-download (`modelNotReady`) at any time.
enum OnDeviceModel {

    /// Whether this OS build can offer the model at all. Device eligibility
    /// is a runtime question — `readiness()` — but an OS below 26 can never
    /// show the card.
    static var isOfferedOnThisOS: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) { return true }
        #endif
        return false
    }

    /// Whether Settings should show the card: the OS offers it and this
    /// device can run it (Apple Intelligence may still be switched off — that
    /// is a status on the card, not a reason to hide it).
    static var isEligibleDevice: Bool {
        if case .unsupported = readiness() { return false }
        return true
    }

    static func readiness() -> OnDeviceReadiness {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return readiness(of: SystemLanguageModel.default)
        }
        #endif
        return .unsupported(
            reason: "The on-device model needs iOS 26 or macOS 26 with Apple Intelligence."
        )
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    static func readiness(of model: SystemLanguageModel) -> OnDeviceReadiness {
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unsupported(
                    reason: "This device can't run Apple's on-device model. Connect another provider to ask questions."
                )
            case .appleIntelligenceNotEnabled:
                return .unavailable(
                    reason: "Turn on Apple Intelligence in Settings to use the on-device model."
                )
            case .modelNotReady:
                return .unavailable(
                    reason: "The on-device model is still downloading. Try again in a few minutes."
                )
            @unknown default:
                return .unavailable(reason: "The on-device model isn't available right now.")
            }
        }
    }
    #endif
}

// MARK: - Errors

/// What went wrong with an on-device request, in the reader's words.
enum OnDeviceModelError: LocalizedError, DiagnosticallyDescribable {
    /// The model's guardrails declined the passage or the answer.
    case declined
    /// Even after trimming, the passages didn't fit the 4,096-token window.
    case tooLong
    /// The OS refused: Apple Intelligence off, model not ready, busy.
    case unavailable(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .declined:
            return "The on-device model declined to answer about this passage."
        case .tooLong:
            return "This question needed more of the book than the on-device model can hold at once."
        case .unavailable:
            return "The on-device model isn't available right now."
        case .other:
            return "The on-device model couldn't answer."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .declined:
            return "Apple's model refuses some content it considers sensitive. Try rephrasing, or connect another provider in Settings → AI Providers."
        case .tooLong:
            return "Try a more specific question, or connect a cloud provider for whole-book questions."
        case .unavailable(let reason):
            return reason
        case .other:
            return "Try again, or connect another provider in Settings → AI Providers."
        }
    }

    var diagnosticSummary: String {
        switch self {
        case .declined: return "OnDeviceModelError.declined"
        case .tooLong: return "OnDeviceModelError.tooLong"
        case .unavailable(let reason): return "OnDeviceModelError.unavailable: \(reason)"
        case .other(let detail): return "OnDeviceModelError.other: \(detail.prefix(300))"
        }
    }
}

// MARK: - Provider

#if canImport(FoundationModels)

/// `LLMProvider` over `LanguageModelSession`. One session per request — the
/// conversation history rides in the prompt, so nothing is kept between
/// questions and a refused turn can't poison the next one.
@available(iOS 26, macOS 26, *)
final class FoundationModelsProvider: LLMProvider, OnDeviceReadinessReporting, @unchecked Sendable {

    let info: ProviderInfo

    /// Book text is the reader's own content being summarised and questioned,
    /// which is the case Apple's relaxed guardrail profile exists for; fiction
    /// still trips the default profile on violence and intimacy far too often
    /// to read a novel with.
    private let model = SystemLanguageModel(
        useCase: .general, guardrails: .permissiveContentTransformations
    )

    /// Room kept for the answer inside the window. The context strategy asks
    /// for 1,024; the window can't afford that alongside the passages.
    static let maxAnswerTokens = 600

    /// Apple's tokeniser runs a little denser than the kit's four-characters-
    /// per-token estimate on English prose; budget on the safe side.
    private static let charactersPerToken = 3.4

    init(info: ProviderInfo) {
        self.info = info
    }

    func readiness() async -> OnDeviceReadiness {
        OnDeviceModel.readiness(of: model)
    }

    func countTokens(_ text: String) throws -> Int {
        TokenCounter.estimate(text)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [model] in
                do {
                    var (instructions, prompt) = Self.split(request)
                    let window = Self.contextWindow(of: model)
                    let answer = min(request.maxOutputTokens, Self.maxAnswerTokens)
                    prompt = Self.fit(prompt, instructions: instructions, window: window, answer: answer)
                    let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: answer)

                    var attempt = 0
                    while true {
                        do {
                            try await Self.run(
                                model: model, instructions: instructions, prompt: prompt,
                                options: options, into: continuation
                            )
                            continuation.finish()
                            return
                        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_)
                            where attempt < 2 {
                            // The estimate undershot: drop passages and retry,
                            // rather than fail a question that would fit with
                            // one fewer.
                            attempt += 1
                            guard let shorter = Self.droppingLastPassage(from: prompt) else {
                                throw OnDeviceModelError.tooLong
                            }
                            prompt = shorter
                        }
                    }
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Running

    private static func run(
        model: SystemLanguageModel,
        instructions: String,
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(model: model, instructions: instructions)
        var delivered = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            try Task.checkCancellation()
            // Snapshots are cumulative; the kit's chunks are deltas.
            let content = snapshot.content
            let delta: String
            if content.hasPrefix(delivered) {
                delta = String(content.dropFirst(delivered.count))
            } else {
                // The model revised earlier text (rare): send the tail past
                // what was shown rather than duplicate the whole answer.
                delta = String(content.dropFirst(min(delivered.count, content.count)))
            }
            if !delta.isEmpty {
                continuation.yield(ChatChunk(textDelta: delta))
            }
            delivered = content
        }
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return OnDeviceModelError.other(String(reflecting: error))
        }
        switch generation {
        case .guardrailViolation, .refusal:
            return OnDeviceModelError.declined
        case .exceededContextWindowSize:
            return OnDeviceModelError.tooLong
        case .assetsUnavailable:
            return OnDeviceModelError.unavailable(
                "The on-device model is still downloading. Try again in a few minutes."
            )
        case .rateLimited, .concurrentRequests:
            return OnDeviceModelError.unavailable("The on-device model is busy. Try again in a moment.")
        case .unsupportedLanguageOrLocale:
            return OnDeviceModelError.unavailable(
                "The on-device model doesn't support this book's language yet. Connect another provider for it."
            )
        default:
            return OnDeviceModelError.other(String(reflecting: generation))
        }
    }

    // MARK: Fitting the window

    /// The window in tokens, from the OS where it can say (26.4+), else the
    /// documented 4,096.
    private static func contextWindow(of model: SystemLanguageModel) -> Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return model.contextSize
        }
        return 4_096
    }

    private static func estimateTokens(_ text: String) -> Int {
        Int(Double(text.count) / charactersPerToken) + 1
    }

    /// Drop retrieved passages from the end until instructions + prompt +
    /// answer sit inside the window with a margin for the tokeniser's
    /// disagreement with the estimate.
    static func fit(_ prompt: String, instructions: String, window: Int, answer: Int) -> String {
        let margin = 200
        var fitted = prompt
        while estimateTokens(instructions) + estimateTokens(fitted) + answer + margin > window,
              let shorter = droppingLastPassage(from: fitted) {
            fitted = shorter
        }
        return fitted
    }

    static let passagesHeader = "Relevant passages from elsewhere in the book:\n"

    /// The prompt with its last retrieved passage removed, or nil when there
    /// is nothing left to drop. Passages are separated by blank lines between
    /// the header the context strategy writes and its "Question:" line.
    static func droppingLastPassage(from prompt: String) -> String? {
        guard let header = prompt.range(of: passagesHeader),
              let question = prompt.range(of: "\n\nQuestion: ", range: header.upperBound..<prompt.endIndex)
        else { return nil }
        let block = String(prompt[header.upperBound..<question.lowerBound])
        var passages = block.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        guard !passages.isEmpty else { return nil }
        passages.removeLast()
        let kept = passages.isEmpty ? "(passages omitted to fit the on-device model)" : passages.joined(separator: "\n\n")
        return String(prompt[..<header.upperBound]) + kept + String(prompt[question.lowerBound...])
    }

    // MARK: Shaping the request

    /// System content becomes the session's instructions; the conversation
    /// becomes one prompt, earlier turns labelled so the model can tell them
    /// from the question it has to answer now.
    static func split(_ request: ChatRequest) -> (instructions: String, prompt: String) {
        var instructions: [String] = []
        if let prefix = request.cacheableSystemPrefix, !prefix.isEmpty {
            instructions.append(prefix)
        }
        var turns: [String] = []
        for message in request.messages {
            switch message.role {
            case .system:
                instructions.append(message.content)
            case .user:
                turns.append(message.content)
            case .assistant:
                turns.append("(Your earlier answer:) " + message.content)
            }
        }
        // The last user message is the live question; earlier turns are context.
        let prompt: String
        if turns.count > 1 {
            let earlier = turns.dropLast().joined(separator: "\n\n")
            prompt = "Earlier in this conversation:\n" + earlier + "\n\n---\n\n" + (turns.last ?? "")
        } else {
            prompt = turns.last ?? ""
        }
        return (instructions.joined(separator: "\n\n"), prompt)
    }
}

#endif
