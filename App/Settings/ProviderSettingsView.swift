import SwiftUI
import ReadrKit

/// Provider settings (J5): connect Claude, ChatGPT, or a local model and pick
/// the active one. Per docs/AUTH.md, API keys are the default path; OAuth is an
/// opt-in "use your subscription" option. Styled as the design's Settings:
/// caps section labels, provider cards on the elevated surface with a status
/// dot + badge, and the privacy footer.
struct ProviderSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    init(app: AppModel) {
        _model = StateObject(wrappedValue: SettingsModel(
            manager: app.providerManager,
            store: app.credentialStore
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("MODEL")
                    // displayedKinds, not kinds: the Local row is hidden on
                    // iOS (loopback Ollama is unreachable on-device — see
                    // SettingsModel.displayedKinds).
                    ForEach(model.displayedKinds, id: \.self) { kind in
                        providerCard(kind)
                    }

                    sectionLabel("PRIVACY")
                        .padding(.top, 18)
                    Text("No telemetry, no accounts. Books, highlights, notes and questions stay on this device; questions leave it only when you choose a cloud model.")
                        .font(.system(size: 11.5))
                        .lineSpacing(4)
                        .foregroundStyle(theme.faint)
                    Text("API keys are stored in your device Keychain. "
                         + "Local models stay on-device.")
                        .font(.system(size: 11.5))
                        .lineSpacing(4)
                        .foregroundStyle(theme.faint)
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("AI Providers")
            .task { model.refresh() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Provider error",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(theme.faint)
            .padding(.bottom, 2)
    }

    // MARK: Provider cards

    @ViewBuilder
    private func providerCard(_ kind: ProviderInfo.Kind) -> some View {
        let isConfigured = model.configured[kind] ?? false

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isConfigured ? Color.green.opacity(0.85) : theme.faint.opacity(0.55))
                    .frame(width: 8, height: 8)
                Text(title(for: kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                badge(for: kind)
                Spacer(minLength: 0)
                if isConfigured {
                    Button("Disconnect", role: .destructive) { model.disconnect(kind) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
            }

            Text(isConfigured ? "Connected" : "Not connected")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)

            if kind != .local {
                APIKeyField(kind: kind, theme: theme) { model.saveAPIKey($0, for: kind) }
                // First-run users stall at the key field with no idea where
                // keys come from — link straight to the provider's console.
                if let console = keyConsole(for: kind) {
                    Link(destination: console.url) {
                        Label("Get an API key", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.muted)
                    }
                    .accessibilityIdentifier("settings.getKey.\(console.slug)")
                }
                if model.supportsOAuth(kind) {
                    Button {
                        Task { await model.signIn(kind) }
                    } label: {
                        if model.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Sign in with subscription", systemImage: "person.badge.key")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sign in with subscription")
                    .disabled(model.isSigningIn)
                }
            }

            ModelPicker(
                kind: kind,
                models: model.models(for: kind),
                selection: model.activeSelection,
                enabled: isConfigured
            ) { modelID in
                model.makeActive(kind: kind, modelID: modelID)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
    }

    /// Small pill naming how this provider connects, derived from the flow it
    /// offers: keys for cloud providers, on-device for the local model.
    private func badge(for kind: ProviderInfo.Kind) -> some View {
        Text(kind == .local ? "Local" : "API key")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(theme.faint)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
    }

    /// The provider console where a key is created, or nil for kinds that
    /// don't use keys.
    private func keyConsole(for kind: ProviderInfo.Kind) -> (url: URL, slug: String)? {
        switch kind {
        case .anthropic:
            return (URL(string: "https://console.anthropic.com/settings/keys")!, "anthropic")
        case .openAI:
            return (URL(string: "https://platform.openai.com/api-keys")!, "openai")
        case .local:
            return nil
        }
    }

    private func title(for kind: ProviderInfo.Kind) -> String {
        switch kind {
        case .anthropic: return "Claude (Anthropic)"
        case .openAI: return "ChatGPT (OpenAI)"
        case .local: return "Local model (on-device)"
        }
    }
}

private struct APIKeyField: View {
    let kind: ProviderInfo.Kind
    let theme: ReadingTheme
    let onSave: (String) -> Void
    @State private var key = ""

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            SecureField("API key", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.inkColor)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
            Button {
                onSave(key)
                key = ""
            } label: {
                Text("Save")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.background)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(canSave ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save API key")
            .disabled(!canSave)
        }
    }
}

private struct ModelPicker: View {
    let kind: ProviderInfo.Kind
    let models: [ProviderInfo]
    let selection: ProviderSelection?
    let enabled: Bool
    let onSelect: (String) -> Void

    private var currentModelID: String {
        if let selection, selection.kind == kind { return selection.modelID }
        return models.first?.modelID ?? ""
    }

    var body: some View {
        Picker("Model", selection: Binding(
            get: { currentModelID },
            set: { onSelect($0) }
        )) {
            ForEach(models, id: \.modelID) { info in
                Text(info.modelID).tag(info.modelID)
            }
        }
        .font(.system(size: 12))
        .disabled(!enabled)
    }
}
