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

    /// Whether Settings should show the card. Permanent for the process: an
    /// OS below 26 or hardware that can't run the model never changes its
    /// mind, so this is computed once. Apple Intelligence being switched off
    /// is a status on the card, not a reason to hide it.
    static let isEligibleDevice: Bool = {
        if case .unsupported = readiness() { return false }
        return true
    }()

    private static let cacheLock = NSLock()
    private static var cached: (readiness: OnDeviceReadiness, at: Date)?

    /// The model's current state. `maxAge` lets hot callers (the provider
    /// manager's default-selection closure, read from view bodies) reuse a
    /// recent answer instead of asking the framework on every pass.
    static func readiness(maxAge: TimeInterval = 0) -> OnDeviceReadiness {
        if maxAge > 0 {
            cacheLock.lock()
            let hit = cached.flatMap { Date().timeIntervalSince($0.at) <= maxAge ? $0.readiness : nil }
            cacheLock.unlock()
            if let hit { return hit }
        }
        let fresh = currentReadiness()
        cacheLock.lock()
        cached = (fresh, Date())
        cacheLock.unlock()
        return fresh
    }

    private static func currentReadiness() -> OnDeviceReadiness {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            // The same handle the provider generates with, so "ready" here
            // and "ready" in validation can never disagree.
            return readiness(of: FoundationModelsProvider.sharedModel)
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
    /// The OS refused: Apple Intelligence off, model not ready, busy. The
    /// payload is the reader-facing reason.
    case unavailable(String)
    /// Anything else, with a bounded triage summary that is never shown.
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

    /// One handle for the process: the manager builds a provider on every
    /// `activeProvider()` call, including from view bodies. Book text is the
    /// reader's own content being summarised and questioned, which is the
    /// case Apple's relaxed guardrail profile exists for; fiction still trips
    /// the default profile on violence and intimacy far too often to read a
    /// novel with.
    static let sharedModel = SystemLanguageModel(
        useCase: .general, guardrails: .permissiveContentTransformations
    )
    private let model: SystemLanguageModel

    /// Apple's tokeniser runs a little denser than the kit's four-characters-
    /// per-token estimate on English prose; budget on the safe side.
    static let charactersPerToken = 3.4
    /// Headroom for the estimate's error, inside the window.
    static let windowMargin = 200
    /// Below this the answer would be cut off mid-thought; better to say the
    /// question was too long.
    static let minimumAnswerTokens = 150
    /// A question's answer: a paragraph or two. Articles are not capped here.
    static let maxQuestionTokens = 350

    /// Appended to the shared system prompt for questions. The shared prompt
    /// is written for models that can hold a book; this one needs the rules
    /// spelled out.
    static let questionStyle = """
        Answer style: reply in your own words in two to five sentences. Do not \
        copy the passages out — refer to what happens in them, and quote at \
        most a short phrase. Only state things the passages support; if they \
        don't answer the question, say the book doesn't say, then mention what \
        in the passages comes closest. Never repeat a sentence you have already \
        written.
        """

    /// Restated after the question, where a small model is actually looking.
    static let answerCue = "\nAnswer, in your own words, using only the passages (say if they don't tell):"

    // MARK: Routing off-topic questions

    /// The reader's question, as the context strategy laid it out.
    static func question(in prompt: String) -> String? {
        guard let range = prompt.range(of: AdaptiveContextStrategy.questionPrefix, options: .backwards) else {
            return nil
        }
        let question = prompt[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    /// The book's title line from the anchor — and only that. The anchor also
    /// carries the selected passage and its surroundings, and a small model
    /// answering a general question with book text in front of it went off
    /// reciting the text (a card-suit list, round and round) instead.
    static func anchor(in prompt: String) -> String {
        guard let header = prompt.range(of: AdaptiveContextStrategy.passagesHeader) else { return "" }
        return prompt[..<header.lowerBound]
            .split(separator: "\n")
            .first { $0.hasPrefix("Book: ") }
            .map(String.init) ?? ""
    }

    /// One short, passage-free call: is this about the book? Small models are
    /// good at this yes/no and bad at answering while eight passages compete
    /// for attention. Unsure or failing → treated as about the book, the
    /// path with citations.
    static func isAboutTheBook(_ question: String, model: SystemLanguageModel) async -> Bool? {
        // Examples, because a 3B model sorts by keyword: "can I be a rabbit?"
        // went BOOK on the strength of "rabbit" in Alice. The reader talking
        // about themself is the tell the examples teach.
        let session = LanguageModelSession(
            model: model,
            instructions: """
                You sort a reader's questions. Reply with exactly one word.
                BOOK: the question asks what the book says — its story, characters, events, places, themes, or wording.
                GENERAL: the question is about the reader themself (I, me, my, can I, should I), the real world, advice, or anything the book would not answer — even if it mentions something from the book.
                Examples:
                "Why does Alice follow the White Rabbit?" → BOOK
                "Who shouts off with their heads?" → BOOK
                "Can I be a rabbit?" → GENERAL
                "Can I shrink if I drink from a bottle?" → GENERAL
                "What should I read next?" → GENERAL
                "Is the Cheshire Cat real?" → GENERAL
                "What does the Cheshire Cat say about which way to go?" → BOOK
                """
        )
        do {
            let reply = try await session.respond(
                to: "The reader's question: \"\(question)\"\nOne word, BOOK or GENERAL:",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 3)
            ).content.uppercased()
            if reply.contains("GENERAL") { return false }
            if reply.contains("BOOK") { return true }
            return nil
        } catch {
            return nil
        }
    }

    static let generalInstructions = """
        You are a reading companion inside an ebook app. The reader asked \
        something that is not about the book. Answer it plainly and kindly in \
        your own words in one to three sentences — if it is impossible or \
        whimsical, say so with a light touch — then add one sentence about \
        what in the book they are reading comes closest to it. Never copy text \
        from the book. Never repeat a sentence.
        """

    static func generalPrompt(question: String, bookAnchor: String) -> String {
        (bookAnchor.isEmpty ? "" : bookAnchor + "\n\n") + "The reader asks: " + question + "\nAnswer:"
    }

    init(info: ProviderInfo) {
        self.info = info
        self.model = Self.sharedModel
    }

    func readiness() async -> OnDeviceReadiness {
        OnDeviceModel.readiness(of: model)
    }

    func countTokens(_ text: String) throws -> Int {
        TokenCounter.estimate(text)
    }

    static func tokens(_ text: String) -> Int {
        TokenCounter.estimate(text, charactersPerToken: charactersPerToken)
    }

    /// The window in tokens. `contextSize` arrived in the 26.4 SDK
    /// (back-deployed to 26.0, where it answers 4,096); CI builds with the
    /// 26.3 SDK, whose framework has no such member, so the read is a
    /// compile-time gate on the Swift 6.3 toolchain that ships with 26.4.
    static func contextWindow(of model: SystemLanguageModel) -> Int {
        #if compiler(>=6.3)
        return model.contextSize
        #else
        return 4_096
        #endif
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [model] in
                do {
                    var (instructions, rawPrompt) = Self.split(request)
                    var isQuestion = rawPrompt.contains(AdaptiveContextStrategy.passagesHeader)
                    if isQuestion, let question = Self.question(in: rawPrompt),
                       await Self.isAboutTheBook(question, model: model) == false {
                        // A small model handed eight passages answers from the
                        // passages whatever was asked — "can I be a rabbit?"
                        // came back "Yes, Alice can become a rabbit." Asked
                        // first whether the question is about the book at
                        // all, it can tell; if not, it answers plainly from
                        // common sense, with one line tying back to the book.
                        DiagnosticsLog.shared.record(
                            .info, .provider, "on-device: question judged not about the book; answering without passages"
                        )
                        instructions = Self.generalInstructions
                        rawPrompt = Self.generalPrompt(question: question, bookAnchor: Self.anchor(in: rawPrompt))
                        isQuestion = false
                    }
                    if isQuestion {
                        // A 3B model given eight passages will copy them out at
                        // length unless told plainly not to; a reader asked
                        // "can I be a rabbit?" and got two pages of dialogue.
                        instructions += "\n\n" + Self.questionStyle
                        // Small models answer what they read last: restate the
                        // task after the question, not only in the instructions.
                        rawPrompt += Self.answerCue
                    }
                    let window = Self.contextWindow(of: model)
                    let fixed = Self.tokens(instructions) + Self.windowMargin
                    // The strategy already budgeted passages to the catalog's
                    // figure; this drops whole passages if the denser estimate
                    // still overshoots. Prose is never cut.
                    let prompt = RetrievalPromptTrimmer.fit(
                        rawPrompt, budget: window - fixed - Self.minimumAnswerTokens, measure: Self.tokens
                    )
                    let room = window - fixed - Self.tokens(prompt)
                    guard room >= Self.minimumAnswerTokens else { throw OnDeviceModelError.tooLong }
                    // An article gets the whole remaining window; a question
                    // is answered in a few sentences, and a small model left
                    // to run on will fill the rest with the passages.
                    let answer = min(request.maxOutputTokens, room, isQuestion ? Self.maxQuestionTokens : .max)
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    // Nucleus sampling with some warmth: greedy-ish decoding is
                    // what sends a small model round the same sentence.
                    let options = GenerationOptions(
                        sampling: .random(probabilityThreshold: 0.9),
                        temperature: 0.5,
                        maximumResponseTokens: answer
                    )

                    // Snapshots are cumulative; the kit's chunks are deltas.
                    // Text is released a completed sentence at a time, held
                    // back just long enough for the repetition guard to judge
                    // it — so a loop ends before its first repeat is shown,
                    // and the reader never sees the same sentence six times.
                    // What the reader sees is the model's text minus sentences
                    // pasted from the passages (`isCopied`) — a whole copied
                    // sentence answers nothing — released a completed sentence
                    // at a time so both guards judge it first.
                    var shown = ShownAnswer(source: isQuestion ? prompt : "")
                    let repetition = RepetitionGuard()
                    var content = ""
                    streaming: for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        content = snapshot.content
                        switch repetition.verdict(for: content) {
                        case let .looping(keep):
                            shown.settle(RepetitionGuard.settledPrefix(of: keep), into: continuation)
                            DiagnosticsLog.shared.record(
                                .warning, .provider, "on-device answer cut short: the model began repeating itself"
                            )
                            content = ""
                            break streaming
                        case .fine:
                            shown.settle(RepetitionGuard.settledPrefix(of: content), into: continuation)
                        }
                    }
                    // The final fragment, if the stream ended cleanly.
                    shown.finish(content, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The answer as shown: the model's settled sentences, minus any lifted
    /// verbatim from `source`. Tracks how much of the model text has been
    /// judged (by count — O(new text) per step) and yields only new sentences.
    private struct ShownAnswer {
        let source: String
        private var judgedCount = 0

        init(source: String) { self.source = source }

        /// Judge the settled prefix of the model text past what was judged.
        mutating func settle(_ settled: String, into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) {
            let count = settled.count
            guard count > judgedCount else { return }
            let fresh = String(settled.suffix(count - judgedCount))
            judgedCount = count
            var kept = ""
            for sentence in RepetitionGuard.completedSentences(in: fresh) {
                if !source.isEmpty, RepetitionGuard.isCopied(String(sentence.text), from: source) {
                    DiagnosticsLog.shared.record(
                        .info, .provider, "on-device answer: dropped a sentence copied from the passages"
                    )
                    continue
                }
                kept += sentence.text
            }
            if !kept.isEmpty { continuation.yield(ChatChunk(textDelta: kept)) }
        }

        /// The trailing fragment at the end of a clean stream.
        mutating func finish(_ content: String, into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) {
            settle(RepetitionGuard.settledPrefix(of: content), into: continuation)
            let count = content.count
            guard count > judgedCount else { return }
            let tail = String(content.suffix(count - judgedCount))
            judgedCount = count
            if !source.isEmpty, RepetitionGuard.isCopied(tail, from: source) { return }
            continuation.yield(ChatChunk(textDelta: tail))
        }
    }

    // MARK: Errors

    static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        // The provider's own errors pass through untouched — `.tooLong`
        // carries the one message that tells the reader what to do.
        if let own = error as? OnDeviceModelError { return own }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return OnDeviceModelError.other(String(String(describing: error).prefix(300)))
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
            return OnDeviceModelError.other(String(String(describing: generation).prefix(300)))
        }
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
