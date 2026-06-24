import SwiftUI
import ReadrKit

/// Provider settings (J5): connect Claude, ChatGPT, or a local model and pick
/// the active one. Per docs/AUTH.md, API keys are the default path; OAuth is an
/// opt-in "use your subscription" option.
struct ProviderSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel) {
        _model = StateObject(wrappedValue: SettingsModel(
            manager: app.providerManager,
            store: app.credentialStore
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(model.kinds, id: \.self) { kind in
                    Section(header: Text(title(for: kind))) {
                        providerSection(kind)
                    }
                }
                Section {
                    Text("API keys and tokens are stored in your device Keychain. "
                         + "Signing in with a Claude/ChatGPT subscription is optional and "
                         + "may be subject to the provider's terms. Local models stay on-device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
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

    @ViewBuilder
    private func providerSection(_ kind: ProviderInfo.Kind) -> some View {
        let isConfigured = model.configured[kind] ?? false

        HStack {
            Image(systemName: isConfigured ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(isConfigured ? .green : .secondary)
            Text(isConfigured ? "Connected" : "Not connected")
                .foregroundStyle(.secondary)
            Spacer()
            if isConfigured {
                Button("Disconnect", role: .destructive) { model.disconnect(kind) }
                    .buttonStyle(.borderless)
            }
        }

        if kind != .local {
            APIKeyField(kind: kind) { model.saveAPIKey($0, for: kind) }
            if model.supportsOAuth(kind) {
                Button {
                    Task { await model.signIn(kind) }
                } label: {
                    if model.isSigningIn {
                        ProgressView()
                    } else {
                        Label("Sign in with subscription", systemImage: "person.badge.key")
                    }
                }
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
    let onSave: (String) -> Void
    @State private var key = ""

    var body: some View {
        HStack {
            SecureField("API key", text: $key)
            Button("Save") {
                onSave(key)
                key = ""
            }
            .accessibilityLabel("Save API key")
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .disabled(!enabled)
    }
}
