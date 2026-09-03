import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One row of OpenRouter's model catalogue, as the picker shows it: a name,
/// the namespaced id Ask sends, the context window, and the price per
/// million tokens each way. Prices are what the picker sorts cheap models
/// by; `contextLength` is what `ProviderCatalog.resolve` turns into a router
/// budget for a model the static list has never heard of.
public struct OpenRouterModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var contextLength: Int
    public var promptUSDPerMillion: Double
    public var completionUSDPerMillion: Double

    public init(
        id: String,
        name: String,
        contextLength: Int,
        promptUSDPerMillion: Double,
        completionUSDPerMillion: Double
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.promptUSDPerMillion = promptUSDPerMillion
        self.completionUSDPerMillion = completionUSDPerMillion
    }

    /// Costs nothing either way — OpenRouter's `:free` tier. Exactly zero
    /// both ways; `parse` never produces a negative price (OpenRouter's "-1"
    /// sentinel for dynamically priced routers is dropped there), and a
    /// hand-built row with one is not free either.
    public var isFree: Bool {
        promptUSDPerMillion == 0 && completionUSDPerMillion == 0
    }

    /// "$0.08 in · $0.17 out per 1M tokens", or "Free".
    public var priceLabel: String {
        guard !isFree else { return "Free" }
        return "\(Self.dollars(promptUSDPerMillion)) in · \(Self.dollars(completionUSDPerMillion)) out per 1M tokens"
    }

    /// The picker's one-line summary: "$0.08 in · $0.17 out per 1M · 1M
    /// context", or "Free · 1M context".
    public var pickerLine: String {
        let price = isFree
            ? "Free"
            : "\(Self.dollars(promptUSDPerMillion)) in · \(Self.dollars(completionUSDPerMillion)) out per 1M"
        return "\(price) · \(contextLabel)"
    }

    /// "1M context", "200K context".
    public var contextLabel: String {
        if contextLength >= 1_000_000 {
            let millions = Double(contextLength) / 1_000_000
            // 1,048,576 reads as "1M", 1,310,720 as "1.3M".
            let rounded = (millions * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded))M context" : "\(rounded)M context"
        }
        return "\(Int((Double(contextLength) / 1_000).rounded()))K context"
    }

    /// Whole dollars without decimals ("$2"), otherwise cents ("$0.20",
    /// "$1.25"); a price under a cent keeps a third digit ("$0.075") rather
    /// than rounding to "$0.08" and lying about the cheapest rows.
    static func dollars(_ value: Double) -> String {
        if value == value.rounded() { return "$\(Int(value))" }
        let cents = (value * 100).rounded() / 100
        if abs(cents - value) < 0.0005 {
            return "$" + String(format: "%.2f", value)
        }
        return "$" + String(format: "%.3f", value)
    }
}

/// Parses `GET https://openrouter.ai/api/v1/models`. Pure: no network, no
/// disk. The store below owns both.
public enum OpenRouterModelCatalog {

    /// The live endpoint. Public, unauthenticated.
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!

    private struct Envelope: Decodable {
        var data: [Entry]
    }

    /// Only the fields the picker needs; everything else in the payload is
    /// ignored so a new key on OpenRouter's side can never break the parse.
    private struct Entry: Decodable {
        var id: String
        var name: String?
        var contextLength: Int?
        var pricing: Pricing?
        var architecture: Architecture?

        struct Pricing: Decodable {
            var prompt: String?
            var completion: String?
        }

        struct Architecture: Decodable {
            var outputModalities: [String]?
        }
    }

    /// Text-output models only, minus the `:batch` variants (a different
    /// billing path Ask can't use), the `~` router aliases (not a model),
    /// and any row whose price OpenRouter can't state — "-1" is its sentinel
    /// for routers priced per upstream model (openrouter/fusion), and a
    /// missing or unparseable price is no better; either would otherwise
    /// masquerade as $0 and land in the Free section. Sorted by name.
    /// Pricing strings are USD per token; the result is USD per million.
    public static func parse(_ data: Data) throws -> [OpenRouterModel] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(Envelope.self, from: data)

        var seen = Set<String>()
        var models: [OpenRouterModel] = []
        for entry in envelope.data {
            let id = entry.id
            guard !id.hasSuffix(":batch"), !id.hasPrefix("~") else { continue }
            guard entry.architecture?.outputModalities?.contains("text") == true else { continue }
            guard let prompt = perMillion(entry.pricing?.prompt),
                  let completion = perMillion(entry.pricing?.completion) else { continue }
            guard seen.insert(id).inserted else { continue }
            models.append(OpenRouterModel(
                id: id,
                name: entry.name?.isEmpty == false ? entry.name! : id,
                contextLength: entry.contextLength ?? 0,
                promptUSDPerMillion: prompt,
                completionUSDPerMillion: completion
            ))
        }
        return models.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Nil for a price that isn't one: missing, unparseable, or negative.
    private static func perMillion(_ perToken: String?) -> Double? {
        guard let perToken, let value = Double(perToken), value.isFinite, value >= 0 else { return nil }
        return value * 1_000_000
    }
}

/// Loads the OpenRouter catalogue: a disk copy under Caches first (24h TTL,
/// still served stale when a refresh fails), the network when the copy is
/// old or missing, and the curated list when there is neither. Every list
/// that arrives — live or cached — is registered with `ProviderCatalog` so
/// a picked model keeps its context budget.
///
/// Under any `-uiTest…` launch flag the store never touches the network or
/// the disk and returns the curated list only, so UI tests are deterministic
/// offline.
public actor OpenRouterModelStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// Where a list came from — the picker says so when it is the curated
    /// fallback.
    public enum Source: Sendable, Equatable {
        case live, cache, curated
    }

    public struct Loaded: Sendable, Equatable {
        public let models: [OpenRouterModel]
        public let source: Source
    }

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var models: [OpenRouterModel]
    }

    private let cacheURL: URL
    private let timeToLive: TimeInterval
    private let curatedOnly: Bool
    private let now: @Sendable () -> Date
    private let fetch: Fetch
    private var memory: CacheFile?

    /// - Parameters:
    ///   - cacheURL: the JSON file to keep the list in; defaults to
    ///     `OpenRouterModels.json` under the user's Caches directory.
    ///   - timeToLive: how long a copy is served without a refresh.
    ///   - arguments: the process arguments; any `-uiTest…` flag pins the
    ///     store to the curated list.
    ///   - fetch: the network call; defaults to `URLSession.shared`.
    public init(
        cacheURL: URL? = nil,
        timeToLive: TimeInterval = 24 * 60 * 60,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: Fetch? = nil
    ) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.timeToLive = timeToLive
        self.curatedOnly = arguments.contains { $0.hasPrefix("-uiTest") }
        self.now = now
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    private static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenRouterModels.json")
    }

    /// The disk copy, whatever its age, with no network — for a launch-time
    /// registration so a persisted live-picked model keeps its budget before
    /// Settings is ever opened. Empty when there is none (or under a UI-test
    /// flag).
    public func cachedModels() -> [OpenRouterModel] {
        guard !curatedOnly else { return [] }
        let cached = readCache()
        if let cached { ProviderCatalog.registerOpenRouterModels(cached.models) }
        return cached?.models ?? []
    }

    /// Cached first, then refreshed: a copy younger than the TTL is served
    /// as-is; otherwise the network is tried, and a failure falls back to the
    /// stale copy, then to the curated list.
    public func load() async -> Loaded {
        guard !curatedOnly else {
            return Loaded(models: ProviderCatalog.openRouterCurated, source: .curated)
        }
        let cached = memory ?? readCache()
        if let cached, isFresh(cached) {
            memory = cached
            ProviderCatalog.registerOpenRouterModels(cached.models)
            return Loaded(models: cached.models, source: .cache)
        }
        do {
            let data = try await fetch(OpenRouterModelCatalog.endpoint)
            let models = try OpenRouterModelCatalog.parse(data)
            guard !models.isEmpty else { throw URLError(.zeroByteResource) }
            let fresh = CacheFile(fetchedAt: now(), models: models)
            memory = fresh
            writeCache(fresh)
            ProviderCatalog.registerOpenRouterModels(models)
            return Loaded(models: models, source: .live)
        } catch {
            if let cached, !cached.models.isEmpty {
                memory = cached
                ProviderCatalog.registerOpenRouterModels(cached.models)
                return Loaded(models: cached.models, source: .cache)
            }
            return Loaded(models: ProviderCatalog.openRouterCurated, source: .curated)
        }
    }

    /// `load().models` — the list, from wherever it came.
    public func models() async -> [OpenRouterModel] {
        await load().models
    }

    /// Within the TTL — and not from the future: a clock corrected backwards
    /// leaves a stamp ahead of now, and a negative age would otherwise pass
    /// as "younger than the TTL" for as long as the clock stayed behind it.
    private func isFresh(_ cached: CacheFile) -> Bool {
        let age = now().timeIntervalSince(cached.fetchedAt)
        return age >= 0 && age <= timeToLive
    }

    private func readCache() -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheFile.self, from: data)
    }

    private func writeCache(_ file: CacheFile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
