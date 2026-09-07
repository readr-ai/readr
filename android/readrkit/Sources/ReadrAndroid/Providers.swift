import Foundation
import ReadrKit

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
  /// The line under the card's title, written here so the screen renders what
  /// it is given: "Connected", "Not connected", or the kit's own sentence for
  /// a check that did not settle well.
  var statusLine: String
  /// What that line reads while a check this side started is still running —
  /// the kit has not been told about it yet, so it cannot be derived from
  /// `status`.
  var checkingLine: String
  var models: [ProviderModelRow]
  /// The model the picker should show selected: the active selection's when
  /// this kind holds it, else what "Make active" would choose. Resolved
  /// through the catalogue, so a retired id shows its replacement's name.
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
  /// What Ask will actually use — the reader's choice, else the phone's own
  /// model while it can run one.
  var selection: ProviderSelection?
  /// What the reader chose, ignoring that default. Nil until they pick, which
  /// is how the screen tells "nothing chosen" from "chosen for you".
  var explicitSelection: ProviderSelection?
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
  /// The phone's own model: what it says about itself, and what it answers.
  private let onDevice: OnDeviceModelBox
  /// Guards `_manager`, which is replaced when a disconnect has to drop the
  /// selection (see `disconnect(_:)`).
  private let managerLock = NSLock()
  private var _manager: ProviderManager

  var manager: ProviderManager {
    managerLock.lock(); defer { managerLock.unlock() }
    return _manager
  }

  private let openRouterStore: OpenRouterModelStore
  /// Where a cloud provider's requests actually go. Empty in every build a
  /// reader runs — see `overrideEndpoint(_:url:)` in `Ask.swift`.
  let endpointOverrides: EndpointOverrides
  /// The OpenRouter list the picker shows — the curated slice until the disk
  /// cache (at launch) or `refreshOpenRouterModels()` brings a longer one.
  private let lock = NSLock()
  private var _openRouterModels: [OpenRouterModel] = ProviderCatalog.openRouterCurated

  /// Where the active selection is remembered. `ProviderManager` persists
  /// through `UserDefaults`, which on Android is a plist in a directory
  /// nobody owns; the library root is the app's own storage, and it is where
  /// every other Readr file already lives.
  private var selectionFile: URL { root.appendingPathComponent("provider-selection.json") }

  public init(store: any SecretStore, rootDirectory: String, model: any OnDeviceModel) {
    let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
    self.root = root
    let credentials = SecretCredentialStore(store: store)
    credentialStore = credentials
    let modelBox = OnDeviceModelBox(model)
    onDevice = modelBox

    let overrides = EndpointOverrides()
    endpointOverrides = overrides
    let stored = Self.readSelection(root.appendingPathComponent("provider-selection.json"))
    _manager = Self.makeManager(
      store: credentials, overrides: overrides, model: modelBox, selection: stored)
    let store = OpenRouterModelStore(
      cacheURL: root.appendingPathComponent("OpenRouterModels.json"))
    openRouterStore = store

    // The catalogue the picker shows, and — more importantly — the budgets a
    // live-picked model's id needs, before Settings is ever opened: without
    // this a model chosen from the live list last week resolves as an unknown
    // id, shows as its id rather than its name, and routes on a guessed
    // budget. Off the caller's thread: it is a file read.
    let box = OpenRouterModelsBox(self)
    Task {
      let cached = await store.cachedModels()
      guard !cached.isEmpty else { return }
      box.remember(cached)
    }
  }

  /// One manager, however many times it has to be built. `persistingIn` is
  /// nil on purpose — see `persistingSelection`.
  private static func makeManager(
    store: SecretCredentialStore,
    overrides: EndpointOverrides,
    model: OnDeviceModelBox,
    selection: ProviderSelection?
  ) -> ProviderManager {
    let factory: ProviderManager.ProviderFactory = { info, credentials in
      // The phone's own model is not the kit's to build — AICore is an
      // Android API — so the facade supplies it and the default factory
      // handles every kind that speaks HTTP. The transport comes from
      // `EndpointOverrides`, which hands back one shared session unless a
      // test has pointed this kind somewhere else.
      guard info.kind == .geminiNano else {
        return try DefaultProviderFactory.make(
          info: info, credentials: credentials, http: overrides.client(for: info.kind))
      }
      return NanoProvider(info: info, model: model)
    }
    return ProviderManager(
      store: store,
      factory: factory,
      selection: selection,
      persistingIn: nil,
      // The phone's own model is the answer while the reader has chosen
      // nothing — but only while the phone can actually run it. Resolved on
      // every read, never written down: the day AICore goes away the reader
      // is back to "nothing chosen" rather than pinned to a dead selection.
      defaultSelection: {
        model.isReady
          ? ProviderSelection(
              kind: .geminiNano,
              modelID: ProviderCatalog.defaultModel(for: .geminiNano).modelID)
          : nil
      },
      supportedKinds: Set(Self.supportedKinds))
  }

  // MARK: Reading

  /// Everything the settings screen draws, in one answer: the line naming
  /// what Ask uses, the active selection, and a card per vendor.
  public func providersJSON() -> String {
    // Every card in the payload asks the same three questions about a kind,
    // and two of them reach the Keystore. Asked once here and carried down.
    let facts = Facts(manager: manager, credentials: credentialStore, model: onDevice)
    let payload = ProviderSettingsPayload(
      askUsesLine: askUsesLine(facts),
      selection: facts.selection,
      explicitSelection: facts.explicitSelection,
      vendors: ProviderVendor.displayed(forKinds: Self.supportedKinds).map { card(for: $0, facts) })
    guard let data = try? AndroidLibrary.encoder().encode(payload) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Whether Ask has a model to put a question to — the same optimism the
  /// Apple app has: an unproven key is worth trying, and only a key the
  /// provider has actually rejected (or a selection with nothing behind it)
  /// counts as nothing to ask with.
  public func hasAnyProvider() -> Bool {
    ((try? manager.activeProvider()) ?? nil) != nil
  }

  /// An honest empty-state sentence for a panel with nothing connected —
  /// "Add an API key or use the model built into this phone to ask
  /// questions." Mirrors `SettingsModel.setupGuidance(toDo:)`, and names the
  /// phone's own model only where the phone can actually run it.
  public func setupGuidance(_ action: String) -> String {
    "\(Self.joined(setupPaths)) to \(action)."
  }

  /// The ways a reader can connect something in *this* build. Derived from
  /// the kinds on offer and the model, so it never advertises a door that is
  /// not there: no sign-in (A3 is keys only), and no on-device path on a
  /// phone whose own model cannot run.
  private var setupPaths: [String] {
    // Capitalised: it leads the sentence `setupGuidance` builds.
    var paths: [String] = []
    if Self.supportedKinds.contains(where: \.usesAPIKey) { paths.append("Add an API key") }
    if Self.supportedKinds.contains(where: \.isOnDevice), onDevice.isReady {
      paths.append("use the model built into this phone")
    }
    return paths.isEmpty ? ["Connect an AI provider"] : paths
  }

  /// ["a"] -> "a"; ["a","b"] -> "a or b"; ["a","b","c"] -> "a, b, or c".
  private static func joined(_ parts: [String]) -> String {
    switch parts.count {
    case 0: return ""
    case 1: return parts[0]
    case 2: return "\(parts[0]) or \(parts[1])"
    default: return "\(parts.dropLast().joined(separator: ", ")), or \(parts.last!)"
    }
  }

  // MARK: Writing

  /// Store an API key for `kind` and forget whatever the last check said
  /// about it — the new key is unproven, and a stale "Connected" would
  /// otherwise stand until the caller's `connect` settles.
  public func saveAPIKey(_ kind: String, apiKey: String) throws {
    try readerFacing {
      let k = try self.kind(kind)
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw AndroidBridgeError.emptyAPIKey }
      try credentialStore.save(.apiKey(trimmed), for: k)
      manager.clearValidation(k)
    }
  }

  /// Prove a freshly stored credential and let it take the active slot if the
  /// kit's rule allows — the whole activation policy, in the kit, where the
  /// Apple app keeps it too: an unproven key may take a slot nothing usable
  /// holds (`requestActivation`), and a key the provider *accepted* — or one
  /// whose check could not complete — may take it from a working provider
  /// only after the check (`validateAndActivate`). A rejected key never does.
  /// Returns the settled status, as `validate` does.
  public func connect(_ kind: String) async throws -> String {
    try await readerFacing {
      let k = try self.kind(kind)
      persistingSelection { manager.requestActivation(of: k) }
      await persistingSelection { await manager.validateAndActivate(k) }
      return self.statusJSON(manager.validationState(k))
    }
  }

  /// Check a kind again unless a *successful* check is younger than
  /// `maxAgeSeconds`. What the screen's on-open sweep uses: a credential
  /// check posts a one-token completion, and repeating it on every visit
  /// would spend the reader's money to learn nothing.
  public func validateIfStale(_ kind: String, maxAgeSeconds: Int64) async throws -> String {
    try await readerFacing {
      let k = try self.kind(kind)
      await persistingSelection {
        await manager.validateIfStale(k, maxAge: TimeInterval(maxAgeSeconds))
      }
      return self.statusJSON(manager.validationState(k))
    }
  }

  /// Take a key away: the credential, the last thing a check said about it,
  /// and — when it was the model Ask had been pointed at — the selection
  /// itself, on disk and in this process.
  public func disconnect(_ kind: String) throws {
    try readerFacing {
      let k = try self.kind(kind)
      try credentialStore.delete(for: k)
      // A deleted key must not linger as ".active", or the card stays
      // "Connected" and `activeProvider()` would still resolve it.
      manager.clearValidation(k)
      guard manager.explicitSelection?.kind == k else { return }
      dropSelection()
    }
  }

  /// The older name for `disconnect`, kept because it says what it does at
  /// the call site that only wants the key gone.
  public func deleteCredential(_ kind: String) throws { try disconnect(kind) }

  /// Check that a kind is actually usable — a one-token authenticated call
  /// for a cloud key, the phone's own check for the on-device model — and report
  /// where it landed. Never skipped: this is the reader pressing "Check
  /// again", and a cached answer is exactly what they are disputing.
  public func validate(_ kind: String) async throws -> String {
    try await readerFacing {
      let k = try self.kind(kind)
      if k.isOnDevice { onDevice.invalidate() }
      _ = await persistingSelection { await manager.validate(k) }
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
      persistingSelection { manager.setActive(kind: k, modelID: id.isEmpty ? nil : id) }
    }
  }

  /// Bring in OpenRouter's catalogue — the disk copy while it is fresh, the
  /// network otherwise, the curated slice when there is neither. The rows
  /// themselves come back on the next `providersJSON()`, so the screen has
  /// one place it reads the model list from.
  public func refreshOpenRouterModels() async throws {
    try await readerFacing {
      let loaded = await openRouterStore.load()
      remember(loaded.models)
    }
  }

  // MARK: Building the cards

  /// The three things every card asks about a kind, asked once. `isConfigured`
  /// mirrors `ProviderManager.isConfigured` but leans on the presence-only
  /// credential check, so building a payload never decrypts a key it is not
  /// going to use.
  private struct Facts {
    let selection: ProviderSelection?
    let explicitSelection: ProviderSelection?
    private let states: [ProviderInfo.Kind: ProviderManager.ValidationState?]
    private let stored: [ProviderInfo.Kind: Bool]
    private let onDeviceReady: Bool

    init(manager: ProviderManager, credentials: SecretCredentialStore, model: OnDeviceModelBox) {
      selection = manager.selection
      explicitSelection = manager.explicitSelection
      var states: [ProviderInfo.Kind: ProviderManager.ValidationState?] = [:]
      var stored: [ProviderInfo.Kind: Bool] = [:]
      for kind in AndroidProviders.supportedKinds {
        states[kind] = manager.validationState(kind)
        stored[kind] = kind.isOnDevice ? false : credentials.has(kind)
      }
      self.states = states
      self.stored = stored
      onDeviceReady = model.isReady
    }

    func state(_ kind: ProviderInfo.Kind) -> ProviderManager.ValidationState? {
      states[kind] ?? nil
    }

    func hasCredential(_ kind: ProviderInfo.Kind) -> Bool { stored[kind] ?? false }

    /// Verified usable, or — before any check — a stored key / a phone that
    /// says it can run its own model.
    func isConfigured(_ kind: ProviderInfo.Kind) -> Bool {
      if let state = state(kind) { return state == .active }
      if kind.isOnDevice { return onDeviceReady }
      return hasCredential(kind)
    }
  }

  /// Which model Ask is actually using, in one line: "Ask uses Claude Opus 5
  /// · Claude (Anthropic)". Connected means usable — a rejected key or a
  /// phone that cannot run Nano adds "— not connected", the way the card's
  /// dot goes red. `SettingsModel.askUsesLine` on the Apple side.
  private func askUsesLine(_ facts: Facts) -> String {
    guard let selection = facts.selection else {
      return "Ask uses no model yet — connect one below."
    }
    return "Ask uses " + selection.summary(connected: facts.isConfigured(selection.kind))
  }

  private func card(for vendor: ProviderVendor, _ facts: Facts) -> ProviderVendorCard {
    ProviderVendorCard(
      id: vendor.id,
      title: vendor.title,
      badge: badge(for: vendor),
      hint: hint(for: vendor, facts),
      kinds: vendor.methods.map { card(for: $0, facts) })
  }

  private func card(for kind: ProviderInfo.Kind, _ facts: Facts) -> ProviderKindCard {
    let status = ProviderStatusSummary(facts.state(kind))
    let hasCredential = facts.hasCredential(kind)
    let selection = facts.selection
    let modelID = selection?.kind == kind
      ? selection!.modelID
      : ProviderCatalog.defaultModel(for: kind).modelID
    return ProviderKindCard(
      kind: kind.rawValue,
      displayName: methodLabel(for: kind),
      usesAPIKey: kind.usesAPIKey,
      isOnDevice: kind.isOnDevice,
      hasCredential: hasCredential,
      // Active only when this card holds the selection AND it is usable —
      // the same test the Apple card's badge makes.
      isActive: selection?.kind == kind && facts.isConfigured(kind),
      status: status,
      statusLine: statusLine(for: kind, status: status, hasCredential: hasCredential),
      checkingLine: checkingLine(for: kind),
      models: models(for: kind),
      // Through the catalogue: a model id that has since been retired resolves
      // to its replacement, so the picker shows a name rather than a raw id.
      activeModelID: ProviderCatalog.resolve(modelID: modelID, for: kind).modelID)
  }

  /// The line under a card's title. The kit's own sentence for anything that
  /// went wrong, and short neutral words for everything else — written here
  /// so the screen renders what it is handed.
  private func statusLine(
    for kind: ProviderInfo.Kind, status: ProviderStatusSummary, hasCredential: Bool
  ) -> String {
    switch status.state {
    case "validating": return checkingLine(for: kind)
    case "active": return "Connected"
    case "invalid": return status.reason ?? "Not connected"
    case "unavailable": return status.reason ?? "Temporarily unavailable"
    default:
      // Never checked this session. The on-device model is always about to be
      // probed; a stored key shows as connected until a live check settles it
      // one way or the other.
      if kind.isOnDevice { return checkingLine(for: kind) }
      return hasCredential ? "Connected" : "Not connected"
    }
  }

  private func checkingLine(for kind: ProviderInfo.Kind) -> String {
    kind.isOnDevice ? "Checking this phone…" : "Validating…"
  }

  /// Keep the list a load brought in. Its own method so the lock is never
  /// held across an `await` — a suspension with a mutex held is an error in
  /// the Swift 6 language mode, and a deadlock in any of them.
  func remember(_ models: [OpenRouterModel]) {
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
  /// that isn't there. The one place that rewrite happens.
  private func badge(for vendor: ProviderVendor) -> String {
    guard vendor.methods.contains(where: \.offersSignIn) else { return vendor.badge }
    return vendor.methods.contains(where: \.usesAPIKey) ? "API key" : vendor.badge
  }

  /// A single sentence telling a disconnected card what to do — phrased from
  /// what this build offers, so it never names sign-in. Nil once something is
  /// connected: the status line takes over.
  private func hint(for vendor: ProviderVendor, _ facts: Facts) -> String? {
    guard !vendor.methods.contains(where: { facts.hasCredential($0) }) else { return nil }
    if vendor.methods.contains(where: \.usesAPIKey) { return "Paste an API key to connect." }
    guard vendor.methods.allSatisfy(\.isOnDevice) else { return nil }
    return Self.onDeviceHint
  }

  /// The one sentence the phone's own card carries while nothing is set up.
  static let onDeviceHint =
    "The model built into this phone. Nothing to set up, nothing leaves your phone."

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

  /// The kind a wire string names, refusing anything this build does not
  /// offer. Not private: `Ask.swift`'s extensions parse the same strings.
  func providerKind(_ raw: String) throws -> ProviderInfo.Kind { try kind(raw) }

  private func kind(_ raw: String) throws -> ProviderInfo.Kind {
    guard let kind = ProviderInfo.Kind(rawValue: raw), Self.supportedKinds.contains(kind) else {
      throw AndroidBridgeError.unknownProviderKind(raw)
    }
    return kind
  }

  // MARK: Selection persistence

  /// Every selection write goes through here.
  ///
  /// `ProviderManager` persists through `UserDefaults` and is built with
  /// `persistingIn: nil`, so the file is the facade's to write — and not only
  /// for `setActive`: `requestActivation` and `validateAndActivate` move the
  /// selection themselves, and an activation that is not written down is one
  /// the reader loses on the next launch.
  @discardableResult
  private func persistingSelection<T>(_ body: () -> T) -> T {
    let result = body()
    writeSelection(manager.explicitSelection)
    return result
  }

  @discardableResult
  private func persistingSelection<T>(_ body: () async -> T) async -> T {
    let result = await body()
    writeSelection(manager.explicitSelection)
    return result
  }

  /// Back to "nothing chosen", here and on disk.
  ///
  /// `ProviderManager` has no way to un-choose — `setActive` is the only door
  /// in and it always names a kind — so the facade builds a fresh manager
  /// over the same store, factory and model. It forgets what this session had
  /// checked, which the next sweep re-establishes. KIT FOLLOW-UP: a
  /// `clearSelection()` on `ProviderManager` would make this a one-liner and
  /// keep those results.
  private func dropSelection() {
    managerLock.lock()
    _manager = Self.makeManager(
      store: credentialStore, overrides: endpointOverrides, model: onDevice, selection: nil)
    managerLock.unlock()
    writeSelection(nil)
  }

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

/// Hands a launch-time model list back to the facade without the `Task`
/// capturing a non-`Sendable` class. The facade outlives the task (it is the
/// process's provider settings), and `remember` is lock-guarded.
final class OpenRouterModelsBox: @unchecked Sendable {
  private let providers: AndroidProviders

  init(_ providers: AndroidProviders) { self.providers = providers }

  func remember(_ models: [OpenRouterModel]) { providers.remember(models) }
}
