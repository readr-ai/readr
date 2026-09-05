import SwiftUI
import ReadrKit

/// Provider settings (J5): connect Claude, OpenAI, OpenRouter or a local model
/// and pick the active one. Per docs/AUTH.md, API keys are the default path;
/// OAuth is an opt-in "use your subscription" option. Styled as the design's
/// Settings: caps section labels, cards on the elevated surface with a status
/// dot + badge, and the privacy footer.
///
/// One card per COMPANY, not per connection method: the ChatGPT subscription
/// and an OpenAI API key are two doors into the same account, and as two
/// sibling cards they read as two separate services (see `ProviderVendor`).
/// Inside a card each method keeps its own status, credential, and
/// Active/Make Active/Disconnect controls — only the presentation is merged.
///
/// Every action here wears a filled or bordered pill (`CardActionLabel`).
/// They used to be bare muted captions, which left no sign of what was
/// tappable; the card now also opens with a line saying what to do.
///
/// A2/A3: each method mirrors `ProviderManager.validate(_:)` — a stored remote
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

    @State private var showingBugReport = false
    @State private var showingOpenRouterPicker = false

    init(app: AppModel) {
        _model = StateObject(wrappedValue: SettingsModel(
            manager: app.providerManager,
            store: app.credentialStore,
            openRouterStore: app.openRouterModelStore
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("MODEL")
                    // One card per company, not per connection method: the
                    // ChatGPT subscription and an OpenAI API key are two doors
                    // into the same account and used to sit here as two
                    // sibling cards (see ProviderVendor). Vendors and their
                    // methods are both filtered to what this build exposes —
                    // no Local row on iOS, no ChatGPT sign-in on iOS.
                    ForEach(model.displayedVendors) { vendor in
                        vendorCard(vendor)
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

                    sectionLabel("HELP")
                        .padding(.top, 18)
                    helpSection
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
            .navigationTitle("Settings")
            .task {
                model.refresh()
                // Verify stored keys / probe Ollama so the cards reflect real
                // readiness rather than a premature "Connected".
                await model.validateDisplayed()
            }
            .task {
                // The OpenRouter catalogue, alongside validation rather than
                // after it — the picker row shows the current model's price
                // as soon as the list is in.
                await model.loadOpenRouterModels()
            }
            .sheet(isPresented: $showingOpenRouterPicker) {
                OpenRouterModelPickerView(model: model, theme: theme)
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

    // MARK: Help

    /// Reporting a bug (#41) and passing Readr on (#40). Both were missing
    /// entirely: the EPUB bugs this cycle were only caught by manual
    /// screenshots because a reader had no way to tell us anything.
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                showingBugReport = true
            } label: {
                helpRow(
                    "Report a bug",
                    detail: "Send what went wrong, with app and device details attached.",
                    systemImage: "ladybug"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.reportBug")

            theme.line.frame(height: 1)

            ShareLink(item: ReadrShare.joinURL, message: Text(ReadrShare.message)) {
                helpRow(
                    "Share Readr",
                    detail: "Send someone the free beta.",
                    systemImage: "square.and.arrow.up"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.shareReadr")

            Text(versionLine)
                .font(.caption2)
                .foregroundStyle(theme.faint)
                .padding(.top, 2)
                .accessibilityIdentifier("settings.version")
        }
        .sheet(isPresented: $showingBugReport) {
            ReportBugView(log: .shared)
        }
    }

    private func helpRow(
        _ title: String, detail: String, systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.inkColor)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.faint)
        }
        .contentShape(Rectangle())
    }

    /// Shown so a reader filing a report can quote it even if they'd rather
    /// not send diagnostics.
    private var versionLine: String {
        let environment = BugReportEnvironment.current
        return "Readr \(environment.appVersion) (\(environment.build)) — \(environment.osVersion)"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(theme.faint)
            .padding(.bottom, 2)
    }

    // MARK: Provider cards

    private func vendorCard(_ vendor: ProviderVendor) -> some View {
        let pickerKind = modelPickerKind(for: vendor)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vendorDotColor(vendor))
                    .frame(width: 8, height: 8)
                Text(vendor.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.inkColor)
                badge(vendor.badge)
                Spacer(minLength: 0)
            }

            // What to do here, said plainly. Without it the card states a
            // problem ("Not connected") and leaves the reader to infer that
            // the greyed-out field below is the fix — reported as "there's no
            // indication to show where we should click".
            if let hint = connectHint(vendor) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.hint.\(vendor.id)")
            }

            ForEach(Array(vendor.methods.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    // Two ways into one account read as one card with a seam,
                    // not as two cards.
                    theme.line.frame(height: 1).padding(.vertical, 2)
                }
                method(kind, in: vendor)
            }

            let pickerEnabled = vendor.methods.contains {
                (model.hasCredential[$0] ?? false) || $0.isOnDevice
            }
            if pickerKind == .openRouter {
                // OpenRouter's list is live and hundreds long — a menu can't
                // hold it. The row names the current model and its price and
                // opens the searchable picker sheet.
                OpenRouterModelRow(
                    model: currentOpenRouterModel,
                    modelID: currentOpenRouterModelID,
                    enabled: pickerEnabled,
                    theme: theme
                ) {
                    showingOpenRouterPicker = true
                }
            } else if pickerKind != .appleIntelligence {
                // The on-device model is whatever the OS ships — one entry,
                // nothing to pick, and its id is not a name anyone chose.
                ModelPicker(
                    kind: pickerKind,
                    models: model.models(for: pickerKind),
                    selection: model.activeSelection,
                    enabled: pickerEnabled
                ) { modelID in
                    model.makeActive(kind: pickerKind, modelID: modelID)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.card.\(vendor.id)")
    }

    /// One connection method inside a vendor card: its own status, its own
    /// controls, and its own Active/Make Active/Disconnect — the kinds stay
    /// independently connected and activated even though they share a card.
    ///
    /// A method with a stored credential is *connected*, and a connected
    /// method drops its connect controls: no sign-in button, no key field, no
    /// console link — just the status line (with the Active badge or Make
    /// Active), Disconnect, and the card's model picker. An OpenRouter card
    /// that still said "Sign in" over a live key read as not connected. The
    /// one exception is a rejected key (`.invalid`): the key field comes
    /// back so the reader can replace it, with Disconnect still beside it.
    @ViewBuilder
    private func method(_ kind: ProviderInfo.Kind, in vendor: ProviderVendor) -> some View {
        let isConfigured = model.configured[kind] ?? false
        // Present ≠ verified: a key that failed a live check must stay
        // removable and re-pointable, so these two controls key off storage.
        let hasCredential = model.hasCredential[kind] ?? false
        let state = model.validation[kind]
        let status = cardStatus(for: kind, isConfigured: isConfigured, state: state)
        let isRejected: Bool = {
            if case .invalid = state { return true }
            return false
        }()
        let showsSignIn = !hasCredential
        let showsKeyField = !hasCredential || isRejected

        VStack(alignment: .leading, spacing: 10) {
            // Only when the card offers a choice — a lone method needs no
            // label to distinguish it from itself. On its own line, not
            // inline: the status row already has to fit a badge, Make Active
            // and Disconnect on a phone.
            if vendor.hasMultipleMethods {
                Text(methodLabel(for: kind))
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.faint)
            }
            HStack(spacing: 8) {
                statusLine(status)
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
                if hasCredential {
                    Button("Disconnect", role: .destructive) { model.disconnect(kind) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if kind == .downloadedModel {
                #if os(iOS)
                DownloadedModelControls(
                    modelID: currentDownloadedModelID, theme: theme,
                    onChange: { Task { await model.validate(kind) } }
                )
                #endif
            }
            if kind.isOnDevice {
                // A manual re-check for when the reader has just started
                // Ollama or pulled the model, or switched Apple Intelligence
                // on (mirrors the mockup's "Check again"). Re-probes and
                // refreshes the status inline.
                Button {
                    Task { await model.validate(kind) }
                } label: {
                    CardActionLabel(
                        title: "Check again",
                        systemImage: "arrow.clockwise",
                        theme: theme
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.recheck.\(kind.rawValue)")
                .disabled(state == .validating)
            } else {
                if showsSignIn, model.supportsOAuth(kind) {
                    Button {
                        Task { await model.signIn(kind) }
                    } label: {
                        if model.signingInKind == kind {
                            ProgressView().controlSize(.small)
                        } else {
                            // Prominent: signing in is the fastest way to a
                            // working provider, so it should look like the
                            // button it is.
                            CardActionLabel(
                                title: signInLabel(for: kind),
                                systemImage: "person.badge.key",
                                theme: theme,
                                prominent: true
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(signInLabel(for: kind))
                    .disabled(model.isSigningIn)
                    // The subscription path rides an unofficial client — say
                    // so up front instead of surprising the reader later
                    // (docs/AUTH.md ToS caveat; keep the key path primary).
                    if kind == .chatGPT {
                        Text("Uses your ChatGPT subscription. This unofficial path may be subject to OpenAI's terms.")
                            .font(.caption2)
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.tosCaveat.chatgpt")
                    }
                }
                if showsKeyField, kind.usesAPIKey {
                    APIKeyField(kind: kind, theme: theme) { model.saveAPIKey($0, for: kind) }
                    // First-run users stall at the key field with no idea where
                    // keys come from — link straight to the provider's console.
                    // macOS only: on iOS an outbound link to a page where the
                    // user can buy API credits is an App Review liability
                    // (Guideline 3.1.1 — purchases outside IAP), and the App
                    // Store build must not carry it. Not on a rejected-key
                    // card: the reader has a key, it just isn't accepted.
                    #if os(macOS)
                    if showsSignIn, let console = keyConsole(for: kind) {
                        Link(destination: console.url) {
                            CardActionLabel(
                                title: "Get an API key",
                                systemImage: "arrow.up.right.square",
                                theme: theme
                            )
                        }
                        // Plain, so the pill keeps its own colours instead of
                        // the platform's blue link tint.
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.getKey.\(console.slug)")
                    }
                    #endif
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The downloadable model the card's controls act on: the active
    /// selection when it is one, else the best model this device can hold.
    private var currentDownloadedModelID: String {
        if let selection = model.activeSelection, selection.kind == .downloadedModel {
            return selection.modelID
        }
        return model.defaultModelID(for: .downloadedModel)
    }

    /// The OpenRouter id the picker row names: the active selection when it
    /// is an OpenRouter one, else the catalog default (what Make Active
    /// would choose).
    private var currentOpenRouterModelID: String {
        if let selection = model.activeSelection, selection.kind == .openRouter {
            return selection.modelID
        }
        return ProviderCatalog.defaultModel(for: .openRouter).modelID
    }

    /// Name and price for the row — the live list first, the curated table
    /// offline, nil for an id the app has no data on (the row then shows the
    /// bare id).
    private var currentOpenRouterModel: OpenRouterModel? {
        model.openRouterModel(id: currentOpenRouterModelID)
    }

    /// Names one door into a vendor, used only on cards that offer more than
    /// one.
    private func methodLabel(for kind: ProviderInfo.Kind) -> String {
        switch kind {
        case .chatGPT: return "SUBSCRIPTION"
        case .openRouter: return "SIGN IN OR KEY"
        case .anthropic, .openAI: return "API KEY"
        case .local, .appleIntelligence, .downloadedModel: return "ON-DEVICE"
        }
    }

    /// A single sentence telling a disconnected card what to do, phrased from
    /// the methods it actually offers. Nil once something is connected (the
    /// status line takes over) and for Local, whose readiness is a probe
    /// rather than a thing the reader supplies.
    private func connectHint(_ vendor: ProviderVendor) -> String? {
        guard !vendor.methods.contains(where: { model.hasCredential[$0] ?? false }) else {
            return nil
        }
        let signIn = vendor.methods.contains(where: \.offersSignIn)
        let key = vendor.methods.contains(where: \.usesAPIKey)
        switch (signIn, key) {
        case (true, true):
            return "Sign in to use your existing subscription, or paste an API key."
        case (true, false):
            return "Sign in to connect."
        case (false, true):
            return "Paste an API key to connect."
        case (false, false):
            switch vendor.methods {
            case [.appleIntelligence]:
                return "Apple's on-device model. Nothing to set up, nothing leaves your device."
            case [.downloadedModel]:
                return "A stronger model that runs on this iPhone after a one-time download. Private and free; slower than the cloud."
            default:
                return nil
            }
        }
    }

    /// Which method's model list the card's picker shows. The active method
    /// wins so the picker always reflects what Ask will use; otherwise the
    /// first connected one, else the vendor's primary method.
    private func modelPickerKind(for vendor: ProviderVendor) -> ProviderInfo.Kind {
        if let active = model.activeKind, vendor.methods.contains(active) { return active }
        if let connected = vendor.methods.first(where: { model.hasCredential[$0] ?? false }) {
            return connected
        }
        return vendor.methods[0]
    }

    /// The card's dot: green once any of its methods is usable; otherwise the
    /// state of the first method that has a credential to be unhappy about
    /// (red for a rejected key, amber for a transient failure); grey while
    /// nothing is connected at all.
    private func vendorDotColor(_ vendor: ProviderVendor) -> Color {
        var fallback: Color?
        for kind in vendor.methods {
            let status = cardStatus(
                for: kind,
                isConfigured: model.configured[kind] ?? false,
                state: model.validation[kind]
            )
            if status.isConnected { return status.dotColor }
            if model.hasCredential[kind] ?? false, fallback == nil {
                fallback = status.dotColor
            }
        }
        return fallback ?? theme.faint.opacity(0.55)
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
    /// choice to preserve). Sits in the same slot as the Active badge it
    /// produces, so the control and its result read as one affordance.
    private func makeActiveButton(for kind: ProviderInfo.Kind) -> some View {
        Button {
            model.makeActive(kind: kind, modelID: model.defaultModelID(for: kind))
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

    /// The per-provider sign-in button title — also the accessibility label
    /// the UI tests assert.
    private func signInLabel(for kind: ProviderInfo.Kind) -> String {
        switch kind {
        case .chatGPT: return "Sign in with ChatGPT"
        case .openRouter: return "Sign in with OpenRouter"
        case .anthropic, .openAI, .local, .appleIntelligence, .downloadedModel: return "Sign in with subscription"
        }
    }

    /// Small pill naming how this vendor connects. The text comes from
    /// `ProviderVendor.badge`, which derives it from the methods actually on
    /// offer, so a gated-off path is never advertised.
    private func badge(_ label: String) -> some View {
        Text(label)
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
        case .openRouter:
            return (URL(string: "https://openrouter.ai/keys")!, "openrouter")
        case .chatGPT, .local, .appleIntelligence, .downloadedModel:
            // ChatGPT connects by subscription sign-in only; the on-device
            // kinds need no key.
            return nil
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
        /// Usable right now — what the vendor dot goes green for.
        var isConnected: Bool
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
                text: kind == .local ? "Checking Ollama…"
                    : kind.isOnDevice ? "Checking this device…" : "Validating…",
                textColor: theme.muted,
                dotColor: theme.faint.opacity(0.55),
                showsSpinner: true,
                isActive: false,
                isConnected: false
            )
        case .active:
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: "Connected",
                textColor: theme.muted,
                dotColor: green,
                showsSpinner: false,
                isActive: isActive,
                isConnected: true
            )
        case let .invalid(reason):
            return CardStatus(
                kindRawValue: kind.rawValue,
                text: reason ?? "Not connected",
                textColor: .red,
                dotColor: .red.opacity(0.85),
                showsSpinner: false,
                isActive: false,
                isConnected: false
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
                isActive: false,
                isConnected: false
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
                isActive: isActive,
                isConnected: isConfigured
            )
        }
    }
}

/// The look of a tappable action inside a provider card.
///
/// These used to be bare `Label`s in muted caption grey with
/// `.buttonStyle(.plain)` — indistinguishable from the explanatory captions
/// beside them, so the screen gave no sign of where to click (user-reported).
/// They now carry a filled or bordered shape, which is the only thing that
/// says "control" rather than "text".
///
/// `prominent` is the ink-filled treatment, for the one action that connects
/// a provider fastest; everything else is bordered and quieter, so a card
/// never shows two primary buttons.
private struct CardActionLabel: View {
    let title: String
    let systemImage: String
    let theme: ReadingTheme
    var prominent = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(prominent ? theme.background : theme.inkColor)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background {
                if prominent {
                    Capsule().fill(theme.inkColor)
                } else {
                    Capsule().fill(theme.paper)
                }
            }
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(theme.line, lineWidth: 1)
                }
            }
            // The whole pill is the hit target, not just the glyphs.
            .contentShape(Capsule())
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

/// The OpenRouter card's model control: the current model's name with its
/// price beneath, as a tappable row that opens `OpenRouterModelPickerView`.
/// A `Picker` menu of the catalogue's four hundred rows would be unusable,
/// and it could not show prices.
private struct OpenRouterModelRow: View {
    let model: OpenRouterModel?
    let modelID: String
    let enabled: Bool
    let theme: ReadingTheme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model?.name ?? modelID)
                        .font(.callout)
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(1)
                    Text(model?.priceLabel ?? modelID)
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel("Model")
        .accessibilityValue(model?.name ?? modelID)
        .accessibilityIdentifier("settings.model.openRouter")
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
                Text(DownloadedModelCatalog.spec(for: info.modelID)?.displayName ?? info.modelID).tag(info.modelID)
            }
        }
        .font(.callout)
        .disabled(!enabled)
    }
}


#if os(iOS)
/// The downloaded-model card's own controls: what a Download costs before it
/// starts (App Review 4.2.3(ii)), its progress with a Cancel, Delete
/// afterwards, and a plain retry — the Hub client resumes partial blobs, so
/// a failed download never starts from zero.
private struct DownloadedModelControls: View {
    let modelID: String
    let theme: ReadingTheme
    /// Fired when the model's state settles (downloaded, deleted, failed,
    /// cancelled) so the card re-validates.
    let onChange: () -> Void

    @ObservedObject private var store = MLXModelStore.shared

    private var spec: DownloadedModelSpec? { DownloadedModelCatalog.spec(for: modelID) }

    var body: some View {
        // Read once per body: the state may come from a directory scan.
        let state = store.state(for: modelID)
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .notDownloaded:
                Button {
                    store.download(modelID)
                } label: {
                    CardActionLabel(
                        title: "Download \(spec?.displayName ?? "model") · \(spec?.downloadSizeDescription ?? "")",
                        systemImage: "arrow.down.circle", theme: theme, prominent: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.download.model")
                Text("A one-time download of about \(spec?.downloadSizeDescription ?? "a few GB") — best on Wi-Fi. It stays on this device until you delete it here.")
                    .font(.caption2)
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            case .downloading(let fraction):
                HStack(spacing: 12) {
                    ProgressView(value: fraction) {
                        Text("Downloading \(spec?.displayName ?? "model")… \(Int(fraction * 100))%")
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                    }
                    .tint(theme.iris)
                    .accessibilityIdentifier("settings.download.progress")
                    Button("Cancel") { store.cancelDownload(modelID) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                        .accessibilityIdentifier("settings.download.cancel")
                }
            case .downloaded:
                HStack(spacing: 12) {
                    Text("Downloaded · \(spec?.downloadSizeDescription ?? "")")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                    Button("Delete", role: .destructive) { store.delete(modelID) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.download.delete")
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.dismissFailure(modelID)
                    store.download(modelID)
                } label: {
                    CardActionLabel(title: "Try again", systemImage: "arrow.clockwise", theme: theme)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: state) { _, _ in onChange() }
    }
}
#endif
