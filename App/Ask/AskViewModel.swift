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
    private let prepare: () async -> Void
    /// Which provider answered, for diagnostics only (#41). A closure because
    /// the active provider can change while the panel is open, same as
    /// `makeService`.
    private let providerName: () -> String
    private let providerAnswersFromBookOnly: () -> Bool
    private let book: Book
    private let selection: Selection?
    /// The question the panel was opened with, if any — the Recap button
    /// opens the panel with the recap already asked. Sent once, the first
    /// time there is a provider to send it to.
    private let initialQuestion: String?
    /// Whether `initialQuestion` has gone out. Set the moment it is sent, so
    /// no number of re-appearances or provider refreshes sends it twice.
    private var didSendInitialQuestion = false
    /// The last question submitted and the scope it was asked under, kept so
    /// a Retry can re-run it verbatim after an error (A5) without the reader
    /// retyping — or re-choosing.
    private(set) var lastRequest: (question: String, scope: ReadingScope)?

    /// The scope is NOT an init argument: the panel hands it to every
    /// `ask(_:scope:)` from its toggle, so a panel opened scoped can ask the
    /// next question about the whole book without a new view model.
    init(
        makeService: @escaping () -> AskService?,
        prepare: @escaping () async -> Void,
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
        self.initialQuestion = initialQuestion
        let resolved = makeService()
        self.service = resolved
        self.hasProvider = resolved != nil
        self.answersFromBookOnly = answersFromBookOnly()
    }

    /// Re-resolve the provider binding. Called when the providers sheet
    /// dismisses so a newly saved key flips the panel out of its empty state.
    func refresh() {
        let resolved = makeService()
        service = resolved
        hasProvider = resolved != nil
        answersFromBookOnly = providerAnswersFromBookOnly()
    }

    func ask(_ question: String, scope: ReadingScope) async {
        await run(question, scope: scope, replacingLastExchange: false)
    }

    /// Send the question the panel was opened with, if there is one and a
    /// provider to send it to. The panel calls this on appearance and
    /// whenever the provider binding changes; flipping the flag before the
    /// send is the once-guard.
    func sendInitialQuestionIfReady(scope: ReadingScope) {
        guard let initialQuestion, !didSendInitialQuestion, hasProvider, !isStreaming else { return }
        didSendInitialQuestion = true
        Task { await ask(initialQuestion, scope: scope) }
    }

    /// Re-run the last question after an error (A5), under the scope it was
    /// asked with. No-op when nothing has been asked yet.
    func retry() async {
        guard let last = lastRequest else { return }
        await run(last.question, scope: last.scope, replacingLastExchange: true)
    }

    // MARK: - Streaming

    private func run(_ question: String, scope: ReadingScope, replacingLastExchange: Bool) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrant submits while a stream is already in flight.
        guard !isStreaming else { return }
        // Keep the request so a Retry can re-run it verbatim after a failure.
        lastRequest = (trimmed, scope)
        errorMessage = nil
        errorRecovery = nil

        // A Retry re-runs the SAME turn: drop the failed one rather than
        // stacking a second copy of the question in the transcript.
        if replacingLastExchange, let last = exchanges.last, last.answerText.isEmpty {
            exchanges.removeLast()
        }
        let id = UUID()
        exchanges.append(Exchange(id: id, question: trimmed, scope: scope))

        guard self.service != nil else {
            fail(id, "Connect an AI provider in settings to ask questions.", recovery: nil)
            return
        }

        isStreaming = true
        let history = historyBefore(id)
        defer {
            isStreaming = false
            update(id) { $0.isStreaming = false }
        }

        await prepare()
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
                switch event {
                case let .contextAssembled(tier):
                    update(id) { $0.tier = tier }
                case let .citations(list):
                    update(id) { $0.citations = list }
                case let .token(delta):
                    update(id) { $0.answerText += delta }
                case let .completed(fullText):
                    // Authoritative final text — covers providers that don't
                    // stream incremental deltas.
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

    /// Completed turns before `id`, oldest first — what the model is shown of
    /// the conversation so far. A failed or empty turn carries no answer and
    /// is left out.
    private func historyBefore(_ id: UUID) -> [ConversationTurn] {
        exchanges.prefix(while: { $0.id != id }).compactMap { exchange -> ConversationTurn? in
            guard !exchange.failed, !exchange.answerText.isEmpty else { return nil }
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

    private func fail(_ id: UUID, _ message: String, recovery: String?) {
        errorMessage = message
        errorRecovery = recovery
        update(id) {
            $0.failed = true
            $0.isStreaming = false
        }
    }
}
