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
    ///
    /// Unicode extensions are dropped: `Locale.current.identifier` can hand
    /// back things like `en_US@rg=inzzzz` (a region-override set in system
    /// settings), and carrying the `@…` through made the exact-locale match
    /// fail against every installed voice — so an en-US book fell through to a
    /// language-wide search and picked whatever sorted first across all the
    /// English locales.
    static func normalized(_ tag: String) -> String {
        let base = tag.split(separator: "@", maxSplits: 1).first.map(String.init) ?? tag
        return base.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

/// Chooses which voice reads a book.
///
/// The book's language leads, because the platform's default follows the
/// *device's* language and a French novel read in an English voice is
/// unlistenable. Within a language, though, the platform's default is a better
/// judge than any rule of ours — it is the voice Apple ships as the sensible
/// one — so it is deferred to for ties rather than reranked from scratch.
public struct VoiceSelector: Sendable {
    public init() {}

    /// The voice to narrate with, given the book's language and what is
    /// installed. In order: the reader's explicit choice if it is still
    /// installed, an exact locale match, any voice for the same language, then
    /// nil — which leaves the engine to fall back to its own default rather
    /// than reading a book aloud in the wrong language.
    ///
    /// `systemDefault` is the voice the platform itself would use for that
    /// language, and it breaks ties **above** the alphabetical order. Without
    /// it macOS reads English books in "Albert": every installed English voice
    /// there reports the same quality tier, so the name comparison decided
    /// everything, and macOS ships novelty voices (Albert, Bad News, Bahh,
    /// Bells, Boing, Bubbles, Cellos…) that sort ahead of every real one.
    /// Quality still wins first, so an enhanced voice the reader downloaded is
    /// still preferred over a compact system default.
    public func voice(
        for language: String?,
        in voices: [SpeechVoice],
        preferring voiceID: String? = nil,
        systemDefault: String? = nil
    ) -> SpeechVoice? {
        if let voiceID, let chosen = voices.first(where: { $0.id == voiceID }) {
            return chosen
        }
        guard let language else { return nil }
        let tag = SpeechVoice.normalized(language)
        guard !tag.isEmpty else { return nil }

        let exact = voices.filter { SpeechVoice.normalized($0.language) == tag }
        if let best = sorted(exact, systemDefault: systemDefault).first {
            return best
        }
        let code = tag.split(separator: "-").first.map(String.init) ?? tag
        return sorted(
            voices.filter { $0.languageCode == code }, systemDefault: systemDefault
        ).first
    }

    /// Voices that could read a book in `language`, best first — what the
    /// voice picker lists. An unrecognised or missing language lists
    /// everything rather than nothing, so the reader can still choose.
    public func voices(
        matching language: String?,
        in voices: [SpeechVoice],
        systemDefault: String? = nil
    ) -> [SpeechVoice] {
        guard let language else { return sorted(voices, systemDefault: systemDefault) }
        let code = SpeechVoice.normalized(language).split(separator: "-")
            .first.map(String.init) ?? ""
        let matches = voices.filter { $0.languageCode == code }
        return sorted(matches.isEmpty ? voices : matches, systemDefault: systemDefault)
    }

    /// Best first: quality, then the platform's own default for the language,
    /// then name. The middle term is what keeps a picker from opening on a
    /// wall of novelty voices — see `voice(for:in:preferring:systemDefault:)`.
    private func sorted(
        _ voices: [SpeechVoice], systemDefault: String?
    ) -> [SpeechVoice] {
        voices.sorted { first, second in
            if first.quality != second.quality { return first.quality > second.quality }
            let firstIsDefault = first.id == systemDefault
            let secondIsDefault = second.id == systemDefault
            if firstIsDefault != secondIsDefault { return firstIsDefault }
            return first.name < second.name
        }
    }
}
