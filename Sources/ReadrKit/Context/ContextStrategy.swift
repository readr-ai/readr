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
    /// - Parameter scope: what the answer may draw on — the whole book,
    ///   everything read so far, or only the paragraphs near the passage in
    ///   hand. Named at every call site; see `ReadingScope`.
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

/// Default adaptive router. The scope names what the reader asked for, and
/// the router takes it at its word:
/// - `.window` — the paragraphs around the passage plus retrieved passages.
///   Never the book. Only exception: while what has been read is still small
///   (see `defaultSmallBookTokenCap`), that rides along instead, because it
///   costs about the same and cannot miss what retrieval might.
/// - `.upTo` — everything read so far, if the model can spare the room.
/// - `.wholeBook` — the whole book, if the model can spare the room.
/// A text that does not fit its share of the budget falls back to retrieval,
/// and the panel says so. Both tiers always inject the selection, the chapter
/// and the TOC anchor.
///
/// The rule used to be "the book fits 60% of the budget" — which, against a
/// 200k-token budget, sent the whole book for almost every real book on every
/// question. That is a large bill for something most questions do not need:
/// the reader asked about a sentence, and a model reads a question about a
/// sentence the way a reader does — the passage in hand, the paragraphs just
/// before it, and whatever it goes back to look up. See
/// docs/CONTEXT-STRATEGY.md.
public struct AdaptiveContextStrategy: ContextStrategy {
    private let index: RAGIndex
    private let lengths: ReadingLengthCache
    /// Fraction of the context budget a text may occupy when the reader asked
    /// for the text itself (leaves room for history + answer).
    private let wholeBookBudgetFraction: Double
    /// The read-so-far size under which the read text rides along even in the
    /// nearby-passages scope.
    private let smallBookTokenCap: Int

    /// - Parameter lengths: per-book chapter lengths, shared with whatever
    ///   else measures books (the app hands in its one cache) so a scoped
    ///   question's token estimate never re-walks the text.
    /// - Parameter smallBookTokenCap: see `defaultSmallBookTokenCap`.
    public init(
        index: RAGIndex,
        lengths: ReadingLengthCache = ReadingLengthCache(),
        wholeBookBudgetFraction: Double = AdaptiveContextStrategy.defaultWholeBookBudgetFraction,
        smallBookTokenCap: Int = AdaptiveContextStrategy.defaultSmallBookTokenCap
    ) {
        self.index = index
        self.lengths = lengths
        self.wholeBookBudgetFraction = wholeBookBudgetFraction
        self.smallBookTokenCap = smallBookTokenCap
    }

    /// The share of the context budget a text may occupy when the reader
    /// asked for the text itself — "Read so far" or "Whole book" in the
    /// panel. The nearby-passages scope does not consult it: it is gated by
    /// `defaultSmallBookTokenCap` instead. Named rather than written twice: a
    /// caller that has to predict the tier without a strategy in hand reads
    /// this one, so a change here cannot leave a second copy behind.
    public static let defaultWholeBookBudgetFraction = 0.6

    /// How much text a book may have *read so far* and still ride along in
    /// the nearby-passages scope, where the reader did not ask for text.
    ///
    /// Small reads are both cheaper and more accurate sent whole: below this
    /// size the text is the same order of magnitude as a handful of retrieved
    /// passages, so retrieval would cost about as much and could miss. It is
    /// also the rung where the analogy to a reader holds best — at the start
    /// of a book you have all of it in mind; past the first few chapters you
    /// have the current page and whatever you go back to look up.
    ///
    /// 6,000 tokens ≈ 12–15 printed pages of prose. Measured in English; CJK
    /// text is denser per character, so the cap lands on fewer pages there —
    /// which is the conservative direction for a bill.
    public static let defaultSmallBookTokenCap = 6_000

    /// Emergency grounding while a book's retrieval index is still warming.
    /// Keep it deliberately small: this path exists to answer immediately,
    /// not to turn a nearby question into a hidden whole-book request.
    public static let defaultFallbackPassageCharacterCap = 1_600

    // MARK: - Routing

    /// The tier decision, and the numbers it rests on, in one place.
    ///
    /// `assembleContext` reads the parts it also needs to build the prompt;
    /// `routesWholeBook` reads only the verdict. Neither carries its own copy
    /// of the rule, so a caller that plans work on the prediction — skipping
    /// an index build for a question that will never retrieve — cannot be
    /// told one thing and served another.
    struct Routing {
        /// The share of the provider's context budget a text may occupy when
        /// the reader asked for the text itself.
        let budget: Int
        /// Characters before the frontier, or nil for an unscoped question —
        /// nil and 0 are different answers, and only 0 means "not started".
        let charactersRead: Int?
        /// A scoped question from a reader who has not started. Nothing has
        /// been read, so nothing is sent: the whole-book tier with an empty
        /// book, whatever the provider — there is no text to be too big for
        /// it and nothing for retrieval to find.
        var nothingRead: Bool { charactersRead == 0 }
        /// Whether the text rides along whole: small enough to ride along
        /// unasked, or asked for and small enough for this model. Local models
        /// never qualify — they are the small-window case retrieval exists
        /// for.
        let fits: Bool
        /// The tier `assembleContext` picks.
        var isWholeBook: Bool { nothingRead || fits }
    }

    static func routing(
        book: Book,
        scope: ReadingScope,
        provider: ProviderInfo,
        lengths: ReadingLengthCache,
        wholeBookBudgetFraction: Double,
        smallBookTokenCap: Int
    ) -> Routing {
        let budget = Int(Double(provider.contextBudget) * wholeBookBudgetFraction)
        // Counted, not built: a long book the reader has only started is a
        // short text, and the text itself is only assembled once the
        // whole-book tier is chosen.
        let charactersRead = scope.frontier.map { lengths.table(for: book).charactersRead(upTo: $0) }
        // What would ride along on the whole-book tier, and therefore what has
        // to fit. A question with no frontier (a PDF page) has no read-so-far
        // to measure, so the whole document is what would be sent.
        let bookTokens = charactersRead.map(estimateTokens(characterCount:)) ?? book.estimatedTokenCount
        // The scope says how much text the reader asked for, so it sets the
        // cap: the nearby-passages scope sends extracts and never the book —
        // except while the read text is still small enough that sending it
        // costs about what retrieval would (and cannot miss) — while the two
        // text scopes are honored up to what the model can actually hold.
        let cap: Int
        switch scope {
        case .window: cap = min(smallBookTokenCap, budget)
        case .upTo, .wholeBook: cap = budget
        }
        return Routing(
            budget: budget,
            charactersRead: charactersRead,
            fits: !provider.isLocal && bookTokens <= cap
        )
    }

    /// Whether a question would be answered from the book's own text rather
    /// than from retrieved passages — `assembleContext`'s tier choice, made
    /// without assembling anything.
    ///
    /// For callers that must act on the tier *before* the prompt exists: an
    /// index is only worth building for a question that will retrieve, and
    /// chunking and embedding a long book is seconds no whole-book answer
    /// would use.
    public func routesWholeBook(
        book: Book,
        scope: ReadingScope,
        provider: ProviderInfo
    ) -> Bool {
        Self.routing(
            book: book, scope: scope, provider: provider, lengths: lengths,
            wholeBookBudgetFraction: wholeBookBudgetFraction,
            smallBookTokenCap: smallBookTokenCap
        ).isWholeBook
    }

    /// The same predicate for a caller with no strategy instance yet, given
    /// the same inputs the strategy would use.
    ///
    /// - Parameter lengths: required, not defaulted. A scoped question
    ///   measures what has been read, and measuring it through a throwaway
    ///   cache walks every chapter of the book — on a per-question check
    ///   ("is an index worth building?") that is a full text pass each time.
    ///   Hand in the same cache the strategy gets.
    public static func routesWholeBook(
        book: Book,
        scope: ReadingScope,
        provider: ProviderInfo,
        lengths: ReadingLengthCache,
        wholeBookBudgetFraction: Double = AdaptiveContextStrategy.defaultWholeBookBudgetFraction,
        smallBookTokenCap: Int = AdaptiveContextStrategy.defaultSmallBookTokenCap
    ) -> Bool {
        routing(
            book: book, scope: scope, provider: provider, lengths: lengths,
            wholeBookBudgetFraction: wholeBookBudgetFraction,
            smallBookTokenCap: smallBookTokenCap
        ).isWholeBook
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
        var systemContent: String
        if scope.isWindow {
            // Nearby is the one-click, latency-sensitive reading path. Keep
            // its instructions as compact as its passage set: the full
            // long-form prompt costs more prefill than the two or three local
            // paragraphs the reader actually asked about.
            systemContent = Self.nearbySystemPrompt
            if frontier != nil {
                systemContent += "\n\n" + Self.nearbySpoilerGuard
            }
        } else {
            systemContent = scope.isScoped
                ? Self.systemPrompt + "\n\n" + Self.spoilerGuard
                : Self.systemPrompt
        }
        let priorTurns = Self.historyMessages(from: history)
        // The tier decision and the numbers behind it, from the one place
        // that holds the rule — `routesWholeBook` asks the same question of
        // the same code, so a caller that predicted the tier gets it.
        let routing = Self.routing(
            book: book, scope: scope, provider: provider, lengths: lengths,
            wholeBookBudgetFraction: wholeBookBudgetFraction,
            smallBookTokenCap: smallBookTokenCap
        )
        // The prompt says "the book below", which is only true where the text
        // was actually sent. Say so when it wasn't — the nearby scope is the
        // one that hands the model extracts — but only when that is what
        // happened: a read small enough to ride along whole leaves no unseen
        // book to warn about.
        if scope.isWindow, !routing.isWholeBook {
            systemContent += "\n\n" + Self.nearbyOnlyNote
        }
        let budget = routing.budget

        if routing.nothingRead {
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

        // A selected passage is already a complete local anchor. Even in the
        // first few pages, don't replace it with every character read so far:
        // that turns the one-click "explain this" interaction into a large
        // prompt and recreates the latency Nearby exists to avoid.
        let usesCompactSelectedPassage = scope.isWindow && selection != nil
        if routing.fits, !usesCompactSelectedPassage {
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

        // Tier 2: bounded context. With a frontier, the index is asked for
        // passages at or before the last chapter the reader has finished —
        // the ceiling is the index's to apply, before its limit.
        let maxChapterIndex: Int? = frontier.map { frontier in
            book.hasFinishedChapter(at: frontier) ? frontier.chapterIndex : frontier.chapterIndex - 1
        }

        var passages: [RetrievedPassage] = []

        if scope.isWindow {
            // This is the reader's instant path, matching the original AI
            // reading area: local paragraphs plus at most three 160-character
            // search snippets. Eight full ~1,200-character chunks made the
            // provider spend seconds on prompt prefill before the first token.
            //
            // Without a selection the anchor contains only the position, so
            // carry a small tail of the visible/read text as the local source.
            if selection == nil, let frontier {
                let tail = book.readTail(
                    upTo: frontier,
                    lastCharacters: min(
                        budget * 4, Self.defaultFallbackPassageCharacterCap
                    )
                )
                if !tail.text.isEmpty {
                    passages.append(RetrievedPassage(
                        text: tail.text, locator: Self.readSoFarLocator, score: 1,
                        chapterIndex: tail.chapterIndex,
                        characterOffset: tail.characterOffset
                    ))
                }
            }

            let searchHits = try await index.retrieve(
                query: selection?.quotedText ?? question,
                bookID: book.id,
                limit: 3,
                maxChapterIndex: maxChapterIndex
            )
            passages.append(contentsOf: searchHits.map { passage in
                RetrievedPassage(
                    text: Self.snippet(from: passage.text),
                    locator: passage.locator,
                    score: passage.score,
                    chapterIndex: passage.chapterIndex,
                    characterOffset: passage.characterOffset
                )
            })
        } else {
            // Read-so-far and whole-book retrieval intentionally trade more
            // context for breadth; they retain the richer eight-chunk path.
            passages = try await index.retrieve(
                query: question,
                bookID: book.id,
                limit: 8,
                maxChapterIndex: maxChapterIndex
            )
        }

        if passages.isEmpty, let selection {
            // "Explain this" already carries the quote and surrounding
            // paragraphs in the anchor. Reuse that compact neighborhood as
            // its source while the background index warms; the old generic
            // read-tail fallback could inject 800,000 characters for a 200K
            // model and was the real 3–5 second first-token regression.
            let chapterIndex = book.chaptersInReadingOrder.firstIndex {
                $0.id == selection.chapterID
            }
            let locator = chapterIndex.map { index in
                Chunker.locator(for: book.chaptersInReadingOrder[index])
            } ?? selection.chapterTitle ?? "Selected passage"
            let text = selection.surroundingText.isEmpty
                ? selection.quotedText : selection.surroundingText
            if !text.isEmpty {
                passages = [
                    RetrievedPassage(
                        text: text, locator: locator, score: 1,
                        chapterIndex: chapterIndex, characterOffset: nil
                    ),
                ]
            }
        } else if passages.isEmpty, let frontier {
            // The reader has read something (the empty case returned above),
            // but none of it survived the chapter filter — they are partway
            // through the first chapter, say. The end of what they've read is
            // the best available grounding, so the passage block is never
            // empty: the last budget's worth of it, as one passage.
            //
            // Where the passage points is the tail's own start, which the
            // walk reports: a long tail read from just inside a chapter
            // begins in the one before it, and the citation has to open the
            // book there rather than at the frontier.
            // Nearby is intentionally capped: it promises a compact window.
            // Read-so-far uses the full remaining prompt budget, otherwise a
            // recap silently shrinks from `budget * 4` to 1,600 characters
            // whenever the index has no eligible hit.
            let fallbackCharacters = scope.isWindow
                ? min(budget * 4, Self.defaultFallbackPassageCharacterCap)
                : budget * 4
            let tail = book.readTail(
                upTo: frontier,
                lastCharacters: fallbackCharacters
            )
            if !tail.text.isEmpty {
                passages = [
                    RetrievedPassage(
                        text: tail.text, locator: Self.readSoFarLocator, score: 0,
                        chapterIndex: tail.chapterIndex,
                        characterOffset: tail.characterOffset
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
        // A citation carries the passage's position as well as its wording:
        // the locator is what the reader reads, the two indices are what the
        // app needs to open the book at the passage the answer leaned on.
        let citations = kept.map { passage in
            Citation(
                locator: passage.locator,
                quotedText: Self.snippet(from: passage.text),
                chapterIndex: passage.chapterIndex,
                characterOffset: passage.characterOffset
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

    /// Compact instructions for the interactive Nearby path. It preserves
    /// the full prompt's two product guarantees — answer beyond the book when
    /// useful, never invent what the book says — without making a short
    /// passage explanation prefill a multi-paragraph policy document.
    static let nearbySystemPrompt = """
    You are a precise reading companion. Answer in the user's language, \
    directly and briefly (usually under 200 words). Ground claims about the \
    book in the supplied text; never invent or misattribute what it says. If \
    the text is insufficient, say so briefly, then use your own knowledge \
    where helpful and distinguish it from the book. No preamble, restatement, \
    or closing recap. Use Markdown sparingly.
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

    /// Nearby gets the same spoiler boundary in a form sized for an instant
    /// passage explanation. The text after the frontier is already withheld;
    /// this also stops spoilers from the model's world knowledge.
    static let nearbySpoilerGuard = """
    Do not reveal or hint at anything after the reader's current position, \
    including facts you know about the book. A recap covers only what has \
    been read so far. If the question requires later material, say briefly \
    that you are keeping the answer spoiler-free.
    """

    /// Appended when a `.window` question is answered from extracts — the one
    /// scope where the model is handed passages rather than text, so the
    /// prompt's own "the book below" would otherwise be a lie it answers
    /// from. Pinned by `ReadingFrontierTests`.
    static let nearbyOnlyNote = """
    You were given only nearby and searched passages, not the whole book. If \
    unseen text would decide the answer, say so briefly instead of guessing, \
    and do not generalize about the entire book from these extracts.
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
