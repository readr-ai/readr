import Foundation

/// The reader's voice preferences, in human terms: `rate` 1.0 is "how this
/// voice normally speaks", 1.5 is half again as fast. The mapping onto a
/// particular synthesizer's scale happens in `platformRate(normal:minimum:
/// maximum:)`, so the stored preference survives an engine swap and can be
/// tested without one.
///
/// Every value is clamped on the way in — including when decoded, since a
/// persisted file can be edited or written by a build with different limits,
/// and a rate of 40 is silence in practice.
public struct SpeechSettings: Hashable, Sendable, Codable {
    public static let rateRange: ClosedRange<Double> = 0.5...2.0
    public static let pitchRange: ClosedRange<Double> = 0.5...2.0
    public static let volumeRange: ClosedRange<Double> = 0.0...1.0

    /// The speeds the speed control cycles through.
    public static let rateSteps: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public var rate: Double {
        didSet { rate = Self.clamp(rate, to: Self.rateRange) }
    }
    public var pitch: Double {
        didSet { pitch = Self.clamp(pitch, to: Self.pitchRange) }
    }
    public var volume: Double {
        didSet { volume = Self.clamp(volume, to: Self.volumeRange) }
    }
    /// Chosen voice, or nil to let the engine pick one for the book's language.
    public var voiceID: String?
    /// Whether narration reads on into the next chapter. Off stops at each
    /// chapter end — the audiobook equivalent of putting the book down.
    public var autoAdvancesChapters: Bool

    public init(
        rate: Double = 1,
        pitch: Double = 1,
        volume: Double = 1,
        voiceID: String? = nil,
        autoAdvancesChapters: Bool = true
    ) {
        // Property observers don't run during initialization, so clamp here.
        self.rate = Self.clamp(rate, to: Self.rateRange)
        self.pitch = Self.clamp(pitch, to: Self.pitchRange)
        self.volume = Self.clamp(volume, to: Self.volumeRange)
        self.voiceID = voiceID
        self.autoAdvancesChapters = autoAdvancesChapters
    }

    // MARK: - Rate

    /// Fraction of the engine's headroom above `normal` that one whole step of
    /// requested speed-up costs.
    ///
    /// A synthesizer's rate scale is not proportional to how fast you actually
    /// hear the words, and above its default it climbs steeply. Spreading the
    /// reader's 1×…2× linearly across the engine's remaining range — the
    /// obvious mapping, and the one shipped first — made every label above 1×
    /// roughly a double lie. Measured against AVFoundation on macOS by
    /// rendering the synthesizer's own PCM and timing one sentence:
    ///
    ///     label   engine rate   spoken   actual
    ///     0.75×   0.250         6.11s    0.77×   ✓
    ///     1×      0.500         4.70s    1.00×   ✓
    ///     1.25×   0.625         2.74s    1.71×
    ///     1.5×    0.750         1.89s    2.49×
    ///     1.75×   0.875         1.51s    3.11×
    ///     2×      1.000         1.17s    4.04×
    ///
    /// The slow half was honest, so it keeps its linear mapping. The fast half
    /// is inverted through that curve instead: roughly a third of the headroom
    /// buys a genuine doubling, so 2× means twice as fast rather than four
    /// times. Empirical — worth re-measuring if the engine changes.
    private static let fastHeadroomPerStep = 0.344

    /// `rate` expressed on a synthesizer's own scale, where `normal` is its
    /// default speaking rate and `minimum`/`maximum` are its limits. 1.0 maps
    /// to `normal` exactly, and the label is meant to be the truth: 1.5× should
    /// take two thirds of the time, not two fifths.
    ///
    /// The fast end therefore stops short of `maximum` — the engine's top rate
    /// is far faster than anyone asked for, and reaching it was the bug.
    public func platformRate(normal: Double, minimum: Double, maximum: Double) -> Double {
        guard rate > 1 else {
            let fraction = (1 - rate) / (1 - Self.rateRange.lowerBound)
            return normal - (normal - minimum) * fraction
        }
        let headroom = maximum - normal
        return min(maximum, normal + (rate - 1) * headroom * Self.fastHeadroomPerStep)
    }

    /// The next speed the speed control should offer, wrapping past the top
    /// back to the slowest.
    public func cyclingRate() -> Double {
        Self.rateSteps.first { $0 > rate + 0.001 } ?? Self.rateSteps[0]
    }

    /// A speed formatted the way the control labels it ("1×", "1.25×").
    public static func rateLabel(_ rate: Double) -> String {
        let rounded = (rate * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\u{00D7}"
        }
        return "\(rounded)\u{00D7}"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case rate, pitch, volume, voiceID, autoAdvancesChapters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Routed through the clamping initializer — see the type's doc.
        self.init(
            rate: try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1,
            pitch: try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 1,
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            voiceID: try container.decodeIfPresent(String.self, forKey: .voiceID),
            autoAdvancesChapters: try container.decodeIfPresent(
                Bool.self, forKey: .autoAdvancesChapters
            ) ?? true
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
