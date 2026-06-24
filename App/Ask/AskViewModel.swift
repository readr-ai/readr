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
    @Published var errorMessage: String?

    /// True when there is no configured provider to answer with.
    let hasProvider: Bool

    private let service: AskService?
    private let prepare: () async -> Void
    private let book: Book
    private let selection: Selection?

    init(service: AskService?, prepare: @escaping () async -> Void, book: Book, selection: Selection?) {
        self.service = service
        self.hasProvider = service != nil
        self.prepare = prepare
        self.book = book
        self.selection = selection
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore re-entrant submits while a stream is already in flight.
        guard !isStreaming else { return }
        guard let service else {
            errorMessage = "Connect an AI provider in settings to ask questions."
            return
        }
        answer = ""
        tier = nil
        citations = []
        errorMessage = nil
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
            errorMessage = error.localizedDescription
        }
    }
}
