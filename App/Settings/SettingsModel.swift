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

    private let manager: ProviderManager
    private let store: any CredentialStore

    let kinds: [ProviderInfo.Kind] = [.anthropic, .openAI, .local]

    init(manager: ProviderManager, store: any CredentialStore) {
        self.manager = manager
        self.store = store
        self.activeSelection = manager.selection
        // No Keychain I/O here: SwiftUI re-evaluates `StateObject(wrappedValue:)`
        // on every re-render and discards all but the first instance. The view
        // calls `refresh()` from `.task` instead.
    }

    func refresh() {
        for kind in kinds { configured[kind] = manager.isConfigured(kind) }
    }

    func models(for kind: ProviderInfo.Kind) -> [ProviderInfo] {
        ProviderCatalog.models(for: kind)
    }

    func saveAPIKey(_ key: String, for kind: ProviderInfo.Kind) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.save(.apiKey(trimmed), for: kind)
            refresh()
        } catch {
            errorMessage = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    func signIn(_ kind: ProviderInfo.Kind) async {
        guard let config = Self.oauthConfig(for: kind) else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let credentials = try await OAuthCoordinator().signIn(config: config)
            try store.save(credentials, for: kind)
            refresh()
        } catch AuthError.userCancelled {
            // user backed out — no error to show
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func disconnect(_ kind: ProviderInfo.Kind) {
        try? store.delete(for: kind)
        refresh()
    }

    func makeActive(kind: ProviderInfo.Kind, modelID: String) {
        manager.setActive(kind: kind, modelID: modelID)
        activeSelection = manager.selection
    }

    /// Whether a kind offers a browser OAuth "sign in" option.
    func supportsOAuth(_ kind: ProviderInfo.Kind) -> Bool {
        Self.oauthConfig(for: kind) != nil
    }

    static func oauthConfig(for kind: ProviderInfo.Kind) -> OAuthProviderConfig? {
        switch kind {
        case .openAI: return .openAI
        // Anthropic subscription OAuth is intentionally NOT offered: Anthropic's
        // Consumer Terms prohibit using Free/Pro/Max OAuth tokens in third-party
        // apps. Use an Anthropic API key instead. See docs/AUTH.md.
        case .anthropic: return nil
        case .local: return nil
        }
    }
}
