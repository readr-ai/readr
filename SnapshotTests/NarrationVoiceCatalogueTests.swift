import XCTest
import ReadrKit
@testable import Readr

@MainActor
final class NarrationVoiceCatalogueTests: XCTestCase {
    private final class Engine: SpeechEngine, NarrationVoiceCataloguing {
        weak var delegate: (any SpeechEngineDelegate)?
        let state: SpeechEngineState = .idle
        var spoken = 0
        let voice = SpeechVoice(id: "readr.voice.kokoro.fixture", name: "Offline narrator", language: "en-US", quality: .premium, family: .modern)
        func voices(for language: String) -> [SpeechVoice] { language == "en" ? [voice] : [] }
        func speak(_ request: SpeechRequest) { spoken += 1 }
        func pause() {}
        func resume() {}
        func stop() {}
    }
    func testEngineCatalogueIsResolvedBeforeFirstListenWithoutStartingSynthesis() {
        let engine = Engine()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = NarrationModel(defaults: defaults, engine: engine)
        let book = Book(metadata: BookMetadata(title: "English", language: "en"), chapters: [], estimatedTokenCount: 0)
        model.prepareVoices(for: book)
        XCTAssertEqual(model.voices.map(\.id), [engine.voice.id])
        XCTAssertEqual(model.voiceName, engine.voice.name)
        XCTAssertEqual(engine.spoken, 0)
    }
    func testPersistedSystemVoiceIsReplacedByAnOfferedNeuralVoice() {
        let engine = Engine()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("com.apple.speech.synthesis.voice.legacy", forKey: "narrationVoiceID2")
        let model = NarrationModel(defaults: defaults, engine: engine)
        model.prepareVoices(for: Book(metadata: BookMetadata(title: "English", language: "en"), chapters: [], estimatedTokenCount: 0))
        XCTAssertEqual(model.voiceID, engine.voice.id)
        XCTAssertEqual(engine.spoken, 0)
    }
    func testUnsupportedEngineLanguageOffersNoFallbackVoice() {
        let engine = Engine()
        let model = NarrationModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, engine: engine)
        model.prepareVoices(for: Book(metadata: BookMetadata(title: "French", language: "fr"), chapters: [], estimatedTokenCount: 0))
        XCTAssertTrue(model.voices.isEmpty)
        XCTAssertTrue(model.readrVoiceUnavailable)
        XCTAssertEqual(engine.spoken, 0)
    }
}
