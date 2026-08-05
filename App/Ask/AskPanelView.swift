import SwiftUI
import ReadrKit

/// "Ask the book" panel (J4): shows the selected sentence (when there is one —
/// nil selection means a whole-book question), takes a question, and streams an
/// answer grounded in the book's context. Wears the design's ask popover: ✦
/// caps header, iris-edged quote, quiet paper input, iris suggestion chips,
/// three thinking dots, and citation pills.
///
/// It is a CONVERSATION, not a single exchange: the transcript scrolls above a
/// composer pinned to the bottom, each question shows as sent the moment it is
/// sent, and follow-ups carry the earlier turns with them.
struct AskPanelView: View {
    let book: Book
    let selection: Selection?

    @StateObject private var vm: AskViewModel
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

    init(app: AppModel, book: Book, selection: Selection?) {
        self.book = book
        self.selection = selection
        _vm = StateObject(wrappedValue: AskViewModel(
            makeService: { app.makeAskService() },
            prepare: {
                await app.ensureIndexed(book)
                await app.refreshActiveProviderCredentialsIfNeeded()
            },
            book: book,
            selection: selection,
            providerName: { app.providerManager.selection?.kind.rawValue ?? "none" }
        ))
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Ask the book")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(AppTheme.aiGlyph)
                            .font(.subheadline)
                            .foregroundStyle(theme.iris)
                        Text("ASK THE BOOK")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(theme.muted)
                    }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Ask the book")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

    /// What the question is anchored to: the selected sentence, or a note that
    /// the whole book is in scope.
    @ViewBuilder
    private var contextHeader: some View {
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
            // No selection: the panel was opened for whole-book questions —
            // say so instead of showing an empty quote box.
            Label("Ask anything about this book", systemImage: "book")
                .font(.footnote)
                .foregroundStyle(theme.muted)
        }
    }

    private func exchangeView(_ exchange: AskViewModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sentQuestion(exchange.question)
            if !exchange.answerText.isEmpty {
                AnswerMarkdownView(markdown: exchange.answerText, theme: theme)
            }
            // A4: retrieval tier lists real, tappable sources; the whole-book
            // tier explains — honestly — that there is no citation list
            // because nothing was retrieved.
            if exchange.tier?.providesCitations == true, !exchange.citations.isEmpty {
                citationsSection(exchange)
            } else if exchange.tier?.providesCitations == false, !exchange.answerText.isEmpty {
                wholeBookNote
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

            // Suggested questions get first-time users past the blank field;
            // tapping inserts the text (still editable) rather than submitting.
            if vm.exchanges.isEmpty && !vm.isStreaming {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestedQuestions, id: \.self) { suggestion in
                            Button {
                                question = suggestion
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
                        tier.providesCitations ? "Using relevant passages" : "Using the whole book",
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
    /// drops the "with citations" claim it can't honor.
    private var groundingCaption: String {
        if vm.tier?.providesCitations == false {
            return "Grounded in the whole book — plus the model\u{2019}s wider knowledge."
        }
        return "Grounded in this book with citations — plus the model\u{2019}s wider knowledge."
    }

    /// A4: the honest whole-book footer — the answer drew on the entire text,
    /// so there is no passage retrieval and no citation list to show.
    private var wholeBookNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USING THE WHOLE BOOK")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.faint)
            Text("This book is short enough to read in full, so the answer draws on the entire text — no passage retrieval, no citation list.")
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
            // `AskViewModel.ask` records `lastQuestion` — so there is always a
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

    /// Static starters, tuned to the mode: passage questions when there's a
    /// selection, whole-book questions otherwise.
    private var suggestedQuestions: [String] {
        if selection != nil {
            return [
                "What does this passage mean?",
                "How does this connect to the rest of the book?",
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
        Task { await vm.ask(q) }
    }

    /// A5: re-run the last question after a failure.
    private func retry() {
        Task { await vm.retry() }
    }
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
