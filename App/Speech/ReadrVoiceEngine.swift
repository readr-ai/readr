import Foundation
import ReadrKit

/// A Kokoro ("Readr Voice") engine, whichever runtime is behind it — CoreML
/// on macOS (`KokoroSpeechEngine`), MLX on iPhone and iPad
/// (`MLXKokoroSpeechEngine`). `RoutingSpeechEngine` prepares exactly one of
/// them per platform and reports its readiness to the Listen bar through
/// this seam, so the model and the bar never need to know which one it is.
protocol ReadrVoiceEngine: SpeechEngine {
    var readiness: ReadrVoiceReadiness { get }
    /// Fires on the main thread when `readiness` changes.
    var onReadinessChange: ((ReadrVoiceReadiness) -> Void)? { get set }
    var isReady: Bool { get }
    /// Start the model download/load without speaking, so the first sentence
    /// doesn't carry the whole wait.
    func prepare()
}
