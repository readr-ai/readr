/// The engine a narration request lands on.
public enum NarrationEngineChoice: Equatable, Sendable {
    /// Kokoro through FluidAudio's CoreML port — macOS.
    case coreMLKokoro
    /// Kokoro on the Metal GPU through MLX — iPhone and iPad.
    case mlxKokoro
    /// The platform synthesizer (`AVSpeechSynthesizer`).
    case platform
}

/// Which engine speaks a request — the one routing rule, kept pure so every
/// row of it is table-tested (`NarrationEnginePolicyTests`).
///
/// The app's `RoutingSpeechEngine` evaluates this per sentence, which is
/// what makes the fallbacks seamless: while a model downloads, or while the
/// screen is locked on iOS, the platform voice reads that sentence and Readr
/// Voice returns at the next boundary once it can.
public enum NarrationEnginePolicy {

    /// Everything the rule looks at.
    public struct Situation: Hashable, Sendable {
        /// The request names a Readr Voice id (anything else is a platform
        /// voice, or nil for "pick for the language").
        public var requestsReadrVoice: Bool
        /// The CoreML engine can speak right now: this OS is outside the BNNS
        /// crash gate (`NeuralVoiceAvailability`) AND its model is loaded.
        public var coreMLKokoroUsable: Bool
        /// An MLX engine exists on this platform — an iOS/iPadOS device build
        /// with a Metal GPU. Never true on macOS or the iOS Simulator.
        public var mlxKokoroAvailable: Bool
        /// The MLX engine's weights and G2P assets are loaded.
        public var mlxKokoroReady: Bool
        /// The app is not backgrounded (from `didEnterBackground` until
        /// `willEnterForeground`, plus the engine's short head start on
        /// `willResignActive` for the lock — Control Center, banners and an
        /// iPad Split View neighbour do not count). Metal refuses GPU work
        /// from a backgrounded app and the refusal is an uncatchable abort
        /// (mlx-swift#274/#407), so MLX must not be entered with the screen
        /// locked. Always true where there is no MLX engine.
        public var isForeground: Bool

        public init(
            requestsReadrVoice: Bool,
            coreMLKokoroUsable: Bool,
            mlxKokoroAvailable: Bool,
            mlxKokoroReady: Bool,
            isForeground: Bool
        ) {
            self.requestsReadrVoice = requestsReadrVoice
            self.coreMLKokoroUsable = coreMLKokoroUsable
            self.mlxKokoroAvailable = mlxKokoroAvailable
            self.mlxKokoroReady = mlxKokoroReady
            self.isForeground = isForeground
        }
    }

    /// Platform voice ids go to the platform. Readr Voice goes to MLX where
    /// an MLX engine exists (iOS) — but only ready and in the foreground,
    /// otherwise the platform voice reads this sentence — and to CoreML
    /// where it doesn't (macOS) whenever CoreML can serve. A platform with
    /// an MLX engine never enters CoreML, even on an OS that passes the
    /// CoreML gate: one runtime and one model download per platform, and no
    /// BNNS exposure at all on the phone.
    public static func engine(for situation: Situation) -> NarrationEngineChoice {
        guard situation.requestsReadrVoice else { return .platform }
        if situation.mlxKokoroAvailable {
            return situation.mlxKokoroReady && situation.isForeground ? .mlxKokoro : .platform
        }
        return situation.coreMLKokoroUsable ? .coreMLKokoro : .platform
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
