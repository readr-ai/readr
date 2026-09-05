import Foundation

/// Shortens a retrieval-tier prompt for a provider with a hard window the
/// context strategy's estimate overshot — by whole passages, newest-ranked
/// last, never by cutting prose.
///
/// `AdaptiveContextStrategy` already budgets passages to `contextBudget`;
/// this is the backstop for a tokeniser denser than the estimate. Passages
/// are recognised by their `[locator]` prefix (`AdaptiveContextStrategy
/// .passageLine`), not by blank lines, because passage text is book prose and
/// has blank lines of its own.
public enum RetrievalPromptTrimmer {

    public static let omittedPlaceholder = "(passages omitted to fit the on-device model)"

    /// The prompt with its last passage removed. Nil when there is nothing
    /// left to remove: no passage block, or a block already down to the
    /// placeholder — so a caller looping on this always terminates.
    public static func droppingLastPassage(from prompt: String) -> String? {
        guard let header = prompt.range(of: AdaptiveContextStrategy.passagesHeader),
              let question = prompt.range(
                  of: AdaptiveContextStrategy.questionPrefix,
                  range: header.upperBound..<prompt.endIndex
              )
        else { return nil }
        let block = String(prompt[header.upperBound..<question.lowerBound])
        var passages = passages(in: block)
        guard !passages.isEmpty else { return nil }
        passages.removeLast()
        let kept = passages.isEmpty
            ? omittedPlaceholder
            : passages.joined(separator: AdaptiveContextStrategy.passageSeparator)
        return String(prompt[..<header.upperBound]) + kept + String(prompt[question.lowerBound...])
    }

    /// Drop passages until `measure(prompt) <= budget` or none remain,
    /// returning the shortest prompt reached. A prompt that has no passage
    /// block, or that is over budget with none left, comes back as is — the
    /// caller decides whether what remains is worth sending.
    public static func fit(_ prompt: String, budget: Int, measure: (String) -> Int) -> String {
        var fitted = prompt
        while measure(fitted) > budget, let shorter = droppingLastPassage(from: fitted) {
            fitted = shorter
        }
        return fitted
    }

    /// The passages in a block, split where a `[locator]` line begins after
    /// the separator. A block that doesn't start with a locator — the
    /// placeholder — holds none.
    static func passages(in block: String) -> [String] {
        guard block.hasPrefix("[") else { return [] }
        var result: [String] = []
        var current = ""
        let boundary = AdaptiveContextStrategy.passageSeparator + "["
        var rest = Substring(block)
        while let range = rest.range(of: boundary) {
            current += rest[..<range.lowerBound]
            result.append(current)
            current = ""
            rest = rest[rest.index(before: range.upperBound)...]  // keep the "["
        }
        current += rest
        if !current.isEmpty { result.append(current) }
        return result
    }
}
