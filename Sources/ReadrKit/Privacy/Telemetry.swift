import Foundation

/// Privacy posture for Readr (zero-egress audit, J7).
///
/// Readr collects **no telemetry, analytics, or crash reporting by default** —
/// the app ships with telemetry off and there is no code path that turns it on.
/// On-device features (parsing, chunking, embedding, hybrid retrieval) never
/// touch the network, and the local LLM path only ever contacts a loopback
/// Ollama server. Secrets (API keys, OAuth tokens) live exclusively in the
/// Keychain and never leave it — never `UserDefaults`, plists, or logs.
///
/// `PrivacyAuditTests` enforces these invariants structurally.
public enum Telemetry {
    /// Telemetry is OFF by default; Readr ships no analytics.
    public static let isEnabled = false
}
