import Foundation

/// When narration should stop on its own.
public enum SleepTimer: Hashable, Sendable {
    case off
    /// Stop after a stretch of *listening* — time spent paused doesn't count.
    case after(minutes: Int)
    /// Stop when the current chapter ends, rather than reading on.
    case endOfChapter

    /// The durations the sleep control offers.
    public static let minuteOptions = [5, 10, 15, 30, 45, 60]

    public var isOn: Bool { self != .off }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case let .after(minutes): return "\(max(1, minutes)) min"
        case .endOfChapter: return "End of chapter"
        }
    }
}

/// The live state of a sleep timer: its mode and, for a timed one, when it
/// expires.
///
/// Kept apart from `NarrationController` so the arithmetic that matters —
/// pausing must not burn the countdown, and re-arming must restart it — is
/// testable against injected dates instead of a real clock.
public struct SleepTimerState: Hashable, Sendable {
    public private(set) var mode: SleepTimer
    /// When a timed sleep expires; nil when off or paused.
    public private(set) var deadline: Date?
    /// Time left at the moment narration was paused, restored on resume.
    private var heldRemaining: TimeInterval?

    public init(mode: SleepTimer = .off) {
        self.mode = mode
        self.deadline = nil
        self.heldRemaining = nil
    }

    /// Whether narration should stop rather than cross into the next chapter.
    public var stopsAtChapterEnd: Bool { mode == .endOfChapter }

    /// Set the mode and start counting. Re-arming the mode already set
    /// restarts it, which is what a reader tapping "15 min" again means.
    public mutating func arm(_ mode: SleepTimer, at now: Date) {
        self.mode = mode
        heldRemaining = nil
        switch mode {
        case let .after(minutes):
            deadline = now.addingTimeInterval(Double(max(1, minutes)) * 60)
        case .off, .endOfChapter:
            deadline = nil
        }
    }

    public mutating func disarm() {
        mode = .off
        deadline = nil
        heldRemaining = nil
    }

    /// Hold the countdown while narration is paused — a reader who pauses for
    /// lunch should still get the 15 minutes they asked for.
    public mutating func pause(at now: Date) {
        guard let deadline else { return }
        heldRemaining = max(0, deadline.timeIntervalSince(now))
        self.deadline = nil
    }

    public mutating func resume(at now: Date) {
        guard let heldRemaining else { return }
        deadline = now.addingTimeInterval(heldRemaining)
        self.heldRemaining = nil
    }

    /// True once a timed sleep has run out. Chapter-end sleeps never expire on
    /// the clock — `stopsAtChapterEnd` is checked at the chapter boundary.
    public func hasExpired(at now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// Time left for the countdown readout, or nil when nothing is counting.
    public func remaining(at now: Date) -> TimeInterval? {
        if let deadline { return max(0, deadline.timeIntervalSince(now)) }
        return heldRemaining
    }
}
