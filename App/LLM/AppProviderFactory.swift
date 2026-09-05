import Foundation
import ReadrKit

/// The app's `ProviderManager.ProviderFactory`: `DefaultProviderFactory` for
/// every kind the kit can build, plus the on-device model, whose runtime is
/// an Apple framework and therefore lives here rather than in `ReadrKit`
/// (which must keep building on platforms without it).
enum AppProviderFactory {

    static func factory(http: HTTPClient = URLSessionHTTPClient()) -> ProviderManager.ProviderFactory {
        let base = DefaultProviderFactory.factory(http: http)
        return { info, credentials in
            guard info.kind == .appleIntelligence else {
                return try base(info, credentials)
            }
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                return FoundationModelsProvider(info: info)
            }
            #endif
            throw ProviderManager.ProviderError.notConfigured(.appleIntelligence)
        }
    }
}
