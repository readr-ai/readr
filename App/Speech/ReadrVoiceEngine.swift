import Foundation
import ReadrKit

/// A Kokoro ("Readr Voice") engine, whichever runtime is behind it — CoreML
/// on macOS (`KokoroSpeechEngine`), MLX on iPhone and iPad
/// (`MLXKokoroSpeechEngine`). `RoutingSpeechEngine` prepares exactly one of
/// them per platform and reports its readiness to the Listen bar through
/// this seam, so the model and the bar never need to know which one it is.
///
/// A Readr Voice engine *waits* for its model: a request that arrives before
/// the first-use download is in is reported `isPreparing` to the delegate,
/// held, and spoken the moment the model lands — nothing else reads in the
/// meantime. A failed download is a `didFail`, and the way back is
/// `prepare()` again (the bar's Retry).
protocol ReadrVoiceEngine: SpeechEngine {
    var readiness: ReadrVoiceReadiness { get }
    /// Fires on the main thread when `readiness` changes.
    var onReadinessChange: ((ReadrVoiceReadiness) -> Void)? { get set }
    var isReady: Bool { get }
    /// Fraction of the model download done, 0...1, while the download
    /// library reports it; nil outside a download or when it cannot say
    /// (the load and warm-up that follow are indeterminate).
    var downloadProgress: Double? { get }
    /// Fires on the main thread when `downloadProgress` changes.
    var onDownloadProgressChange: ((Double?) -> Void)? { get set }
    /// Start the model download/load without speaking — the explicit pick
    /// and the Retry after a failure. Synchronous as far as `readiness` is
    /// concerned: a `.failed` engine leaves that state before this returns,
    /// so a request routed in the same turn sees an engine that will try.
    func prepare()
}
