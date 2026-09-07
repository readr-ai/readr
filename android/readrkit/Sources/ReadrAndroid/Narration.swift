import Foundation
import ReadrKit

// Listen on Android: ReadrKit's `NarrationController` over the platform
// synthesizer, which Kotlin owns (`android.speech.tts.TextToSpeech`).
//
// The split is the Apple one. Every playback rule — which sentence is next,
// what a skip does to a "finished" callback that was already in flight, how a
// speed change resumes mid-sentence, when the sleep timer burns — lives in
// the kit, where it is unit-tested against a mock engine. This file is glue:
// a Kotlin-implemented `SpeechBackend` behind the kit's `SpeechEngine`, the
// UTF-16 ↔ Character conversion every offset crossing the bridge goes
// through, and one JSON snapshot the Compose card draws from.
//
// THREADING. `NarrationController` is main-thread-confined, and there is no
// dispatch queue on this side to hop with: Swift's main thread *is* the
// Android main looper thread. So every method on `AndroidNarration` and
// `NarrationEvents` must be called from Kotlin's main thread — Kotlin's
// `UtteranceProgressListener` posts its callbacks to the main looper for
// exactly this reason. Nothing here takes a lock, because nothing here is
// ever on two threads.

// MARK: - The platform synthesizer, as Kotlin implements it

/// The phone's own text-to-speech, supplied by Kotlin.
///
/// The boundary rules of `Package.swift` apply: `Int64` rather than `Int`, no
/// optionals, no throws. `voiceID` and `language` are `""` rather than nil
/// when there is nothing to say.
public protocol SpeechBackend {
  /// Speak `text`, replacing anything in flight. `requestID` comes back on
  /// every callback so a late report from a cancelled utterance can be told
  /// apart from the one being spoken.
  ///
  /// `rate` is already on the platform's own scale (see
  /// `BridgedSpeechEngine.platformRate(_:)`) — Kotlin hands it straight to
  /// `setSpeechRate` and does no arithmetic of its own.
  func speak(
    _ requestID: String, text: String, language: String, voiceID: String,
    rate: Double, pitch: Double, volume: Double)
  /// Hold the utterance where it is. Android's synthesizer has no pause, so
  /// Kotlin stops it and remembers the last word boundary; `state()` must
  /// report `paused` afterwards.
  func pause()
  /// Pick the held utterance back up — for Android, re-speaking its
  /// remainder under the same `requestID`, with word boundaries rebased so
  /// this side never learns that the text was cut.
  func resume()
  /// Stop and discard. No finish follows.
  func stop()
  /// `"idle"`, `"speaking"` or `"paused"`, truthfully: this is what the
  /// controller's stall watchdog reads, and a completion callback going
  /// missing is exactly the case it exists for. State kept in a variable that
  /// only those callbacks update would report `speaking` forever precisely
  /// when it mattered.
  func state() -> String
  /// `[{id, name, language, quality, isDefault}]`, quality one of
  /// `standard`/`enhanced`/`premium`. `[]` before the engine is ready.
  func voicesJSON() -> String
}

/// One installed voice, as Kotlin describes it.
private struct VoiceWire: Codable {
  var id: String
  var name: String
  var language: String
  var quality: String?
  var isDefault: Bool?

  var quality_: SpeechVoice.Quality {
    switch quality {
    case "premium": return .premium
    case "enhanced": return .enhanced
    default: return .standard
    }
  }
}

// MARK: - What the reader's card is told

/// Where narration is, as the Compose card follows it. Kotlin implements it;
/// the facade calls it from the main thread, in the middle of a controller
/// call, so every method must be quick and must not throw.
///
/// Only what actually changed is reported: the card is redrawn from these,
/// and a once-a-second tick that republished the same sentence would be a
/// recomposition a second for as long as the book is read aloud.
public protocol NarrationObserver {
  /// `idle`, `preparing`, `speaking`, `paused` or `finished`.
  func statusChanged(_ status: String)
  /// Where the voice is (`utf16Offset`, to the word) and where the sentence
  /// it is in began (`utf16SentenceStart`) — the page follows the first, the
  /// reading position is saved from the second. Both UTF-16, in the chapter.
  func positionChanged(_ chapterIndex: Int64, utf16Offset: Int64, utf16SentenceStart: Int64)
  /// The word being spoken, in chapter UTF-16 offsets.
  func spokenRange(_ chapterIndex: Int64, utf16Start: Int64, utf16End: Int64)
  /// The sentence being read, collapsed for display (see `displaySentence`).
  func sentenceChanged(_ text: String)
  /// `{"mode":…,"minutes":…,"remainingSeconds":…}` — the sleep control's readout.
  func sleepTimerChanged(_ json: String)
  /// Why narration stopped without the reader asking: `""` for nothing,
  /// else a token `holdText(for:)` turns into the sentence the card shows.
  func holdChanged(_ reason: String)
}

// MARK: - Engine callbacks, as Kotlin makes them

/// The synthesizer reporting back. Kotlin holds one of these and calls it
/// from its `UtteranceProgressListener`, always on the main looper.
///
/// It is a class rather than a protocol because the traffic goes the other
/// way: Kotlin implements `SpeechBackend`, and calls *into* this. Kotlin
/// constructs it (its arena owns it), hands it to the backend, and passes it
/// to `AndroidNarration`, which is where it meets the engine it feeds.
public final class NarrationEvents {
  /// The engine these reports belong to. Weak: `AndroidNarration` owns the
  /// engine, and a Kotlin-held events object must not keep a finished
  /// listening session alive.
  weak var engine: BridgedSpeechEngine?

  public init() {}

  /// Audio for the utterance has started.
  public func didBegin(_ requestID: String) {
    engine?.didBegin(requestID)
  }

  /// The utterance was spoken through to its end. Never sent for one the
  /// controller stopped.
  public func didFinish(_ requestID: String) {
    engine?.didFinish(requestID)
  }

  /// The engine is about to speak `utf16Start..<utf16End` **of the request's
  /// own text**. Offsets are Kotlin's (UTF-16); the facade converts them into
  /// the Character offsets the kit addresses text with.
  ///
  /// After a resume the platform speaks only the remainder of the sentence,
  /// and Kotlin adds back where it cut — so these are always offsets into the
  /// text this side handed over, whole.
  public func willSpeak(_ requestID: String, utf16Start: Int64, utf16End: Int64) {
    engine?.willSpeak(requestID, utf16Start: Int(utf16Start), utf16End: Int(utf16End))
  }

  /// The utterance could not be spoken. `diagnostic` is for the log — the
  /// sentence the reader sees is this side's (`SpeechBackendError`), the same
  /// rule `NanoProbe` follows: Kotlin reports a state, never copy.
  public func didFail(_ requestID: String, message diagnostic: String) {
    engine?.didFail(requestID, diagnostic: diagnostic)
  }
}

/// What the reader is told when the phone's voice refuses an utterance. The
/// engine's own code goes to the log and no further.
struct SpeechBackendError: LocalizedError {
  let diagnostic: String
  var errorDescription: String? { "The phone\u{2019}s voice couldn\u{2019}t read that." }
}

// MARK: - The kit's engine over the backend

/// ReadrKit's `SpeechEngine` over a Kotlin `SpeechBackend` — the Android
/// counterpart of `AVSpeechEngine`.
final class BridgedSpeechEngine: SpeechEngine {
  weak var delegate: (any SpeechEngineDelegate)?

  private let backend: any SpeechBackend
  /// The utterance the backend is on, and the table for *its* text: word
  /// boundaries arrive as UTF-16 offsets into exactly this string.
  private var activeID: String?
  private var activeOffsets: UTF16OffsetTable?

  init(backend: any SpeechBackend) {
    self.backend = backend
  }

  /// Asked of the backend rather than tracked here, for the reason
  /// `AVSpeechEngine.state` gives: this is the stall watchdog's only
  /// evidence, and evidence that comes from the callbacks it is watching for
  /// is no evidence at all.
  var state: SpeechEngineState {
    switch backend.state() {
    case "speaking": return .speaking
    case "paused": return .paused
    default: return .idle
    }
  }

  func speak(_ request: SpeechRequest) {
    let id = request.id.uuidString
    activeID = id
    // Built per request, not per chapter: a request is one sentence, so this
    // is a walk over a few dozen characters.
    activeOffsets = UTF16OffsetTable(request.text)
    backend.speak(
      id,
      text: request.text,
      // The form a platform is meant to resolve as BCP-47: extensions cut,
      // case left alone (see `SpeechVoice.withoutExtensions`).
      language: request.language.map(SpeechVoice.withoutExtensions) ?? "",
      voiceID: request.voiceID ?? "",
      rate: Self.platformRate(request.rate),
      pitch: min(max(request.pitch, 0.5), 2.0),
      volume: min(max(request.volume, 0), 1))
  }

  func pause() { backend.pause() }

  func resume() { backend.resume() }

  func stop() {
    // Cleared first: a report for this utterance that lands after the stop
    // is stale by construction, exactly as `AVSpeechEngine` treats one for a
    // replaced `AVSpeechUtterance`.
    activeID = nil
    activeOffsets = nil
    backend.stop()
  }

  // MARK: Callbacks

  func didBegin(_ requestID: String) {
    guard requestID == activeID, let id = UUID(uuidString: requestID) else { return }
    delegate?.speechEngine(self, didBeginSpeaking: id)
  }

  func didFinish(_ requestID: String) {
    guard requestID == activeID, let id = UUID(uuidString: requestID) else { return }
    activeID = nil
    activeOffsets = nil
    delegate?.speechEngine(self, didFinish: id)
  }

  func willSpeak(_ requestID: String, utf16Start: Int, utf16End: Int) {
    guard requestID == activeID, let id = UUID(uuidString: requestID),
      let offsets = activeOffsets
    else { return }
    let lower = offsets.characterOffset(ofUTF16: utf16Start)
    let upper = offsets.characterOffset(ofUTF16: utf16End)
    guard lower < upper else { return }
    delegate?.speechEngine(self, willSpeak: lower..<upper, of: id)
  }

  func didFail(_ requestID: String, diagnostic: String) {
    guard requestID == activeID, let id = UUID(uuidString: requestID) else { return }
    activeID = nil
    activeOffsets = nil
    delegate?.speechEngine(
      self, didFail: id, error: SpeechBackendError(diagnostic: diagnostic))
  }

  // MARK: Rate

  /// Android's `TextToSpeech.setSpeechRate` normal pace.
  static let platformNormalRate = 1.0
  /// The bottom of the useful range. The platform documents its scale as
  /// proportional ("0.5 is half the normal speech rate"), and the reader's
  /// slowest offered speed is 0.75×, which `SpeechSettings` maps linearly —
  /// so 0.5 here is the value that makes a 0.75× label mean 0.75× exactly.
  static let platformMinimumRate = 0.5
  /// The top of the range handed to `SpeechSettings.platformRate`.
  ///
  /// Not the engine's ceiling — a *calibration*. The kit's fast half is bent
  /// through a curve measured against AVFoundation, where the engine's own
  /// scale climbs far faster than the words do (see
  /// `SpeechSettings.fastHeadroomPerStep`). Android's scale does not: it is
  /// documented as proportional, and Google's engine measured that way on
  /// the emulator. Declaring a ceiling of 1 + 1/0.344 ≈ 3.907 is what makes
  /// the kit's curve come back out straight here, so 2× is twice as fast and
  /// not four times. Empirical on both ends — worth re-deriving if the kit's
  /// constant changes or a phone's engine turns out to bend its own scale.
  static let platformMaximumRate = 3.907

  /// The reader's speed multiplier on the platform's scale.
  static func platformRate(_ rate: Double) -> Double {
    SpeechSettings(rate: rate).platformRate(
      normal: platformNormalRate, minimum: platformMinimumRate, maximum: platformMaximumRate)
  }
}

// MARK: - Wire shapes

/// The whole of what the Listen card draws, in one call.
private struct NarrationStateWire: Codable {
  var status: String
  /// Why narration is paused without the reader asking, or nil.
  var holdReason: String?
  /// The sentence for that hold — this side's words, never Kotlin's.
  var holdText: String?
  var chapterIndex: Int
  var utf16Offset: Int
  var utf16SentenceStart: Int
  var sentence: String
  var chapterProgress: Double
  var sleepTimer: SleepTimerWire
  var rate: Double
  var voiceID: String?
}

private struct SleepTimerWire: Codable {
  var mode: String
  var minutes: Int?
  var remainingSeconds: Int?
}

/// The sentence being read, as a chapter range — what Ask quotes when it is
/// opened while the voice is going.
private struct SentenceRangeWire: Codable {
  var chapterIndex: Int
  var utf16Start: Int
  var utf16End: Int
}

/// What `setSleepTimer` takes: `{"mode":"off"|"after"|"endOfChapter","minutes":N}`.
private struct SleepTimerRequest: Codable {
  var mode: String
  var minutes: Int?
}

// MARK: - The facade

/// One book being read aloud.
///
/// Built on the main thread and driven from it — see the threading note at
/// the top of this file. Kotlin holds one of these per listening session and
/// lets it go when the card closes.
public final class AndroidNarration {
  private let controller: NarrationController?
  private let engine: BridgedSpeechEngine
  private let backend: any SpeechBackend
  private let observer: any NarrationObserver
  private let offsets: OffsetTableCache
  private let book: Book?
  /// The last values published to the observer, so a tick that changes
  /// nothing costs no recomposition.
  private var lastStatus = ""
  private var lastSentence = ""
  private var lastPosition: (chapter: Int, offset: Int, sentence: Int)?
  private var lastSleep = ""
  private var lastHold = ""

  /// - Parameters:
  ///   - events: the callback object Kotlin also handed to `backend`. It is
  ///     constructed on the Kotlin side (its arena owns it) and wired to the
  ///     engine here, which is the only place both halves are in scope.
  ///   - settingsJSON: the reader's stored speed and voice, as
  ///     `SpeechSettings` encodes itself. `""` (or anything unreadable) is
  ///     the default: a preferences file is not a contract.
  public init(
    library: AndroidLibrary,
    bookID: String,
    backend: any SpeechBackend,
    events: NarrationEvents,
    observer: any NarrationObserver,
    settingsJSON: String
  ) {
    self.observer = observer
    self.backend = backend
    self.offsets = library.offsetTables
    let engine = BridgedSpeechEngine(backend: backend)
    self.engine = engine
    events.engine = engine

    let book = try? library.book(bookID)
    self.book = book
    guard let book else {
      // A book that is no longer in the library: everything below is a
      // no-op and `stateJSON` reports idle. Nothing here can throw — a
      // bridged initializer has nowhere to put an error — and a card that
      // never opens is a better answer than a crash.
      controller = nil
      return
    }

    var settings = Self.settings(from: settingsJSON)
    settings.voiceID = Self.resolvedVoiceID(
      preferring: settings.voiceID, language: book.metadata.language, backend: backend)
    let controller = NarrationController(book: book, engine: engine, settings: settings)
    self.controller = controller
    controller.onStatusChange = { [weak self] _ in self?.publish() }
    controller.onPositionChange = { [weak self] _ in self?.publish() }
    controller.onSpokenRangeChange = { [weak self] chapterIndex, range in
      self?.publishSpokenRange(chapterIndex, range)
    }
  }

  // MARK: Controls

  /// Start reading. `anchor` is `"nextSentenceStart"` (the top of the visible
  /// page, or a chapter picked from Contents) or `"sentenceContaining"` (a
  /// selection — the reader means the sentence their finger is on).
  public func start(chapterIndex: Int64, utf16Offset: Int64, anchor: String) {
    guard let controller, let book else { return }
    let index = Int(chapterIndex)
    guard book.chapters.indices.contains(index) else { return }
    let offset = offsets.table(for: book, chapterIndex: index)
      .characterOffset(ofUTF16: Int(utf16Offset))
    controller.start(
      atChapter: index, characterOffset: offset,
      anchor: anchor == "sentenceContaining" ? .sentenceContaining : .nextSentenceStart)
    publish()
  }

  public func play() {
    controller?.play()
    publish()
  }

  public func pause() {
    controller?.pause()
    publish()
  }

  public func togglePlayPause() {
    controller?.togglePlayPause()
    publish()
  }

  /// Close the card: the audio stops and the place is forgotten. What the
  /// reader keeps is the reading position, which Kotlin has already saved
  /// from the sentence starts this reported.
  public func stop() {
    controller?.stop()
    publish()
  }

  public func skipToNextSentence() {
    controller?.skipToNextSentence()
    publish()
  }

  public func skipToPreviousSentence() {
    controller?.skipToPreviousSentence()
    publish()
  }

  public func skipToNextChapter() {
    controller?.skipToNextChapter()
    publish()
  }

  public func skipToPreviousChapter() {
    controller?.skipToPreviousChapter()
    publish()
  }

  /// Set the speaking speed. The kit clamps it; read `stateJSON` back rather
  /// than storing what was asked for.
  public func setRate(_ rate: Double) {
    controller?.settings.rate = rate
    publish()
  }

  /// Pick a voice. `""` hands the choice back to the engine's own default for
  /// the book's language.
  public func setVoice(_ voiceID: String) {
    controller?.settings.voiceID = voiceID.isEmpty ? nil : voiceID
    publish()
  }

  /// Arm, re-arm or clear the sleep timer.
  public func setSleepTimer(_ json: String) {
    guard let controller else { return }
    let request = (try? JSONDecoder().decode(SleepTimerRequest.self, from: Data(json.utf8)))
      ?? SleepTimerRequest(mode: "off", minutes: nil)
    switch request.mode {
    case "after": controller.setSleepTimer(.after(minutes: max(1, request.minutes ?? 15)))
    case "endOfChapter": controller.setSleepTimer(.endOfChapter)
    default: controller.setSleepTimer(.off)
    }
    publish()
  }

  /// The once-a-second beat the sleep timer and the stall watchdog need — the
  /// controller has no clock of its own.
  public func tick() {
    controller?.tick()
    publish()
  }

  // MARK: State

  public func isUnderway() -> Bool { controller?.isUnderway ?? false }

  public func isActive() -> Bool { controller?.isActive ?? false }

  /// Everything the card draws, in one call.
  public func stateJSON() -> String {
    let wire = state()
    guard let data = try? AndroidLibrary.encoder().encode(wire) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The sentence being read as a chapter range, or `""` when nothing is —
  /// what Ask asks about when it is opened with no selection while the voice
  /// is going. Taken from the segment rather than from the displayed
  /// sentence, whose runs of spaces have been collapsed: that string's length
  /// is not the sentence's.
  public func currentSentenceRangeJSON() -> String {
    guard let book, let segment = controller?.currentSegment,
      book.chapters.indices.contains(segment.chapterIndex)
    else { return "" }
    let table = offsets.table(for: book, chapterIndex: segment.chapterIndex)
    let wire = SentenceRangeWire(
      chapterIndex: segment.chapterIndex,
      utf16Start: table.utf16Offset(ofCharacter: segment.range.lowerBound),
      utf16End: table.utf16Offset(ofCharacter: segment.range.upperBound))
    guard let data = try? AndroidLibrary.encoder().encode(wire) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The voices worth offering for this book, best first — the kit's own
  /// ordering (`VoiceSelector`) over what the phone has installed. Asked of
  /// the backend each time, so a voice the reader downloads mid-book shows up
  /// without the session being rebuilt.
  public func voicesJSON() -> String {
    let installed = Self.installedVoices(backend.voicesJSON())
    let offered = VoiceSelector().voices(
      matching: book?.metadata.language, in: installed.voices,
      systemDefault: installed.systemDefault)
    let wire = offered.map {
      VoiceWire(
        id: $0.id, name: $0.name, language: $0.language,
        quality: Self.name(of: $0.quality), isDefault: $0.id == installed.systemDefault)
    }
    guard let data = try? AndroidLibrary.encoder().encode(wire) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Publishing

  /// Report what has changed since the last publish, and nothing else.
  private func publish() {
    let wire = state()

    if wire.status != lastStatus {
      lastStatus = wire.status
      observer.statusChanged(wire.status)
    }
    let hold = wire.holdReason ?? ""
    if hold != lastHold {
      lastHold = hold
      observer.holdChanged(hold)
    }
    let position = (wire.chapterIndex, wire.utf16Offset, wire.utf16SentenceStart)
    if lastPosition == nil || lastPosition! != position {
      lastPosition = position
      observer.positionChanged(
        Int64(position.0), utf16Offset: Int64(position.1),
        utf16SentenceStart: Int64(position.2))
    }
    if wire.sentence != lastSentence {
      lastSentence = wire.sentence
      observer.sentenceChanged(wire.sentence)
    }
    if let data = try? AndroidLibrary.encoder().encode(wire.sleepTimer) {
      let json = String(decoding: data, as: UTF8.self)
      if json != lastSleep {
        lastSleep = json
        observer.sleepTimerChanged(json)
      }
    }
  }

  private func publishSpokenRange(_ chapterIndex: Int, _ range: Range<Int>) {
    guard let book, book.chapters.indices.contains(chapterIndex) else { return }
    let table = offsets.table(for: book, chapterIndex: chapterIndex)
    observer.spokenRange(
      Int64(chapterIndex),
      utf16Start: Int64(table.utf16Offset(ofCharacter: range.lowerBound)),
      utf16End: Int64(table.utf16Offset(ofCharacter: range.upperBound)))
  }

  private func state() -> NarrationStateWire {
    guard let controller, let book else {
      return NarrationStateWire(
        status: "idle", holdReason: nil, holdText: nil, chapterIndex: -1, utf16Offset: 0,
        utf16SentenceStart: 0, sentence: "", chapterProgress: 0,
        sleepTimer: SleepTimerWire(mode: "off", minutes: nil, remainingSeconds: nil),
        rate: 1, voiceID: nil)
    }
    var chapterIndex = -1
    var utf16Offset = 0
    var utf16SentenceStart = 0
    if let position = controller.position,
      book.chapters.indices.contains(position.chapterIndex) {
      let table = offsets.table(for: book, chapterIndex: position.chapterIndex)
      chapterIndex = position.chapterIndex
      utf16Offset = table.utf16Offset(ofCharacter: position.characterOffset)
      utf16SentenceStart = table.utf16Offset(ofCharacter: position.sentenceStart)
    }
    let hold = controller.holdReason
    return NarrationStateWire(
      status: Self.name(of: controller.status),
      holdReason: hold.map(Self.name(of:)),
      holdText: hold.map(Self.holdText(for:)),
      chapterIndex: chapterIndex,
      utf16Offset: utf16Offset,
      utf16SentenceStart: utf16SentenceStart,
      sentence: Self.displaySentence(controller.currentSegment?.text ?? ""),
      chapterProgress: controller.chapterProgress,
      sleepTimer: Self.sleepWire(controller),
      rate: controller.settings.rate,
      voiceID: controller.settings.voiceID)
  }

  // MARK: Helpers

  private struct InstalledVoices {
    var voices: [SpeechVoice]
    var systemDefault: String?
  }

  private static func installedVoices(_ json: String) -> InstalledVoices {
    let wire = (try? JSONDecoder().decode([VoiceWire].self, from: Data(json.utf8))) ?? []
    return InstalledVoices(
      voices: wire.map {
        // Android has one generation of voice, so `family` says nothing here
        // and everything is `.modern` — the tier the selector treats as prose.
        SpeechVoice(
          id: $0.id, name: $0.name, language: $0.language, quality: $0.quality_, family: .modern)
      },
      systemDefault: wire.first(where: { $0.isDefault == true })?.id)
  }

  /// The voice to read this book in: the reader's stored choice while it is
  /// still installed, then the kit's own rule over what the phone has — an
  /// exact locale match, then the language, then nothing, which leaves the
  /// engine its default rather than reading a French novel in English.
  private static func resolvedVoiceID(
    preferring stored: String?, language: String?, backend: any SpeechBackend
  ) -> String? {
    let installed = installedVoices(backend.voicesJSON())
    guard !installed.voices.isEmpty else { return stored }
    return VoiceSelector().voice(
      for: language, in: installed.voices, preferring: stored,
      systemDefault: installed.systemDefault)?.id ?? stored
  }

  private static func settings(from json: String) -> SpeechSettings {
    guard !json.isEmpty,
      let decoded = try? JSONDecoder().decode(SpeechSettings.self, from: Data(json.utf8))
    else { return SpeechSettings() }
    return decoded
  }

  private static func sleepWire(_ controller: NarrationController) -> SleepTimerWire {
    let remaining = controller.sleepTimerRemaining().map { Int($0.rounded()) }
    switch controller.sleepTimer.mode {
    case .off:
      return SleepTimerWire(mode: "off", minutes: nil, remainingSeconds: nil)
    case let .after(minutes):
      return SleepTimerWire(mode: "after", minutes: minutes, remainingSeconds: remaining)
    case .endOfChapter:
      return SleepTimerWire(mode: "endOfChapter", minutes: nil, remainingSeconds: nil)
    }
  }

  private static func name(of status: NarrationStatus) -> String {
    switch status {
    case .idle: return "idle"
    case .preparing: return "preparing"
    case .speaking: return "speaking"
    case .paused: return "paused"
    case .finished: return "finished"
    }
  }

  private static func name(of quality: SpeechVoice.Quality) -> String {
    switch quality {
    case .standard: return "standard"
    case .enhanced: return "enhanced"
    case .premium: return "premium"
    }
  }

  private static func name(of reason: NarrationHoldReason) -> String {
    switch reason {
    case .needsForeground: return "needsForeground"
    }
  }

  /// The hold as the card says it — the Apple app's sentence, so a listener
  /// on either platform reads the same words. "Paused" leads: someone
  /// glancing at the card sees a stopped state before they read why.
  private static func holdText(for reason: NarrationHoldReason) -> String {
    switch reason {
    case .needsForeground: return "Paused \u{2014} unlock Readr to keep listening"
    }
  }

  /// Muted footnote markers leave runs of spaces in a segment's text (the
  /// substitution is length-preserving by design, so offsets stay true).
  /// Collapse them for display only — the contains-check matters, because
  /// this runs on a once-a-second tick and the common sentence has no marker.
  static func displaySentence(_ text: String) -> String {
    guard text.contains("  ") else { return text }
    return text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
  }
}
