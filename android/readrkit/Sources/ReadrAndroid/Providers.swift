import Foundation
import ReadrKit

/// Whether the phone's own model (Gemini Nano, through AICore) can answer a
/// question right now — asked of Kotlin, which is the only side that can see
/// AICore.
///
/// One string rather than three methods, because a bridged protocol method
/// may not throw and may not return an optional: `"ready"`,
/// `"unavailable:<reason>"` (fixable or temporary — still downloading, AICore
/// updating) or `"unsupported:<reason>"` (this phone can never run it). The
/// reason is a sentence the reader sees, so it is written on the Kotlin side
/// where the platform detail is known.
public protocol OnDeviceProbe {
  func readiness() -> String
}

/// The probe as the kit's `OnDeviceReadinessReporting` wants it: `Sendable`,
/// and speaking `OnDeviceReadiness` rather than a wire string.
///
/// `@unchecked`: the Kotlin object behind it is a plain, stateless reader of
/// `PackageManager`; the same bargain `SecretCredentialStore` makes.
final class OnDeviceProbeBox: @unchecked Sendable {
  private let probe: any OnDeviceProbe

  init(_ probe: any OnDeviceProbe) { self.probe = probe }

  /// Parses the wire string. Anything unrecognised is `unsupported` — a
  /// probe that cannot say what it means must not leave the reader on a
  /// provider that can only fail.
  var readiness: OnDeviceReadiness {
    let answer = probe.readiness()
    if answer == "ready" { return .ready }
    let parts = answer.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let reason = parts.count == 2
      ? String(parts[1]).trimmingCharacters(in: .whitespaces)
      : "Gemini Nano isn't available on this phone."
    switch parts.first {
    case "unavailable": return .unavailable(reason: reason)
    default: return .unsupported(reason: reason)
    }
  }

  var isReady: Bool { readiness == .ready }
}

/// Stands in for the real Gemini Nano provider until A3c wires ML Kit's GenAI
/// APIs up: it reports the phone's readiness (which is what Settings needs to
/// show the card honestly) and refuses to answer.
///
/// A refusal here is a *sentence*, not a crash: `ProviderManager.validate`
/// only ever asks it for `readiness()`, but Ask could still reach `stream`
/// while the card says "ready" on a phone whose model this build cannot yet
/// drive.
struct PlaceholderOnDeviceProvider: LLMProvider, OnDeviceReadinessReporting {
  let info: ProviderInfo
  let probe: OnDeviceProbeBox

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(throwing: AndroidBridgeError.onDeviceModelNotReady)
    }
  }

  func countTokens(_ text: String) throws -> Int { TokenCounter.estimate(text) }

  func readiness() async -> OnDeviceReadiness { probe.readiness }
}

// MARK: - The JSON Settings renders

/// One selectable model on a card.
struct ProviderModelRow: Codable {
  var id: String
  var name: String
  var contextBudget: Int
}

/// The last thing a validation said about a kind. `state` is one of
/// `validating`, `active`, `invalid`, `unavailable`, `unknown` (never
/// checked); `reason` is the kit's reader-facing sentence when there is one.
struct ProviderStatusSummary: Codable {
  var state: String
  var reason: String?

  init(_ state: ProviderManager.ValidationState?) {
    switch state {
    case .validating: self.state = "validating"
    case .active: self.state = "active"
    case .invalid(let reason): self.state = "invalid"; self.reason = reason
    case .unavailable(let reason): self.state = "unavailable"; self.reason = reason
    case nil: self.state = "unknown"
    }
  }
}

/// One connection method inside a card.
struct ProviderKindCard: Codable {
  var kind: String
  /// What this door into the vendor is called, the way iOS's `methodLabel`
  /// says it ("API KEY", "ON-DEVICE") — shown only on a card that offers
  /// more than one, which none do on Android today.
  var displayName: String
  var usesAPIKey: Bool
  var isOnDevice: Bool
  var hasCredential: Bool
  var isActive: Bool
  var status: ProviderStatusSummary
  var models: [ProviderModelRow]
  /// The model the picker should show selected: the active selection's when
  /// this kind holds it, else what "Make active" would choose.
  var activeModelID: String
}

/// One company's card.
struct ProviderVendorCard: Codable {
  var id: String
  var title: String
  var badge: String
  /// What to do here while nothing is connected, or nil once something is.
  var hint: String?
  var kinds: [ProviderKindCard]
}

struct ProviderSettingsPayload: Codable {
  var askUsesLine: String
  var selection: ProviderSelection?
  var vendors: [ProviderVendorCard]
}

// MARK: - The facade

/// AI provider settings for the Android app: which models this phone can
/// reach, which one Ask uses, and the keys that unlock them.
///
/// Everything structured crosses as JSON and every sentence in it is the
/// kit's, so the Kotlin screen writes no reader-facing copy of its own.
public final class AndroidProviders {

  /// The connection methods this build has. ChatGPT's subscription path and
  /// Ollama are deliberately absent: the first rides an unofficial backend
  /// (docs/AUTH.md), the second would point at a loopback server no phone
  /// runs. Apple's on-device model is not a thing an Android phone has.
  static let supportedKinds: [ProviderInfo.Kind] = [.anthropic, .openAI, .openRouter, .geminiNano]

  private let root: URL
  private let credentialStore: SecretCredentialStore
  private let probe: OnDeviceProbeBox
  let manager: ProviderManager
  private let openRouterStore: OpenRouterModelStore
  /// The OpenRouter list the picker shows — the curated slice until
  /// `refreshOpenRouterModels()` brings the live (or disk-cached) one.
  private let lock = NSLock()
  private var _openRouterModels: [OpenRouterModel] = ProviderCatalog.openRouterCurated

  /// Where the active selection is remembered. `ProviderManager` persists
  /// through `UserDefaults`, which on Android is a plist in a directory
  /// nobody owns; the library root is the app's own storage, and it is where
  /// every other Readr file already lives.
  private var selectionFile: URL { root.appendingPathComponent("provider-selection.json") }

  public init(store: any SecretStore, rootDirectory: String, probe: any OnDeviceProbe) {
    let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    self.root = root
    credentialStore = SecretCredentialStore(store: store)
    let probeBox = OnDeviceProbeBox(probe)
    self.probe = probeBox

    let remote = DefaultProviderFactory.factory(http: URLSessionHTTPClient())
    let factory: ProviderManager.ProviderFactory = { info, credentials in
      // The phone's own model is not the kit's to build — AICore is an
      // Android API — so the facade supplies it and the default factory
      // handles every kind that speaks HTTP.
      guard info.kind == .geminiNano else { return try remote(info, credentials) }
      return PlaceholderOnDeviceProvider(info: info, probe: probeBox)
    }

    let stored = Self.readSelection(root.appendingPathComponent("provider-selection.json"))
    manager = ProviderManager(
      store: credentialStore,
      factory: factory,
      selection: stored,
      persistingIn: nil,
      // The phone's own model is the answer while the reader has chosen
      // nothing — but only while the phone can actually run it. Resolved on
      // every read, never written down: the day AICore goes away the reader
      // is back to "nothing chosen" rather than pinned to a dead selection.
      defaultSelection: { probeBox.isReady ? ProviderSelection(kind: .geminiNano, modelID: ProviderCatalog.defaultModel(for: .geminiNano).modelID) : nil },
      supportedKinds: Set(Self.supportedKinds))
    openRouterStore = OpenRouterModelStore(
      cacheURL: root.appendingPathComponent("OpenRouterModels.json"))
  }

  // MARK: Reading

  /// Everything the settings screen draws, in one answer: the line naming
  /// what Ask uses, the active selection, and a card per vendor.
  public func providersJSON() -> String {
    let payload = ProviderSettingsPayload(
      askUsesLine: askUsesLine(),
      selection: manager.selection,
      vendors: ProviderVendor.displayed(forKinds: Self.supportedKinds).map(card(for:)))
    guard let data = try? AndroidLibrary.encoder().encode(payload) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Whether Ask has a model to put a question to — an active selection this
  /// build supports, with whatever it needs to run.
  public func hasAnyProvider() -> Bool {
    guard let selection = manager.selection else { return false }
    return manager.isConfigured(selection.kind)
  }

  // MARK: Writing

  /// Store an API key for `kind` and forget whatever the last check said
  /// about it — the new key is unproven, and a stale "Connected" would
  /// otherwise stand until the caller's `validate` settles.
  public func saveAPIKey(_ kind: String, apiKey: String) throws {
    try readerFacing {
      let k = try self.kind(kind)
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw AndroidBridgeError.emptyAPIKey }
      try credentialStore.save(.apiKey(trimmed), for: k)
      manager.clearValidation(k)
    }
  }

  public func deleteCredential(_ kind: String) throws {
    try readerFacing {
      let k = try self.kind(kind)
      try credentialStore.delete(for: k)
      // A deleted key must not linger as ".active", or the card stays
      // "Connected" and `activeProvider()` would still resolve it.
      manager.clearValidation(k)
    }
  }

  /// Check that a kind is actually usable — a one-token authenticated call
  /// for a cloud key, the phone's probe for the on-device model — and report
  /// where it landed.
  public func validate(_ kind: String) async throws -> String {
    try await readerFacing {
      let k = try self.kind(kind)
      _ = await manager.validate(k)
      // Re-read rather than trust the return value: a key saved mid-flight
      // discards this run's result, and the manager holds the fresh state.
      return self.statusJSON(manager.validationState(k))
    }
  }

  /// Make `kind` + `modelID` the selection Ask uses, and remember it.
  public func setActive(_ kind: String, modelID: String) throws {
    try readerFacing {
      let k = try self.kind(kind)
      let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
      manager.setActive(kind: k, modelID: id.isEmpty ? nil : id)
      writeSelection(manager.explicitSelection)
    }
  }

  /// Bring in OpenRouter's catalogue — the disk copy while it is fresh, the
  /// network otherwise, the curated slice when there is neither — and hand
  /// back the rows the picker should now show.
  public func refreshOpenRouterModels() async throws -> String {
    try await readerFacing {
      let loaded = await openRouterStore.load()
      remember(loaded.models)
      guard let data = try? AndroidLibrary.encoder().encode(self.models(for: .openRouter)) else { return "[]" }
      return String(decoding: data, as: UTF8.self)
    }
  }

  // MARK: Building the cards

  /// Which model Ask is actually using, in one line: "Ask uses Claude Opus 5
  /// · Claude (Anthropic)". Connected means usable — a rejected key or a
  /// phone that cannot run Nano adds "— not connected", the way the card's
  /// dot goes red. `SettingsModel.askUsesLine` on the Apple side.
  private func askUsesLine() -> String {
    guard let selection = manager.selection else {
      return "Ask uses no model yet — connect one below."
    }
    return "Ask uses " + selection.summary(connected: manager.isConfigured(selection.kind))
  }

  private func card(for vendor: ProviderVendor) -> ProviderVendorCard {
    ProviderVendorCard(
      id: vendor.id,
      title: vendor.title,
      badge: badge(for: vendor),
      hint: hint(for: vendor),
      kinds: vendor.methods.map(card(for:)))
  }

  private func card(for kind: ProviderInfo.Kind) -> ProviderKindCard {
    let selection = manager.selection
    let isConfigured = manager.isConfigured(kind)
    return ProviderKindCard(
      kind: kind.rawValue,
      displayName: methodLabel(for: kind),
      usesAPIKey: kind.usesAPIKey,
      isOnDevice: kind.isOnDevice,
      hasCredential: manager.hasStoredCredential(kind),
      // Active only when this card holds the selection AND it is usable —
      // the same test the Apple card's badge makes.
      isActive: selection?.kind == kind && isConfigured,
      status: ProviderStatusSummary(manager.validationState(kind)),
      models: models(for: kind),
      activeModelID: selection?.kind == kind
        ? selection!.modelID
        : ProviderCatalog.defaultModel(for: kind).modelID)
  }

  /// Keep the list a load brought in. Its own method so the lock is never
  /// held across an `await` — a suspension with a mutex held is an error in
  /// the Swift 6 language mode, and a deadlock in any of them.
  private func remember(_ models: [OpenRouterModel]) {
    lock.lock(); defer { lock.unlock() }
    _openRouterModels = models
  }

  private func models(for kind: ProviderInfo.Kind) -> [ProviderModelRow] {
    guard kind == .openRouter else {
      return ProviderCatalog.models(for: kind).map {
        ProviderModelRow(id: $0.modelID, name: $0.name, contextBudget: $0.contextBudget)
      }
    }
    // OpenRouter's catalogue is live: `resolve` carries the budget the store
    // registered for each id, and the row's own name.
    lock.lock()
    let live = _openRouterModels
    lock.unlock()
    return live.map { model in
      ProviderModelRow(
        id: model.id,
        name: model.name,
        contextBudget: ProviderCatalog.resolve(modelID: model.id, for: .openRouter).contextBudget)
    }
  }

  /// The card's pill. `ProviderVendor.badge` derives it from the methods on
  /// offer, and counts a browser sign-in among them — which this build does
  /// not have yet (A3 offers keys only), so OpenRouter would advertise a door
  /// that isn't there. Everything else is the vendor's own badge.
  private func badge(for vendor: ProviderVendor) -> String {
    guard vendor.methods.contains(where: \.offersSignIn) else { return vendor.badge }
    return vendor.methods.contains(where: \.usesAPIKey) ? "API key" : vendor.badge
  }

  /// A single sentence telling a disconnected card what to do — phrased from
  /// what this build offers, so it never names sign-in. Nil once something is
  /// connected: the status line takes over.
  private func hint(for vendor: ProviderVendor) -> String? {
    guard !vendor.methods.contains(where: { manager.hasStoredCredential($0) }) else { return nil }
    if vendor.methods.contains(where: \.usesAPIKey) { return "Paste an API key to connect." }
    guard vendor.methods.allSatisfy(\.isOnDevice) else { return nil }
    return "The model built into this phone. Nothing to set up, nothing leaves your phone."
  }

  /// Names one door into a vendor — derived from what the method is, as the
  /// Apple screen's `methodLabel` does.
  private func methodLabel(for kind: ProviderInfo.Kind) -> String {
    if kind.isOnDevice { return "ON-DEVICE" }
    if kind == .chatGPT { return "SUBSCRIPTION" }
    return kind.offersSignIn ? "SIGN IN OR KEY" : "API KEY"
  }

  private func statusJSON(_ state: ProviderManager.ValidationState?) -> String {
    guard let data = try? AndroidLibrary.encoder().encode(ProviderStatusSummary(state)) else {
      return "{\"state\":\"unknown\"}"
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func kind(_ raw: String) throws -> ProviderInfo.Kind {
    guard let kind = ProviderInfo.Kind(rawValue: raw), Self.supportedKinds.contains(kind) else {
      throw AndroidBridgeError.unknownProviderKind(raw)
    }
    return kind
  }

  // MARK: Selection persistence

  private static func readSelection(_ file: URL) -> ProviderSelection? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    guard let selection = try? JSONDecoder().decode(ProviderSelection.self, from: data),
          supportedKinds.contains(selection.kind) else { return nil }
    return selection
  }

  private func writeSelection(_ selection: ProviderSelection?) {
    guard let selection, let data = try? JSONEncoder().encode(selection) else {
      try? FileManager.default.removeItem(at: selectionFile)
      return
    }
    try? data.write(to: selectionFile, options: .atomic)
  }
}
