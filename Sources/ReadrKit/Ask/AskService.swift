import Foundation

/// Events emitted while answering a question about a book.
public enum AskEvent: Sendable, Equatable {
    /// The router chose a context tier and the request is ready to send.
    case contextAssembled(tier: AssembledContext.Tier)
    /// The retrieved passages grounding the answer (retrieval tier only).
    case citations([Citation])
    /// A streamed text delta from the model.
    case token(String)
    /// Streaming finished; carries the full accumulated answer text.
    case completed(String)
}

/// Orchestrates the "ask the book" flow: assemble context, stream the answer.
public struct AskService: Sendable {
    private let strategy: ContextStrategy
    private let provider: LLMProvider

    public init(strategy: ContextStrategy, provider: LLMProvider) {
        self.strategy = strategy
        self.provider = provider
    }

    /// Answer `question` about `book`, optionally anchored to a `selection`.
    ///
    /// Emits `.contextAssembled` once routing is decided, then a `.token` for
    /// each streamed delta, then a final `.completed` with the full text.
    public func ask(
        _ question: String,
        about book: Book,
        selection: Selection?
    ) -> AsyncThrowingStream<AskEvent, Error> {
        let strategy = self.strategy
        let provider = self.provider
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let assembled = try await strategy.assembleContext(
                        for: question,
                        in: book,
                        selection: selection,
                        provider: provider.info
                    )
                    try Task.checkCancellation()
                    continuation.yield(.contextAssembled(tier: assembled.tier))
                    if !assembled.citations.isEmpty {
                        continuation.yield(.citations(assembled.citations))
                    }

                    var fullText = ""
                    for try await chunk in provider.stream(assembled.request) {
                        try Task.checkCancellation()
                        fullText += chunk.textDelta
                        continuation.yield(.token(chunk.textDelta))
                    }

                    try Task.checkCancellation()
                    continuation.yield(.completed(fullText))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
