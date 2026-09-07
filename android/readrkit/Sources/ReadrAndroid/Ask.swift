import Foundation
import ReadrKit

/// Where an answer goes as it arrives. Kotlin implements it; the facade calls
/// it from the Swift task that is streaming, so every method must be quick and
/// must not throw — the boundary rules in `Package.swift` (no optionals, no
/// throws, `Int64` rather than `Int`) apply to this protocol as much as to
/// `SecretStore`.
///
/// The order is fixed: `contextAssembled` (possibly twice — once with
/// `"indexing"` while the book's index is being built, then with the routing
/// tier), then `citations` when the tier has any, then a `token` per streamed
/// delta, then exactly one of `completed` or `failed`. A cancelled ask calls
/// neither of the last two: the Kotlin side asked for the stop and already
/// knows what state it is in.
public protocol AskSink {
  /// `"indexing"`, or the kit's `AssembledContext.Tier` raw value —
  /// `"retrieval"` or `"wholeBook"`.
  func contextAssembled(_ tier: String)
  /// `[{locator, quotedText, chapterIndex?, utf16Offset?}]`. Only the
  /// retrieval tier has any.
  func citations(_ json: String)
  func token(_ text: String)
  /// The whole answer, once. Providers that stream deltas send the same text
  /// again here; the panel takes this as authoritative.
  func completed(_ text: String)
  /// A reader-facing sentence and, when the error carries one, a concrete
  /// next step. Never a Swift case name. `recovery` is "" when there is none:
  /// a bridged protocol method may not take an optional.
  func failed(_ message: String, recovery: String)
}

/// The sink as the streaming task needs it: `Sendable`, and each call made
/// exactly where the event happened. `@unchecked` for the same reason
/// `OnDeviceProbeBox` is — the object behind it is a Kotlin listener that
/// hops to the main thread itself.
final class AskSinkBox: @unchecked Sendable {
  private let sink: any AskSink

  init(_ sink: any AskSink) { self.sink = sink }

  func contextAssembled(_ tier: String) { sink.contextAssembled(tier) }
  func citations(_ json: String) { sink.citations(json) }
  func token(_ text: String) { sink.token(text) }
  func completed(_ text: String) { sink.completed(text) }
  func failed(_ error: Error) {
    let localized = error as? LocalizedError
    // `errorDescription` and `recoverySuggestion` separately rather than
    // `readerFacingMessage`, which is the two of them joined: the sink has a
    // slot for each, and the panel draws them as a sentence and a next step —
    // joining here would print the recovery twice. Same split as the Apple
    // panel's `AskViewModel.fail`.
    let message = localized?.errorDescription ?? error.localizedDescription
    sink.failed(message, recovery: localized?.recoverySuggestion ?? "")
  }
  func failed(_ message: String, recovery: String) { sink.failed(message, recovery: recovery) }
}

/// A request the panel put together wrongly — a scope with neither case named,
/// a selection that will not decode, an override URL with no host. Always a
/// programming error on the Kotlin side, so what the reader is told is short
/// and the field name rides in the diagnostics.
enum AskRequestError: LocalizedError, CustomStringConvertible, DiagnosticallyDescribable {
  case malformed(String)

  var errorDescription: String? { "Readr couldn't put that question together." }
  var recoverySuggestion: String? { "Try asking again." }
  var description: String { errorDescription ?? "" }
  var diagnosticSummary: String {
    switch self {
    case .malformed(let field): return "malformed ask request: \(field)"
    }
  }
}

// MARK: - The wire shapes

/// `{"wholeBook":true}` or `{"frontier":{"chapterIndex":N,"utf16Offset":M}}`.
/// Two named cases rather than a nullable frontier, so a caller that forgets
/// to say cannot be read as "the whole book" by accident — the kit's
/// `ReadingScope` makes the same point in Swift.
struct AskScopeWire: Decodable {
  struct Frontier: Decodable {
    var chapterIndex: Int
    var utf16Offset: Int
  }

  var wholeBook: Bool?
  var frontier: Frontier?
}

/// `{"chapterIndex":N,"utf16Start":a,"utf16End":b}` — the passage the question
/// is about, in the coordinates Compose reports.
struct AskSelectionWire: Decodable {
  var chapterIndex: Int
  var utf16Start: Int
  var utf16End: Int
}

/// A `Citation` with its offset in UTF-16, which is what a "Show in book"
/// tap needs. `chapterIndex`/`utf16Offset` are absent for a citation with no
/// passage behind it.
struct AskCitationWire: Codable {
  var locator: String
  var quotedText: String
  var chapterIndex: Int?
  var utf16Offset: Int?
}

/// One answered turn of the conversation so far, as Kotlin keeps it.
struct AskTurnWire: Codable {
  var question: String
  var answerText: String
  /// `AssembledContext.Tier` raw value; anything else reads as `retrieval`.
  var tier: String?
  var citations: [AskCitationWire]?
}

/// `ReadingPositionSummary` flattened: the caption the Ask sheet shows over a
/// scoped conversation, plus its parts for anything that wants them apart.
struct AskPositionWire: Codable {
  var caption: String
  var chapterLine: String
  var chapterTitle: String
  var chapterNumber: Int
  var chapterCount: Int
  var percent: Int
  var titleIsFallback: Bool
}

// MARK: - Runs in flight

/// One ask, so it can be cancelled by handle from Kotlin.
///
/// The task cannot be handed in at construction — it does not exist until
/// `Task { }` returns, and by then it may already have finished — so the run
/// is made first, handed out, and the task attached after. A cancel that
/// lands in that window is remembered and applied on attach.
final class AskRun: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  func attach(_ task: Task<Void, Never>) {
    lock.lock()
    let alreadyCancelled = cancelled
    if !alreadyCancelled { self.task = task }
    lock.unlock()
    if alreadyCancelled { task.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = self.task
    self.task = nil
    lock.unlock()
    task?.cancel()
  }
}

/// The asks this process has going, by handle. Handles are never reused, so a
/// cancel that arrives after an answer landed is a no-op rather than a stop
/// signal aimed at somebody else's question.
final class AskRunRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var next: Int64 = 1
  private var runs: [Int64: AskRun] = [:]

  func add(_ run: AskRun) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    let handle = next
    next += 1
    runs[handle] = run
    return handle
  }

  func finish(_ handle: Int64) {
    lock.lock(); defer { lock.unlock() }
    runs[handle] = nil
  }

  func cancel(_ handle: Int64) {
    lock.lock()
    let run = runs.removeValue(forKey: handle)
    lock.unlock()
    run?.cancel()
  }
}

/// The retrieval indexes Ask has built, most recently used last.
///
/// Two books' worth: one is the book being read, the second covers a reader
/// who flips back to what they were reading before without paying to index it
/// again. Building is the expensive part (chunk, embed, count terms) and a
/// third book's index is memory nobody is asking questions of.
final class AskIndexes: @unchecked Sendable {
  private let lock = NSLock()
  private var indexes: [UUID: HybridRAGIndex] = [:]
  private var order: [UUID] = []
  private let capacity = 2

  func index(for bookID: UUID) -> HybridRAGIndex {
    lock.lock(); defer { lock.unlock() }
    order.removeAll { $0 == bookID }
    order.append(bookID)
    if let index = indexes[bookID] { return index }
    let index = HybridRAGIndex()
    indexes[bookID] = index
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      indexes[oldest] = nil
    }
    return index
  }

  func forget(_ bookID: UUID) {
    lock.lock(); defer { lock.unlock() }
    order.removeAll { $0 == bookID }
    indexes[bookID] = nil
  }
}

// MARK: - Ask

// `extension X { public func … }` rather than `public extension X`: jextract
// reads each member's own modifiers, so a method that inherits its visibility
// from the extension is taken for internal and never reaches Java. Every other
// facade extension is written the same way.
extension AndroidLibrary {

  /// What the panel says when there is no model to put a question to. The
  /// Apple panel's sentence, so both platforms send the reader the same way.
  static var noProviderMessage: String { "Connect an AI provider in settings to ask questions." }

  /// Ask the book a question and stream the answer into `sink`.
  ///
  /// Returns a handle for `cancelAsk(_:)`, or 0 when nothing was started —
  /// which happens only after `sink.failed` has already said why, so a caller
  /// never has to invent a sentence for the silent case.
  ///
  /// - Parameters:
  ///   - scopeJSON: `{"wholeBook":true}` or
  ///     `{"frontier":{"chapterIndex":N,"utf16Offset":M}}`. Named at every
  ///     call, as the kit's `ReadingScope` requires.
  ///   - selectionJSON: `""` for a question about the book, else
  ///     `{"chapterIndex":N,"utf16Start":a,"utf16End":b}`.
  ///   - historyJSON: the answered turns so far, oldest first.
  ///   - providers: the process's provider settings, which own the active
  ///     model and its credentials.
  public func ask(
    _ bookID: String,
    question: String,
    scopeJSON: String,
    selectionJSON: String,
    historyJSON: String,
    providers: AndroidProviders,
    sink: any AskSink
  ) -> Int64 {
    let box = AskSinkBox(sink)

    // Nothing is started without something to answer with: the panel's empty
    // state is a reader-facing sentence, not a stream that fails a second
    // later.
    let provider: LLMProvider
    do {
      guard let active = try providers.manager.activeProvider() else {
        box.failed(Self.noProviderMessage, recovery: "")
        return 0
      }
      provider = active
    } catch {
      // A selection that will not resolve (a key the provider rejected) says
      // so in the kit's own words, which name the vendor and the fix.
      box.failed(error)
      return 0
    }

    let book: Book
    let scope: ReadingScope
    let selection: Selection?
    let history: [ConversationTurn]
    do {
      book = try self.book(bookID)
      scope = try askScope(scopeJSON, in: book)
      selection = try askSelection(selectionJSON, in: book)
      history = askHistory(historyJSON, in: book)
    } catch {
      box.failed(error)
      return 0
    }

    let run = AskRun()
    let handle = askRuns.add(run)
    let registry = askRuns
    let indexes = askIndexes
    let lengths = readingLengths
    let task = Task { [book, scope, selection, history] in
      defer { registry.finish(handle) }
      do {
        let index = indexes.index(for: book.id)
        if await index.isBuilt(bookID: book.id) == false {
          guard !run.isCancelled, !Task.isCancelled else { return }
          // Chunking and embedding a long book is seconds, not milliseconds,
          // and it happens before the router has anything to say — so the
          // panel is told that this is what the wait is.
          box.contextAssembled("indexing")
          try await index.build(for: book, embeddings: LocalEmbeddingProvider())
        }
        let service = AskService(
          strategy: AdaptiveContextStrategy(index: index, lengths: lengths),
          provider: provider)
        for try await event in service.ask(
          question, about: book, selection: selection, history: history, scope: scope
        ) {
          // A cancelled ask says nothing more: the Kotlin side stopped it and
          // owns what the panel shows from here.
          guard !run.isCancelled, !Task.isCancelled else { return }
          switch event {
          case let .contextAssembled(tier):
            box.contextAssembled(tier.rawValue)
          case let .citations(citations):
            box.citations(self.askCitationsJSON(citations, in: book))
          case let .token(delta):
            box.token(delta)
          case let .completed(text):
            box.completed(text)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        guard !run.isCancelled, !Task.isCancelled else { return }
        box.failed(error)
      }
    }
    run.attach(task)
    return handle
  }

  /// Stop the ask `handle` names. The sink hears nothing more from it — no
  /// `completed`, no `failed`. An unknown handle (an ask that already landed)
  /// is a no-op.
  public func cancelAsk(_ handle: Int64) {
    askRuns.cancel(handle)
  }

  /// "Chapter 7 of 24 · 31% · The Whale" for a place in the book — the kit's
  /// `ReadingPositionSummary`, so the Ask sheet's caption is word for word the
  /// one the Apple panel shows and the one the model is told. `""` for a book
  /// with no linear chapters: there is nothing to be partway through.
  public func positionSummaryJSON(_ bookID: String, chapterIndex: Int64, utf16Offset: Int64) throws -> String {
    try readerFacing {
      let book = try book(bookID)
      let frontier = askFrontier(in: book, chapterIndex: Int(chapterIndex), utf16Offset: Int(utf16Offset))
      guard let summary = ReadingPositionSummary(
        book: book, frontier: frontier, lengths: readingLengths.table(for: book)
      ) else { return "" }
      let wire = AskPositionWire(
        caption: summary.caption,
        chapterLine: summary.chapterLine,
        chapterTitle: summary.chapterTitle,
        chapterNumber: summary.chapterNumber,
        chapterCount: summary.chapterCount,
        percent: summary.percent,
        titleIsFallback: summary.titleIsFallback)
      return String(decoding: try Self.encoder().encode(wire), as: UTF8.self)
    }
  }
}

// MARK: - Decoding what the panel sends

extension AndroidLibrary {

  /// The frontier a chapter and a UTF-16 offset name, with the offset in the
  /// kit's own character count. A chapter index outside the book clamps into
  /// it rather than failing: the reader's place is not worth an error.
  func askFrontier(in book: Book, chapterIndex: Int, utf16Offset: Int) -> ReadingFrontier {
    guard !book.chapters.isEmpty else {
      return ReadingFrontier(chapterIndex: 0, characterOffset: 0)
    }
    let index = min(max(chapterIndex, 0), book.chapters.count - 1)
    let characterOffset = offsetTables
      .table(for: book, chapterIndex: index)
      .characterOffset(ofUTF16: max(0, utf16Offset))
    return ReadingFrontier(chapterIndex: index, characterOffset: characterOffset)
  }

  func askScope(_ json: String, in book: Book) throws -> ReadingScope {
    let data = Data(json.utf8)
    guard let wire = try? JSONDecoder().decode(AskScopeWire.self, from: data) else {
      throw AskRequestError.malformed("scope")
    }
    if let frontier = wire.frontier {
      return .upTo(askFrontier(
        in: book, chapterIndex: frontier.chapterIndex, utf16Offset: frontier.utf16Offset))
    }
    guard wire.wholeBook == true else { throw AskRequestError.malformed("scope") }
    return .wholeBook
  }

  /// The selected passage, with ~300 characters either side for the anchor —
  /// the same shape `AppModel.makeSelection` builds on the Apple side.
  func askSelection(_ json: String, in book: Book) throws -> Selection? {
    guard !json.isEmpty else { return nil }
    guard let wire = try? JSONDecoder().decode(AskSelectionWire.self, from: Data(json.utf8)) else {
      throw AskRequestError.malformed("selection")
    }
    let chapter = try chapter(book, Int64(wire.chapterIndex))
    let table = offsetTables.table(for: book, chapterIndex: wire.chapterIndex)
    let characters = Array(chapter.text)
    let lower = min(max(0, table.characterOffset(ofUTF16: wire.utf16Start)), characters.count)
    let upper = min(max(lower, table.characterOffset(ofUTF16: wire.utf16End)), characters.count)
    let contextLower = max(0, lower - Self.selectionContextCharacters)
    let contextUpper = min(characters.count, upper + Self.selectionContextCharacters)
    return Selection(
      chapterID: chapter.id,
      quotedText: lower < upper ? String(characters[lower..<upper]) : "",
      surroundingText: String(characters[contextLower..<contextUpper]),
      chapterTitle: chapter.title)
  }

  /// The conversation so far. A turn that will not decode is dropped rather
  /// than failing the question: history is context, and a question the reader
  /// just typed must not be refused over a transcript entry.
  func askHistory(_ json: String, in book: Book) -> [ConversationTurn] {
    guard !json.isEmpty,
          let wire = try? JSONDecoder().decode([AskTurnWire].self, from: Data(json.utf8))
    else { return [] }
    return wire.map { turn in
      ConversationTurn(
        question: turn.question,
        answer: Answer(
          text: turn.answerText,
          tier: AssembledContext.Tier(rawValue: turn.tier ?? "") ?? .retrieval,
          citations: (turn.citations ?? []).map { citation in
            Citation(
              locator: citation.locator,
              quotedText: citation.quotedText,
              chapterIndex: citation.chapterIndex,
              characterOffset: citation.chapterIndex.flatMap { chapterIndex in
                citation.utf16Offset.map { utf16 in
                  book.chapters.indices.contains(chapterIndex)
                    ? offsetTables.table(for: book, chapterIndex: chapterIndex)
                      .characterOffset(ofUTF16: utf16)
                    : utf16
                }
              })
          }))
    }
  }

  /// The citations as the panel draws them, offsets converted to UTF-16 so a
  /// "Show in book" tap lands on the passage the answer leaned on. A citation
  /// whose chapter is not in the book any more keeps its words and loses its
  /// place: a pill that quotes something is worth more than none at all.
  func askCitationsJSON(_ citations: [Citation], in book: Book) -> String {
    let wire = citations.map { citation -> AskCitationWire in
      var utf16Offset: Int?
      if let chapterIndex = citation.chapterIndex,
         let characterOffset = citation.characterOffset,
         book.chapters.indices.contains(chapterIndex) {
        utf16Offset = offsetTables
          .table(for: book, chapterIndex: chapterIndex)
          .utf16Offset(ofCharacter: characterOffset)
      }
      return AskCitationWire(
        locator: citation.locator,
        quotedText: citation.quotedText,
        chapterIndex: utf16Offset == nil ? nil : citation.chapterIndex,
        utf16Offset: utf16Offset)
    }
    guard let data = try? Self.encoder().encode(wire) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Characters of context either side of a selected passage. A little wider
  /// than the Apple reader's 240 — a phone selection is usually a sentence,
  /// and the paragraph around it is what makes the question answerable.
  static var selectionContextCharacters: Int { 300 }
}

// MARK: - What the Ask sheet needs to know about the provider

extension AndroidProviders {

  /// True when the model Ask would use runs on the phone itself. The sheet's
  /// grounding caption turns on this: an on-device model answers from the
  /// passages and nothing else, so promising "the model's wider knowledge"
  /// would promise what a 3B model on a handset cannot do.
  public func isActiveOnDevice() -> Bool {
    manager.selection?.kind.isOnDevice ?? false
  }

  /// TEST ONLY. Sends every request for `kind` to `url`'s origin instead of
  /// the vendor's, keeping the path the provider built — so an instrumented
  /// test can point the OpenAI-shaped provider at a server it runs itself
  /// (`http://127.0.0.1:<port>` answers `/v1/chat/completions`). Pass "" to
  /// put the vendor's own host back.
  ///
  /// Nothing in the app calls this; it exists so the streaming path can be
  /// tested end to end on a device without a key, a network, or a bill.
  public func overrideEndpoint(_ kind: String, url: String) throws {
    try readerFacing {
      let k = try self.providerKind(kind)
      guard !url.isEmpty else {
        endpointOverrides.set(nil, for: k)
        return
      }
      guard let origin = URL(string: url), origin.host != nil else {
        throw AskRequestError.malformed("endpoint URL")
      }
      endpointOverrides.set(origin, for: k)
    }
  }
}

/// Per-kind endpoint replacements, consulted by the provider factory. Empty
/// in every build a reader runs; see `AndroidProviders.overrideEndpoint`.
final class EndpointOverrides: @unchecked Sendable {
  private let lock = NSLock()
  private var origins: [ProviderInfo.Kind: URL] = [:]

  func set(_ origin: URL?, for kind: ProviderInfo.Kind) {
    lock.lock(); defer { lock.unlock() }
    origins[kind] = origin
  }

  func origin(for kind: ProviderInfo.Kind) -> URL? {
    lock.lock(); defer { lock.unlock() }
    return origins[kind]
  }

  /// The transport a provider of `kind` should be built with: the ordinary
  /// one, or a redirected one while an override stands.
  func client(for kind: ProviderInfo.Kind) -> HTTPClient {
    guard let origin = origin(for: kind) else { return URLSessionHTTPClient() }
    return OriginOverridingHTTPClient(origin: origin)
  }
}

/// An `HTTPClient` that swaps the scheme, host and port of every request for
/// another origin's and leaves the path, query, headers and body alone — so
/// the provider builds exactly the request it would have sent to the vendor
/// and a local server receives it.
struct OriginOverridingHTTPClient: HTTPClient {
  let origin: URL
  private let base = URLSessionHTTPClient()

  init(origin: URL) { self.origin = origin }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await base.send(redirected(request))
  }

  func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
    try await base.stream(redirected(request))
  }

  private func redirected(_ request: HTTPRequest) -> HTTPRequest {
    guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
          let target = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    else { return request }
    components.scheme = target.scheme
    components.host = target.host
    components.port = target.port
    guard let url = components.url else { return request }
    var redirected = request
    redirected.url = url
    return redirected
  }
}
