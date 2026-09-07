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
            prompt = earlierTurnsHeader + earlier + earlierTurnsSeparator + (turns.last ?? "")
        } else {
            prompt = turns.last ?? ""
        }
        return (instructions.joined(separator: "\n\n"), prompt)
    }

    /// What the history is labelled with, and what divides it from the live
    /// question. Named because `plan` has to find that divide again.
    static let earlierTurnsHeader = "Earlier in this conversation:\n"
    static let earlierTurnsSeparator = "\n\n---\n\n"

    /// The live turn of a prompt `split` built: everything past the last
    /// divider, or the whole thing when there is no history.
    static func liveTurn(in prompt: String) -> String {
        guard let divide = prompt.range(of: earlierTurnsSeparator, options: .backwards) else {
            return prompt
        }
        return String(prompt[divide.upperBound...])
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

// MARK: - The whole recipe

public extension SmallModelPrompt {

    /// The numbers a small on-device model is budgeted with.
    ///
    /// Measured against Apple's FoundationModels, which runs a little denser
    /// than the kit's four-characters-per-token estimate on English prose,
    /// and used as the starting point for every other small runtime until one
    /// is measured on its own hardware.
    struct Budget: Sendable, Equatable {
        /// Characters per token, for estimating a prompt's cost.
        public var charactersPerToken: Double
        /// Headroom inside the window for the estimate's own error.
        public var windowMargin: Int
        /// Below this the answer is cut off mid-thought, and saying the
        /// question was too long is the honest outcome.
        public var minimumAnswerTokens: Int
        /// A question's answer is a paragraph or two. Left to run on, a small
        /// model fills the rest of the window with the passages.
        public var maxQuestionTokens: Int

        public init(
            charactersPerToken: Double = 3.4,
            windowMargin: Int = 200,
            minimumAnswerTokens: Int = 150,
            maxQuestionTokens: Int = 350
        ) {
            self.charactersPerToken = charactersPerToken
            self.windowMargin = windowMargin
            self.minimumAnswerTokens = minimumAnswerTokens
            self.maxQuestionTokens = maxQuestionTokens
        }

        /// The default, and the only one anything uses today.
        public static let onDevice = Budget()

        /// What this text costs, in this budget's tokens.
        public func tokens(_ text: String) -> Int {
            TokenCounter.estimate(text, charactersPerToken: charactersPerToken)
        }
    }

    /// Everything a small-model provider needs in order to make one call.
    struct Plan: Equatable, Sendable {
        /// The session's instructions.
        public var instructions: String
        /// The prompt, shortened to fit beside them.
        public var prompt: String
        /// The cap on the answer.
        public var answerTokens: Int
        /// True when the question turned out not to be about the book and
        /// this is the plain-answer path — no passages, no citations.
        public var isGeneral: Bool
        /// What a copied sentence would have been copied FROM, for
        /// `SnapshotAnswerStream`: the passages and the instructions, and
        /// nothing else. Empty when there are no passages to copy out.
        ///
        /// Deliberately not the whole prompt. The prompt also carries the
        /// conversation so far, and a sentence the model itself wrote a
        /// question ago is not a passage pasted out — dropping it would
        /// delete the answer to "say that again more simply".
        public var copiedSentenceSource: String

        public init(
            instructions: String,
            prompt: String,
            answerTokens: Int,
            isGeneral: Bool,
            copiedSentenceSource: String
        ) {
            self.instructions = instructions
            self.prompt = prompt
            self.answerTokens = answerTokens
            self.isGeneral = isGeneral
            self.copiedSentenceSource = copiedSentenceSource
        }
    }

    /// One short, passage-free call the plan makes on its way: the model is
    /// handed instructions and a prompt and answers in one word. The reply is
    /// returned raw; anything unreadable (including a failure, as an empty
    /// string) is read back as "unsure", which means "about the book".
    typealias Classifier = @Sendable (_ instructions: String, _ prompt: String) async -> String

    /// The whole recipe for asking a small on-device model a question, from a
    /// `ChatRequest` to the two strings and the token cap a runtime needs.
    ///
    /// Every step here exists because a ~3B model did something a reader
    /// complained about, and none of it depends on which runtime generates:
    /// Apple's FoundationModels, Android's Gemini Nano, a bundled MLX model.
    /// Each provider supplies the model calls — the classifier closure, and
    /// the generation itself — and nothing else.
    ///
    /// - Throws: `DoesNotFit` when even the shortest prompt leaves no room
    ///   for an answer.
    static func plan(
        request: ChatRequest,
        window: Int,
        budget: Budget = .onDevice,
        classify: Classifier
    ) async throws -> Plan {
        var (instructions, prompt) = split(request)
        // The tier is a property of THIS turn, read off the live question
        // alone. Read off the whole prompt it was the history's: one
        // retrieval turn made every later question in the conversation look
        // like a retrieval one, so a whole-book follow-up was answered under
        // the passage rules with no passages in front of it.
        var isQuestion = isRetrievalTier(liveTurn(in: prompt))
        var isGeneral = false

        if isQuestion, let question = question(in: liveTurn(in: prompt)) {
            // A small model handed eight passages answers from the passages
            // whatever was asked — "can I be a rabbit?" came back "Yes,
            // Alice can become a rabbit." Asked first whether the question
            // is about the book at all, it can tell; if not, it answers
            // plainly, with one line tying back to the book.
            let reply = await classify(classifierInstructions, classifierPrompt(question: question))
            if classification(from: reply) == false {
                let anchor = anchor(in: liveTurn(in: prompt))
                instructions = generalInstructions
                prompt = generalPrompt(question: question, bookAnchor: anchor)
                isQuestion = false
                isGeneral = true
            }
        }

        if isQuestion {
            // A 3B model given eight passages will copy them out at length
            // unless told plainly not to; a reader asked "can I be a rabbit?"
            // and got two pages of dialogue.
            instructions += "\n\n" + questionStyle
            // Small models answer what they read last: restate the task after
            // the question, not only in the instructions.
            prompt += answerCue
        }

        // The strategy already budgeted the passages to the catalog's figure;
        // this drops whole passages if a denser tokeniser still overshoots.
        // Prose is never cut.
        let fitted = try fit(
            rawPrompt: prompt,
            window: window,
            fixedTokens: budget.tokens(instructions) + budget.windowMargin,
            minimumAnswerTokens: budget.minimumAnswerTokens,
            measure: budget.tokens
        )
        // An article gets the whole remaining window; a question is answered
        // in a few sentences.
        let answerTokens = min(
            request.maxOutputTokens, fitted.answerTokens,
            isQuestion ? budget.maxQuestionTokens : .max
        )
        return Plan(
            instructions: instructions,
            prompt: fitted.prompt,
            answerTokens: answerTokens,
            isGeneral: isGeneral,
            copiedSentenceSource: isQuestion
                ? instructions + "\n\n" + liveTurn(in: fitted.prompt)
                : ""
        )
    }
}
