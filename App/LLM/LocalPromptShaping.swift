import Foundation
import ReadrKit

/// What the two in-app model runtimes share: turning a `ChatRequest` into
/// instructions plus one prompt, and releasing an answer to the reader a
/// judged sentence at a time.
enum LocalPromptShaping {

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

    /// Appended to the shared system prompt for questions. The shared prompt
    /// is written for models that can hold a book; a small one needs the
    /// rules spelled out.
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
    /// reciting the text instead.
    static func bookLine(in prompt: String) -> String {
        guard let header = prompt.range(of: AdaptiveContextStrategy.passagesHeader) else { return "" }
        return prompt[..<header.lowerBound]
            .split(separator: "\n")
            .first { $0.hasPrefix("Book: ") }
            .map(String.init) ?? ""
    }

    static let generalInstructions = """
        You are a reading companion inside an ebook app. The reader asked \
        something that is not about the book. Answer it plainly and kindly in \
        your own words in one to three sentences — if it is impossible or \
        whimsical, say so with a light touch — then add one sentence about \
        what in the book they are reading comes closest to it. Never copy text \
        from the book. Never repeat a sentence.
        """

    static func generalPrompt(question: String, bookLine: String) -> String {
        (bookLine.isEmpty ? "" : bookLine + "\n\n") + "The reader asks: " + question + "\nAnswer:"
    }
}

/// The answer as shown: the model's settled sentences, minus any lifted
/// verbatim from `source`, minus anything past the point a loop began.
/// Tracks how much of the model text has been judged (by count — O(new text)
/// per step) and yields only new sentences.
struct ShownAnswer {
    let source: String
    private var judgedCount = 0
    private let repetition = RepetitionGuard()
    /// True once the guard cut the answer; nothing more is shown.
    private(set) var stopped = false

    init(source: String) { self.source = source }

    /// Judge the cumulative model text; yield what is newly safe to show.
    /// Returns false once the answer has been cut short.
    @discardableResult
    mutating func observe(
        _ content: String, into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation
    ) -> Bool {
        guard !stopped else { return false }
        switch repetition.verdict(for: content) {
        case let .looping(keep):
            settle(RepetitionGuard.settledPrefix(of: keep), into: continuation)
            DiagnosticsLog.shared.record(
                .warning, .provider, "local model answer cut short: the model began repeating itself"
            )
            stopped = true
            return false
        case .fine:
            settle(RepetitionGuard.settledPrefix(of: content), into: continuation)
            return true
        }
    }

    /// The trailing fragment at the end of a clean stream.
    mutating func finish(_ content: String, into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) {
        guard !stopped else { return }
        settle(RepetitionGuard.settledPrefix(of: content), into: continuation)
        let count = content.count
        guard count > judgedCount else { return }
        let tail = String(content.suffix(count - judgedCount))
        judgedCount = count
        if !source.isEmpty, RepetitionGuard.isCopied(tail, from: source) { return }
        continuation.yield(ChatChunk(textDelta: tail))
    }

    private mutating func settle(_ settled: String, into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation) {
        let count = settled.count
        guard count > judgedCount else { return }
        let fresh = String(settled.suffix(count - judgedCount))
        judgedCount = count
        var kept = ""
        for sentence in RepetitionGuard.completedSentences(in: fresh) {
            if !source.isEmpty, RepetitionGuard.isCopied(String(sentence.text), from: source) {
                DiagnosticsLog.shared.record(
                    .info, .provider, "local model answer: dropped a sentence copied from the passages"
                )
                continue
            }
            kept += sentence.text
        }
        if !kept.isEmpty { continuation.yield(ChatChunk(textDelta: kept)) }
    }
}
