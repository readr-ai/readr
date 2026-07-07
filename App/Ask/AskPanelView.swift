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
            service: app.makeAskService(),
            prepare: { await app.ensureIndexed(book) },
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
                        Text("Add an API key, sign in, or pick a local model to ask questions.")
                    } actions: {
                        Button {
                            showProviders = true
                        } label: {
                            Text("Open AI Providers")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(theme.background)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 16)
                                .background(theme.inkColor, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .sheet(isPresented: $showProviders) {
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
                            .font(.system(size: 13))
                            .foregroundStyle(theme.iris)
                        Text("ASK THE BOOK")
                            .font(.system(size: 10.5, weight: .semibold))
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
                    .font(.system(size: 12, design: .serif))
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
            }

            HStack(spacing: 8) {
                TextField("Ask a question about this book…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
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
                                    .font(.system(size: 11.5))
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

            Text("Grounded in this book with citations — plus the model\u{2019}s wider knowledge.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)

            if let tier = vm.tier {
                Label(
                    tier == .wholeBook ? "Using the whole book" : "Using relevant passages",
                    systemImage: tier == .wholeBook ? "book.closed" : "doc.text.magnifyingglass"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(vm.answer)
                        .font(.system(size: 13))
                        .lineSpacing(7)
                        .foregroundStyle(theme.inkColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !vm.citations.isEmpty {
                        citationsSection
                    }
                }
            }

            if vm.isStreaming { ThinkingDots(color: theme.iris) }
            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }

    /// Citations as tappable iris pills labeled by locator; tapping one opens
    /// its quoted passage beneath the row (tap again to collapse).
    private var citationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES")
                .font(.system(size: 10, weight: .semibold))
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
                                .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 12, design: .serif))
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
