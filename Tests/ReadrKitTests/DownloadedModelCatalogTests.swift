import XCTest
@testable import ReadrKit

/// Which downloadable model a phone is offered follows its memory, not the
/// model's ambitions.
final class DownloadedModelCatalogTests: XCTestCase {

    private let gigabyte: Int64 = 1_000_000_000

    func testAnEightGigabytePhoneIsOfferedTheFourBModelFirst() {
        let offered = DownloadedModelCatalog.models(forPhysicalMemory: 8 * gigabyte)
        XCTAssertEqual(offered.map(\.displayName), ["Qwen3.5 4B", "Qwen3.5 2B"])
        XCTAssertEqual(
            DownloadedModelCatalog.recommendedModel(forPhysicalMemory: 8 * gigabyte)?.repository,
            "mlx-community/Qwen3.5-4B-4bit"
        )
    }

    func testASixGigabytePhoneGetsOnlyTheTwoBModel() {
        let offered = DownloadedModelCatalog.models(forPhysicalMemory: 6 * gigabyte)
        XCTAssertEqual(offered.map(\.displayName), ["Qwen3.5 2B"])
    }

    func testAFourGigabytePhoneIsOfferedNothing() {
        XCTAssertTrue(DownloadedModelCatalog.models(forPhysicalMemory: 4 * gigabyte).isEmpty)
        XCTAssertNil(DownloadedModelCatalog.recommendedModel(forPhysicalMemory: 4 * gigabyte))
    }

    func testTheDownloadSizeIsDisclosedInGigabytes() {
        XCTAssertEqual(DownloadedModelCatalog.spec(for: "mlx-community/Qwen3.5-4B-4bit")?.downloadSizeDescription, "3.1 GB")
        XCTAssertEqual(DownloadedModelCatalog.spec(for: "mlx-community/Qwen3.5-2B-4bit")?.downloadSizeDescription, "1.8 GB")
        XCTAssertNil(DownloadedModelCatalog.spec(for: "nobody/nothing"))
    }

    /// The provider catalog mirrors this list, so Settings' model picker and
    /// the download store agree on what exists.
    func testTheProviderCatalogMirrorsTheDownloadableModels() {
        let infos = ProviderCatalog.models(for: .downloadedModel)
        XCTAssertEqual(infos.map(\.modelID), DownloadedModelCatalog.all.map(\.repository))
        for info in infos {
            XCTAssertTrue(info.isLocal)
            XCTAssertFalse(info.supportsPromptCaching)
            XCTAssertEqual(info.contextBudget, DownloadedModelCatalog.spec(for: info.modelID)?.contextBudget)
        }
        XCTAssertTrue(ProviderInfo.Kind.downloadedModel.isOnDevice)
        XCTAssertFalse(ProviderInfo.Kind.downloadedModel.usesAPIKey)
        XCTAssertEqual(ProviderVendor.vendor(for: .downloadedModel)?.badge, "On-device")
    }

    func testTheKitFactoryRefusesTheDownloadedModel() {
        let info = ProviderCatalog.defaultModel(for: .downloadedModel)
        XCTAssertThrowsError(try DefaultProviderFactory.make(info: info, credentials: nil, http: MockHTTPClient())) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.downloadedModel))
        }
    }
}
