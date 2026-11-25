/// The engine a narration request lands on.
public enum NarrationEngineChoice: Equatable, Sendable {
    /// Kokoro through FluidAudio's CoreML port — macOS.
    case coreMLKokoro
    /// Kokoro through MLX — iPhone and iPad.
    case mlxKokoro
    /// The platform synthesizer (`AVSpeechSynthesizer`).
    case platform
    /// No supported neural narrator. Report a recoverable error, never a system voice.
    case unavailable
}

/// Which engine speaks a request — the one routing rule, kept pure so every
/// row of it is table-tested (`NarrationEnginePolicyTests`).
///
/// The app applies this per sentence. A missing/failed Kokoro engine or a
/// legacy system-voice choice is unavailable. Downloading still selects Kokoro,
/// which prepares and waits. A system voice never reads in its place.
public enum NarrationEnginePolicy {

    /// Everything the rule looks at.
    public struct Situation: Hashable, Sendable {
        /// The request names a Readr Voice id (anything else is a platform
        /// voice, or nil for "pick for the language").
        public var requestsReadrVoice: Bool
        /// A CoreML engine exists — this OS is outside the BNNS crash gate
        /// (`NeuralVoiceAvailability`), so it was built — and it has not
        /// failed. Whether its model is loaded does not matter: it waits.
        public var coreMLKokoroAvailable: Bool
        /// An MLX engine exists on this platform — an iOS/iPadOS device build
        /// with a Metal GPU. Never true on macOS or the iOS Simulator.
        public var mlxKokoroAvailable: Bool
        /// The MLX engine gave up: its download failed in the foreground, or
        /// a synthesis hung. It refuses every request until re-prepared.
        public var mlxKokoroFailed: Bool

        public init(
            requestsReadrVoice: Bool,
            coreMLKokoroAvailable: Bool,
            mlxKokoroAvailable: Bool,
            mlxKokoroFailed: Bool
        ) {
            self.requestsReadrVoice = requestsReadrVoice
            self.coreMLKokoroAvailable = coreMLKokoroAvailable
            self.mlxKokoroAvailable = mlxKokoroAvailable
            self.mlxKokoroFailed = mlxKokoroFailed
        }
    }

    /// Platform voice ids go to the platform. Readr Voice goes to MLX where
    /// an MLX engine exists (iOS) unless that engine has failed, and to
    /// CoreML where it doesn't (macOS) whenever a CoreML engine can serve. A
    /// platform with an MLX engine never enters CoreML, even on an OS that
    /// passes the CoreML gate: one runtime and one model download per
    /// platform, and no BNNS exposure at all on the phone.
    public static func engine(for situation: Situation) -> NarrationEngineChoice {
        guard situation.requestsReadrVoice else { return .unavailable }
        if situation.mlxKokoroAvailable {
            return situation.mlxKokoroFailed ? .unavailable : .mlxKokoro
        }
        return situation.coreMLKokoroAvailable ? .coreMLKokoro : .unavailable
    }

    /// The Kokoro runtime a platform prepares (downloads and warms) for
    /// Readr Voice.
    public enum KokoroRuntime: Equatable, Sendable {
        case coreML
        case mlx
    }

    /// Nil when neither runtime can serve — Readr Voice is then not offered.
    public static func kokoroRuntime(mlxAvailable: Bool, coreMLSupported: Bool) -> KokoroRuntime? {
        if mlxAvailable { return .mlx }
        if coreMLSupported { return .coreML }
        return nil
    }
}
