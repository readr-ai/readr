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

    /// How suited a voice is to reading prose for an hour, as judged by the
    /// platform layer — which is the only layer that can tell. macOS installs
    /// three distinct generations side by side and reports them all as the same
    /// quality tier: the modern narration voices, the DECtalk-style accessibility
    /// voices, and a legacy set that includes the novelty ones (Albert, Bad News,
    /// Bubbles) — which also turn out to follow a completely different speaking-
    /// rate curve, so a reader who picked one would get wrong speeds too.
    ///
    /// Deliberately not a list of names: the app derives this from the
    /// identifier's family prefix, so it keeps working as the platform adds
    /// voices.
    public enum Family: Int, Hashable, Sendable, Codable, Comparable, CaseIterable {
        case legacy = 0
        case alternate = 1
        case modern = 2

        public static func < (lhs: Family, rhs: Family) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Engine-specific identifier, persisted as the reader's choice.
    public var id: String
    public var name: String
    /// BCP-47 language tag, e.g. `en-GB`.
    public var language: String
    public var quality: Quality
    public var family: Family

    public init(
        id: String,
        name: String,
        language: String,
        quality: Quality = .standard,
        family: Family = .modern
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.family = family
    }

    /// Primary language subtag, lowercased — `en` for both `en-GB` and `EN_us`.
    public var languageCode: String {
        Self.normalized(language).split(separator: "-").first.map(String.init) ?? ""
    }

    /// A language tag with its extensions removed and its separators regular,
    /// but its **case left alone** — `en_US@rg=inzzzz` and `en-US-u-rg-inzzzz`
    /// both become `en-US`.
    ///
    /// This is the form to hand a platform API that resolves a tag to a voice.
    /// A region override set in system settings arrives as one of those two
    /// spellings, and `AVSpeechSynthesisVoice(language:)` *honours* the
    /// override: on a Mac set to en-US with `rg=IN` it answers Rishi (en-IN),
    /// a voice that isn't even in the en-US list the picker shows — so the
    /// checked row and the first row disagreed with each other. Case is
    /// preserved because the platform is being asked to parse this as BCP-47,
    /// not to compare it against anything of ours.
    ///
    /// Everything from the first single-character subtag onwards is a BCP-47
    /// singleton extension (`-u-`, `-t-`, `-x-`), so cutting there closes the
    /// whole class rather than one more spelling of it. A script subtag
    /// (`zh-Hant-TW`) is four characters and survives.
    public static func withoutExtensions(_ tag: String) -> String {
        let base = tag.split(separator: "@", maxSplits: 1).first.map(String.init) ?? tag
        let cleaned = base.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespaces)
        var kept: [Substring] = []
        for subtag in cleaned.split(separator: "-") {
            if kept.count > 0, subtag.count == 1 { break }
            kept.append(subtag)
        }
        return kept.joined(separator: "-")
    }

    /// The same thing lowercased, so `en_US`, `EN-us` and `en-US` compare equal
    /// (platforms and EPUB metadata disagree here). This is the matching form —
    /// everything Readr compares a tag against goes through it.
    ///
    /// The `@` spelling was fixed first and the `-u-` spelling was still live
    /// behind it: the device that found the first was matching on the second.
    /// Carried through, either one makes the exact-locale match fail against
    /// every installed voice, so a book falls through to a language-wide search
    /// and takes whatever sorts first across every locale of that language.
    static func normalized(_ tag: String) -> String {
        withoutExtensions(tag).lowercased()
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

    /// Best first: family, then quality, then the platform's own default for
    /// the language, then name — with the platform's default exempt from the
    /// family rule.
    ///
    /// Family leads because the platform reports every generation of voice at
    /// the same quality tier, so nothing below it could separate a narration
    /// voice from a novelty one — a picker sorted without it opened on Albert,
    /// Bad News, Bahh, Bells, Boing and Bubbles.
    ///
    /// But family is a heuristic over identifier prefixes, and the legacy
    /// prefix is not purely novelty: `com.apple.speech.synthesis.voice.` holds
    /// Alex, Fred, Victoria and Kathy as well as Albert and Bubbles. Demoting
    /// that whole prefix beneath the DECtalk-style voices would mean a Mac
    /// whose own default is Alex — a serious narration voice — silently getting
    /// an accessibility voice instead. So a voice the platform *names* as its
    /// default is never demoted by family: the platform blessing it is direct
    /// evidence, where the prefix is only an inference, and no novelty voice is
    /// ever a system default. Below that pair the heuristic still decides.
    private func sorted(
        _ voices: [SpeechVoice], systemDefault: String?
    ) -> [SpeechVoice] {
        func family(of voice: SpeechVoice) -> SpeechVoice.Family {
            voice.id == systemDefault ? max(voice.family, .modern) : voice.family
        }
        return voices.sorted { first, second in
            let firstFamily = family(of: first)
            let secondFamily = family(of: second)
            if firstFamily != secondFamily { return firstFamily > secondFamily }
            if first.quality != second.quality { return first.quality > second.quality }
            let firstIsDefault = first.id == systemDefault
            let secondIsDefault = second.id == systemDefault
            if firstIsDefault != secondIsDefault { return firstIsDefault }
            return first.name < second.name
        }
    }
}
