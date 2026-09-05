import Foundation

/// Heuristic token estimator shared by all providers' `countTokens`.
///
/// Uses the rough industry approximation of ~4 characters per token. This is
/// only used for routing decisions (Tier 1 vs Tier 2), so an approximation is
/// acceptable. The result is at least 1 for any non-empty estimate.
public enum TokenCounter {
    /// Estimate the number of tokens in `text` (~4 chars/token, min 1).
    ///
    /// `charactersPerToken` lets a provider whose tokeniser runs denser than
    /// the default budget on the safe side without keeping a second estimator.
    public static func estimate(_ text: String, charactersPerToken: Double = 4) -> Int {
        max(1, Int((Double(text.count) / charactersPerToken).rounded(.up)))
    }
}
