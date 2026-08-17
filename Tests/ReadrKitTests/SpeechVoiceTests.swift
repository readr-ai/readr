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

    func testQualityOrdersFromStandardToPremium() {
        XCTAssertLessThan(SpeechVoice.Quality.standard, SpeechVoice.Quality.enhanced)
        XCTAssertLessThan(SpeechVoice.Quality.enhanced, SpeechVoice.Quality.premium)
    }
}
