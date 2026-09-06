import Foundation
import ReadrKit

/// Encrypted key/value storage supplied by Kotlin (Android Keystore-backed).
/// Values are opaque strings; `read` returns "" when the key is absent, since
/// protocol methods cannot return optionals across the bridge.
public protocol SecretStore {
  func write(_ key: String, value: String) -> Bool
  func read(_ key: String) -> String
  func remove(_ key: String) -> Bool
}

/// ReadrKit's `CredentialStore` over a Kotlin `SecretStore`: the Android
/// counterpart of `KeychainCredentialStore`. Credentials are stored as the
/// same JSON the Keychain store writes, one entry per provider kind.
final class SecretCredentialStore: CredentialStore, @unchecked Sendable {
  private let store: any SecretStore
  private let prefix = "credentials."

  init(store: any SecretStore) { self.store = store }

  private func key(_ kind: ProviderInfo.Kind) -> String { prefix + kind.rawValue }

  func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws {
    let json = try JSONEncoder().encode(credentials)
    guard let text = String(data: json, encoding: .utf8), store.write(key(kind), value: text) else {
      throw AndroidBridgeError.secretStoreFailed("write \(kind.rawValue)")
    }
  }

  func load(for kind: ProviderInfo.Kind) throws -> Credentials? {
    let text = store.read(key(kind))
    guard !text.isEmpty else { return nil }
    return try JSONDecoder().decode(Credentials.self, from: Data(text.utf8))
  }

  func delete(for kind: ProviderInfo.Kind) throws {
    guard store.remove(key(kind)) else {
      throw AndroidBridgeError.secretStoreFailed("remove \(kind.rawValue)")
    }
  }
}

/// Facade errors. `errorDescription` is reader-facing (it is what reaches the
/// screen through `ReaderFacingError`); `diagnosticSummary` is for logs.
enum AndroidBridgeError: LocalizedError, CustomStringConvertible {
  case secretStoreFailed(String)
  case unknownBook(String)
  case unknownProviderKind(String)
  case invalidChapter(Int)

  var errorDescription: String? {
    switch self {
    case .secretStoreFailed: return "Readr couldn't save this key on the device."
    case .unknownBook: return "This book is no longer in your library."
    case .unknownProviderKind: return "That provider isn't supported on this device."
    case .invalidChapter: return "That chapter doesn't exist in this book."
    }
  }

  var description: String { errorDescription ?? "Readr hit an unexpected error." }

  var diagnosticSummary: String {
    switch self {
    case .secretStoreFailed(let what): return "secret store failed: \(what)"
    case .unknownBook(let id): return "no book with id \(id)"
    case .unknownProviderKind(let kind): return "unknown provider kind \(kind)"
    case .invalidChapter(let index): return "no chapter at index \(index)"
    }
  }
}

/// Provider credentials for the Android app, backed by `SecretCredentialStore`.
/// This is the object Settings talks to; `ProviderManager` receives the same
/// store in the Ask milestone.
public final class AndroidCredentials {
  let credentialStore: SecretCredentialStore

  public init(store: any SecretStore) {
    credentialStore = SecretCredentialStore(store: store)
  }

  /// `kind` is a `ProviderInfo.Kind` raw value ("anthropic", "openAI", ...).
  public func saveAPIKey(_ kind: String, apiKey: String) throws {
    try readerFacing {
      guard let k = ProviderInfo.Kind(rawValue: kind) else { throw AndroidBridgeError.unknownProviderKind(kind) }
      try credentialStore.save(.apiKey(apiKey), for: k)
    }
  }

  public func hasCredential(_ kind: String) -> Bool {
    guard let k = ProviderInfo.Kind(rawValue: kind) else { return false }
    return (try? credentialStore.load(for: k)) != nil
  }

  /// The stored API key, or "" when none (or when the credential is OAuth).
  public func apiKey(_ kind: String) -> String {
    guard let k = ProviderInfo.Kind(rawValue: kind), case .apiKey(let key)? = try? credentialStore.load(for: k) else { return "" }
    return key
  }

  public func deleteCredential(_ kind: String) throws {
    try readerFacing {
      guard let k = ProviderInfo.Kind(rawValue: kind) else { throw AndroidBridgeError.unknownProviderKind(kind) }
      try credentialStore.delete(for: k)
    }
  }
}
