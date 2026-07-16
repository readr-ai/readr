import Foundation
import ReadrKit

/// Canned "LLM" used ONLY when the app is launched with `-uiTestStubLLM`
/// (the CI screenshot walk's second pass). It lets UI tests exercise the
/// real Ask pipeline — context assembly, tier routing, streaming, the
/// citations UI — deterministically and with zero network. Normal launches
/// never construct it (see `AppModel.activeProvider()`).
struct UITestStubProvider: LLMProvider {
    var info: ProviderInfo {
        // `-uiTestStubWholeBook`: report a remote model so a small seeded book
        // fits the whole-book tier (which the adaptive router only ever picks
        // for non-local providers), letting UI tests exercise the honest
        // no-citations copy (A4). Default stays local so the retrieval tier —
        // and its citations UI — is exercised by the screenshot walk.
        let wholeBook = ProcessInfo.processInfo.arguments.contains("-uiTestStubWholeBook")
        return ProviderInfo(
            kind: wholeBook ? .anthropic : .local,
            modelID: "ui-test-stub",
            contextBudget: 8_000,
            supportsPromptCaching: false,
            isLocal: !wholeBook
        )
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // `-uiTestStubError`: fail the stream with a mapped transport
                // error so UI tests can exercise the actionable error state and
                // the Retry affordance (A5) deterministically and offline.
                if ProcessInfo.processInfo.arguments.contains("-uiTestStubError") {
                    continuation.finish(throwing: HTTPError.transport(.timedOut))
                    return
                }
                let answer = """
                The opening line signals that something is wrong with this \
                world: clocks striking thirteen breaks ordinary time, and the \
                vile wind and gritty dust Winston shelters from set the \
                novel's tone of decay from its first sentence.
                """
                // Word-by-word so the walk can catch the streaming state.
                for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                    continuation.yield(ChatChunk(textDelta: String(word) + " "))
                    try? await Task.sleep(nanoseconds: 12_000_000)
                }
                continuation.finish()
            }
        }
    }

    func countTokens(_ text: String) throws -> Int {
        max(1, text.count / 4)
    }
}
