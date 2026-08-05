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
    private let book: Book
    private let selection: Selection?
    /// The last question submitted, kept so a Retry can re-run it after an
    /// error (A5) without the reader retyping.
    private(set) var lastQuestion: String?

    init(
        makeService: @escaping () -> AskService?,
        prepare: @escaping () async -> Void,
        book: Book,
        selection: Selection?,
        providerName: @escaping () -> String = { "unknown" }
    ) {
        self.makeService = makeService
        self.prepare = prepare
        self.providerName = providerName
        self.book = book
        self.selection = selection
        let resolved = makeService()
        self.service = resolved
        self.hasProvider = resolved != nil
    }

    /// Re-resolve the provider binding. Called when the providers sheet
    /// dismisses so a newly saved key flips the panel out of its empty state.
    func refresh() {
        let resolved = makeService()
        service = resolved
        hasProvider = resolved != nil
    }

    func ask(_ question: String) async {
        await run(question, replacingLastExchange: false)
    }

    /// Re-run the last question after an error (A5). No-op when nothing has
    /// been asked yet.
    func retry() async {
        guard let question = lastQuestion else { return }
        await run(question, replacingLastExchange: true)
    }

    // MARK: - Streaming

    private func run(_ question: String, replacingLastExchange: Bool) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrant submits while a stream is already in flight.
        guard !isStreaming else { return }
        // Keep the question so a Retry can re-run it verbatim after a failure.
        lastQuestion = trimmed
        errorMessage = nil
        errorRecovery = nil

        // A Retry re-runs the SAME turn: drop the failed one rather than
        // stacking a second copy of the question in the transcript.
        if replacingLastExchange, let last = exchanges.last, last.answerText.isEmpty {
            exchanges.removeLast()
        }
        let id = UUID()
        exchanges.append(Exchange(id: id, question: trimmed))

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
                trimmed, about: book, selection: selection, history: history
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
