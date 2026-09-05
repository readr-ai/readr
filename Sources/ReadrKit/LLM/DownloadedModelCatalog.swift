import Foundation

/// The language models Readr can download and run itself, on the MLX runtime
/// it already ships for Readr Voice (`.downloadedModel`). For readers whose
/// iPhone can't run Apple's on-device model — iOS 17–25, or hardware without
/// Apple Intelligence — this is the other way to ask a book without a key.
///
/// Weights are never bundled (the 4B model alone would blow the iOS 17
/// bundle cap); they download from Hugging Face on the reader's say-so, with
/// the size shown first (App Review 4.2.3(ii)). Which model is offered
/// follows the device's memory: a 4-bit 4B model wants ~3.5 GB resident, and
/// on a 6 GB phone that is the app's whole allowance.
public struct DownloadedModelSpec: Sendable, Hashable, Identifiable {
    /// The Hugging Face repository, which is also the catalog `modelID`.
    public var repository: String
    public var displayName: String
    /// Approximate download, for the disclosure before it starts.
    public var downloadBytes: Int64
    /// The least physical memory a device needs to hold the weights and a
    /// working KV cache alongside the app.
    public var minimumPhysicalMemory: Int64
    /// What the prompt may use, in tokens — well inside the model's window,
    /// chosen for the phone's memory rather than the model's limit.
    public var contextBudget: Int

    public var id: String { repository }

    public init(
        repository: String, displayName: String, downloadBytes: Int64,
        minimumPhysicalMemory: Int64, contextBudget: Int
    ) {
        self.repository = repository
        self.displayName = displayName
        self.downloadBytes = downloadBytes
        self.minimumPhysicalMemory = minimumPhysicalMemory
        self.contextBudget = contextBudget
    }

    /// "3.1 GB" — what the download button says.
    public var downloadSizeDescription: String {
        let gigabytes = Double(downloadBytes) / 1_000_000_000
        return String(format: "%.1f GB", gigabytes)
    }
}

public enum DownloadedModelCatalog {

    static let gigabyte: Int64 = 1_000_000_000

    /// Best first. Qwen3.5 is Apache-2.0, in the MLX community's 4-bit
    /// conversions, and the strongest small model on grounded question
    /// answering as of September 2026; the 2B variant is the only model
    /// with a measured footprint (~1.3 GB peak) that plausibly fits a 6 GB
    /// phone.
    public static let all: [DownloadedModelSpec] = [
        DownloadedModelSpec(
            repository: "mlx-community/Qwen3.5-4B-4bit",
            displayName: "Qwen3.5 4B",
            downloadBytes: 3_060_000_000,
            minimumPhysicalMemory: 7 * gigabyte + gigabyte / 2,
            contextBudget: 8_192
        ),
        DownloadedModelSpec(
            repository: "mlx-community/Qwen3.5-2B-4bit",
            displayName: "Qwen3.5 2B",
            downloadBytes: 1_750_000_000,
            minimumPhysicalMemory: 5 * gigabyte + gigabyte / 2,
            contextBudget: 8_192
        ),
    ]

    public static func spec(for repository: String) -> DownloadedModelSpec? {
        all.first { $0.repository == repository }
    }

    /// The models a device with this much memory can run, best first — the
    /// list Settings offers. Empty on a 4 GB phone, where none fits.
    public static func models(forPhysicalMemory bytes: Int64) -> [DownloadedModelSpec] {
        all.filter { $0.minimumPhysicalMemory <= bytes }
    }

    /// The model to offer by default for this much memory, or nil.
    public static func recommendedModel(forPhysicalMemory bytes: Int64) -> DownloadedModelSpec? {
        models(forPhysicalMemory: bytes).first
    }
}
