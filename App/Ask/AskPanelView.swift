import SwiftUI
import ReadrKit

/// "Ask the book" panel (J4): shows the selected sentence, takes a question, and
/// streams an answer grounded in the book's context.
struct AskPanelView: View {
    let book: Book
    let selection: Selection?

    @StateObject private var vm: AskViewModel
    @State private var question = ""
    @Environment(\.dismiss) private var dismiss

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
                    ContentUnavailableView(
                        "No AI provider connected",
                        systemImage: "sparkles",
                        description: Text("Add an API key, sign in, or pick a local model under AI Providers to ask questions.")
                    )
                }
            }
            .navigationTitle("Ask the book")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
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
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                TextField("Ask a question about this book…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(vm.isStreaming || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let tier = vm.tier {
                Label(
                    tier == .wholeBook ? "Using the whole book" : "Using relevant passages",
                    systemImage: tier == .wholeBook ? "book.closed" : "doc.text.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(vm.answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !vm.citations.isEmpty {
                        citationsSection
                    }
                }
            }

            if vm.isStreaming { ProgressView() }
            if let error = vm.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding()
    }

    private var citationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sources", systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(vm.citations.enumerated()), id: \.offset) { _, citation in
                DisclosureGroup {
                    Text(citation.quotedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(citation.locator)
                        .font(.caption.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func submit() {
        let q = question
        Task { await vm.ask(q) }
    }
}
