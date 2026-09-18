import Foundation

/// Reader-controlled defaults for the Ask surface.
///
/// Kept in one place so Settings, an already-open Ask panel, and a newly
/// created conversation all read the same keys and bounds.
enum AskPreferences {
    static let answerFontSizeKey = "ask.answerFontSize"
    static let contextRangeKey = "ask.contextRange"

    static let defaultAnswerFontSize = 15.0
    static let minimumAnswerFontSize = 12.0
    static let maximumAnswerFontSize = 22.0

    static func clampedAnswerFontSize(_ value: Double) -> Double {
        min(max(value, minimumAnswerFontSize), maximumAnswerFontSize)
    }

    static var defaultContextRange: AskContextRange {
        get {
            guard let raw = UserDefaults.standard.string(forKey: contextRangeKey) else {
                return .nearby
            }
            return AskContextRange(rawValue: raw) ?? .nearby
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: contextRangeKey)
        }
    }
}

/// How much of the book the next Ask question may draw from.
enum AskContextRange: String, CaseIterable, Identifiable, Sendable {
    /// The passage in hand, its neighboring paragraphs, and retrieval hits.
    case nearby
    /// Everything before the current reading position.
    case readSoFar
    /// The complete book, including unread chapters.
    case wholeBook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearby: return "Nearby"
        case .readSoFar: return "Read so far"
        case .wholeBook: return "Whole book"
        }
    }

    var note: String {
        switch self {
        case .nearby:
            return "The passage in question, nearby paragraphs, and passages found by search. Cheapest."
        case .readSoFar:
            return "Everything you have read, without spoilers. Sent in full when the model can hold it."
        case .wholeBook:
            return "The entire book, including chapters you have not read yet."
        }
    }
}
