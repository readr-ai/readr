import Foundation

/// How a ~3B on-device model is asked a question about a book.
///
/// A small model needs the task spelled out, restated where it is looking,
/// and kept inside a window measured in low thousands of tokens. None of that
/// depends on which runtime is doing the generating — Apple's
/// FoundationModels, Android's Gemini Nano, a bundled MLX model — so the
/// rules live here and each platform's provider supplies only the model call.
///
/// Every string below is load-bearing: each one exists because a small model
/// did something a reader complained about. `SmallModelPromptTests` pins them
/// so a change is a deliberate one.
public enum SmallModelPrompt {

    /// The window has no room left for an answer, even with every passage
    /// dropped. Providers map this to their own reader-facing "too long".
    public struct DoesNotFit: Error, Equatable {
        public init() {}
    }

    // MARK: - Shaping the request

    /// System content becomes the session's instructions; the conversation
    /// becomes one prompt, earlier turns labelled so the model can tell them
    /// from the question it has to answer now.
    public static func split(_ request: ChatRequest) -> (instructions: String, prompt: String) {
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

    /// Whether this prompt is the retrieval tier's — a block of passages the
    /// answer has to stay inside — rather than a whole-book or article one.
    public static func isRetrievalTier(_ prompt: String) -> Bool {
        prompt.contains(AdaptiveContextStrategy.passagesHeader)
    }

    /// Appended to the shared system prompt for questions. The shared prompt
    /// is written for models that can hold a book; this one needs the rules
    /// spelled out.
    public static let questionStyle = """
        Answer style: reply in your own words in two to five sentences. Do not \
        copy the passages out — refer to what happens in them, and quote at \
        most a short phrase. Only state things the passages support; if they \
        don't answer the question, say the book doesn't say, then mention what \
        in the passages comes closest. Never repeat a sentence you have already \
        written.
        """

    /// Restated after the question, where a small model is actually looking.
    public static let answerCue =
        "\nAnswer, in your own words, using only the passages (say if they don't tell):"

    // MARK: - Reading the prompt back

    /// The reader's question, as the context strategy laid it out.
    public static func question(in prompt: String) -> String? {
        guard let range = prompt.range(
            of: AdaptiveContextStrategy.questionPrefix, options: .backwards
        ) else { return nil }
        let question = prompt[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    /// The book's title line from the anchor — and only that. The anchor also
    /// carries the selected passage and its surroundings, and a small model
    /// answering a general question with book text in front of it went off
    /// reciting the text (a card-suit list, round and round) instead.
    public static func anchor(in prompt: String) -> String {
        guard let header = prompt.range(of: AdaptiveContextStrategy.passagesHeader) else { return "" }
        return prompt[..<header.lowerBound]
            .split(separator: "\n")
            .first { $0.hasPrefix("Book: ") }
            .map(String.init) ?? ""
    }

    // MARK: - Routing off-topic questions

    /// Instructions for one short, passage-free call: is this about the book?
    /// Small models are good at this yes/no and bad at answering while eight
    /// passages compete for attention.
    ///
    /// Examples, because a 3B model sorts by keyword: "can I be a rabbit?"
    /// went BOOK on the strength of "rabbit" in Alice. The reader talking
    /// about themself is the tell the examples teach.
    public static let classifierInstructions = """
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

    /// The one-line prompt that goes with those instructions.
    public static func classifierPrompt(question: String) -> String {
        "The reader's question: \"\(question)\"\nOne word, BOOK or GENERAL:"
    }

    /// The classifier's reply, read back. Nil when the model said neither —
    /// unsure is treated by callers as about the book, the path with
    /// citations.
    public static func classification(from reply: String) -> Bool? {
        let upper = reply.uppercased()
        if upper.contains("GENERAL") { return false }
        if upper.contains("BOOK") { return true }
        return nil
    }

    public static let generalInstructions = """
        You are a reading companion inside an ebook app. The reader asked \
        something that is not about the book. Answer it plainly and kindly in \
        your own words in one to three sentences — if it is impossible or \
        whimsical, say so with a light touch — then add one sentence about \
        what in the book they are reading comes closest to it. Never copy text \
        from the book. Never repeat a sentence.
        """

    public static func generalPrompt(question: String, bookAnchor: String) -> String {
        (bookAnchor.isEmpty ? "" : bookAnchor + "\n\n") + "The reader asks: " + question + "\nAnswer:"
    }

    // MARK: - Fitting the window

    /// A prompt shortened to fit, and what is left of the window for the
    /// answer.
    public struct Fitted: Equatable, Sendable {
        public var prompt: String
        /// Tokens still free once the instructions and this prompt are in.
        public var answerTokens: Int

        public init(prompt: String, answerTokens: Int) {
            self.prompt = prompt
            self.answerTokens = answerTokens
        }
    }

    /// Shorten `rawPrompt` until an answer fits alongside it.
    ///
    /// `AdaptiveContextStrategy` has already budgeted the passages to the
    /// catalog's figure; this is the backstop for a tokeniser denser than
    /// that estimate. Whole passages go, newest-ranked first
    /// (`RetrievalPromptTrimmer`) — prose is never cut mid-sentence.
    ///
    /// - Parameter fixedTokens: everything else already committed to the
    ///   window: the instructions, plus whatever margin the platform keeps
    ///   for its own tokeniser's error.
    /// - Throws: `DoesNotFit` when even the shortest prompt leaves less than
    ///   `minimumAnswerTokens` — below that the answer is cut off
    ///   mid-thought, and saying the question was too long is the honest
    ///   outcome.
    public static func fit(
        rawPrompt: String,
        window: Int,
        fixedTokens: Int,
        minimumAnswerTokens: Int,
        measure: (String) -> Int
    ) throws -> Fitted {
        let prompt = RetrievalPromptTrimmer.fit(
            rawPrompt, budget: window - fixedTokens - minimumAnswerTokens, measure: measure
        )
        let room = window - fixedTokens - measure(prompt)
        guard room >= minimumAnswerTokens else { throw DoesNotFit() }
        return Fitted(prompt: prompt, answerTokens: room)
    }
}
