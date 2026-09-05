import Foundation
import ReadrKit

#if os(iOS)
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import UIKit

/// The downloaded models' lifecycle on this device: on disk or not,
/// downloading (with progress), loaded onto the GPU, gone. One per process —
/// the weights are gigabytes and the GPU holds one model at a time.
///
/// Weights live in the same Hugging Face cache Readr Voice uses
/// (`HubCache.default`), fetched with the same client, so there is one
/// download path to reason about. Loading is lazy (first question) and the
/// container is dropped on a memory warning; the next question reloads it.
@MainActor
final class MLXModelStore: ObservableObject {

    static let shared = MLXModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    private var containers: [String: ModelContainer] = [:]
    private var loads: [String: Task<ModelContainer, Error>] = [:]
    private let cache = HubCache.default
    private var memoryWarning: NSObjectProtocol?

    private init() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.unloadAll(reason: "memory warning") }
        }
    }

    // MARK: Disk

    func state(for repository: String) -> State {
        if let known = states[repository] { return known }
        return isDownloaded(repository) ? .downloaded : .notDownloaded
    }

    /// Weights and config present in the cache's snapshot directory.
    func isDownloaded(_ repository: String) -> Bool {
        guard let directory = snapshotDirectory(for: repository) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") } && files.contains("config.json")
    }

    private func snapshotDirectory(for repository: String) -> URL? {
        guard let repo = Repo.ID(rawValue: repository) else { return nil }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        let revisions = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        // Any revision with weights counts; there is normally one.
        return revisions.map { snapshots.appendingPathComponent($0) }.first { revision in
            ((try? FileManager.default.contentsOfDirectory(atPath: revision.path)) ?? [])
                .contains { $0.hasSuffix(".safetensors") }
        }
    }

    func download(_ repository: String) {
        guard case .notDownloaded = state(for: repository) else { return }
        guard let repo = Repo.ID(rawValue: repository) else {
            states[repository] = .failed("That model's name isn't valid.")
            return
        }
        states[repository] = .downloading(0)
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: starting \(repository)")
        Task {
            do {
                let client = HubClient(cache: cache)
                _ = try await client.downloadSnapshot(
                    of: repo,
                    matching: ["*.safetensors", "*.json", "*.txt", "*.model", "*.tiktoken", "*.jinja"],
                    progressHandler: { [weak self] progress in
                        self?.states[repository] = .downloading(min(1, max(0, progress.fractionCompleted)))
                    }
                )
                states[repository] = isDownloaded(repository)
                    ? .downloaded
                    : .failed("The download finished but the model files are incomplete. Try again.")
                DiagnosticsLog.shared.record(.info, .provider, "downloaded model: finished \(repository)")
            } catch is CancellationError {
                states[repository] = .notDownloaded
            } catch {
                states[repository] = .failed("The download didn't finish. Check your connection and try again.")
                DiagnosticsLog.shared.record(
                    .error, .provider, "downloaded model: download failed for \(repository)", error: error
                )
            }
        }
    }

    func delete(_ repository: String) {
        unload(repository, reason: "deleted")
        if let repo = Repo.ID(rawValue: repository) {
            try? FileManager.default.removeItem(at: cache.repoDirectory(repo: repo, kind: .model))
        }
        states[repository] = .notDownloaded
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: deleted \(repository)")
    }

    // MARK: GPU

    /// The loaded model, loading it on first use. Concurrent callers share
    /// one load.
    func container(for repository: String) async throws -> ModelContainer {
        if let loaded = containers[repository] { return loaded }
        if let inFlight = loads[repository] { return try await inFlight.value }
        let task = Task<ModelContainer, Error> {
            let started = Date()
            let container = try await loadModelContainer(
                from: HubDownloaderBridge(HubClient(cache: cache)),
                using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(id: repository)
            )
            DiagnosticsLog.shared.record(
                .info, .provider,
                "downloaded model: loaded \(repository) in \(Int(Date().timeIntervalSince(started)))s"
            )
            return container
        }
        loads[repository] = task
        defer { loads[repository] = nil }
        let container = try await task.value
        containers[repository] = container
        return container
    }

    func unload(_ repository: String, reason: String) {
        guard containers.removeValue(forKey: repository) != nil else { return }
        MLX.GPU.clearCache()
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: unloaded \(repository) (\(reason))")
    }

    func unloadAll(reason: String) {
        for repository in Array(containers.keys) { unload(repository, reason: reason) }
    }
}

// MARK: - Bridges to the Hub client and swift-transformers
//
// mlx-swift-lm offers these as macros; the expansions are short enough to
// write out, and doing so keeps the swift-syntax macro toolchain out of the
// build.

struct HubDownloaderBridge: MLXLMCommon.Downloader {
    private let upstream: HubClient
    init(_ upstream: HubClient) { self.upstream = upstream }

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw MLXModelError.invalidRepository(id)
        }
        return try await upstream.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum MLXModelError: LocalizedError, DiagnosticallyDescribable {
    case invalidRepository(String)
    case notDownloaded
    case unsupportedDevice

    var errorDescription: String? {
        switch self {
        case .invalidRepository: return "That model isn't available."
        case .notDownloaded: return "The downloaded model isn't on this device yet."
        case .unsupportedDevice: return "This device can't run a downloaded model."
        }
    }
    var recoverySuggestion: String? {
        switch self {
        case .invalidRepository: return "Pick another model in Settings → AI Providers."
        case .notDownloaded: return "Download it in Settings → AI Providers, or connect another provider."
        case .unsupportedDevice: return "Connect a cloud provider in Settings → AI Providers."
        }
    }
    var diagnosticSummary: String {
        switch self {
        case .invalidRepository(let id): return "MLXModelError.invalidRepository: \(id)"
        case .notDownloaded: return "MLXModelError.notDownloaded"
        case .unsupportedDevice: return "MLXModelError.unsupportedDevice"
        }
    }
}
#endif
