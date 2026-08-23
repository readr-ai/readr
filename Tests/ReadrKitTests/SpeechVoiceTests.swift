import XCTest
@testable import ReadrKit

/// Which voice reads the book. Getting this wrong is not a subtle bug — a
/// French novel read by an English voice is unlistenable — and the rules can't
/// be checked on a device without knowing what happens to be installed there.
final class SpeechVoiceTests: XCTestCase {

    private let selector = VoiceSelector()

    private let catalog = [
        SpeechVoice(id: "en-US.compact", name: "Samantha", language: "en-US"),
        SpeechVoice(id: "en-US.premium", name: "Ava", language: "en-US", quality: .premium),
        SpeechVoice(id: "en-GB.enhanced", name: "Daniel", language: "en-GB", quality: .enhanced),
        SpeechVoice(id: "fr-FR.compact", name: "Thomas", language: "fr-FR"),
        SpeechVoice(id: "de-DE.compact", name: "Anna", language: "de-DE"),
    ]

    // MARK: - Matching

    func testExactLocaleWinsOverTheSameLanguage() {
        let voice = selector.voice(for: "en-GB", in: catalog)
        XCTAssertEqual(voice?.id, "en-GB.enhanced")
    }

    func testHigherQualityWinsWithinTheSameLocale() {
        let voice = selector.voice(for: "en-US", in: catalog)
        XCTAssertEqual(voice?.id, "en-US.premium")
    }

    func testALanguageWithoutAnExactLocaleFallsBackToTheSameLanguage() {
        let voice = selector.voice(for: "en-AU", in: catalog)
        XCTAssertEqual(voice?.id, "en-US.premium", "Best English voice available")
    }

    func testBareLanguageTagsMatch() {
        XCTAssertEqual(selector.voice(for: "fr", in: catalog)?.id, "fr-FR.compact")
    }

    func testTagsAreMatchedCaseAndSeparatorInsensitively() {
        // EPUB metadata and platform voice lists disagree about `en_US` vs
        // `en-US` vs `EN-us`.
        XCTAssertEqual(selector.voice(for: "EN_us", in: catalog)?.id, "en-US.premium")
    }

    func testAnUnavailableLanguageChoosesNothingRatherThanTheWrongOne() {
        XCTAssertNil(
            selector.voice(for: "ja-JP", in: catalog),
            "Better to let the engine default than read Japanese in German"
        )
        XCTAssertNil(selector.voice(for: nil, in: catalog))
        XCTAssertNil(selector.voice(for: "  ", in: catalog))
        XCTAssertNil(selector.voice(for: "en-US", in: []))
    }

    // MARK: - The platform's own default

    func testTheSystemDefaultBreaksTiesAheadOfTheAlphabet() {
        // The bug this exists for: on macOS every installed English voice
        // reports the same quality tier, so the name comparison decided
        // everything — and macOS ships novelty voices that sort first. An
        // English book was read aloud by "Albert".
        let macOSish = [
            SpeechVoice(id: "albert", name: "Albert", language: "en-US"),
            SpeechVoice(id: "bad-news", name: "Bad News", language: "en-US"),
            SpeechVoice(id: "bubbles", name: "Bubbles", language: "en-US"),
            SpeechVoice(id: "samantha", name: "Samantha", language: "en-US"),
        ]
        let chosen = selector.voice(for: "en-US", in: macOSish, systemDefault: "samantha")
        XCTAssertEqual(chosen?.id, "samantha")
        XCTAssertEqual(
            selector.voices(matching: "en-US", in: macOSish, systemDefault: "samantha").first?.id,
            "samantha",
            "The picker opens on the sensible voice, not the joke ones"
        )
    }

    func testQualityStillOutranksTheSystemDefault() {
        // A voice the reader downloaded is better than the compact one the
        // system defaults to — this is the iOS case, where the tiers differ.
        let voices = [
            SpeechVoice(id: "compact", name: "Samantha", language: "en-US"),
            SpeechVoice(id: "enhanced", name: "Zoe", language: "en-US", quality: .enhanced),
        ]
        XCTAssertEqual(
            selector.voice(for: "en-US", in: voices, systemDefault: "compact")?.id,
            "enhanced"
        )
    }

    func testAnExplicitChoiceStillBeatsTheSystemDefault() {
        XCTAssertEqual(
            selector.voice(
                for: "en-US", in: catalog, preferring: "en-GB.enhanced",
                systemDefault: "en-US.compact"
            )?.id,
            "en-GB.enhanced"
        )
    }

    func testLocaleExtensionsAreIgnoredWhenMatching() {
        // `Locale.current.identifier` hands back "en_US@rg=inzzzz" when a
        // region override is set in system settings. Carrying the extension
        // through made the exact-locale match fail against every installed
        // voice, widening the search to every English variant.
        XCTAssertEqual(
            selector.voice(for: "en_US@rg=inzzzz", in: catalog)?.id, "en-US.premium"
        )
        XCTAssertEqual(
            SpeechVoice(id: "x", name: "X", language: "en_US@rg=inzzzz").languageCode, "en"
        )
    }

    func testTheVoiceFamilyOutranksEverythingBelowIt() {
        // macOS reports every generation at the same quality tier, so nothing
        // below family could separate a narration voice from a novelty one.
        let mixed = [
            SpeechVoice(id: "albert", name: "Albert", language: "en-US", family: .legacy),
            SpeechVoice(id: "eddy", name: "Eddy", language: "en-US", family: .alternate),
            SpeechVoice(id: "samantha", name: "Samantha", language: "en-US", family: .modern),
        ]
        XCTAssertEqual(
            selector.voices(matching: "en-US", in: mixed).map(\.id),
            ["samantha"],
            "The picker offers prose voices only — no accessibility or novelty rows"
        )
        XCTAssertEqual(selector.voice(for: "en-US", in: mixed)?.id, "samantha")
    }

    func testThePickerHidesAccessibilityAndNoveltyVoices() {
        // The DECtalk-style accessibility set and the novelty voices exist for
        // reasons that aren't an hour of prose, and on a stock Mac they were
        // most of the list — a wall between the reader and the real voices.
        // They are hidden from the picker but NOT from selection: a stored
        // choice of one (an accessibility user who wants Eloquence at speed)
        // is still honoured by `voice(for:preferring:)`.
        let mixed = [
            SpeechVoice(id: "albert", name: "Albert", language: "en-US", family: .legacy),
            SpeechVoice(id: "eddy", name: "Eddy", language: "en-US", family: .alternate),
            SpeechVoice(id: "samantha", name: "Samantha", language: "en-US", family: .modern),
        ]
        XCTAssertEqual(selector.voices(matching: "en-US", in: mixed).map(\.id), ["samantha"])
        XCTAssertEqual(
            selector.voice(for: "en-US", in: mixed, preferring: "eddy")?.id, "eddy",
            "A stored accessibility-voice choice keeps working"
        )
    }

    func testAnAllFilteredListFallsBackToEverything() {
        // If hiding the non-prose families would leave the picker empty (a
        // language whose only installed voice is an accessibility one), offer
        // them anyway — an empty picker helps nobody.
        let onlyAlternate = [
            SpeechVoice(id: "eddy", name: "Eddy", language: "en-US", family: .alternate),
        ]
        XCTAssertEqual(
            selector.voices(matching: "en-US", in: onlyAlternate).map(\.id), ["eddy"]
        )
    }

    func testBcp47ExtensionsAreStrippedToo() {
        // The `@rg=` spelling was fixed first and this one was still live
        // behind it: `Locale.current.identifier(.bcp47)` renders the same
        // region override as a `-u-` extension.
        XCTAssertEqual(
            selector.voice(for: "en-US-u-rg-inzzzz", in: catalog)?.id, "en-US.premium"
        )
        XCTAssertEqual(SpeechVoice.normalized("en-US-u-rg-inzzzz"), "en-us")
        XCTAssertEqual(SpeechVoice.normalized("en-x-private"), "en")
        XCTAssertEqual(
            SpeechVoice.normalized("zh-Hant-TW"), "zh-hant-tw",
            "A script subtag is not an extension"
        )
    }

    func testThePlatformsOwnDefaultIsNeverDemotedByItsFamily() {
        // The legacy prefix is not purely novelty: it holds Alex, Fred and
        // Victoria alongside Albert and Bubbles. Ranking that whole family last
        // would hand a Mac whose default is Alex a DECtalk voice instead.
        let mixed = [
            SpeechVoice(id: "albert", name: "Albert", language: "en-US", family: .legacy),
            SpeechVoice(id: "eddy", name: "Eddy", language: "en-US", family: .alternate),
            SpeechVoice(id: "alex", name: "Alex", language: "en-US", family: .legacy),
        ]
        XCTAssertEqual(
            selector.voices(matching: "en-US", in: mixed, systemDefault: "alex").map(\.id),
            ["alex"],
            "The blessed legacy voice is offered; the unblessed families are hidden"
        )
        XCTAssertEqual(
            selector.voice(for: "en-US", in: mixed, systemDefault: "alex")?.id, "alex"
        )
    }

    func testAQualityDownloadStillBeatsTheDefault() {
        // The exemption lifts the default to `.modern`, no further — it must not
        // become a trump card over quality.
        let voices = [
            SpeechVoice(
                id: "compact", name: "Compact", language: "en-US",
                quality: .standard, family: .legacy
            ),
            SpeechVoice(
                id: "enhanced", name: "Enhanced", language: "en-US",
                quality: .enhanced, family: .modern
            ),
        ]
        XCTAssertEqual(
            selector.voice(for: "en-US", in: voices, systemDefault: "compact")?.id,
            "enhanced"
        )
    }

    func testTheCasePreservingFormIsStillValidBcp47() {
        // What gets handed to a platform voice lookup, which parses it as
        // BCP-47 rather than comparing it to anything of ours — and which
        // honours a region override if one survives, answering with a voice
        // for the overriding region.
        XCTAssertEqual(SpeechVoice.withoutExtensions("en-US-u-rg-inzzzz"), "en-US")
        XCTAssertEqual(SpeechVoice.withoutExtensions("en_US@rg=inzzzz"), "en-US")
        XCTAssertEqual(SpeechVoice.withoutExtensions("zh-Hant-TW"), "zh-Hant-TW")
        XCTAssertEqual(SpeechVoice.withoutExtensions(" en-GB "), "en-GB")
    }

    // MARK: - The reader's own choice

    func testAnExplicitChoiceBeatsLanguageMatching() {
        let voice = selector.voice(for: "en-US", in: catalog, preferring: "fr-FR.compact")
        XCTAssertEqual(voice?.id, "fr-FR.compact")
    }

    func testAChoiceThatIsNoLongerInstalledFallsBackToMatching() {
        // Voices are downloadable and can be deleted between launches.
        let voice = selector.voice(for: "en-US", in: catalog, preferring: "en-IE.removed")
        XCTAssertEqual(voice?.id, "en-US.premium")
    }

    // MARK: - The picker's list

    func testTheListOffersTheBooksLanguageBestFirst() {
        let listed = selector.voices(matching: "en-US", in: catalog)
        XCTAssertEqual(listed.map(\.id), ["en-US.premium", "en-GB.enhanced", "en-US.compact"])
    }

    func testTheListFallsBackToEverythingWhenNothingMatches() {
        let listed = selector.voices(matching: "ja", in: catalog)
        XCTAssertEqual(listed.count, catalog.count, "A reader can still pick something")
        XCTAssertEqual(listed.first?.id, "en-US.premium", "Best quality first")
    }

    func testTheListIsStableForVoicesOfEqualQuality() {
        let listed = selector.voices(matching: nil, in: catalog)
        // Ties break by name, so the picker doesn't reshuffle between launches.
        XCTAssertEqual(
            listed.map(\.name), ["Ava", "Daniel", "Anna", "Samantha", "Thomas"]
        )
    }

    // MARK: - Model

    func testLanguageCodeStripsTheRegion() {
        XCTAssertEqual(SpeechVoice(id: "x", name: "X", language: "pt-BR").languageCode, "pt")
        XCTAssertEqual(SpeechVoice(id: "x", name: "X", language: "EN_us").languageCode, "en")
        XCTAssertEqual(SpeechVoice(id: "x", name: "X", language: "de").languageCode, "de")
    }

    func testPrimaryLanguageCodeOfARawTag() {
        XCTAssertEqual(SpeechVoice.primaryLanguageCode(of: "en-US"), "en")
        XCTAssertEqual(SpeechVoice.primaryLanguageCode(of: "en_GB@rg=uszzzz"), "en")
        XCTAssertEqual(SpeechVoice.primaryLanguageCode(of: "EN-us-u-rg-inzzzz"), "en")
        // Three-letter codes are their own languages, not prefixes of ours:
        // Middle English must never match an English-only voice.
        XCTAssertEqual(SpeechVoice.primaryLanguageCode(of: "enm"), "enm")
        XCTAssertEqual(SpeechVoice.primaryLanguageCode(of: ""), "")
    }

    func testQualityOrdersFromStandardToPremium() {
        XCTAssertLessThan(SpeechVoice.Quality.standard, SpeechVoice.Quality.enhanced)
        XCTAssertLessThan(SpeechVoice.Quality.enhanced, SpeechVoice.Quality.premium)
    }
}
