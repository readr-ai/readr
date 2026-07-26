import SwiftUI
import ReadrKit

/// "Ask the book" panel (J4): shows the selected sentence (when there is one —
/// nil selection means a whole-book question), takes a question, and streams an
/// answer grounded in the book's context. Wears the design's ask popover: ✦
/// caps header, iris-edged quote, quiet paper input, iris suggestion chips,
/// three thinking dots, and citation pills.
struct AskPanelView: View {
    let book: Book
    let selection: Selection?

    @StateObject private var vm: AskViewModel
    @State private var question = ""
    @State private var expandedCitation: Int?
    /// Provider settings sheet, reachable from the no-provider empty state so
    /// the guidance is actionable (J4: "guided to set up a provider first").
    @State private var showProviders = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

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
            selection: selection
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
        VStack(alignment: .leading, spacing: 12) {
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

            HStack(spacing: 8) {
                TextField("Ask a question about this book…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(theme.inkColor)
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

            // Suggested questions get first-time users past the blank field;
            // tapping inserts the text (still editable) rather than submitting.
            if vm.answer.isEmpty && !vm.isStreaming {
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

            // A4: the grounding promise is derived from the tier signal, not
            // hardcoded — the whole-book tier returns no per-passage sources,
            // so it must not promise citations it can't deliver.
            Text(groundingCaption)
                .font(.caption2)
                .foregroundStyle(theme.faint)

            if let tier = vm.tier {
                Label(
                    tier.providesCitations ? "Using relevant passages" : "Using the whole book",
                    systemImage: tier.providesCitations ? "doc.text.magnifyingglass" : "book.closed"
                )
                .font(.caption2)
                .foregroundStyle(theme.faint)
            }

            // The error card sits above the answer scroll region so its Retry
            // button stays within the visible area of the iPhone medium sheet
            // detent, ahead of the answer/citations content.
            if let error = vm.errorMessage {
                errorCard(error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(vm.answer)
                        .font(.callout)
                        .lineSpacing(7)
                        .foregroundStyle(theme.inkColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    // A4: retrieval tier lists real, tappable sources; the
                    // whole-book tier explains — honestly — that there is no
                    // citation list because nothing was retrieved.
                    if vm.tier?.providesCitations == true, !vm.citations.isEmpty {
                        citationsSection
                    } else if vm.tier?.providesCitations == false, !vm.answer.isEmpty {
                        wholeBookNote
                    }
                }
            }

            if vm.isStreaming { ThinkingDots(color: theme.iris) }
            Spacer()
        }
        .padding()
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
    private var citationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(theme.faint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(vm.citations.enumerated()), id: \.offset) { index, citation in
                        let isExpanded = expandedCitation == index
                        Button {
                            expandedCitation = isExpanded ? nil : index
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

            if let index = expandedCitation, vm.citations.indices.contains(index) {
                let citation = vm.citations[index]
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

    private func submit() {
        let q = question
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
