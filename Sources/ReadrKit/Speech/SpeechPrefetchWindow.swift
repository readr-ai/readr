import Foundation

/// Pure policy shared by speech engines that keep rate-independent audio on disk.
public enum SpeechPrefetchWindow {
    /// Converts cached 1x audio duration to listening time at the reader's rate.
    public static func playbackSeconds(
        audioSeconds: TimeInterval,
        rate: Double
    ) -> TimeInterval {
        let clampedRate = min(
            max(rate, SpeechSettings.rateRange.lowerBound),
            SpeechSettings.rateRange.upperBound
        )
        return max(0, audioSeconds) / clampedRate
    }

    /// The exclusive end of the prefix that fits in the remaining cache window.
    public static func endIndex(
        forAudioSeconds durations: [TimeInterval],
        capacitySeconds: TimeInterval,
        secondsBehindCursor: TimeInterval = 0
    ) -> Int {
        let budget = max(0, capacitySeconds - max(0, secondsBehindCursor))
        var total: TimeInterval = 0
        var end = 0
        for duration in durations {
            let next = max(0, duration)
            guard total + next <= budget else { break }
            total += next
            end += 1
        }
        return end
    }

    /// Whether another sentence belongs in the current foreground/background fill pass.
    public static func shouldRefill(
        frontier: Int,
        windowEnd: Int,
        bufferedSeconds: TimeInterval,
        isForeground: Bool,
        wasRefilling: Bool,
        startsBelow: TimeInterval,
        stopsAt: TimeInterval
    ) -> Bool {
        guard frontier < windowEnd else { return false }
        guard !isForeground else { return true }
        if wasRefilling {
            return bufferedSeconds < stopsAt
        }
        return bufferedSeconds < startsBelow
    }
}
