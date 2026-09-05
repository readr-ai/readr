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
/// downloading (with progress, cancellable), loaded onto the GPU, gone. One
/// per process — the weights are gigabytes and the GPU holds one model at a
/// time, so loading one evicts the other.
///
/// Weights live in the same Hugging Face cache Readr Voice uses
/// (`HubCache.default`), fetched with the same client, so there is one
/// download path to reason about. Loading is lazy (first question) and goes
/// through `MLXGPULease` like every other MLX graph; the container is dropped
/// on a memory warning and when the app leaves the foreground, and the next
/// question reloads it.
@MainActor
final class MLXModelStore: ObservableObject {

    static let shared = MLXModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    /// Only what the disk can't tell: a download in flight, or the reason
    /// the last one failed. Everything else is read from the cache directory
    /// (memoised until a download or a delete changes it).
    @Published private(set) var transient: [String: State] = [:]
    private var onDisk: [String: Bool] = [:]

    private var downloads: [String: Task<Void, Never>] = [:]
    private var containers: [String: ModelContainer] = [:]
    private var loads: [String: Task<ModelContainer, Error>] = [:]
    /// Which load is current per repository; an unload bumps it so a load
    /// it cancelled can't land its container afterwards.
    private var loadGeneration: [String: Int] = [:]
    private let cache = HubCache.default
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.unloadAll(reason: "memory warning") } })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.unloadAll(reason: "backgrounded") } })
    }

    // MARK: Disk

    func state(for repository: String) -> State {
        if let inFlight = transient[repository] { return inFlight }
        return isDownloaded(repository) ? .downloaded : .notDownloaded
    }

    /// Weights, config and tokenizer present and non-empty in the cache's
    /// snapshot directory. Memoised: the answer only changes through this
    /// store's own download and delete.
    func isDownloaded(_ repository: String) -> Bool {
        if let known = onDisk[repository] { return known }
        let present = Self.snapshotIsComplete(for: repository, in: cache)
        onDisk[repository] = present
        return present
    }

    /// The files a load needs (`model.safetensors` is a single file for the
    /// MLX community's Qwen3.5 conversions; a sharded repo lists its shards
    /// in the index, which is why the index is required too).
    static let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    /// Off any actor: a directory scan, which the provider's readiness check
    /// also needs without hopping to the main actor.
    nonisolated static func snapshotIsComplete(for repository: String, in cache: HubCache) -> Bool {
        guard let repo = Repo.ID(rawValue: repository) else { return false }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        let manager = FileManager.default
        let revisions = (try? manager.contentsOfDirectory(atPath: snapshots.path)) ?? []
        func hasBytes(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
        return revisions.contains { revision in
            let directory = snapshots.appendingPathComponent(revision)
            let files = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            let weights = files.filter { $0.hasSuffix(".safetensors") }
            guard !weights.isEmpty, weights.allSatisfy({ hasBytes(directory.appendingPathComponent($0)) }) else {
                return false
            }
            return requiredFiles.allSatisfy { hasBytes(directory.appendingPathComponent($0)) }
        }
    }

    // MARK: Downloading

    /// Start (or resume) a download. A failed attempt is simply tried again —
    /// the Hub client resumes partial blobs, so nothing already fetched is
    /// lost. Refused only while one is already running or the model is here.
    func download(_ repository: String) {
        guard downloads[repository] == nil else { return }
        guard let repo = Repo.ID(rawValue: repository) else {
            transient[repository] = .failed("That model's name isn't valid.")
            return
        }
        transient[repository] = .downloading(0)
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: starting \(repository)")
        let client = HubClient(cache: cache)
        downloads[repository] = Task { [weak self] in
            do {
                _ = try await client.downloadSnapshot(
                    of: repo,
                    matching: ["*.safetensors", "*.json", "*.txt", "*.model", "*.tiktoken", "*.jinja"],
                    progressHandler: { [weak self] progress in
                        // Whole percents only: the client reports per chunk,
                        // and every publish re-renders the card.
                        let percent = min(1, max(0, progress.fractionCompleted))
                        if case let .downloading(shown)? = self?.transient[repository],
                           Int(shown * 100) == Int(percent * 100) { return }
                        self?.transient[repository] = .downloading(percent)
                    }
                )
                guard let self else { return }
                self.onDisk[repository] = nil
                if self.isDownloaded(repository) {
                    self.transient[repository] = nil
                    DiagnosticsLog.shared.record(.info, .provider, "downloaded model: finished \(repository)")
                } else {
                    self.transient[repository] = .failed("The download finished but the model files are incomplete. Try again.")
                    DiagnosticsLog.shared.record(.warning, .provider, "downloaded model: incomplete after download \(repository)")
                }
            } catch is CancellationError {
                self?.transient[repository] = nil
                DiagnosticsLog.shared.record(.info, .provider, "downloaded model: download cancelled \(repository)")
            } catch {
                self?.transient[repository] = .failed("The download didn't finish. Check your connection and try again — it picks up where it stopped.")
                DiagnosticsLog.shared.record(
                    .error, .provider, "downloaded model: download failed for \(repository)", error: error
                )
            }
            self?.downloads[repository] = nil
        }
    }

    func cancelDownload(_ repository: String) {
        downloads[repository]?.cancel()
    }

    /// Clear a failure so the card offers Download again (the retry itself
    /// is just `download`).
    func dismissFailure(_ repository: String) {
        if case .failed? = transient[repository] { transient[repository] = nil }
    }

    func delete(_ repository: String) {
        cancelDownload(repository)
        unload(repository, reason: "deleted")
        if let repo = Repo.ID(rawValue: repository) {
            let directory = cache.repoDirectory(repo: repo, kind: .model)
            // Gigabytes: off the main thread.
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
        }
        onDisk[repository] = false
        transient[repository] = nil
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: deleted \(repository)")
    }

    // MARK: GPU

    /// The loaded model, loading it on first use under the GPU lease, and
    /// evicting any other model first — one set of weights on the GPU at a
    /// time. Concurrent callers share one load.
    func container(for repository: String) async throws -> ModelContainer {
        if let loaded = containers[repository] { return loaded }
        if let inFlight = loads[repository] { return try await inFlight.value }
        for other in Array(containers.keys) where other != repository { unload(other, reason: "another model requested") }
        let cache = self.cache
        let task = Task<ModelContainer, Error> {
            try await MLXGPULease.shared.withLease {
                // Readr Voice sets the same limit when it loads; whichever MLX
                // user comes first bounds the free-buffer pool for both.
                Memory.cacheLimit = MLXKokoroSpeechEngine.gpuCacheLimit
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
        }
        loads[repository] = task
        let generation = (loadGeneration[repository] ?? 0) + 1
        loadGeneration[repository] = generation
        do {
            let container = try await task.value
            // A cancel (unload) during the load must not resurrect it.
            if loadGeneration[repository] == generation {
                containers[repository] = container
                loads[repository] = nil
            }
            return container
        } catch {
            if loadGeneration[repository] == generation { loads[repository] = nil }
            throw error
        }
    }

    func unload(_ repository: String, reason: String) {
        if let load = loads.removeValue(forKey: repository) {
            loadGeneration[repository, default: 0] += 1
            load.cancel()
            DiagnosticsLog.shared.record(.info, .provider, "downloaded model: load cancelled \(repository) (\(reason))")
        }
        guard containers.removeValue(forKey: repository) != nil else { return }
        MLX.GPU.clearCache()
        DiagnosticsLog.shared.record(.info, .provider, "downloaded model: unloaded \(repository) (\(reason))")
    }

    func unloadAll(reason: String) {
        for repository in Set(containers.keys).union(loads.keys) { unload(repository, reason: reason) }
    }
}

// MARK: - Bridges to the Hub client and swift-transformers
//
// mlx-swift-lm offers these as macros (Libraries/MLXHuggingFaceMacros/
// HuggingFaceIntegrationMacros.swift at tag 3.31.4); the expansions are short
// enough to write out, which keeps the swift-syntax macro toolchain out of
// the build. Re-check against that file on a version bump.

struct HubDownloaderBridge: MLXLMCommon.Downloader {
    private let upstream: HubClient
    init(_ upstream: HubClient) { self.upstream = upstream }

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw OnDeviceModelError.unavailable("That model isn't available. Pick another in Settings → AI Providers.")
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
#endif
