import Foundation

/// A voice the narration engine can speak with, described without reference to
/// any particular synthesizer so the picker, the matching rules, and their
/// tests stay platform-agnostic.
public struct SpeechVoice: Hashable, Sendable, Identifiable, Codable {
    /// Quality tier. Apple ships a compact voice for every language and lets
    /// the reader download better ones; when both are installed the better one
    /// should win by default, which is what the ordering here is for.
    public enum Quality: Int, Hashable, Sendable, Codable, Comparable, CaseIterable {
        case standard = 0
        case enhanced = 1
        case premium = 2

        public static func < (lhs: Quality, rhs: Quality) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Engine-specific identifier, persisted as the reader's choice.
    public var id: String
    public var name: String
    /// BCP-47 language tag, e.g. `en-GB`.
    public var language: String
    public var quality: Quality

    public init(id: String, name: String, language: String, quality: Quality = .standard) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    /// Primary language subtag, lowercased — `en` for both `en-GB` and `EN_us`.
    public var languageCode: String {
        Self.normalized(language).split(separator: "-").first.map(String.init) ?? ""
    }

    /// Lowercased, hyphen-separated form of a language tag, so `en_US`, `EN-us`
    /// and `en-US` compare equal (platforms and EPUB metadata disagree here).
    static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

/// Chooses which voice reads a book.
///
/// Pure rules rather than "whatever the system defaults to": a French novel
/// read in an English voice is unlistenable, and Apple's default is the
/// device's language, not the book's.
public struct VoiceSelector: Sendable {
    public init() {}

    /// The voice to narrate with, given the book's language and what is
    /// installed. In order: the reader's explicit choice if it is still
    /// installed, an exact locale match, any voice for the same language, then
    /// nil — which leaves the engine to fall back to its own default rather
    /// than reading a book aloud in the wrong language.
    ///
    /// Within a tier the best quality wins, ties broken by name so the choice
    /// is stable across launches (the installed list has no guaranteed order).
    public func voice(
        for language: String?,
        in voices: [SpeechVoice],
        preferring voiceID: String? = nil
    ) -> SpeechVoice? {
        if let voiceID, let chosen = voices.first(where: { $0.id == voiceID }) {
            return chosen
        }
        guard let language else { return nil }
        let tag = SpeechVoice.normalized(language)
        guard !tag.isEmpty else { return nil }

        if let exact = best(of: voices.filter { SpeechVoice.normalized($0.language) == tag }) {
            return exact
        }
        let code = tag.split(separator: "-").first.map(String.init) ?? tag
        return best(of: voices.filter { $0.languageCode == code })
    }

    /// Voices that could read a book in `language`, best first — what the
    /// voice picker lists. An unrecognised or missing language lists
    /// everything rather than nothing, so the reader can still choose.
    public func voices(matching language: String?, in voices: [SpeechVoice]) -> [SpeechVoice] {
        guard let language else { return sorted(voices) }
        let code = SpeechVoice.normalized(language).split(separator: "-")
            .first.map(String.init) ?? ""
        let matches = voices.filter { $0.languageCode == code }
        return sorted(matches.isEmpty ? voices : matches)
    }

    private func best(of voices: [SpeechVoice]) -> SpeechVoice? {
        sorted(voices).first
    }

    private func sorted(_ voices: [SpeechVoice]) -> [SpeechVoice] {
        voices.sorted {
            $0.quality == $1.quality ? $0.name < $1.name : $0.quality > $1.quality
        }
    }
}
