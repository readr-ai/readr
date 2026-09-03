/// Where the Readr Voice (Kokoro) model stands between "picked" and
/// "audible", whichever runtime is behind it — CoreML on macOS, MLX on
/// iPhone and iPad. The Listen bar narrates this so a first-use download is
/// never a silent wait; until `.ready` the platform voice reads and the
/// switch happens at a sentence boundary.
public enum ReadrVoiceReadiness: Equatable, Sendable {
    /// No runtime can serve Readr Voice here: the OS build that crashes
    /// CoreML inside Apple's BNNS (macOS 26.4–26.5), or a device the MLX
    /// runtime cannot use (the iOS Simulator, no Metal GPU). The engine
    /// refuses every request and nothing is downloaded.
    case unsupported
    case notReady
    case downloading
    case ready
    case failed
}
