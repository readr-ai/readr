import Foundation
import ReadrKit

/// Drives a single "ask the book" exchange: prepares the index, streams the
/// answer, and exposes which context tier was used.
@MainActor
final class AskViewModel: ObservableObject {
    @Published var answer = ""
    @Published var tier: AssembledContext.Tier?
    @Published var citations: [Citation] = []
    @Published var isStreaming = false
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

    /// Re-resolvable provider binding: the panel calls `refresh()` when the
    /// provider settings sheet dismisses, so a key saved from the empty state
    /// takes effect immediately.
    private let makeService: () -> AskService?
    private var service: AskService?
    private let prepare: () async -> Void
    private let book: Book
    private let selection: Selection?
    /// The last question submitted, kept so a Retry can re-run it after an
    /// error (A5) without the reader retyping.
    private(set) var lastQuestion: String?

    init(makeService: @escaping () -> AskService?, prepare: @escaping () async -> Void, book: Book, selection: Selection?) {
        self.makeService = makeService
        self.prepare = prepare
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

    /// Re-run the last question after an error (A5). No-op when nothing has
    /// been asked yet.
    func retry() async {
        guard let question = lastQuestion else { return }
        await ask(question)
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrant submits while a stream is already in flight.
        guard !isStreaming else { return }
        // Keep the question so a Retry can re-run it verbatim after a failure.
        lastQuestion = trimmed
        guard let service else {
            errorMessage = "Connect an AI provider in settings to ask questions."
            errorRecovery = nil
            return
        }
        answer = ""
        tier = nil
        citations = []
        errorMessage = nil
        errorRecovery = nil
        isStreaming = true
        defer { isStreaming = false }

        await prepare()
        do {
            for try await event in service.ask(trimmed, about: book, selection: selection) {
                switch event {
                case let .contextAssembled(tier):
                    self.tier = tier
                case let .citations(list):
                    self.citations = list
                case let .token(delta):
                    answer += delta
                case let .completed(fullText):
                    // Authoritative final text — covers providers that don't
                    // stream incremental deltas.
                    answer = fullText
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
                errorMessage = localized.errorDescription ?? error.localizedDescription
                errorRecovery = localized.recoverySuggestion
            } else {
                errorMessage = error.localizedDescription
                errorRecovery = nil
            }
        }
    }
}
