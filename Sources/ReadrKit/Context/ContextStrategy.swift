import Foundation

/// The text the reader has selected and is asking about.
public struct Selection: Sendable, Hashable {
    public var chapterID: UUID
    public var quotedText: String
    /// Surrounding paragraphs for the "where you are" anchor.
    public var surroundingText: String
    public var chapterTitle: String?

    public init(
        chapterID: UUID,
        quotedText: String,
        surroundingText: String,
        chapterTitle: String? = nil
    ) {
        self.chapterID = chapterID
        self.quotedText = quotedText
        self.surroundingText = surroundingText
        self.chapterTitle = chapterTitle
    }
}

/// A ready-to-send payload: which routing tier was chosen and the messages.
public struct AssembledContext: Sendable {
    public enum Tier: String, Sendable {
        case wholeBook, retrieval

        /// Whether answers assembled with this tier surface per-passage
        /// citations to the reader. Only the retrieval tier grounds its answer
        /// in a bounded set of passages worth citing; the whole-book tier
        /// grounds the answer in the entire book and returns no per-passage
        /// sources. The UI switches its copy on this so it never promises
        /// citations the whole-book tier can't deliver.
        public var providesCitations: Bool {
            switch self {
            case .retrieval: return true
            case .wholeBook: return false
            }
        }
    }

    public var tier: Tier
    public var request: ChatRequest
    /// Passages surfaced to the reader as sources. Empty for the whole-book tier.
    public var citations: [Citation]

    /// Honest, tier-derived signal for the UI: `true` when this answer will be
    /// backed by citable passages (retrieval tier), `false` when it is grounded
    /// in the whole book with no per-passage sources (whole-book tier). Lets the
    /// Ask panel avoid promising a SOURCES section that never appears.
    public var providesCitations: Bool { tier.providesCitations }

    public init(tier: Tier, request: ChatRequest, citations: [Citation] = []) {
        self.tier = tier
        self.request = request
        self.citations = citations
    }
}

/// Assembles the optimal prompt context for a question about a book.
/// See docs/CONTEXT-STRATEGY.md for the rationale.
public protocol ContextStrategy: Sendable {
    /// - Parameter history: earlier turns of the same conversation, oldest
    ///   first. Without it a follow-up ("but roads are technically 3D") reads
    ///   as a brand-new question with no idea what it is objecting to.
    /// - Parameter scope: what the answer may draw on — the whole book, or
    ///   only what the reader has read. Named at every call site; see
    ///   `ReadingScope`.
    func assembleContext(
        for question: String,
        in book: Book,
        selection: Selection?,
        history: [ConversationTurn],
        scope: ReadingScope,
        provider: ProviderInfo
    ) async throws -> AssembledContext
}

public extension ContextStrategy {
    /// Single-shot convenience: a question with no conversation behind it.
    /// The scope is still the caller's to name.
    func assembleContext(
        for question: String,
        in book: Book,
        selection: Selection?,
        scope: ReadingScope,
        provider: ProviderInfo
    ) async throws -> AssembledContext {
        try await assembleContext(
            for: question, in: book, selection: selection, history: [],
            scope: scope, provider: provider
        )
    }
}

/// Default adaptive router:
/// - Tier 1 (whole book) when the book fits the provider budget.
/// - Tier 2 (retrieval) otherwise, or for local/small-context models.
/// Both tiers always inject the selection + chapter + TOC anchor.
public struct AdaptiveContextStrategy: ContextStrategy {
    private let index: RAGIndex
    private let lengths: ReadingLengthCache
    /// Fraction of the context budget we allow the book to occupy before
    /// switching to retrieval (leaves room for history + answer).
    private let wholeBookBudgetFraction: Double

    /// - Parameter lengths: per-book chapter lengths, shared with whatever
    ///   else measures books (the app hands in its one cache) so a scoped
    ///   question's token estimate never re-walks the text.
    public init(
        index: RAGIndex,
        lengths: ReadingLengthCache = ReadingLengthCache(),
        wholeBookBudgetFraction: Double = 0.6
    ) {
        self.index = index
        self.lengths = lengths
        self.wholeBookBudgetFraction = wholeBookBudgetFraction
    }

    public func assembleContext(
        for question: String,
        in book: Book,
        selection: Selection?,
        history: [ConversationTurn],
        scope: ReadingScope,
        provider: ProviderInfo
    ) async throws -> AssembledContext {
        let frontier = scope.frontier
        let table = frontier == nil ? nil : lengths.table(for: book)
        // The same "Chapter 7 of 24 · The Whale" the panel shows, so the
        // model and the reader are told the same place.
        let position = frontier.flatMap { frontier -> ReadingPositionSummary? in
            guard let table else { return nil }
            return ReadingPositionSummary(book: book, frontier: frontier, lengths: table)
        }
        let anchor = Self.anchor(for: book, selection: selection, position: position, scoped: scope.isScoped)
        // System prompt, then the conversation so far, then the new question:
        // the model reads the earlier turns as what was already said and the
        // last message as what it has to answer. With a frontier, the prompt
        // also carries the no-spoiler rule.
        var systemContent = scope.isScoped
            ? Self.systemPrompt + "\n\n" + Self.spoilerGuard
            : Self.systemPrompt
        let priorTurns = Self.historyMessages(from: history)
        let budget = Int(Double(provider.contextBudget) * wholeBookBudgetFraction)

        // How much would ride along on the whole-book tier — and therefore
        // what the budget has to fit. Counted, not built: a long book the
        // reader has only started is a short text, and the text itself is
        // only assembled once that tier is chosen.
        let charactersRead = frontier.map { frontier in table?.charactersRead(upTo: frontier) ?? 0 }
        if let charactersRead, charactersRead == 0 {
            // Frontier at the very start: nothing has been read, so nothing
            // is sent — not an empty cacheable prefix, which some providers
            // reject and all of them would answer from thin air. The system
            // prompt says so, and a recap answer should too.
            systemContent += "\n\n" + Self.notStartedNote
            let systemMessage = ChatMessage(role: .system, content: systemContent)
            let ask = ChatMessage(role: .user, content: anchor + "\n\nQuestion: " + question)
            let request = ChatRequest(
                messages: [systemMessage] + priorTurns + [ask],
                maxOutputTokens: 1024
            )
            return AssembledContext(tier: .wholeBook, request: request)
        }
        let systemMessage = ChatMessage(role: .system, content: systemContent)
        let bookTokens = charactersRead.map(estimateTokens(characterCount:)) ?? book.estimatedTokenCount
        let fitsWholeBook = !provider.isLocal && bookTokens <= budget

        if fitsWholeBook {
            // Tier 1: the text read so far always rides along; question
            // carries the anchor. Providers that support prompt caching cache
            // the prefix, the rest send it as a plain system message — either
            // way the answer must be grounded in the book.
            let bookText = frontier.map { book.textRead(upTo: $0) } ?? book.fullText
            let ask = ChatMessage(
                role: .user, content: anchor + "\n\nQuestion: " + question
            )
            let request = ChatRequest(
                messages: [systemMessage] + priorTurns + [ask],
                cacheableSystemPrefix: bookText,
                maxOutputTokens: 1024
            )
            return AssembledContext(tier: .wholeBook, request: request)
        }

        // Tier 2: hybrid retrieval over the rest of the book. With a frontier,
        // the index is asked for passages at or before the last chapter the
        // reader has finished — the ceiling is the index's to apply, before
        // its limit, so a scoped question still gets a full set (see
        // `RAGIndex.retrieve`). What a scope-aware index returns is trusted
        // as is: a second filter here would only throw away passages the
        // index has already vouched for, including any it returns without a
        // chapter number.
        let maxChapterIndex: Int? = frontier.map { frontier in
            book.hasFinishedChapter(at: frontier) ? frontier.chapterIndex : frontier.chapterIndex - 1
        }
        var passages = try await index.retrieve(
            query: question,
            bookID: book.id,
            limit: 8,
            maxChapterIndex: maxChapterIndex
        )
        if passages.isEmpty, let frontier {
            // The reader has read something (the empty case returned above),
            // but none of it survived the chapter filter — they are partway
            // through the first chapter, say. The end of what they've read is
            // the best available grounding, so the passage block is never
            // empty: the last budget's worth of it, as one passage.
            let tail = book.textRead(upTo: frontier, lastCharacters: budget * 4)
            if !tail.isEmpty {
                passages = [
                    RetrievedPassage(
                        text: tail, locator: Self.readSoFarLocator, score: 0,
                        chapterIndex: frontier.chapterIndex
                    ),
                ]
            }
        }
        // As many passages as the provider's budget holds, best first — a
        // small-window model (the on-device one: 4,096 tokens *including* the
        // answer) gets fewer, and the citations shown to the reader are
        // exactly the passages the model was sent. Decided here, where the
        // passages are still a list, so no provider has to parse the prompt
        // to shorten it. The best match always rides along.
        let fixedCost = TokenCounter.estimate(
            [systemContent, anchor, Self.passagesHeader, Self.questionPrefix, question].joined()
                + priorTurns.map(\.content).joined()
        )
        var remaining = provider.contextBudget - fixedCost
        var kept: [RetrievedPassage] = []
        for passage in passages {
            let cost = TokenCounter.estimate(Self.passageLine(passage)) + 1
            if kept.isEmpty || cost <= remaining {
                kept.append(passage)
                remaining -= cost
            } else {
                break
            }
        }
        let retrieved = kept.map(Self.passageLine).joined(separator: Self.passageSeparator)
        let citations = kept.map { passage in
            Citation(
                locator: passage.locator,
                quotedText: Self.snippet(from: passage.text)
            )
        }
        let ask = ChatMessage(
            role: .user,
            content: anchor + Self.passagesHeader + retrieved + Self.questionPrefix + question
        )
        let request = ChatRequest(
            messages: [systemMessage] + priorTurns + [ask],
            maxOutputTokens: 1024
        )
        return AssembledContext(tier: .retrieval, request: request, citations: citations)
    }

    /// The retrieval prompt's fixed parts, public so a provider that must fit
    /// a hard window can recognise the passage block without a private copy
    /// of these strings (see `RetrievalPromptTrimmer`).
    public static let passagesHeader = "\n\nRelevant passages from elsewhere in the book:\n"
    public static let passageSeparator = "\n\n"
    public static let questionPrefix = "\n\nQuestion: "

    /// One passage as it appears in the prompt: `[locator] text`. The
    /// bracketed locator is what marks a passage boundary for a trimmer,
    /// since passage text itself may contain blank lines.
    static func passageLine(_ passage: RetrievedPassage) -> String {
        "[\(passage.locator)] \(passage.text)"
    }

    /// Locator of the fallback passage: the end of what the reader has read,
    /// when no indexed passage sits before the frontier.
    static let readSoFarLocator = "Read so far"

    /// How many earlier turns ride along. Enough for a real back-and-forth,
    /// bounded so a long session can't crowd out the book itself — the book
    /// is the point, the chat is not.
    static let maxHistoryTurns = 6
    /// Earlier answers are replayed abridged: they are context for what was
    /// already said, not evidence, and a full one can run to a thousand
    /// tokens.
    static let maxHistoryAnswerCharacters = 700

    /// Answered turns, oldest first, as alternating user/assistant messages.
    /// Unanswered turns (in flight, or failed) are skipped — replaying a
    /// question with no answer would invite the model to answer it twice.
    static func historyMessages(from history: [ConversationTurn]) -> [ChatMessage] {
        history
            .filter { $0.answer != nil }
            .suffix(maxHistoryTurns)
            .flatMap { turn -> [ChatMessage] in
                guard let answer = turn.answer else { return [] }
                let abridged = snippet(
                    from: answer.text, maxLength: maxHistoryAnswerCharacters
                )
                return [
                    ChatMessage(role: .user, content: turn.question),
                    ChatMessage(role: .assistant, content: abridged),
                ]
            }
    }

    /// The reader is mid-book and asking about it, so the book always rides
    /// along as context — but plenty of real questions reach past it ("how has
    /// the science moved on since this was written?", "who directed the film
    /// adaptation?"). An earlier version of this prompt said to answer "using
    /// the provided book context" and to flag when an answer wasn't in the
    /// book, which the model read as licence to decline (#54).
    ///
    /// The guarantee that survives is narrower than "stay in the book": never
    /// invent *what the book says*. Answering freely and attributing carefully
    /// are separate rules, and only the second one is absolute — so the wording
    /// below keeps them apart deliberately. Pinned by `AskScopeTests`.
    static let systemPrompt = """
    You are a reading companion inside an ebook reader. The reader is partway \
    through the book below, and it is the context for everything they ask.

    The book is your context, not your limit. When a question reaches past the \
    book — later research, an adaptation, an author's life, how an idea aged, \
    how it connects to something the book never mentions — answer it from what \
    you know, rather than declining or steering back to the text.

    Be accurate about the book itself: never invent what the book says, and \
    never attribute a claim to it that isn't in the context you were given. \
    Where the book is silent, say so in a few words and answer anyway.

    When an answer draws on both, make clear which is which — a short inline \
    signal ("the book argues…", "since it was published…") is enough. Don't \
    label every sentence, and never open with a disclaimer paragraph.

    Be brief. Two or three short paragraphs at most, and often one is enough. \
    Lead with the answer: no preamble, no restating the question, no summary \
    of what you are about to say, no closing recap.

    Quote the book only where the exact wording carries the point — at most \
    one short quotation, as a Markdown blockquote.

    Write in Markdown, sparingly: bold at most one genuinely key phrase (never \
    a whole sentence), bullets only for a real list, no headings.

    When earlier turns of the conversation are included, answer the new \
    question without repeating what you already said.
    """

    /// Appended to the system prompt whenever the scope is `.upTo` a
    /// frontier. The text past the frontier is already withheld; this covers
    /// the other source of spoilers — what the model knows about the book
    /// from elsewhere — and defines what a recap means. Pinned by
    /// `ReadingFrontierTests`.
    static let spoilerGuard = """
    The reader has only read up to the point marked in the anchor, and the \
    book text you were given stops there too. Do not reveal, hint at, or \
    allude to anything that happens after that point — from the text or \
    from what you know about this book — even if asked directly. If a \
    question can only be answered by going past it, say in one short \
    sentence that you're keeping it spoiler-free, then answer what you can \
    from what they've read.

    A request for a recap or summary means what has happened so far, \
    nothing more. Tell it in reading order, and stop where the reader \
    stopped.
    """

    /// Appended, in place of any book text, when the frontier is at the very
    /// start of the book. Pinned by `ReadingFrontierTests`.
    static let notStartedNote = """
    The reader has not started the book yet, so no book text is included. \
    If asked for a recap or summary, say there is nothing to recap yet.
    """

    /// A short, trimmed preview of a retrieved passage for display as a citation.
    static func snippet(from text: String, maxLength: Int = 160) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        var clipped = String(trimmed[..<cutoff])
        // Prefer to end on a word boundary rather than mid-word.
        if let lastSpace = clipped.lastIndex(where: { $0.isWhitespace }) {
            clipped = String(clipped[..<lastSpace])
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The always-injected "where you are" anchor (Tier 3). With a scope,
    /// the "read so far" line is the panel's own `ReadingPositionSummary`.
    static func anchor(
        for book: Book,
        selection: Selection?,
        position: ReadingPositionSummary?,
        scoped: Bool
    ) -> String {
        var parts: [String] = []
        parts.append("Book: \"\(book.metadata.title)\" by \(book.metadata.authors.joined(separator: ", "))")
        if let position {
            parts.append(
                "Read so far: through \"\(position.chapterTitle)\" (\(position.chapterLine), \(position.percent)%). "
                + "The reader has not read past this point."
            )
        } else if scoped {
            parts.append("Read so far: nothing yet. The reader has not read past this point.")
        }
        if let sel = selection {
            if let ch = sel.chapterTitle { parts.append("Current chapter: \(ch)") }
            parts.append("Selected text: \"\(sel.quotedText)\"")
            parts.append("Surrounding context: \(sel.surroundingText)")
        }
        return parts.joined(separator: "\n")
    }
}
