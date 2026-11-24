import SwiftUI
import ReadrKit

/// Everything one opening of the Ask panel needs, decided by whoever
/// opens it. The reader hands it to the book's conversation
/// (`AskViewModel.open`) — which outlives the panel — and, on iPhone, uses
/// it as the sheet's item so the sheet presents.
struct AskRequest: Identifiable {
    let id = UUID()
    /// The passage the question is about, or nil for a book-wide question.
    var selection: Selection?
    /// What the answer may see. `.upTo` for a text book — the reader has a
    /// place in it — and `.wholeBook` for a native PDF page, which has none.
    var scope: ReadingScope
    /// Sent on the panel's behalf as soon as it has a provider (the Recap
    /// button). Nil opens a plain panel.
    var initialQuestion: String?
}

/// "Ask the book" panel (J4): shows the selected sentence (when there is one —
/// nil selection means a whole-book question), takes a question, and streams an
/// answer grounded in the book's context. Wears the design's ask popover: ✦
/// caps header, iris-edged quote, quiet paper input, iris suggestion chips,
/// three thinking dots, and citation pills.
///
/// It is a CONVERSATION, not a single exchange: the transcript scrolls above a
/// composer pinned to the bottom, each question shows as sent the moment it is
/// sent, and follow-ups carry the earlier turns with them.
///
/// Opened from a text book it is spoiler-scoped: answers see only what the
/// reader has read. An "Answers from" choice in the header — "Up to where I
/// am" or "Whole book", a two-way segmented control rather than an on/off
/// switch — lifts that for the questions that follow; it is not offered when
/// there is no reading position to scope to (a native PDF page).
struct AskPanelView: View {
    /// Where the panel is: a sheet (iPhone) with its own navigation bar and
    /// Done, or a column in the reader's inspector beside Highlights (Mac,
    /// iPad) with a slim header and "New conversation" — the page stays
    /// readable beside the answer (September 2026 UX review, F1).
    enum Presentation {
        case sheet, inspector
    }

    let book: Book
    private let presentation: Presentation
    /// Start a fresh conversation for this book.
    private let onNewConversation: (() -> Void)?

    /// The conversation, owned by the app model so it outlives this view:
    /// closing the panel and opening it again resumes where it was. The
    /// passage, the frontier and the scope choice all live on it.
    @ObservedObject private var vm: AskViewModel

    /// The passage the conversation is about right now.
    private var selection: Selection? { vm.selection }
    /// What a scoped question is held to; nil means the choice is hidden
    /// and every question is about the whole book.
    private var frontier: ReadingFrontier? { vm.frontier }

    @State private var question = ""
    @State private var expandedCitation: ExpandedCitation?
    /// Provider settings sheet, reachable from the no-provider empty state so
    /// the guidance is actionable (J4: "guided to set up a provider first").
    @State private var showProviders = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    /// Which citation pill is open, scoped to its exchange — two answers can
    /// both have a "Ch. 1" pill and they must not toggle each other.
    private struct ExpandedCitation: Equatable {
        var exchangeID: UUID
        var index: Int
    }

    /// A panel over the book's conversation (`AppModel.askConversation`),
    /// already pointed at its opening by the reader.
    init(
        book: Book,
        conversation: AskViewModel,
        presentation: Presentation = .sheet,
        onNewConversation: (() -> Void)? = nil
    ) {
        self.book = book
        self.presentation = presentation
        self.onNewConversation = onNewConversation
        _vm = ObservedObject(wrappedValue: conversation)
    }

    /// A self-contained sheet: the book's conversation, opened on
    /// `request` (previews, the snapshot suite).
    init(app: AppModel, book: Book, request: AskRequest) {
        let conversation = app.askConversation(for: book)
        conversation.open(request)
        self.init(book: book, conversation: conversation)
    }

    /// What the next question will be allowed to see.
    private var scope: ReadingScope { vm.scope }

    private var isScoped: Bool { scope.isScoped }

    /// "Chapter 7 of 24 · 31% · The Whale" — where a scoped answer stops.
    /// Computed here from the book and the frontier, from the app's cached
    /// chapter lengths; there is no separate state to fall out of date.
    private var positionCaption: String? {
        guard let frontier else { return nil }
        return ReadingPositionSummary(
            book: book, frontier: frontier, lengths: model.readingLengths(for: book)
        )?.caption
    }

    var body: some View {
        Group {
            switch presentation {
            case .sheet:
                sheetBody
            case .inspector:
                inspectorBody
            }
        }
        // Recap: the question arrives already sent — once there is a
        // provider and no stream in flight (the conversation retries on
        // its own when either changes; this covers a panel shown before
        // `open` ran).
        .onAppear { vm.sendPendingIfReady() }
    }

    /// The inspector column: a slim ✦ header with "New conversation", then
    /// the same transcript and composer the sheet shows.
    private var inspectorBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AISheetHeader(title: "Ask the book", theme: theme)
                    .accessibilityIdentifier("ask.header")
                Spacer(minLength: 8)
                if !vm.exchanges.isEmpty, let onNewConversation {
                    newConversationButton(onNewConversation)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
            panelContent
        }
        .background(theme.background)
    }

    /// The sheet: the panel inside its own navigation bar, Done on the right.
    private var sheetBody: some View {
        NavigationStack {
            panelContent
            .navigationTitle("Ask the book")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AISheetHeader(title: "Ask the book", theme: theme)
                        .accessibilityIdentifier("ask.header")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                #if os(iOS)
                // The sheet keeps the conversation for the session too, so
                // it needs the same way to start over the column has.
                if !vm.exchanges.isEmpty, let onNewConversation {
                    ToolbarItem(placement: .topBarLeading) {
                        newConversationButton(onNewConversation)
                    }
                }
                #endif
            }
        }
    }

    private func newConversationButton(_ action: @escaping () -> Void) -> some View {
        Button("New conversation", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(theme.muted)
            .help("Start over with an empty transcript")
            .accessibilityIdentifier("ask.newConversation")
    }

    /// The conversation, or the guided empty state while no provider is
    /// connected.
    private var panelContent: some View {
        Group {
            if vm.hasProvider {
                askContent
            } else {
                // Same actionable empty state as the Article studio: the
                // guidance carries a button, not just directions.
                ContentUnavailableView {
                    Label("No AI provider connected", systemImage: "sparkles")
                } description: {
                    Text(SettingsModel.setupGuidance(toDo: "ask questions"))
                } actions: {
                    Button {
                        showProviders = true
                    } label: {
                        Text("Open AI Providers")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(theme.background)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 16)
                            .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
                // A1: re-resolve the provider when the sheet dismisses so a
                // key saved here flips the panel out of its empty state
                // without an app restart.
                .sheet(isPresented: $showProviders, onDismiss: { vm.refresh() }) {
                    ProviderSettingsView(app: model)
                        .environmentObject(model)
                }
            }
        }
        .background(theme.background)
    }

    private var askContent: some View {
        VStack(spacing: 0) {
        transcript
        composer
        }
    }

    // MARK: - Transcript

    /// The conversation so far. Anchored to the newest exchange so a streaming
    /// answer stays in view without the reader chasing it.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextHeader
                    ForEach(vm.exchanges) { exchange in
                        exchangeView(exchange)
                            .id(exchange.id)
                    }
                    if vm.isStreaming, vm.exchanges.last?.answerText.isEmpty == true {
                        ThinkingDots(color: theme.iris)
                    }
                    // Scroll anchor: a zero-height marker that is always the
                    // last thing in the stack, so "scroll to the bottom" works
                    // while the final answer is still growing.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.exchanges.count) { scrollToBottom(proxy) }
            .onChange(of: vm.exchanges.last?.answerText) { scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "ask.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    /// What the question is anchored to — the selected sentence, or a note
    /// saying how much of the book is in scope — with the scope choice
    /// beneath it whenever there is a reading position to scope to.
    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection, !selection.quotedText.isEmpty {
                Text(selection.quotedText)
                    .font(.system(.footnote, design: .serif))
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(theme.muted)
                    .lineLimit(2)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(theme.iris).frame(width: 2)
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(scopeHeadline, systemImage: "book")
                        .font(.footnote)
                        .foregroundStyle(theme.muted)
                    if isScoped, let positionCaption {
                        // Say where a scoped answer stops, so the reader can
                        // see it covers the right stretch of the book.
                        Text(positionCaption)
                            .font(.caption)
                            .foregroundStyle(theme.faint)
                            .accessibilityIdentifier("ask.position")
                    }
                }
            }
            if frontier != nil {
                scopePicker
            }
        }
    }

    /// The no-selection headline: what the panel is for, and how far it
    /// can see.
    private var scopeHeadline: String {
        if vm.openedForRecap, isScoped {
            return "Recap up to where you are"
        }
        return isScoped ? "Ask about what you've read so far" : "Ask anything about this book"
    }

    /// "Up to where I am" or "Whole book": a two-way choice, labelled, with a
    /// line under it saying what the chosen scope means. It was a switch
    /// captioned "Whole book", which read as a feature to turn on rather
    /// than one of two scopes to pick — and off, it gave no hint that the
    /// other scope existed. Changing it changes the scope of every question
    /// sent after; the answers already on screen keep the scope they were
    /// asked under.
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ANSWERS FROM")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.faint)
            Picker("Answers from", selection: $vm.wholeBook) {
                Text("Up to where I am").tag(false)
                Text("Whole book").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            .controlSize(.small)
            #endif
            .tint(theme.iris)
            .accessibilityIdentifier("ask.scope")
            Text(
                vm.wholeBook
                    ? "Answers may use the whole book, including what you haven\u{2019}t read."
                    : "Answers stop where you stopped reading — no spoilers."
            )
            .font(.caption)
            .foregroundStyle(theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ask.scopeNote")
        }
    }

    private func exchangeView(_ exchange: AskViewModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sentQuestion(exchange.question)
            if !exchange.answerText.isEmpty {
                AnswerMarkdownView(markdown: exchange.answerText, theme: theme)
            } else if exchange.isEmpty, !exchange.failed {
                // The stream ended with nothing worth showing (an on-device
                // answer whose every sentence was cut). A blank bubble over a
                // Sources list read as a broken app; say what happened.
                Text("The model couldn\u{2019}t find an answer to that in the book. Try asking about something that happens in it.")
                    .font(.callout)
                    .lineSpacing(4)
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.emptyAnswer")
            }
            // A4: retrieval tier lists real, tappable sources; the whole-book
            // tier explains — honestly — that there is no citation list
            // because nothing was retrieved. Neither for an empty answer:
            // sources for nothing point at nothing.
            if exchange.tier?.providesCitations == true, !exchange.citations.isEmpty, !exchange.answerText.isEmpty {
                citationsSection(exchange)
            } else if exchange.tier?.providesCitations == false, !exchange.answerText.isEmpty {
                wholeBookNote(scoped: exchange.scope.isScoped)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reader's own message, right-aligned in an ink-tinted bubble — the
    /// question has to look SENT, distinct from the answer under it.
    private func sentQuestion(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.callout)
                .lineSpacing(4)
                .foregroundStyle(theme.inkColor)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(theme.iris.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(theme.iris.opacity(0.22), lineWidth: 1)
                )
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
        .accessibilityIdentifier("ask.sentQuestion")
    }

    // MARK: - Composer

    /// The input, its suggestions, the grounding caption, and the error card —
    /// pinned below the transcript so they stay reachable inside the iPhone
    /// medium sheet detent no matter how long the conversation runs.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The error card sits ABOVE the input rather than in the
            // transcript so its Retry button never scrolls out of the visible
            // area of the medium detent.
            if let error = vm.errorMessage {
                errorCard(error)
            }

            // Suggested questions get first-time users past the blank field.
            // Each chip is a complete question, so a tap SENDS it — putting
            // the text in the field and asking for a second tap was a step
            // with nothing in it.
            if vm.exchanges.isEmpty && !vm.isStreaming {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestedQuestions, id: \.self) { suggestion in
                            Button {
                                question = suggestion
                                submit()
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundStyle(theme.iris)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 11)
                                    .background(theme.iris.opacity(0.10), in: Capsule())
                                    .overlay(Capsule().strokeBorder(theme.iris.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            HStack(spacing: 8) {
                TextField(composerPrompt, text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1...4)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 11)
                    .background(theme.paper, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line, lineWidth: 1))
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(theme.iris)
                }
                .buttonStyle(.plain)
                .disabled(vm.isStreaming || question.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("ask.send")
            }

            // A4: the grounding promise is derived from the tier signal, not
            // hardcoded — the whole-book tier returns no per-passage sources,
            // so it must not promise citations it can't deliver.
            // Stacked, not side by side: the caption is a full sentence and
            // the iPhone composer has no width to spare.
            VStack(alignment: .leading, spacing: 4) {
                Text(groundingCaption)
                    .font(.caption2)
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let tier = vm.tier {
                    Label(
                        tier.providesCitations
                            ? "Using relevant passages"
                            : (isScoped ? "Using everything you've read" : "Using the whole book"),
                        systemImage: tier.providesCitations ? "doc.text.magnifyingglass" : "book.closed"
                    )
                    .font(.caption2)
                    .foregroundStyle(theme.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(theme.background)
        .overlay(alignment: .top) { theme.line.frame(height: 1) }
    }

    /// The placeholder shifts once the conversation is under way: the field is
    /// for follow-ups from then on.
    private var composerPrompt: String {
        vm.exchanges.isEmpty ? "Ask a question about this book…" : "Ask a follow-up…"
    }

    /// A4: the grounding caption promises citations only when the answer will
    /// actually carry them. Before a tier is known (or on the citation-backed
    /// retrieval tier) it keeps the full promise; on the whole-book tier it
    /// drops the "with citations" claim it can't honor. Under a scope it
    /// says what the grounding is: what the reader has read, not the book.
    private var groundingCaption: String {
        let grounding = isScoped ? "what you\u{2019}ve read so far" : (vm.tier?.providesCitations == false ? "the whole book" : "this book")
        if vm.answersFromBookOnly {
            // The on-device model answers from the passages and nothing else;
            // promising its "wider knowledge" would promise what it cannot do.
            return "Answers come from \(grounding) only."
        }
        if vm.tier?.providesCitations == false {
            return "Grounded in \(grounding) — plus the model\u{2019}s wider knowledge."
        }
        return "Grounded in \(grounding) with citations — plus the model\u{2019}s wider knowledge."
    }

    /// A4: the honest whole-book footer — the answer drew on the entire text
    /// (or, scoped, on everything read so far), so there is no passage
    /// retrieval and no citation list to show.
    private func wholeBookNote(scoped: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scoped ? "USING EVERYTHING YOU\u{2019}VE READ" : "USING THE WHOLE BOOK")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.faint)
            Text(
                scoped
                    ? "Everything you've read so far fits in one request, so the answer draws on all of it — no passage retrieval, no citation list."
                    : "This book is short enough to read in full, so the answer draws on the entire text — no passage retrieval, no citation list."
            )
            .font(.caption)
            .lineSpacing(3)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.wholeBookNote")
    }

    /// A5: the actionable error state — a plain cause sentence, the mapped
    /// recovery suggestion when the error carries one, and a Retry affordance
    /// that re-runs the same question without retyping.
    @ViewBuilder
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.body)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.inkColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let recovery = vm.errorRecovery {
                        Text(recovery)
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Retry is always shown: `errorCard` only renders when
            // `errorMessage` is set, and every path that sets it runs after
            // `AskViewModel.ask` records `lastRequest` — so there is always a
            // question to re-run. (A prior `if vm.lastQuestion != nil` gate was
            // both redundant and, because `lastQuestion` isn't `@Published`,
            // risked dropping the button from the accessibility tree.)
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.background)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(vm.isStreaming)
            .accessibilityLabel("Retry")
            .accessibilityIdentifier("ask.retry")
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red, lineWidth: 1))
        // Mark this card as an accessibility container so its own
        // `ask.error` identifier stays on the container and does NOT flatten
        // onto the children. Without `.contain`, SwiftUI propagated
        // `ask.error` down to every descendant — the CI accessibility dump
        // showed the Retry button reporting `identifier: 'ask.error'` instead
        // of its own `ask.retry`, so `app.buttons["ask.retry"]` never matched.
        // (Matches the `settings.card.*` and `reader.appearance` containers.)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.error")
    }

    /// Citations as tappable iris pills labeled by locator; tapping one opens
    /// its quoted passage beneath the row (tap again to collapse).
    private func citationsSection(_ exchange: AskViewModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.faint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(exchange.citations.enumerated()), id: \.offset) { index, citation in
                        let isExpanded = expandedCitation
                            == ExpandedCitation(exchangeID: exchange.id, index: index)
                        Button {
                            expandedCitation = isExpanded
                                ? nil
                                : ExpandedCitation(exchangeID: exchange.id, index: index)
                        } label: {
                            Text(citation.locator)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.iris)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(theme.iris.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(theme.iris.opacity(isExpanded ? 0.6 : 0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isExpanded ? .isSelected : [])
                    }
                }
                .padding(.vertical, 1)
            }

            if let expanded = expandedCitation,
               expanded.exchangeID == exchange.id,
               exchange.citations.indices.contains(expanded.index) {
                let citation = exchange.citations[expanded.index]
                Text("\u{201C}\(citation.quotedText)\u{201D}")
                    .font(.system(.footnote, design: .serif))
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(theme.muted)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(theme.iris).frame(width: 2)
                    }
                    .accessibilityLabel(Text(citation.quotedText))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Static starters, tuned to the mode and the scope: passage questions
    /// when there's a selection, book questions otherwise — worded "so far"
    /// whenever answers stop where the reader stopped, because "summarize
    /// this book" is not a question a scoped answer can honestly take. The
    /// recap leads the scoped set: it is the question a reader coming back
    /// to a book actually has, and the one the store copy promises.
    private var suggestedQuestions: [String] {
        if selection != nil {
            return [
                "What does this passage mean?",
                isScoped
                    ? "How does this connect to what I've read so far?"
                    : "How does this connect to the rest of the book?",
            ]
        }
        if isScoped {
            return [
                Self.recapQuestion,
                "Summarize what I've read so far",
                "What are the key themes so far?",
                "Who are the main characters so far?",
            ]
        }
        return [
            "Summarize this book",
            "What are the key themes?",
            "Who are the main characters?",
        ]
    }

    /// Sends the question and empties the field — the text belongs to the
    /// transcript from here on, and leaving it in the input made a sent
    /// message look unsent.
    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !vm.isStreaming else { return }
        question = ""
        vm.submit(q)
    }

    /// A5: re-run the last question after a failure.
    private func retry() {
        vm.retry()
    }

    /// The recap, word for word — the first suggestion chip and what the
    /// Recap button (reader toolbar, Continue Reading card) sends.
    static let recapQuestion = "Recap what I've read so far \u{2014} no spoilers"
}

/// The design's streaming indicator: three 5pt iris dots pulsing in a
/// staggered wave (replaces the platform ProgressView).
private struct ThinkingDots: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: pulsing
                    )
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Thinking")
        .onAppear { pulsing = true }
    }
}
