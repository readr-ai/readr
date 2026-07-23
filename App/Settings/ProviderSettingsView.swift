import SwiftUI
import ReadrKit

/// Provider settings (J5): connect Claude, ChatGPT, or a local model and pick
/// the active one. Per docs/AUTH.md, API keys are the default path; OAuth is an
/// opt-in "use your subscription" option. Styled as the design's Settings:
/// caps section labels, provider cards on the elevated surface with a status
/// dot + badge, and the privacy footer.
///
/// A2/A3: each card mirrors `ProviderManager.validate(_:)` — a stored remote
/// key shows Validating… while it's checked and only reads "Connected" once
/// the test call succeeds; a rejected key or a down/unpopulated Ollama shows an
/// actionable message. A7: the currently-selected connected provider carries an
/// "Active" badge.
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
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(theme.faint)
                    Text("API keys are stored in your device Keychain. "
                         + "Local models stay on-device.")
                        .font(.caption)
                        .lineSpacing(4)
                        .foregroundStyle(theme.faint)
                }
                .padding(20)
                // Extra bottom air: on iPad's shorter form sheet the last
                // privacy line rested exactly on the fold, reading as a
                // mid-glyph clip (CI walk) rather than scrollable content.
                .padding(.bottom, 28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("AI Providers")
            .task {
                model.refresh()
                // Verify stored keys / probe Ollama so the cards reflect real
                // readiness rather than a premature "Connected".
                await model.validateDisplayed()
            }
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
            .font(.caption2.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(theme.faint)
            .padding(.bottom, 2)
    }

    // MARK: Provider cards

    @ViewBuilder
    private func providerCard(_ kind: ProviderInfo.Kind) -> some View {
        let isConfigured = model.configured[kind] ?? false
        let state = model.validation[kind]
        let status = cardStatus(for: kind, isConfigured: isConfigured, state: state)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 8, height: 8)
                Text(title(for: kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.inkColor)
                badge(for: kind)
                if status.isActive {
                    activeBadge(for: kind)
                } else if isConfigured {
                    // The explicit "use this provider" control (#45): the
                    // status dot reads as a radio button but is decorative,
                    // and the only other activation path — the model picker —
                    // is undiscoverable. This also gives users an in-app
                    // recovery from a stale selection without a relaunch.
                    makeActiveButton(for: kind)
                }
                Spacer(minLength: 0)
                if isConfigured {
                    Button("Disconnect", role: .destructive) { model.disconnect(kind) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            statusLine(status)

            if kind != .local {
                APIKeyField(kind: kind, theme: theme) { model.saveAPIKey($0, for: kind) }
                // First-run users stall at the key field with no idea where
                // keys come from — link straight to the provider's console.
                if let console = keyConsole(for: kind) {
                    Link(destination: console.url) {
                        Label("Get an API key", systemImage: "arrow.up.right.square")
                            .font(.caption)
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
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sign in with subscription")
                    .disabled(model.isSigningIn)
                }
            } else {
                // Local: a manual re-check for when the reader has just started
                // Ollama or pulled the model (mirrors the mockup's "Check
                // again"). Re-probes and refreshes the status inline.
                Button {
                    Task { await model.validate(kind) }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.recheck.local")
                .disabled(state == .validating)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.card.\(kind.rawValue)")
    }

    /// The status line under the title: a spinner + "Validating…" while a check
    /// is in flight, otherwise the connection/readiness sentence.
    @ViewBuilder
    private func statusLine(_ status: CardStatus) -> some View {
        HStack(spacing: 6) {
            if status.showsSpinner {
                ProgressView().controlSize(.small)
            }
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.textColor)
        }
        .accessibilityIdentifier("settings.status.\(status.kindRawValue)")
    }

    /// Capsule button on a configured-but-inactive card that makes it the
    /// active provider with the kind's catalog-default model (the selection
    /// is a single global pair, so an inactive kind has no stored model
    /// choice to preserve). Occupies the same header slot as the Active
    /// badge, so the control and the state it produces read as one
    /// affordance.
    private func makeActiveButton(for kind: ProviderInfo.Kind) -> some View {
        Button {
            model.makeActive(
                kind: kind,
                modelID: ProviderCatalog.defaultModel(for: kind).modelID
            )
        } label: {
            Text("Make Active")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.muted)
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.makeActive.\(kind.rawValue)")
    }

    /// The green "Active" pill on the currently-selected connected provider (A7).
    /// The id is kind-scoped so a test can prove the badge lives on the
    /// selected card only.
    private func activeBadge(for kind: ProviderInfo.Kind) -> some View {
        Text("Active")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.green)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .overlay(Capsule().strokeBorder(Color.green, lineWidth: 1))
            .accessibilityIdentifier("settings.activeBadge.\(kind.rawValue)")
    }

    /// Small pill naming how this provider connects, derived from the flow it
    /// offers: keys for cloud providers, on-device for the local model.
    private func badge(for kind: ProviderInfo.Kind) -> some View {
        Text(kind == .local ? "Local" : "API key")
            .font(.caption2.weight(.semibold))
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

    // MARK: - Card status derivation

    /// The visible state of one provider card, derived from whether it's
    /// configured, its `ValidationState`, and whether it's the active selection.
    private struct CardStatus {
        var kindRawValue: String
        var text: String
        var textColor: Color
        var dotColor: Color
        var showsSpinner: Bool
        var isActive: Bool
    }

    private func cardStatus(
        for kind: ProviderInfo.Kind,
        isConfigured: Bool,
        state: ProviderManager.ValidationState?
    ) -> CardStatus {
        // Active only when this card is the persisted selection AND it's usable.
        let isActive = (model.activeKind == kind) && isConfigured
        let green = Color.green.opacity(0.85)

        switch state {
        case .validating:
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: kind == .local ? "Checking Ollama…" : "Validating…",
                textColor: theme.muted,
                dotColor: theme.faint.opacity(0.55),
                showsSpinner: true,
                isActive: false
            )
        case .active:
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: "Connected",
                textColor: theme.muted,
                dotColor: green,
                showsSpinner: false,
                isActive: isActive
            )
        case let .invalid(reason):
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: reason ?? "Not connected",
                textColor: .red,
                dotColor: .red.opacity(0.85),
                showsSpinner: false,
                isActive: false
            )
        case let .unavailable(reason):
            // A transient failure (offline, rate-limit, provider outage, local
            // server down). The credential may still be good, so use a soft
            // amber "temporarily unavailable" tone rather than the red reject
            // style — Ask still tries optimistically and recovers on its own.
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: reason ?? "Temporarily unavailable",
                textColor: .orange,
                dotColor: .orange.opacity(0.85),
                showsSpinner: false,
                isActive: false
            )
        case .none:
            // Never validated this session: fall back to the stored-key
            // heuristic. Configured shows a neutral "Connected" until a live
            // validation settles it one way or the other.
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: isConfigured ? "Connected" : "Not connected",
                textColor: theme.muted,
                dotColor: isConfigured ? green : theme.faint.opacity(0.55),
                showsSpinner: false,
                isActive: isActive
            )
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
                .font(.callout)
                .foregroundStyle(theme.inkColor)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
                .accessibilityIdentifier("settings.apiKey.\(kind.rawValue)")
            Button {
                onSave(key)
                key = ""
            } label: {
                Text("Save")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(canSave ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save API key")
            .accessibilityIdentifier("settings.saveKey.\(kind.rawValue)")
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
        .font(.callout)
        .disabled(!enabled)
    }
}
