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
/// `snapshot` is CUMULATIVE — the whole answer so far, not the new piece —
/// because that is what `SnapshotAnswerStream` is built to read, and it is
/// what Apple's on-device model hands its provider. Kotlin accumulates ML
/// Kit's incremental chunks so both platforms feed the kit the same shape.
///
/// Exactly one ending: `completed` with the final text, or `failed`. A
/// generation Kotlin was asked to cancel reports neither — the caller asked
/// for the stop and owns what happens next.
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

  init(_ continuation: AsyncThrowingStream<OnDeviceStep, Error>.Continuation) {
    self.continuation = continuation
  }

  public func snapshot(_ text: String) {
    guard !hasEnded else { return }
    continuation.yield(.snapshot(text))
  }

  public func completed(_ text: String) {
    guard end() else { return }
    continuation.yield(.completed(text))
    continuation.finish()
  }

  public func failed(_ message: String) {
    guard end() else { return }
    continuation.finish(throwing: NanoError.forCode(message))
  }

  private var hasEnded: Bool {
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
/// `generate` starts a generation and returns at once with a handle; the
/// answer arrives through `sink`. `cancel` stops the generation that handle
/// names, and an unknown handle is a no-op.
///
/// Boundary rules (see `Package.swift`): `Int64` rather than `Int`, no
/// optionals, no throws.
public protocol OnDeviceModel {
  func readiness() -> String
  func generate(
    _ instructions: String, prompt: String, maxOutputTokens: Int64, sink: OnDeviceSink
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
/// `@unchecked`: the Kotlin object behind it is thread-safe by construction
/// (a stateless readiness read, and a handle map for generations); the same
/// bargain `SecretCredentialStore` makes.
final class OnDeviceModelBox: @unchecked Sendable {
  private let model: any OnDeviceModel
  private let lock = NSLock()
  private var cached: (readiness: OnDeviceReadiness, at: Date)?
  private let now: () -> Date

  /// How long an answer stands. The selection is resolved through the model on
  /// every read — building one settings payload asks several times — and each
  /// ask is a JNI hop into ML Kit. Short enough that a model finishing its
  /// download shows up on the next glance at the screen.
  private let maxAge: TimeInterval = 5

  init(_ model: any OnDeviceModel, now: @escaping () -> Date = { Date() }) {
    self.model = model
    self.now = now
  }

  var readiness: OnDeviceReadiness {
    if let fresh = cachedReadiness { return fresh }
    // Asked outside the lock: it is a call into Kotlin, and a mutex held
    // across it would serialise every reader of the selection behind it.
    let answer = model.readiness()
    let readiness = Self.parse(answer)
    lock.lock()
    cached = (readiness, now())
    lock.unlock()
    return readiness
  }

  var isReady: Bool { readiness == .ready }

  /// Forget the cached answer, so the next read really asks the phone. What
  /// "Check again" is for: a reader who has just installed the model is
  /// telling us the last answer is out of date.
  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    cached = nil
  }

  private var cachedReadiness: OnDeviceReadiness? {
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
    instructions: String, prompt: String, maxOutputTokens: Int
  ) -> AsyncThrowingStream<OnDeviceStep, Error> {
    AsyncThrowingStream { continuation in
      let sink = OnDeviceSink(continuation)
      let handle = model.generate(
        instructions, prompt: prompt,
        maxOutputTokens: Int64(max(1, maxOutputTokens)), sink: sink)
      continuation.onTermination = { _ in
        // The sink is held until the generation is over: Kotlin calls back
        // into it from its own thread, and letting it go early would leave a
        // running generation writing into nothing.
        withExtendedLifetime(sink) { self.model.cancel(handle) }
      }
    }
  }

  /// The classifier's one short, passage-free call. What it asks and how its
  /// answer is read are `SmallModelPrompt`'s, shared with every other small
  /// model Readr talks to; only the call is here. A failure comes back as an
  /// empty reply, which the kit reads as "unsure" — the path with citations.
  func classify(instructions: String, prompt: String) async -> String {
    var reply = ""
    do {
      for try await step in generate(
        instructions: instructions, prompt: prompt, maxOutputTokens: Self.classifierTokens
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
  static let classifierTokens = 8
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
            window: info.contextBudget,
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

          // Snapshots are cumulative; the kit's chunks are deltas.
          // `SnapshotAnswerStream` is the converter, and it decides what a
          // reader sees — settled sentences only, no repeats, nothing pasted
          // out of the passages.
          var shown = SnapshotAnswerStream(source: plan.copiedSentenceSource)
          streaming: for try await step in model.generate(
            instructions: plan.instructions,
            prompt: plan.prompt,
            maxOutputTokens: plan.answerTokens
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
