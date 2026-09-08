import Foundation
import ReadrKit

// MARK: - The phone's own model, as Kotlin hands it over

/// Where one generation's output goes while it runs. The facade makes one per
/// generation and hands it to Kotlin, which calls back as the model writes.
///
/// A CLASS rather than a protocol, unlike `SecretStore`, `AskSink` and
/// `OnDeviceModel`: this is the one callback that travels the other way — Swift
/// implements it and passes it INTO a Java-implemented method — and jextract
/// can only carry a concrete jextracted type across that boundary (a protocol
/// existential has no `$memoryAddress` for the Java wrapper to hold). Its
/// initialiser is deliberately not public: Kotlin receives sinks, never makes
/// them.
///
/// `delta` is the NEW text only — what ML Kit's `onNewText` hands over — and
/// the cumulative snapshot `SnapshotAnswerStream` reads is built HERE, on the
/// Swift side. The wire carries the smaller thing and the accumulation
/// happens once, in the language that owns the shape; Kotlin no longer
/// guesses at what the kit wants.
///
/// Exactly one ending: `completed` with the whole final text (ML Kit's own,
/// which may differ from the deltas' sum), or `failed`. A generation Kotlin
/// was asked to cancel reports neither — the caller asked for the stop and
/// owns what happens next.
///
/// `failed` carries a REASON CODE, never a sentence: `background`, `busy`,
/// `declined`, `tooLong`, `unavailable`, or "" for anything else. The words
/// the reader sees are written here (`NanoError`), so Kotlin writes no
/// reader-facing copy — the same bargain `readiness()` makes.
///
/// `@unchecked Sendable`: Kotlin calls these from its own generation thread,
/// and the only mutable state is guarded. Every method is quick and never
/// throws, as the bridge requires.
public final class OnDeviceSink: @unchecked Sendable {
  private let continuation: AsyncThrowingStream<OnDeviceStep, Error>.Continuation
  private let lock = NSLock()
  private var ended = false
  /// The answer so far, built from the deltas. Guarded by `lock`, because
  /// nothing promises Kotlin calls back on one thread.
  private var accumulated = ""
  /// Told when this generation is over, so whoever is holding the sink alive
  /// for the callback's sake can let it go. Called once, outside the lock.
  private let onEnd: (@Sendable () -> Void)?

  init(
    _ continuation: AsyncThrowingStream<OnDeviceStep, Error>.Continuation,
    onEnd: (@Sendable () -> Void)? = nil
  ) {
    self.continuation = continuation
    self.onEnd = onEnd
  }

  /// The new text, appended to what came before. An empty delta says nothing
  /// and is dropped rather than waking the reader's stream for no change.
  public func delta(_ text: String) {
    guard !text.isEmpty else { return }
    lock.lock()
    guard !ended else { lock.unlock(); return }
    accumulated += text
    let snapshot = accumulated
    lock.unlock()
    continuation.yield(.snapshot(snapshot))
  }

  public func completed(_ text: String) {
    guard end() else { return }
    continuation.yield(.completed(text))
    continuation.finish()
    onEnd?()
  }

  public func failed(_ message: String) {
    guard end() else { return }
    continuation.finish(throwing: NanoError.forCode(message))
    onEnd?()
  }

  /// True once an ending has been reported. Read by the box that holds this
  /// sink: a stream torn down after the model already finished must not be
  /// read as the reader cancelling it.
  var hasEnded: Bool {
    lock.lock(); defer { lock.unlock() }
    return ended
  }

  /// True the first time only: a model that reported both endings is a bug on
  /// the Kotlin side, and the stream must still end exactly once.
  private func end() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !ended else { return false }
    ended = true
    return true
  }
}

/// The phone's own model — Gemini Nano through AICore — as only Kotlin can
/// see it. One object answers both questions the facade has: whether the model
/// can run here at all, and what it says when asked something.
///
/// `readiness()` is a bare token, never a sentence: `"ready"`,
/// `"unavailable"` (fixable or temporary — still downloading, AICore
/// updating) or `"unsupported"` (this phone can never run it), optionally
/// followed by `":"` and a reason code (`downloading`). The words the reader
/// sees come from the kit and from this file, so the Android card and the
/// Apple one say the same thing. One string rather than three methods,
/// because a bridged protocol method may not throw and may not return an
/// optional.
///
/// `windowTokens()` is the model's REAL context window, as the runtime
/// reports it — not the catalogue's assembly budget, which is only how much
/// of the book the strategy is allowed to gather. `0` means "cannot say",
/// and the facade falls back to a documented figure. Asked once per
/// generation, and cached on both sides: it does not change under a running
/// process.
///
/// `generate` starts a generation and returns at once with a handle; the
/// answer arrives through `sink` as deltas. `temperature` is the decoding
/// warmth — `0` is greedy, which is what the kit's one-word classifier hop
/// asks for. `cancel` stops the generation that handle names, and an unknown
/// handle is a no-op; it RETURNS ONLY once that generation is cancelled and
/// its sink can no longer be called, so the caller may let the sink go the
/// moment it comes back.
///
/// Boundary rules (see `Package.swift`): `Int64` rather than `Int`, no
/// optionals, no throws.
public protocol OnDeviceModel {
  func readiness() -> String
  func windowTokens() -> Int64
  func generate(
    _ instructions: String, prompt: String, maxOutputTokens: Int64, temperature: Double,
    sink: OnDeviceSink
  ) -> Int64
  func cancel(_ handle: Int64)
}

// MARK: - What the reader is told

/// What went wrong on the phone's own model, in the reader's words. The
/// counterpart of the Apple app's `OnDeviceModelError`, and the reason
/// Kotlin's `failed` carries a code rather than a sentence.
enum NanoError: LocalizedError, CustomStringConvertible, DiagnosticallyDescribable {
  /// Even after trimming, the question did not leave room for an answer.
  case tooLong
  /// Not usable right now — busy, downloading, backgrounded. The payload is
  /// the code Kotlin reported, and is never shown.
  case unavailable(String)
  /// The model refused the passage or the answer.
  case declined
  /// Anything else, with a bounded code for the log.
  case other(String)

  /// The one sentence for a phone that cannot run its own model, straight from
  /// the kit — the same words the Apple app shows for its system model.
  static var notAvailableHere: String {
    ProviderManager.ProviderError.notConfigured(.geminiNano).errorDescription
      ?? "Gemini Nano isn't available on this phone."
  }

  /// The reader-facing failure a reason code from Kotlin stands for.
  static func forCode(_ code: String) -> NanoError {
    switch code.trimmingCharacters(in: .whitespaces) {
    case "tooLong": return .tooLong
    case "declined": return .declined
    case "background", "busy", "unavailable": return .unavailable(code)
    default: return .other(code)
    }
  }

  var errorDescription: String? {
    switch self {
    case .tooLong:
      return "This question needed more of the book than Gemini Nano can hold at once."
    case .unavailable(let code):
      switch code {
      case "background": return "Gemini Nano only answers while Readr is on screen."
      case "busy": return "Gemini Nano is busy."
      default: return "Gemini Nano isn't available right now."
      }
    case .declined:
      return "Gemini Nano declined to answer about this passage."
    case .other:
      return "Gemini Nano couldn't answer that on this phone."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .tooLong:
      return "Try a more specific question, or connect a cloud provider for whole-book questions."
    case .unavailable(let code):
      switch code {
      case "background": return "Come back to Readr and ask again."
      case "busy": return "Try again in a moment."
      default: return "Try again in a few minutes, or connect another provider in Settings → AI Providers."
      }
    case .declined:
      return "Try rephrasing, or connect another provider in Settings → AI Providers."
    case .other:
      return "Try again, or connect another provider in Settings → AI Providers."
    }
  }

  var description: String { errorDescription ?? "" }

  var diagnosticSummary: String {
    switch self {
    case .tooLong: return "NanoError.tooLong"
    case .unavailable(let code): return "NanoError.unavailable: \(code.prefix(60))"
    case .declined: return "NanoError.declined"
    case .other(let code): return "NanoError.other: \(code.prefix(300))"
    }
  }

  /// The kit's "no room for an answer" is this provider's `.tooLong`;
  /// cancellation passes through; everything else is already ours.
  static func mapped(_ error: Error) -> Error {
    if error is CancellationError { return error }
    if error is NanoError { return error }
    if error is SmallModelPrompt.DoesNotFit { return NanoError.tooLong }
    return NanoError.other(String(String(describing: error).prefix(300)))
  }
}

// MARK: - One generation, as an async sequence

/// What one step of a generation produced. `completed` carries the model's
/// own final text, which `SnapshotAnswerStream` reads as the last snapshot.
enum OnDeviceStep: Sendable {
  case snapshot(String)
  case completed(String)
}

// MARK: - The model, as the rest of the facade uses it

/// The Kotlin model as Swift wants it: `Sendable`, speaking `OnDeviceReadiness`
/// rather than a wire string, asked about readiness at most once every few
/// seconds, and generating into an async sequence.
///
/// **The readiness invariant: reading never asks the phone.** `readiness`
/// answers out of the cache and makes no call into Kotlin; only
/// `refreshReadiness()` does. `ProviderManager` invokes the facade's
/// `defaultSelection` closure WITH ITS OWN LOCK HELD, and that closure asks
/// whether this phone can run its model — so a probe on the read path would
/// put a JNI upcall into ML Kit (`checkStatus`, on a five-second leash)
/// inside the manager's mutex, where one wedged AICore would hold every
/// reader of the selection behind it, on whatever thread happened to ask.
///
/// The cache is filled instead by the paths that legitimately touch the
/// model — the settings payload, a credential check, "Check again", and the
/// ask — each of them off that lock and before it reads the selection. They
/// all go through `AndroidProviders.refreshOnDeviceReadiness`, which is the
/// only door to `refreshReadiness()` and says which callers use it.
///
/// `@unchecked`: the Kotlin object behind it is thread-safe by construction
/// (a stateless readiness read, and a handle map for generations); the same
/// bargain `SecretCredentialStore` makes.
final class OnDeviceModelBox: @unchecked Sendable {
  private let model: any OnDeviceModel
  private let lock = NSLock()
  private var cached: (readiness: OnDeviceReadiness, at: Date)?
  private var cachedWindow: Int?
  private let now: () -> Date

  /// Sinks belonging to generations still in flight, by a Swift-side id.
  ///
  /// The sink is a Swift object whose address Kotlin holds through a
  /// jextract wrapper registered with swift-java's AUTO arena: when that
  /// wrapper is collected the arena calls `SwiftObjects.destroy` on the
  /// pointed-at value, and the generated thunk exposes no way to free (or
  /// keep) that allocation from here — the pointer it allocates per call is
  /// never deallocated either. So the lifetime is ours to state: a strong
  /// reference lives here for exactly as long as a callback can still
  /// arrive, and is dropped when the generation reports an ending or when
  /// `cancel` comes back.
  private let generationLock = NSLock()
  private var sinks: [Int64: OnDeviceSink] = [:]
  private var nextGeneration: Int64 = 1

  /// How long an answer stands before a refresh asks again. One settings
  /// payload reads the readiness several times, and each real ask is a JNI
  /// hop into ML Kit. Short enough that a model finishing its download shows
  /// up on the next glance at the screen.
  private let maxAge: TimeInterval = 5

  init(_ model: any OnDeviceModel, now: @escaping () -> Date = { Date() }) {
    self.model = model
    self.now = now
  }

  /// What the phone last said about its own model. Read, never asked — see
  /// the invariant on this type.
  ///
  /// A cache with nothing in it yet reads as `unsupported`: until the phone
  /// has actually been asked, the reader sits on "nothing chosen" rather than
  /// on a model that may not exist. An answer older than `maxAge` is still
  /// returned as it stands — staleness decides whether the next REFRESH asks
  /// again, never what a reader is told in the meantime.
  var readiness: OnDeviceReadiness {
    lock.lock(); defer { lock.unlock() }
    return cached?.readiness ?? Self.unasked
  }

  /// What a phone nobody has asked yet counts as. The sentence is the kit's,
  /// so an unasked phone and an unsupported one read alike to the reader —
  /// and a refresh is one call away on every path that would show it.
  static var unasked: OnDeviceReadiness {
    .unsupported(reason: NanoError.notAvailableHere)
  }

  var isReady: Bool { readiness == .ready }

  /// Ask the phone about its own model, unless the last answer is still
  /// fresh. The one place `OnDeviceModel.readiness()` is called from.
  ///
  /// Blocking, on the caller's thread and outside every lock this facade
  /// holds: `checkStatus` binds to AICore and a broken one can sit in that
  /// bind for the full five seconds of its leash. Every caller is a facade
  /// function Kotlin runs on `Dispatchers.IO`.
  @discardableResult
  func refreshReadiness() -> OnDeviceReadiness {
    if let fresh = freshReadiness { return fresh }
    let readiness = Self.parse(model.readiness())
    lock.lock()
    cached = (readiness, now())
    lock.unlock()
    return readiness
  }

  /// The model's real context window, in tokens.
  ///
  /// The catalogue's `contextBudget` is not this number: it is how much of
  /// the book `AdaptiveContextStrategy` may gather, deliberately smaller so
  /// the passages leave room for the question, the conversation and the
  /// answer. Handing it to `SmallModelPrompt.plan` as the WINDOW made a
  /// five-turn conversation look like one that does not fit, and trimmed
  /// passages the model had room for.
  ///
  /// Only a positive answer is believed, and only a positive answer is
  /// remembered: a runtime that cannot say yet (the model still downloading)
  /// gets asked again next time.
  var window: Int {
    lock.lock()
    if let cachedWindow { lock.unlock(); return cachedWindow }
    lock.unlock()
    let reported = Int(model.windowTokens())
    guard reported > 0 else { return Self.fallbackWindow }
    lock.lock()
    cachedWindow = reported
    lock.unlock()
    return reported
  }

  /// What to assume when the runtime will not say: the figure Apple's
  /// FoundationModels reports on the phones Readr's on-device tier was
  /// measured against, and not a guess above it — a fallback set too small
  /// only costs passages, while one set too large costs a failed answer.
  static let fallbackWindow = 4_096

  /// Forget the cached answers, so the next *refresh* really asks the phone.
  /// What "Check again" is for: a reader who has just installed the model is
  /// telling us the last answer is out of date — and a model that was not
  /// there a moment ago could not report a window either. It is always
  /// followed by a refresh, since a cache emptied and not refilled reads as
  /// a phone that cannot run the model at all.
  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    cached = nil
    cachedWindow = nil
  }

  /// The cached answer while it is young enough to stand in for a new one.
  private var freshReadiness: OnDeviceReadiness? {
    lock.lock(); defer { lock.unlock() }
    guard let cached, now().timeIntervalSince(cached.at) < maxAge else { return nil }
    return cached.readiness
  }

  /// Parses the wire token, and the optional reason code behind it. Anything
  /// unrecognised is `unsupported` — a model that cannot say what it means
  /// must not leave the reader on a provider that can only fail. The sentence
  /// is ours in every case: Kotlin reports a state, not words.
  static func parse(_ answer: String) -> OnDeviceReadiness {
    let parts = answer.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let token = (parts.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
    let code = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    switch token {
    case "ready": return .ready
    case "unavailable": return .unavailable(reason: unavailableReason(code))
    default: return .unsupported(reason: NanoError.notAvailableHere)
    }
  }

  private static func unavailableReason(_ code: String) -> String {
    switch code {
    case "downloading": return "Gemini Nano is still downloading. Try again in a few minutes."
    default: return "Gemini Nano isn't available right now."
    }
  }

  /// Run one generation, as a sequence of cumulative snapshots ending in the
  /// final text. Cancelling the sequence (dropping its iterator, or cancelling
  /// the task reading it) cancels the Kotlin generation.
  func generate(
    instructions: String, prompt: String, maxOutputTokens: Int, temperature: Double
  ) -> AsyncThrowingStream<OnDeviceStep, Error> {
    AsyncThrowingStream { continuation in
      // Held BEFORE Kotlin is called: a model that answers on the calling
      // thread reports its ending inside `generate`, and a sink released
      // before it was ever held is a sink nothing was holding.
      let id = reserveGeneration()
      let sink = OnDeviceSink(continuation) { [weak self] in self?.release(id) }
      hold(sink, as: id)
      let handle = model.generate(
        instructions, prompt: prompt,
        maxOutputTokens: Int64(max(1, maxOutputTokens)), temperature: temperature, sink: sink)
      continuation.onTermination = { [self] _ in
        // A stream taken down after the model finished is not the reader
        // stopping an answer: the sink has already said its ending, and
        // there is nothing left to cancel.
        guard !sink.hasEnded else {
          release(id)
          return
        }
        // `cancel` comes back only once the Kotlin job is cancelled and the
        // sink can no longer be called — up to a couple of seconds. Off the
        // cooperative thread this termination runs on, and the sink is held
        // until it returns.
        Thread.detachNewThread { [self] in
          model.cancel(handle)
          release(id)
        }
      }
    }
  }

  private func reserveGeneration() -> Int64 {
    generationLock.lock(); defer { generationLock.unlock() }
    let id = nextGeneration
    nextGeneration &+= 1
    return id
  }

  private func hold(_ sink: OnDeviceSink, as id: Int64) {
    generationLock.lock(); defer { generationLock.unlock() }
    sinks[id] = sink
  }

  private func release(_ id: Int64) {
    generationLock.lock(); defer { generationLock.unlock() }
    sinks[id] = nil
  }

  /// The classifier's one short, passage-free call. What it asks and how its
  /// answer is read are `SmallModelPrompt`'s, shared with every other small
  /// model Readr talks to; only the call is here. A failure comes back as an
  /// empty reply, which the kit reads as "unsure" — the path with citations.
  ///
  /// Greedy, and three tokens wide: this is a routing decision, not writing,
  /// and the same call on Apple's model is `sampling: .greedy,
  /// maximumResponseTokens: 3`. Warmth here only turns one word into another.
  func classify(instructions: String, prompt: String) async -> String {
    var reply = ""
    do {
      for try await step in generate(
        instructions: instructions, prompt: prompt,
        maxOutputTokens: Self.classifierTokens, temperature: Self.greedy
      ) {
        switch step {
        case .snapshot(let text), .completed(let text): reply = text
        }
      }
    } catch {
      return ""
    }
    return reply
  }

  /// One word — BOOK or GENERAL — and no room to write an essay about it.
  static let classifierTokens = 3

  /// No sampling at all: the likeliest token, every time.
  static let greedy = 0.0

  /// Some warmth for the answer itself. Greedy decoding is what sends a small
  /// model round the same sentence, which is the loop `RepetitionGuard` then
  /// has to cut; the same figure the Apple provider uses.
  static let answerTemperature = 0.5
}

// MARK: - The provider

/// Gemini Nano as an `LLMProvider`: the whole recipe is the kit's
/// (`SmallModelPrompt` for the prompt and the window, `SnapshotAnswerStream`
/// for what the reader sees), and this type supplies only the model calls —
/// exactly the split the Apple app's `FoundationModelsProvider` makes.
///
/// Nothing here reaches the network, and there is no key: the phone answers,
/// or it says it cannot.
struct NanoProvider: LLMProvider, OnDeviceReadinessReporting {
  let info: ProviderInfo
  let model: OnDeviceModelBox

  /// The numbers every small model starts from, measured against Apple's
  /// FoundationModels. Nano has not been measured on its own hardware yet —
  /// see the note on `ProviderCatalog.geminiNanoModels`.
  ///
  /// The window these are spent inside is `model.window` — what the runtime
  /// reports — and NOT `info.contextBudget`, which is the assembly budget
  /// `AdaptiveContextStrategy` gathers passages against.
  static let budget = SmallModelPrompt.Budget.onDevice

  func countTokens(_ text: String) throws -> Int { TokenCounter.estimate(text) }

  func readiness() async -> OnDeviceReadiness { model.readiness }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          // The tier, the off-topic routing, the wording and the window
          // arithmetic are all the kit's. This provider supplies the two model
          // calls and nothing else.
          let plan = try await SmallModelPrompt.plan(
            request: request,
            // The model's own window, not the catalogue's assembly budget:
            // `contextBudget` says how much of the book to GATHER, and using
            // it as the window trimmed passages that fitted perfectly well.
            window: model.window,
            budget: Self.budget
          ) { instructions, prompt in
            await model.classify(instructions: instructions, prompt: prompt)
          }
          if plan.isGeneral {
            DiagnosticsLog.shared.record(
              .info, .provider,
              "gemini nano: question judged not about the book; answering without passages")
          }
          try Task.checkCancellation()

          // Kotlin sends deltas; `OnDeviceSink` adds them up, because
          // `SnapshotAnswerStream` reads the whole answer so far. It is the
          // converter back to the kit's chunks, and it decides what a reader
          // sees — settled sentences only, no repeats, nothing pasted out of
          // the passages.
          var shown = SnapshotAnswerStream(source: plan.copiedSentenceSource)
          streaming: for try await step in model.generate(
            instructions: plan.instructions,
            prompt: plan.prompt,
            maxOutputTokens: plan.answerTokens,
            temperature: OnDeviceModelBox.answerTemperature
          ) {
            try Task.checkCancellation()
            let output: SnapshotAnswerStream.Output
            switch step {
            case .snapshot(let text), .completed(let text): output = shown.advance(to: text)
            }
            Self.emit(output, into: continuation)
            if output.isLooping {
              DiagnosticsLog.shared.record(
                .warning, .provider,
                "gemini nano answer cut short: the model began repeating itself")
              break streaming
            }
          }
          try Task.checkCancellation()
          // The final fragment, if the stream ended cleanly.
          Self.emit(shown.finish(), into: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: NanoError.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// One step of the answer, onto the wire and into the log.
  private static func emit(
    _ step: SnapshotAnswerStream.Output,
    into continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation
  ) {
    for _ in 0..<step.droppedCopiedSentences {
      DiagnosticsLog.shared.record(
        .info, .provider, "gemini nano answer: dropped a sentence copied from the passages")
    }
    if !step.delta.isEmpty { continuation.yield(ChatChunk(textDelta: step.delta)) }
  }
}
