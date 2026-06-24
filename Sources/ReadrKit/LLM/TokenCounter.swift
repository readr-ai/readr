import Foundation

/// Heuristic token estimator shared by all providers' `countTokens`.
///
/// Uses the rough industry approximation of ~4 characters per token. This is
/// only used for routing decisions (Tier 1 vs Tier 2), so an approximation is
/// acceptable. The result is at least 1 for any non-empty estimate.
public enum TokenCounter {
    /// Estimate the number of tokens in `text` (~4 chars/token, min 1).
    public static func estimate(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}
