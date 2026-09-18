import Foundation
import ReadrKit

/// Drives an "ask the book" CONVERSATION: prepares the index, streams each
/// answer, and keeps the transcript so a follow-up can build on what came
/// before.
///
/// It used to hold a single exchange — asking again wiped the previous answer
/// and re-prompted the model from scratch, so "but roads are technically 3D"
/// arrived with nothing to object to.
@MainActor
final class AskViewModel: ObservableObject {

    /// One question and the answer streaming into it.
    struct Exchange: Identifiable, Equatable {
        let id: UUID
        /// Shown immediately, as sent — the reader's message must appear the
        /// moment they send it, not when the answer starts arriving.
        var question: String
        /// What this answer was allowed to see. Kept per exchange because the
        /// panel's toggle can flip between questions, and the footer under
        /// an answer must describe that answer.
        var scope: ReadingScope
        var answerText: String = ""
        var tier: AssembledContext.Tier? = nil
        var citations: [Citation] = []
        /// The passage the question was asked about, when it was about one —
        /// kept so a saved note can quote what its answer is about, the way
        /// the panel showed it at the time.
        var quote: String? = nil
        /// The chapter the question came from, for the saved note's front
        /// matter.
        var chapter: String? = nil
        /// Where this answer was saved in the reader's knowledge base, once
        /// they saved it — the row under the answer then shows the saved state
        /// instead of offering to save it a second time.
        var savedPath: String? = nil
        /// The stream failed; the panel's error card carries the detail.
        var failed = false
        var isStreaming = true

        /// True once there is nothing to show and nothing coming.
        var isEmpty: Bool { answerText.isEmpty && !isStreaming }
    }

    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var isStreaming = false

    /// The mapped, reader-facing failure sentence (an `HTTPError`'s
    /// `errorDescription` when the transport surfaced one). Nil when there is
    /// no error to show.
    @Published var errorMessage: String?
    /// A concrete next step for the reader, shown beneath `errorMessage` (an
    /// `HTTPError`'s `recoverySuggestion`). Nil when the error carries none.
    @Published var errorRecovery: String?

    /// True when there is a configured provider to answer with. Refreshable so
    /// the panel can recover after the reader connects a provider from its own
    /// empty state (A1) without restarting the app.
    @Published private(set) var hasProvider: Bool

    /// True when the active provider can only answer from the book — Apple's
    /// on-device model. The footer then promises exactly that, and no "wider
    /// knowledge" a 3B model does not have.
    @Published private(set) var answersFromBookOnly: Bool

    /// The most recently routed tier — what the grounding caption and the
    /// "Using relevant passages" label describe.
    var tier: AssembledContext.Tier? {
        exchanges.last(where: { $0.tier != nil })?.tier
    }

    /// Re-resolvable provider binding: the panel calls `refresh()` when the
    /// provider settings sheet dismisses, so a key saved from the empty state
    /// takes effect immediately.
    private let makeService: () -> AskService?
    private var service: AskService?
    /// Performs only the work this request's scope needs. In particular, a
    /// whole-text request must not wait for a retrieval index it will not use.
    private let prepare: (ReadingScope, Selection?) async -> Void
    /// Which provider answered, for diagnostics only (#41). A closure because
    /// the active provider can change while the panel is open, same as
    /// `makeService`.
    private let providerName: () -> String
    private let providerAnswersFromBookOnly: () -> Bool
    private let book: Book
    /// The passage the conversation is currently about, or nil for the book
    /// at large. Set per opening (`open`): the conversation outlives the
    /// panel, and the next ✦ Ask on a different passage points it there.
    @Published private(set) var selection: Selection?
    /// How far the reader has read, as of the latest opening. What a scoped
    /// question is held to; nil (a native PDF page) means every question
    /// is about the whole document and the scope choice is hidden.
    @Published private(set) var frontier: ReadingFrontier?
    /// The reader's "Answers from" choice, kept on the conversation, with the
    /// transcript it describes: a choice made for one question holds for the
    /// next opening rather than snapping back while whole-book answers sit in
    /// the history the model is shown.
    ///
    /// Persisted because Settings now exposes it as an explicit reader
    /// preference. The Settings copy warns that Whole book can use more model
    /// context; the in-panel picker writes the same preference.
    @Published var answersFrom: AnswersFrom {
        didSet {
            if AskPreferences.defaultContextRange != answersFrom {
                AskPreferences.defaultContextRange = answersFrom
            }
        }
    }

    /// How much of the book an answer may see — the panel's "Answers from"
    /// choice as three named options. The names describe what the reader
    /// gets; `ReadingScope` is how the strategy hears it.
    typealias AnswersFrom = AskContextRange
    /// True while the latest opening was a Recap, for the panel's headline.
    @Published private(set) var openedForRecap = false
    /// The question an opening asked to send on the panel's behalf (Recap),
    /// waiting for a provider and for any stream in flight to finish. Sent
    /// once; a later opening replaces it.
    private var pendingQuestion: String?
    /// True once `open` has pointed the conversation somewhere — before
    /// that it has no frontier, and the Ask tab must open it properly.
    private(set) var hasBeenOpened = false
    /// The stream in flight, so leaving the book or starting over cancels
    /// it instead of letting it run to completion for nobody.
    private var streamTask: Task<Void, Never>?
    /// The last question submitted, the scope and the passage it was asked
    /// under, kept so a Retry re-runs exactly it after an error (A5) — not
    /// the passage the conversation has since been pointed at.
    private(set) var lastRequest: (question: String, scope: ReadingScope, selection: Selection?)?

    /// What the next question is allowed to see: the reader's choice, pointed
    /// at wherever the conversation currently is.
    var scope: ReadingScope {
        switch answersFrom {
        case .nearby:
            // No reading position (a native PDF page) is still the nearby
            // scope — "nearby" means extracts, not the book.
            return .window(frontier)
        case .readSoFar:
            return frontier.map(ReadingScope.upTo) ?? .wholeBook
        case .wholeBook:
            return .wholeBook
        }
    }

    /// The scope is NOT an init argument: the panel hands it to every
    /// `ask(_:scope:)` from its picker, so a panel opened scoped can ask the
    /// next question about the whole book without a new view model.
    init(
        makeService: @escaping () -> AskService?,
        prepare: @escaping (ReadingScope, Selection?) async -> Void,
        book: Book,
        selection: Selection?,
        initialQuestion: String?,
        providerName: @escaping () -> String = { "unknown" },
        answersFromBookOnly: @escaping () -> Bool = { false }
    ) {
        self.makeService = makeService
        self.prepare = prepare
        self.providerName = providerName
        self.providerAnswersFromBookOnly = answersFromBookOnly
        self.book = book
        self.selection = selection
        self.pendingQuestion = initialQuestion
        self.answersFrom = AskPreferences.defaultContextRange
        let resolved = makeService()
        self.service = resolved
        self.hasProvider = resolved != nil
        self.answersFromBookOnly = answersFromBookOnly()
    }

    /// Point the conversation at a new opening: the passage (or none), how
    /// far the reader has read, and, for a Recap, the question to send on
    /// the panel's behalf. The transcript stays — one conversation per
    /// book, per session. A stale error from an earlier question does not:
    /// it was about that question, not this opening.
    func open(_ request: AskRequest) {
        selection = request.selection
        frontier = request.scope.frontier
        openedForRecap = request.initialQuestion != nil
        pendingQuestion = request.initialQuestion
        hasBeenOpened = true
        errorMessage = nil
        errorRecovery = nil
        sendPendingIfReady()
    }

    /// Start over: cancel anything in flight, empty the transcript, keep
    /// the passage and frontier the conversation was last pointed at.
    func startOver() {
        cancel()
        exchanges = []
        errorMessage = nil
        errorRecovery = nil
        lastRequest = nil
        pendingQuestion = nil
        openedForRecap = false
    }

    /// Stop the stream in flight, if any. The answer keeps what arrived.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Re-resolve the provider binding. Called when the providers sheet
    /// dismisses so a newly saved key flips the panel out of its empty state.
    func refresh() {
        let resolved = makeService()
        service = resolved
        hasProvider = resolved != nil
        answersFromBookOnly = providerAnswersFromBookOnly()
        sendPendingIfReady()
    }

    /// Pull in a Settings change for conversations that already exist. The
    /// guard avoids writing the same value back to UserDefaults and turning a
    /// defaults notification into a loop.
    func refreshAskPreferences() {
        let stored = AskPreferences.defaultContextRange
        guard answersFrom != stored else { return }
        answersFrom = stored
    }

    /// Ask, under the current scope and about the current passage. The
    /// stream runs as the conversation's own task, so it can be cancelled.
    func submit(_ question: String) {
        let scope = self.scope
        let selection = self.selection
        streamTask = Task { await run(question, scope: scope, selection: selection, replacingLastExchange: false) }
    }

    /// Send the question an opening asked for (the Recap), once there is a
    /// provider and no stream in flight. Called from `open`, from
    /// `refresh`, and when a stream ends — so a Recap opened over a
    /// running answer goes out when that answer is done, not never.
    func sendPendingIfReady() {
        guard let question = pendingQuestion, hasProvider, !isStreaming else { return }
        pendingQuestion = nil
        submit(question)
    }

    /// Re-run the last question after an error (A5), under the scope and
    /// about the passage it was asked with. No-op when nothing has been
    /// asked yet.
    func retry() {
        guard let last = lastRequest else { return }
        streamTask = Task {
            await run(last.question, scope: last.scope, selection: last.selection, replacingLastExchange: true)
        }
    }

    // MARK: - Streaming

    private func run(
        _ question: String, scope: ReadingScope, selection: Selection?, replacingLastExchange: Bool
    ) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var preparedAt = startedAt
        var contextAssembledAt = startedAt
        var loggedFirstToken = false
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrant submits while a stream is already in flight.
        guard !isStreaming else { return }
        // Keep the request — question, scope AND passage — so a Retry
        // re-runs exactly it after a failure.
        lastRequest = (trimmed, scope, selection)
        errorMessage = nil
        errorRecovery = nil

        // A Retry re-runs the SAME turn: drop the failed one rather than
        // stacking a second copy of the question in the transcript.
        if replacingLastExchange, let last = exchanges.last, last.answerText.isEmpty {
            exchanges.removeLast()
        }
        let id = UUID()
        exchanges.append(Exchange(
            id: id, question: trimmed, scope: scope,
            quote: selection?.quotedText, chapter: selection?.chapterTitle
        ))

        guard self.service != nil else {
            fail(id, "Connect an AI provider in settings to ask questions.", recovery: nil)
            return
        }

        isStreaming = true
        let history = historyBefore(id, scope: scope)
        defer {
            isStreaming = false
            update(id) { $0.isStreaming = false }
            // A Recap that arrived while this answer streamed goes now.
            sendPendingIfReady()
        }

        await prepare(scope, selection)
        preparedAt = ProcessInfo.processInfo.systemUptime
        // `prepare` renews expired OAuth tokens (see AskPanelView); providers
        // capture credentials by value, so re-resolve the service to bake the
        // refreshed tokens into the one that streams.
        refresh()
        guard let service else {
            fail(id, "Connect an AI provider in settings to ask questions.", recovery: nil)
            return
        }
        do {
            for try await event in service.ask(
                trimmed, about: book, selection: selection, history: history,
                scope: scope
            ) {
                // Cancelled (the reader left the book or started over):
                // keep what arrived, say nothing.
                if Task.isCancelled { return }
                switch event {
                case let .contextAssembled(tier):
                    contextAssembledAt = ProcessInfo.processInfo.systemUptime
                    update(id) { $0.tier = tier }
                case let .citations(list):
                    update(id) { $0.citations = list }
                case let .token(delta):
                    if !loggedFirstToken, !delta.isEmpty {
                        loggedFirstToken = true
                        let now = ProcessInfo.processInfo.systemUptime
                        DiagnosticsLog.shared.record(
                            .info, .provider,
                            "ask timing: provider \(providerName()), prepare \(Self.milliseconds(preparedAt - startedAt)) ms, context \(Self.milliseconds(contextAssembledAt - preparedAt)) ms, first token \(Self.milliseconds(now - startedAt)) ms"
                        )
                    }
                    update(id) { $0.answerText += delta }
                case let .completed(fullText):
                    // Authoritative final text — covers providers that don't
                    // stream incremental deltas.
                    if !loggedFirstToken, !fullText.isEmpty {
                        loggedFirstToken = true
                        let now = ProcessInfo.processInfo.systemUptime
                        DiagnosticsLog.shared.record(
                            .info, .provider,
                            "ask timing: provider \(providerName()), prepare \(Self.milliseconds(preparedAt - startedAt)) ms, context \(Self.milliseconds(contextAssembledAt - preparedAt)) ms, first answer \(Self.milliseconds(now - startedAt)) ms"
                        )
                    }
                    update(id) { $0.answerText = fullText }
                }
            }
            // A small model can end with nothing to show — every sentence it
            // produced was a copy of the passages, or a loop cut at its first
            // sentence. The panel says so in a line; the log says which
            // provider, for the bug report.
            if exchanges.first(where: { $0.id == id })?.answerText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                DiagnosticsLog.shared.record(
                    .warning, .provider, "ask: answer came back empty (provider \(providerName()))"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            // Surface the mapped, actionable sentence from the error (A5):
            // `HTTPError` conforms to `LocalizedError` so timeouts, rejected
            // keys, and rate limits read as something the reader can act on
            // instead of Foundation's generic "operation couldn't be
            // completed." The recovery suggestion, when present, is shown
            // beneath it.
            if let localized = error as? LocalizedError {
                fail(
                    id,
                    localized.errorDescription ?? error.localizedDescription,
                    recovery: localized.recoverySuggestion
                )
            } else {
                fail(id, error.localizedDescription, recovery: nil)
            }
            // The provider and routing tier, never the question — that's the
            // reader's, and a bug report is public (#41).
            DiagnosticsLog.shared.recordAskFailure(
                provider: providerName(),
                tier: (exchanges.first { $0.id == id }?.tier)?.rawValue ?? "unrouted",
                error: error
            )
        }
    }

    private static func milliseconds(_ duration: TimeInterval) -> Int {
        max(0, Int((duration * 1_000).rounded()))
    }

    /// Completed turns before `id`, oldest first — what the model is shown of
    /// the conversation so far. A failed or empty turn carries no answer and
    /// is left out. So is a whole-book turn when THIS question is scoped:
    /// the no-spoilers promise covers the history the model reads, not
    /// just the passages it is handed.
    private func historyBefore(_ id: UUID, scope: ReadingScope) -> [ConversationTurn] {
        exchanges.prefix(while: { $0.id != id }).compactMap { exchange -> ConversationTurn? in
            guard !exchange.failed, !exchange.answerText.isEmpty else { return nil }
            if scope.isScoped, !exchange.scope.isScoped { return nil }
            return ConversationTurn(
                question: exchange.question,
                answer: Answer(
                    text: exchange.answerText,
                    tier: exchange.tier ?? .retrieval,
                    citations: exchange.citations
                )
            )
        }
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }

    /// The active model's name, for a saved note's front matter — the same
    /// string the bug reports and the sidebar use ("DeepSeek Flash").
    var modelName: String { providerName() }

    /// Record that an answer was written to the knowledge base, so the row
    /// under it stops offering to save it again.
    func markSaved(_ id: UUID, path: String) {
        update(id) { $0.savedPath = path }
    }

    private func fail(_ id: UUID, _ message: String, recovery: String?) {
        errorMessage = message
        errorRecovery = recovery
        update(id) {
            $0.failed = true
            $0.isStreaming = false
        }
    }
}
