import Foundation
import ReadrKit

/// Where an answer goes as it arrives. Kotlin implements it; the facade calls
/// it from the Swift task that is streaming, so every method must be quick and
/// must not throw — the boundary rules in `Package.swift` (no optionals, no
/// throws, `Int64` rather than `Int`) apply to this protocol as much as to
/// `SecretStore`.
///
/// The order is fixed: `indexing` when the book's index has to be built
/// first, then `contextAssembled` with the routing tier, then `citations`
/// when the tier has any, then a `token` per streamed delta, then exactly one
/// of `completed` or `failed`. A cancelled ask calls neither of the last two:
/// the Kotlin side asked for the stop and already knows what state it is in.
public protocol AskSink {
  /// The book's retrieval index is being built; the answer waits on it. Its
  /// own call rather than a pseudo-tier, so `contextAssembled` only ever
  /// carries a tier the router actually chose.
  func indexing()
  /// `{"tier":"retrieval"|"wholeBook","providesCitations":Bool}` — the kit's
  /// `AssembledContext.Tier` and what it says about itself, so the panel's
  /// caption follows the kit rather than re-deriving the rule.
  func contextAssembled(_ json: String)
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
/// `OnDeviceModelBox` is — the object behind it is a Kotlin listener that
/// hops to the main thread itself.
final class AskSinkBox: @unchecked Sendable {
  private let sink: any AskSink

  init(_ sink: any AskSink) { self.sink = sink }

  func indexing() { sink.indexing() }
  func contextAssembled(_ tier: AssembledContext.Tier) {
    let wire = AskTierWire(tier: tier.rawValue, providesCitations: tier.providesCitations)
    guard let data = try? AndroidLibrary.encoder().encode(wire) else { return }
    sink.contextAssembled(String(decoding: data, as: UTF8.self))
  }
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

/// The routing tier, and what it promises. `providesCitations` is the kit's
/// own answer (`AssembledContext.Tier.providesCitations`): the whole-book
/// tier retrieves no passages, so a caption that offered citations there
/// would promise a SOURCES row that never comes.
struct AskTierWire: Codable {
  var tier: String
  var providesCitations: Bool
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
  /// Whether this turn was answered under a frontier. A scoped question is
  /// not shown the answers to unscoped ones — the no-spoilers promise covers
  /// the history the model reads, not only the passages it is handed — and
  /// a turn that does not say reads as unscoped, which is the safe direction.
  var scoped: Bool?
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

/// One block of an answer, as the sheet draws it: the kit's `AnswerBlock`
/// flattened for Kotlin. `kind` is one of paragraph, heading, quote, code,
/// list, rule; the optional fields carry the payload of the kinds that have
/// one, and a list's items arrive with the marker already rendered ("2.").
struct AnswerBlockWire: Codable {
  struct Item: Codable {
    var marker: String
    var text: String
  }

  var kind: String
  var text: String?
  var level: Int?
  var language: String?
  var paragraphs: [String]?
  var ordered: Bool?
  var items: [Item]?

  init(_ block: AnswerBlock) {
    switch block {
    case .paragraph(let text):
      kind = "paragraph"; self.text = text
    case .heading(let level, let text):
      kind = "heading"; self.level = level; self.text = text
    case .quote(let paragraphs):
      kind = "quote"; self.paragraphs = paragraphs
    case .code(let language, let text):
      kind = "code"; self.language = language; self.text = text
    case .list(let ordered, let items):
      kind = "list"
      self.ordered = ordered
      self.items = items.map { Item(marker: $0.marker, text: $0.text) }
    case .rule:
      kind = "rule"
    }
  }
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

  /// A book's index and the build filling it, as ONE entry.
  ///
  /// Kept together because they are only ever true of each other: an
  /// eviction that dropped the index and left the build behind would leave a
  /// question awaiting work that fills an index nobody can reach any more,
  /// and the answer would be assembled from an empty one — an ungrounded
  /// answer, with no error to show for it.
  private struct Entry {
    var index: HybridRAGIndex
    var task: Task<Void, Error>?
    /// Which build `task` is, so a task that finishes after its entry was
    /// evicted and remade cannot clear the new entry's build.
    var buildID: Int64 = 0
  }

  private let lock = NSLock()
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private var nextBuildID: Int64 = 1
  private let capacity = 2

  func index(for bookID: UUID) -> HybridRAGIndex {
    lock.lock()
    let index = locked(bookID).index
    let evicted = evict()
    lock.unlock()
    evicted.forEach { $0.cancel() }
    return index
  }

  /// The book's index and the build filling it, started if none is running.
  ///
  /// Both come from the same entry under the same lock, so the caller can
  /// await the build and then read the index it filled. One task per book:
  /// the reader opening a book starts it off the critical path, and a
  /// question a moment later awaits the same task.
  @discardableResult
  func build(for book: Book) -> (index: HybridRAGIndex, task: Task<Void, Error>) {
    lock.lock()
    var entry = locked(book.id)
    if let running = entry.task {
      let evicted = evict()
      lock.unlock()
      evicted.forEach { $0.cancel() }
      return (entry.index, running)
    }
    let index = entry.index
    let buildID = nextBuildID
    nextBuildID += 1
    let task = Task<Void, Error>.detached(priority: .utility) { [weak self] in
      // The lock is held until the task below is registered, so this cannot
      // run ahead of its own registration.
      defer { self?.finished(book.id, buildID: buildID) }
      if await index.isBuilt(bookID: book.id) { return }
      try await index.build(for: book, embeddings: LocalEmbeddingProvider())
    }
    entry.task = task
    entry.buildID = buildID
    entries[book.id] = entry
    let evicted = evict()
    lock.unlock()
    evicted.forEach { $0.cancel() }
    return (index, task)
  }

  /// Drop a book's index and stop the build filling it — its own build and no
  /// other: a task started for an entry that has since been replaced belongs
  /// to that replacement.
  func forget(_ bookID: UUID) {
    lock.lock()
    order.removeAll { $0 == bookID }
    let entry = entries.removeValue(forKey: bookID)
    lock.unlock()
    entry?.task?.cancel()
  }

  /// A build that ended. It clears the entry's task only while it is still
  /// the registered one — an evicted (or forgotten, or re-started) build
  /// says nothing about the build running now.
  private func finished(_ bookID: UUID, buildID: Int64) {
    lock.lock(); defer { lock.unlock() }
    guard var entry = entries[bookID], entry.buildID == buildID else { return }
    entry.task = nil
    entry.buildID = 0
    entries[bookID] = entry
  }

  /// The entry for a book, made if there is none, and most-recently-used
  /// either way — the caller holds the lock.
  private func locked(_ bookID: UUID) -> Entry {
    order.removeAll { $0 == bookID }
    order.append(bookID)
    if let entry = entries[bookID] { return entry }
    let entry = Entry(index: HybridRAGIndex())
    entries[bookID] = entry
    return entry
  }

  /// Everything past the capacity, dropped whole — index and build together.
  /// The caller holds the lock and cancels what comes back once it has let
  /// go of it, since cancelling runs other people's code.
  private func evict() -> [Task<Void, Error>] {
    var dropped: [Task<Void, Error>] = []
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      if let task = entries.removeValue(forKey: oldest)?.task { dropped.append(task) }
    }
    return dropped
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
      history = askHistory(historyJSON, in: book, scoped: scope.isScoped)
    } catch {
      box.failed(error)
      return 0
    }

    let run = AskRun()
    let handle = askRuns.add(run)
    let registry = askRuns
    let indexes = askIndexes
    let lengths = readingLengths
    let wholeBook = routesWholeBook(book, scope: scope, provider: provider.info)
    let task = Task { [book, scope, selection, history] in
      defer { registry.finish(handle) }
      do {
        var index = indexes.index(for: book.id)
        // The index is only worth having for the tier that reads it. A book
        // that fits the provider's whole-book budget rides along entire, and
        // the router never asks for a passage — chunking and embedding it
        // would be seconds of work no answer would use.
        if !wholeBook, await index.isBuilt(bookID: book.id) == false {
          guard !run.isCancelled, !Task.isCancelled else { return }
          // Chunking and embedding a long book is seconds, not milliseconds,
          // and it happens before the router has anything to say — so the
          // panel is told that this is what the wait is. `prepareAsk` may
          // have started this work when the book opened; then this waits on
          // that task rather than doing it twice.
          box.indexing()
          // The index the build is filling, not the one looked up a moment
          // ago: two other books opening in between would have evicted that
          // one, and the strategy would then read an index nothing filled.
          let building = indexes.build(for: book)
          index = building.index
          try await building.task.value
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
            box.contextAssembled(tier)
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

  /// Start building the book's retrieval index, unless a question about it
  /// would never use one.
  ///
  /// Called when the book opens, and returns at once: the work runs on a
  /// detached task, and the reader pays for it while they are reading page
  /// one rather than after they have typed a question. Nothing is reported —
  /// a build that does not finish is simply built (and waited for) by `ask`.
  ///
  /// The estimate is made against the whole book, which is the most a
  /// question can ever ship: a book that fits the active provider's
  /// whole-book budget routes there under every scope, so there is nothing to
  /// index.
  public func prepareAsk(_ bookID: String, providers: AndroidProviders) {
    guard let book = try? self.book(bookID) else { return }
    guard let provider = (try? providers.manager.activeProvider()) ?? nil else { return }
    guard !routesWholeBook(book, scope: .wholeBook, provider: provider.info) else { return }
    _ = askIndexes.build(for: book)
  }

  /// Whether `AdaptiveContextStrategy` would send the text itself rather than
  /// retrieve passages — decided on the same numbers it uses: a non-local
  /// provider, and a text that fits `wholeBookBudgetFraction` of the model's
  /// context budget. A scoped question measures only what has been read, and
  /// a reader who has read nothing routes whole-book with nothing in it.
  ///
  /// KIT FOLLOW-UP: this is a *copy* of the strategy's own rule, and a change
  /// to `AdaptiveContextStrategy` that this does not follow shows up as an
  /// index built for a question that never reads it — or a question that
  /// waits for no index at all and is answered from an empty one.
  /// `KitBridgeTest.theRoutingRuleDecidesWhetherTheBookIsIndexed` pins the
  /// two together from the outside until the kit exposes the decision
  /// itself, at which point this should call it rather than restate it.
  func routesWholeBook(_ book: Book, scope: ReadingScope, provider: ProviderInfo) -> Bool {
    guard !provider.isLocal else { return false }
    let budget = Int(Double(provider.contextBudget) * Self.wholeBookBudgetFraction)
    guard let frontier = scope.frontier else { return book.estimatedTokenCount <= budget }
    let read = readingLengths.table(for: book).charactersRead(upTo: frontier)
    guard read > 0 else { return true }
    return estimateTokens(characterCount: read) <= budget
  }

  /// `AdaptiveContextStrategy`'s own default: the share of the context budget
  /// a book may occupy before the router switches to retrieval, leaving the
  /// rest for the conversation and the answer.
  static var wholeBookBudgetFraction: Double { 0.6 }

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
    // Through the table in both directions: to characters, so a selection
    // that lands inside a grapheme still cuts on one, and back to UTF-16 to
    // index the string itself. Making an `[Character]` of the chapter to
    // slice a sentence out of it copies the whole chapter, on the main path
    // of every selection question.
    let lower = table.characterOffset(ofUTF16: wire.utf16Start)
    let upper = max(lower, table.characterOffset(ofUTF16: wire.utf16End))
    let contextLower = max(0, lower - Self.selectionContextCharacters)
    let contextUpper = min(table.characterCount, upper + Self.selectionContextCharacters)
    let text = chapter.text
    func position(_ characterOffset: Int) -> String.Index {
      String.Index(utf16Offset: table.utf16Offset(ofCharacter: characterOffset), in: text)
    }
    return Selection(
      chapterID: chapter.id,
      quotedText: lower < upper ? String(text[position(lower)..<position(upper)]) : "",
      surroundingText: String(text[position(contextLower)..<position(contextUpper)]),
      chapterTitle: chapter.title)
  }

  /// The conversation so far. A turn that will not decode is dropped rather
  /// than failing the question: history is context, and a question the reader
  /// just typed must not be refused over a transcript entry.
  func askHistory(_ json: String, in book: Book, scoped: Bool) -> [ConversationTurn] {
    guard !json.isEmpty,
          let wire = try? JSONDecoder().decode([AskTurnWire].self, from: Data(json.utf8))
    else { return [] }
    // A scoped question is answered from what the reader has read — including
    // in the conversation behind it, so an earlier whole-book answer cannot
    // walk a spoiler back in through the history.
    return wire.filter { !scoped || $0.scoped == true }.map { turn in
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

  /// Characters of context either side of a selected passage — the Apple
  /// reader's 240, so a question about the same passage is anchored the same
  /// way on both platforms.
  static var selectionContextCharacters: Int { 240 }

  /// The answer's Markdown as the blocks the sheet draws — the kit's own
  /// `AnswerMarkdown`, so a heading, a numbered list or a code fence is cut
  /// out of the stream by the same parser the Apple panel uses rather than by
  /// a second, smaller one written in Kotlin. Runs on every streamed token,
  /// and is tolerant of half-written input for that reason.
  public func answerBlocksJSON(_ markdown: String) -> String {
    let wire = AnswerMarkdown.blocks(from: markdown).map(AnswerBlockWire.init)
    guard let data = try? Self.encoder().encode(wire) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
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

  /// DEBUG AND TEST ONLY. Sends every request for `kind` to `url`'s origin
  /// instead of the vendor's, keeping the path the provider built — so an
  /// instrumented test can point the OpenAI-shaped provider at a server it
  /// runs itself (`http://127.0.0.1:<port>` answers `/v1/chat/completions`).
  /// Pass "" to put the vendor's own host back.
  ///
  /// Only a loopback origin is accepted: this device, and this device only.
  /// Nothing in the app calls it, but a hook that could redirect a
  /// credentialed request to any host on the internet is not a hook worth
  /// having at all — `10.0.2.2` is in the list because that is how an
  /// emulator reaches the machine running it.
  public func overrideEndpoint(_ kind: String, url: String) throws {
    try readerFacing {
      let k = try self.providerKind(kind)
      guard !url.isEmpty else {
        endpointOverrides.set(nil, for: k)
        return
      }
      guard let origin = URL(string: url), let host = origin.host else {
        throw AskRequestError.malformed("endpoint URL")
      }
      guard Self.loopbackHosts.contains(host.lowercased()) else {
        throw AndroidBridgeError.endpointNotLoopback(host)
      }
      endpointOverrides.set(origin, for: k)
    }
  }

  /// The only hosts an override may name.
  static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "10.0.2.2"]
}

/// Per-kind endpoint replacements, consulted by the provider factory. Empty
/// in every build a reader runs; see `AndroidProviders.overrideEndpoint`.
final class EndpointOverrides: @unchecked Sendable {
  private let lock = NSLock()
  private var redirected: [ProviderInfo.Kind: OriginOverridingHTTPClient] = [:]
  /// One session for the whole process, made once. `activeProvider()` builds
  /// a provider on every question and every validation, and a `URLSession`
  /// per provider is a connection pool per question — the sockets a
  /// keep-alive would have reused are thrown away with it.
  private let shared = URLSessionHTTPClient()

  func set(_ origin: URL?, for kind: ProviderInfo.Kind) {
    lock.lock(); defer { lock.unlock() }
    redirected[kind] = origin.map { OriginOverridingHTTPClient(origin: $0, base: shared) }
  }

  /// The transport a provider of `kind` should be built with: the shared one,
  /// or the redirect standing for this kind — which sends through the same
  /// shared session.
  func client(for kind: ProviderInfo.Kind) -> HTTPClient {
    lock.lock(); defer { lock.unlock() }
    return redirected[kind] ?? shared
  }
}

/// An `HTTPClient` that swaps the scheme, host and port of every request for
/// another origin's and leaves the path, query, headers and body alone — so
/// the provider builds exactly the request it would have sent to the vendor
/// and a local server receives it.
struct OriginOverridingHTTPClient: HTTPClient {
  let origin: URL
  private let base: HTTPClient

  init(origin: URL, base: HTTPClient) {
    self.origin = origin
    self.base = base
  }

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
