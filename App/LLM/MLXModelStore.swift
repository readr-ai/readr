import Foundation
import ReadrKit
#if os(iOS)
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import UIKit

/// Explicit downloads own network access. Inference opens a validated local
/// snapshot directory and is given a downloader that always refuses network.
@MainActor
final class MLXModelStore: ObservableObject {
    static let shared = MLXModelStore()
    enum State: Equatable { case notDownloaded, downloading(Double), downloaded, deleting, failed(String) }
    @Published private(set) var transient: [String: State] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]
    private var deletions: [String: Task<Void, Never>] = [:]
    private var containers: [String: ModelContainer] = [:]
    private var loads: [String: Task<ModelContainer, Error>] = [:]
    private var loadGeneration: [String: Int] = [:]
    private var uses: [String: [UUID: ModelGenerationUse]] = [:]
    private let cache = HubCache.default
    private var observers: [NSObjectProtocol] = []
    private init() {
        let center = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.unloadAll(reason: "device lifecycle") }
            })
        }
    }
    func state(for repository: String) -> State { transient[repository] ?? (isDownloaded(repository) ? .downloaded : .notDownloaded) }
    func isDownloaded(_ repository: String) -> Bool { Self.snapshotDirectory(for: repository, in: cache) != nil }
    nonisolated static func snapshotIsComplete(for repository: String, in cache: HubCache) -> Bool { snapshotDirectory(for: repository, in: cache) != nil }
    nonisolated static func snapshotDirectory(for repository: String, in cache: HubCache) -> URL? {
        guard DownloadedModelCatalog.spec(for: repository) != nil, let repo = Repo.ID(rawValue: repository) else { return nil }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        let revisions = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        // A snapshot's commit directory pins the actual downloaded revision.
        // No Hub client is called to resolve the branch during inference.
        let pinned = UserDefaults.standard.string(forKey: "Readr.downloaded.snapshot." + repository)
        let ordered = pinned.map { [$0] } ?? []
        return (ordered + revisions.sorted().reversed().filter { $0 != pinned }).map { snapshots.appendingPathComponent($0) }
            .first(where: DownloadedModelSnapshot.isComplete)
    }
    func download(_ repository: String) {
        guard downloads[repository] == nil, deletions[repository] == nil, !isDownloaded(repository) else { return }
        guard let specification = DownloadedModelCatalog.spec(for: repository),
              specification.minimumPhysicalMemory <= MLXLLMProvider.physicalMemory,
              let repo = Repo.ID(rawValue: repository) else {
            transient[repository] = .failed("Choose a model from the download list."); return
        }
        transient[repository] = .downloading(0)
        let client = HubClient(cache: cache)
        downloads[repository] = Task { [weak self] in
            do {
                let snapshot = try await client.downloadSnapshot(of: repo,
                    matching: ["*.safetensors", "*.json", "*.txt", "*.model", "*.tiktoken", "*.jinja"],
                    progressHandler: { [weak self] progress in
                        guard case .downloading? = self?.transient[repository] else { return }
                        let value = min(1, max(0, progress.fractionCompleted))
                        if case .downloading(let shown)? = self?.transient[repository], Int(shown * 100) == Int(value * 100) { return }
                        self?.transient[repository] = .downloading(value)
                    })
                try Task.checkCancellation()
                guard let self else { return }
                if DownloadedModelSnapshot.isComplete(snapshot) {
                    UserDefaults.standard.set(snapshot.lastPathComponent, forKey: "Readr.downloaded.snapshot." + repository)
                }
                if self.deletions[repository] == nil {
                    self.transient[repository] = self.isDownloaded(repository) ? nil : .failed("The model files are incomplete. Tap Download to retry.")
                }
            } catch is CancellationError {
                if self?.deletions[repository] == nil { self?.transient[repository] = nil }
            } catch {
                DiagnosticsLog.shared.record(.error, .provider, "Model download failed", error: error)
                if self?.deletions[repository] == nil { self?.transient[repository] = .failed("The download didn't finish. Check your connection and retry.") }
            }
            self?.downloads[repository] = nil
        }
    }
    func cancelDownload(_ repository: String) { downloads[repository]?.cancel() }
    func dismissFailure(_ repository: String) { if case .failed? = transient[repository] { transient[repository] = nil } }
    func delete(_ repository: String) {
        guard deletions[repository] == nil, let repo = Repo.ID(rawValue: repository), DownloadedModelCatalog.spec(for: repository) != nil else { return }
        transient[repository] = .deleting
        let downloading = downloads[repository]
        downloading?.cancel()
        let consumers = Array(uses[repository]?.values ?? Dictionary<UUID, ModelGenerationUse>().values)
        consumers.forEach { $0.cancel() }
        unload(repository, reason: "deleted")
        let directory = cache.repoDirectory(repo: repo, kind: .model)
        deletions[repository] = Task { [weak self] in
            await downloading?.value
            for consumer in consumers { await consumer.waitForCompletion() }
            do {
                let token = try await MLXGPULease.shared.acquire()
                do {
                    try await Task.detached(priority: .utility) {
                        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    }.value
                    await MLXGPULease.shared.release(token)
                } catch { await MLXGPULease.shared.release(token); throw error }
                UserDefaults.standard.removeObject(forKey: "Readr.downloaded.snapshot." + repository)
                self?.transient[repository] = nil
            } catch {
                DiagnosticsLog.shared.record(.error, .provider, "Model removal failed", error: error)
                self?.transient[repository] = .failed("The model couldn't be removed. Tap Remove to retry.")
            }
            self?.deletions[repository] = nil
        }
    }
    func register(_ use: ModelGenerationUse, repository: String) throws {
        guard deletions[repository] == nil else { throw OnDeviceModelError.unavailable("This model is being removed.") }
        uses[repository, default: [:]][use.id] = use
    }
    func finished(_ use: ModelGenerationUse, repository: String) { uses[repository]?[use.id] = nil }
    func container(for repository: String) async throws -> ModelContainer {
        try Task.checkCancellation()
        guard deletions[repository] == nil else { throw OnDeviceModelError.unavailable("This model is being removed.") }
        if let loaded = containers[repository] { return loaded }
        guard let directory = Self.snapshotDirectory(for: repository, in: cache) else { throw OnDeviceModelError.unavailable("Download this model in Settings first.") }
        let task: Task<ModelContainer, Error>
        let generation: Int
        if let existing = loads[repository] { task = existing; generation = loadGeneration[repository, default: 0] }
        else {
            for other in Set(containers.keys).union(loads.keys) where other != repository { unload(other, reason: "model changed") }
            generation = loadGeneration[repository, default: 0] + 1
            loadGeneration[repository] = generation
            task = Task {
                try await MLXGPULease.shared.withLease {
                    Memory.cacheLimit = MLXKokoroSpeechEngine.gpuCacheLimit
                    return try await withError {
                        try await loadModelContainer(from: NoNetworkModelDownloader(), using: TransformersTokenizerLoader(), configuration: ModelConfiguration(directory: directory))
                    }
                }
            }
            loads[repository] = task
        }
        do {
            let container = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard loadGeneration[repository] == generation, deletions[repository] == nil else { throw CancellationError() }
            containers[repository] = container; loads[repository] = nil
            return container
        } catch {
            if loadGeneration[repository] == generation { loads[repository] = nil }
            throw error
        }
    }
    func unload(_ repository: String, reason: String) {
        loadGeneration[repository, default: 0] += 1
        loads.removeValue(forKey: repository)?.cancel()
        uses[repository]?.values.forEach { $0.cancel() }
        containers[repository] = nil
        // Clear only after all submitted graphs release process-wide ownership.
        Task { if let token = try? await MLXGPULease.shared.acquire() { MLX.GPU.clearCache(); await MLXGPULease.shared.release(token) } }
    }
    func unloadAll(reason: String) { for repo in Set(containers.keys).union(loads.keys).union(uses.keys) { unload(repo, reason: reason) } }
}

/// A loading SDK cannot accidentally reintroduce Hub requests to inference.
struct NoNetworkModelDownloader: MLXLMCommon.Downloader {
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        throw OnDeviceModelError.unavailable("Local model files are missing. Download the model in Settings first.")
    }
}

/// Cancellation may arrive before a Task has been attached or after it ends.
final class ModelGenerationUse: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var ended = false
    func attach(_ value: Task<Void, Never>) {
        let cancel = lock.withLock { () -> Bool in
            if !ended { task = value }; return cancelled
        }
        if cancel { value.cancel() }
    }
    func cancel() { let value = lock.withLock { cancelled = true; return task }; value?.cancel() }
    func finish() { lock.withLock { ended = true; task = nil } }
    func waitForCompletion() async { if let value = lock.withLock({ task }) { await value.value } }
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
