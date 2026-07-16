import Foundation
import ReadrKit

/// Backs the provider settings screen (J5): connect via API key, OAuth sign-in,
/// or pick a local model; choose the active provider/model.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var configured: [ProviderInfo.Kind: Bool] = [:]
    @Published var activeSelection: ProviderSelection?
    @Published var errorMessage: String?
    @Published var isSigningIn = false
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

    /// Every provider kind the app knows about, in display order.
    static let allKinds: [ProviderInfo.Kind] = [.anthropic, .openAI, .local]

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
            activateIfNeeded(kind)
            refresh()
            // A stored key isn't trusted until a lightweight test call
            // succeeds — verify it so the card shows Validating… → Connected
            // (or an invalid-key message) rather than a premature "Connected".
            Task { await validate(kind) }
        } catch {
            errorMessage = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    /// A just-connected provider becomes the active one (keeping an existing
    /// model choice for the same kind) — the user's next step is asking the
    /// book, not hunting for a second dropdown.
    private func activateIfNeeded(_ kind: ProviderInfo.Kind) {
        if manager.selection?.kind != kind {
            manager.setActive(kind: kind)
        }
        activeSelection = manager.selection
    }

    func signIn(_ kind: ProviderInfo.Kind) async {
        guard let config = Self.oauthConfig(for: kind) else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let credentials = try await OAuthCoordinator().signIn(config: config)
            try store.save(credentials, for: kind)
            // New credentials — drop any prior result so a stale state can't
            // mask the un-checked sign-in before the validate below settles.
            manager.clearValidation(kind)
            activateIfNeeded(kind)
            refresh()
            await validate(kind)
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

    static func oauthConfig(for kind: ProviderInfo.Kind) -> OAuthProviderConfig? {
        switch kind {
        // OpenAI subscription OAuth stays hidden until it's verified
        // end-to-end: the flow borrows the Codex CLI's client registration
        // and its tokens are not expected to authenticate against
        // api.openai.com, and no token-refresh path is wired up yet
        // (`OAuthClient.refresh` has no call sites). The iOS in-process
        // browser plumbing IS now implemented — OAuthCoordinator presents an
        // SFSafariViewController so the app stays foregrounded and the
        // loopback server can answer the 127.0.0.1:1455 redirect — but it
        // can't be exercised without a signed build on a physical device
        // (developer account not yet verified). Re-enable by returning
        // `.openAI` once the whole flow is verified on-device — the sign-in
        // button reappears automatically (see `supportsOAuth`), and flip
        // testProviderSettingsOffersNoOAuthSignIn to match.
        case .openAI: return nil
        // Anthropic subscription OAuth is intentionally NOT offered: Anthropic's
        // Consumer Terms prohibit using Free/Pro/Max OAuth tokens in third-party
        // apps. Use an Anthropic API key instead. See docs/AUTH.md.
        case .anthropic: return nil
        case .local: return nil
        }
    }
}
