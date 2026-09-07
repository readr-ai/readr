import Foundation
import ReadrKit

/// Encrypted key/value storage supplied by Kotlin (Android Keystore-backed).
/// Values are opaque strings; `read` returns "" when the key is absent, since
/// protocol methods cannot return optionals across the bridge.
public protocol SecretStore {
  func write(_ key: String, value: String) -> Bool
  func read(_ key: String) -> String
  func remove(_ key: String) -> Bool
  /// Whether an entry exists, without decrypting it. Settings asks this of
  /// every provider on every read of the screen, and decrypting a key to
  /// learn that it is there is a Keystore round trip for an answer the
  /// preferences file already holds.
  func has(_ key: String) -> Bool
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

  /// Whether a credential is stored, without reading it. What the settings
  /// payload uses: the screen needs to know a key is there, never what it is.
  func has(_ kind: ProviderInfo.Kind) -> Bool { store.has(key(kind)) }
}

/// Facade errors. `errorDescription` is reader-facing (it is what reaches the
/// screen through `ReaderFacingError`); `diagnosticSummary` is for logs.
enum AndroidBridgeError: LocalizedError, CustomStringConvertible {
  case secretStoreFailed(String)
  case unknownBook(String)
  case unknownProviderKind(String)
  case invalidChapter(Int)
  case unknownHighlight(String)
  case unknownBookmark(String)
  case unknownHighlightColor(String)
  /// Save pressed with nothing in the field.
  case emptyAPIKey
  /// Ask reached the phone's own model before A3c taught it to answer.
  case onDeviceModelNotReady
  /// A debug endpoint override that pointed somewhere other than this device.
  case endpointNotLoopback(String)

  var errorDescription: String? {
    switch self {
    case .secretStoreFailed: return "Readr couldn't save this key on the device."
    case .unknownBook: return "This book is no longer in your library."
    case .unknownProviderKind: return "That provider isn't supported on this device."
    case .invalidChapter: return "That chapter doesn't exist in this book."
    case .unknownHighlight: return "That highlight is no longer in your library."
    case .unknownBookmark: return "That bookmark is no longer in your library."
    case .unknownHighlightColor: return "That highlight colour isn't available."
    case .emptyAPIKey: return "Paste an API key to connect."
    case .onDeviceModelNotReady: return "Gemini Nano isn't ready on this phone yet."
    case .endpointNotLoopback: return "Readr can only be pointed at a server on this device."
    }
  }

  var description: String { errorDescription ?? "Readr hit an unexpected error." }

  var diagnosticSummary: String {
    switch self {
    case .secretStoreFailed(let what): return "secret store failed: \(what)"
    case .unknownBook(let id): return "no book with id \(id)"
    case .unknownProviderKind(let kind): return "unknown provider kind \(kind)"
    case .invalidChapter(let index): return "no chapter at index \(index)"
    case .unknownHighlight(let id): return "no highlight with id \(id)"
    case .unknownBookmark(let id): return "no bookmark with id \(id)"
    case .unknownHighlightColor(let name): return "unknown highlight color \(name)"
    case .emptyAPIKey: return "empty API key"
    case .onDeviceModelNotReady: return "on-device provider is a placeholder until A3c"
    case .endpointNotLoopback(let host): return "endpoint override is not loopback: \(host)"
    }
  }
}
