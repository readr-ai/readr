import Foundation
import ReadrKit

/// Backs the provider settings screen (J5): connect via API key, OAuth sign-in,
/// or pick a local model; choose the active provider/model.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var configured: [ProviderInfo.Kind: Bool] = [:]
    @Published var activeSelection: ProviderSelection?
    @Published var errorMessage: String?
    /// The kind whose OAuth flow is in flight, or nil. Non-nil disables every
    /// sign-in button (one loopback flow at a time); only the matching card
    /// shows the spinner.
    @Published var signingInKind: ProviderInfo.Kind?
    var isSigningIn: Bool { signingInKind != nil }
    /// Latest validation/readiness state per kind, mirrored from the manager so
    /// the cards can show Validating… / Connected / an error inline (A2/A3).
    @Published private(set) var validation: [ProviderInfo.Kind: ProviderManager.ValidationState] = [:]

    private let manager: ProviderManager
    private let store: any CredentialStore

    /// `-uiTestSkipProviderValidation`: skip the live validate/probe calls so
    /// the Active-badge XCUITest is deterministic offline (a saved key stays
    /// "Connected" via the stored-key heuristic instead of failing the real
    /// authenticated test call). Normal launches always validate.
    private let skipValidation = ProcessInfo.processInfo.arguments
        .contains("-uiTestSkipProviderValidation")

    /// Every provider kind the app knows about, in display order: the two
    /// sign-in paths lead (lowest-friction first-run), then the key-only
    /// cloud providers, then Local.
    static let allKinds: [ProviderInfo.Kind] = [.chatGPT, .openRouter, .anthropic, .openAI, .local]

    let kinds: [ProviderInfo.Kind] = SettingsModel.allKinds

    /// The provider rows the settings screen renders. On iOS the Local row is
    /// hidden: LocalLLMProvider defaults to loopback Ollama
    /// (http://127.0.0.1:11434), and nothing listens on a phone's loopback —
    /// the row would be a dead end. macOS keeps it; pointing at a LAN-hosted
    /// Ollama from iOS is a tracked fast-follow.
    static var displayedKinds: [ProviderInfo.Kind] {
        #if os(iOS)
        return allKinds.filter { $0 != .local }
        #else
        return allKinds
        #endif
    }

    var displayedKinds: [ProviderInfo.Kind] { Self.displayedKinds }

    // MARK: - First-run guidance (A6)

    /// The ways a user can actually connect a provider in *this* build, phrased
    /// for onboarding copy. Derived from `displayedKinds`/`supportsOAuth` so the
    /// copy never advertises a path the reader can't take: "sign in" only when a
    /// displayed kind offers OAuth (all are hidden today), and "pick a local
    /// model" only when the Local row is shown (never on iOS — see
    /// `displayedKinds`). "Add an API key" is always available.
    static var availableSetupPaths: [String] {
        var paths = ["Add an API key"]
        let displayed = displayedKinds
        if displayed.contains(where: { oauthConfig(for: $0) != nil }) {
            paths.append("sign in")
        }
        if displayed.contains(.local) {
            paths.append("pick a local model")
        }
        return paths
    }

    /// An honest onboarding sentence for an empty state, e.g.
    /// "Add an API key or pick a local model to ask questions." Only names the
    /// connection paths this build exposes (see `availableSetupPaths`).
    static func setupGuidance(toDo action: String) -> String {
        "\(joined(availableSetupPaths)) to \(action)."
    }

    /// Join a list into an English phrase with an Oxford "or":
    /// ["a"] → "a"; ["a","b"] → "a or b"; ["a","b","c"] → "a, b, or c".
    private static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) or \(parts[1])"
        default:
            let head = parts.dropLast().joined(separator: ", ")
            return "\(head), or \(parts.last!)"
        }
    }

    init(manager: ProviderManager, store: any CredentialStore) {
        self.manager = manager
        self.store = store
        self.activeSelection = manager.selection
        // No Keychain I/O here: SwiftUI re-evaluates `StateObject(wrappedValue:)`
        // on every re-render and discards all but the first instance. The view
        // calls `refresh()` from `.task` instead.
    }

    func refresh() {
        for kind in kinds {
            configured[kind] = manager.isConfigured(kind)
            validation[kind] = manager.validationState(kind)
        }
        activeSelection = manager.selection
    }

    /// The provider kind `ProviderManager.setActive` last selected (restored
    /// from the persisted selection), used to badge the active card (A7). Nil
    /// until the user has chosen one.
    var activeKind: ProviderInfo.Kind? { activeSelection?.kind }

    /// Kick off (or refresh) validation for a kind and mirror the result:
    /// remote keys get a lightweight authenticated probe, Local hits Ollama's
    /// `api/tags`. `validation[kind]` flips to `.validating` immediately so the
    /// card can show a spinner, then settles to `.active` (verified),
    /// `.invalid` (rejected key), or `.unavailable` (transient — offline,
    /// rate-limited, provider/Ollama down).
    func validate(_ kind: ProviderInfo.Kind) async {
        guard !skipValidation else { return }
        validation[kind] = .validating
        _ = await manager.validate(kind)
        // Re-read the manager's authoritative state rather than the call's
        // return value: if the credential changed mid-flight (the user saved a
        // new key), this run's result was discarded and the manager now holds
        // the fresh state (often nil) — mirroring the return value would land a
        // stale result in the published map.
        validation[kind] = manager.validationState(kind)
        configured[kind] = manager.isConfigured(kind)
    }

    /// Validate every displayed kind that has something to check: remote kinds
    /// with a stored credential, and Local always (its readiness is derived
    /// from a live probe). Called from the view's `.task`.
    func validateDisplayed() async {
        for kind in displayedKinds where kind == .local || (configured[kind] ?? false) {
            await validate(kind)
        }
    }

    func models(for kind: ProviderInfo.Kind) -> [ProviderInfo] {
        ProviderCatalog.models(for: kind)
    }

    func saveAPIKey(_ key: String, for kind: ProviderInfo.Kind) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.save(.apiKey(trimmed), for: kind)
            // The new key hasn't been checked yet — drop any prior result so the
            // card doesn't flash a stale Connected/invalid from the old key
            // before the re-validate below settles.
            manager.clearValidation(kind)
            // A just-connected provider becomes the active one — the user's
            // next step is asking the book, not hunting for a second
            // dropdown. But the takeover is immediate only when nothing
            // usable holds the active slot; otherwise it completes inside
            // `validateAndActivate` once the key clears, so a bad save can't
            // displace a working provider and strand Ask on a rejected
            // credential (issue #44).
            manager.requestActivation(of: kind)
            refresh()
            // A stored key isn't trusted until a lightweight test call
            // succeeds — verify it so the card shows Validating… → Connected
            // (or an invalid-key message) rather than a premature "Connected".
            Task { await validateAndActivate(kind) }
        } catch {
            errorMessage = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    /// Validate a just-saved credential, complete its (possibly deferred)
    /// activation unless the key was rejected, and mirror the settled state.
    /// See `ProviderManager.requestActivation(of:)` / `validateAndActivate(_:)`.
    ///
    /// Under `-uiTestSkipProviderValidation` this returns before the manager
    /// call, so a takeover that `requestActivation` deferred never completes —
    /// UI tests that save a key over an already-configured provider must not
    /// expect the Active badge to move.
    private func validateAndActivate(_ kind: ProviderInfo.Kind) async {
        guard !skipValidation else { return }
        validation[kind] = .validating
        _ = await manager.validateAndActivate(kind)
        validation[kind] = manager.validationState(kind)
        configured[kind] = manager.isConfigured(kind)
        activeSelection = manager.selection
    }

    func signIn(_ kind: ProviderInfo.Kind) async {
        guard let config = Self.oauthConfig(for: kind) else { return }
        guard signingInKind == nil else { return }
        signingInKind = kind
        defer { signingInKind = nil }
        do {
            let credentials = try await OAuthCoordinator().signIn(config: config)
            try store.save(credentials, for: kind)
            // New credentials — drop any prior result so a stale state can't
            // mask the un-checked sign-in before the validate below settles.
            // Activation follows the same guarded policy as saveAPIKey (#44).
            manager.clearValidation(kind)
            manager.requestActivation(of: kind)
            refresh()
            await validateAndActivate(kind)
        } catch AuthError.userCancelled {
            // user backed out — no error to show
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func disconnect(_ kind: ProviderInfo.Kind) {
        try? store.delete(for: kind)
        // Drop the cached validation result so a deleted key can't linger as
        // ".active" — otherwise the card stays "Connected" and activeProvider()
        // would still resolve it.
        manager.clearValidation(kind)
        refresh()
    }

    func makeActive(kind: ProviderInfo.Kind, modelID: String) {
        manager.setActive(kind: kind, modelID: modelID)
        activeSelection = manager.selection
        // The selected model feeds Local's readiness probe (which model tag it
        // looks for), so re-validate Local when its model changes.
        if kind == .local {
            Task { await validate(kind) }
        }
    }

    /// Whether a kind offers a browser OAuth "sign in" option.
    func supportsOAuth(_ kind: ProviderInfo.Kind) -> Bool {
        Self.oauthConfig(for: kind) != nil
    }

    /// Delegates to `OAuthProviderConfig.config(for:)` — the single source of
    /// truth shared with the token refresher. `.chatGPT` and `.openRouter`
    /// offer sign-in; `.openAI` is API-key-only by design; Anthropic
    /// subscription OAuth is intentionally NOT offered (Anthropic's Consumer
    /// Terms prohibit Free/Pro/Max OAuth tokens in third-party apps — use an
    /// Anthropic API key instead; docs/AUTH.md).
    static func oauthConfig(for kind: ProviderInfo.Kind) -> OAuthProviderConfig? {
        OAuthProviderConfig.config(for: kind)
    }
}
