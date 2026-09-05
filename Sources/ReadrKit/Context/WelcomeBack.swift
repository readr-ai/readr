import Foundation

/// The rule behind the reader's welcome-back line: a one-line card above
/// the page, offering a spoiler-free recap, shown only when the reader
/// comes back to a book after a while away.
///
/// It needs nothing new stored. `BookState.lastOpenedAt` is already stamped
/// on every open; the reader compares the *previous* stamp with now before
/// that stamp is overwritten. The line then goes after a few page turns —
/// the reader has evidently picked the thread up — or on Recap or ✕, and it
/// is never persisted, so it can only come back after another absence.
public enum WelcomeBack {
    /// How long a reader must have been away before the line is offered.
    public static let minimumAbsence: TimeInterval = 24 * 60 * 60

    /// Page turns after which the line goes on its own.
    public static let pageTurnsBeforeDismissal = 3

    /// Scroll layout has no page turns, so there the line goes after this
    /// much reading time instead — the same "you have evidently picked the
    /// thread up" as three pages, measured the only way that layout can.
    public static let scrollReadingBeforeDismissal: TimeInterval = 2 * 60

    /// Whether to offer the line on this open.
    ///
    /// - `lastOpenedAt`: the stamp from *before* this open (nil ⇒ first open).
    /// - `hasProgress`: something has been read — a position past the very
    ///   start. A book opened and closed at page one has nothing to recap,
    ///   and a first open is a first open.
    public static func shouldOffer(lastOpenedAt: Date?, now: Date, hasProgress: Bool) -> Bool {
        guard hasProgress, let lastOpenedAt else { return false }
        return now.timeIntervalSince(lastOpenedAt) >= minimumAbsence
    }

    /// "Something has been read": any chapter past the first, or any offset
    /// into it. The reader's saved position at the top of page one is what
    /// a book opened and closed unread looks like.
    public static func hasProgress(_ position: ReadingPosition?) -> Bool {
        guard let position else { return false }
        return position.chapterIndex > 0 || position.characterOffset > 0
    }

    /// "it’s been 6 days" — the absence in the roundest honest unit. Days
    /// under two weeks, weeks under two months, months under a year, then
    /// years. Never "0 days": the rule above guarantees at least one.
    public static func absencePhrase(from lastOpenedAt: Date, to now: Date) -> String {
        let seconds = max(now.timeIntervalSince(lastOpenedAt), minimumAbsence)
        let days = Int(seconds / (24 * 60 * 60))
        let unit: (count: Int, singular: String, plural: String)
        switch days {
        case ..<14: unit = (days, "a day", "days")
        case ..<60: unit = (days / 7, "a week", "weeks")
        case ..<365: unit = (days / 30, "a month", "months")
        default: unit = (days / 365, "a year", "years")
        }
        let span = unit.count <= 1 ? unit.singular : "\(unit.count) \(unit.plural)"
        return "it\u{2019}s been \(span)"
    }
}
