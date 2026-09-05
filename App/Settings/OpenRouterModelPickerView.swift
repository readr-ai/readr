import SwiftUI
import ReadrKit

/// The OpenRouter model picker: a search field over the live catalogue, with
/// the curated set on top. Three sections — Recommended (the curated ids, in
/// curated order), Free (the `:free` rows), and All models — each row naming
/// the model, its id, and "$in · $out per 1M · context". Picking a row makes
/// it the active OpenRouter model and closes the sheet.
///
/// Opened from `ProviderSettingsView`'s OpenRouter card. The list itself is
/// `SettingsModel.openRouterModels`, loaded by the settings view's `.task`;
/// while it loads the sheet shows the curated list with a spinner, and when
/// only the curated list could be had (offline, first launch) it says so.
struct OpenRouterModelPickerView: View {
    @ObservedObject var model: SettingsModel
    let theme: ReadingTheme
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    searchField

                    if model.isLoadingOpenRouterModels {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading the OpenRouter catalogue…")
                                .font(.caption)
                                .foregroundStyle(theme.muted)
                        }
                        .accessibilityIdentifier("settings.modelPicker.loading")
                    } else if model.openRouterListSource == .curated {
                        Text("Showing the built-in list — the full OpenRouter catalogue needs a connection.")
                            .font(.caption)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.modelPicker.offline")
                    }

                    if recommended.isEmpty, free.isEmpty, all.isEmpty {
                        Text("No models match “\(query)”.")
                            .font(.caption)
                            .foregroundStyle(theme.faint)
                            .padding(.top, 8)
                    }
                    section("RECOMMENDED", recommended)
                    section("FREE", free)
                    section("ALL MODELS", all)
                }
                .padding(20)
                .padding(.bottom, 28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("OpenRouter model")
            .toolbar {
                // A pick applies on tap, so the way out is Done, on the
                // right, like every other sheet.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    // MARK: - Sections

    private var currentID: String {
        if let selection = model.activeSelection, selection.kind == .openRouter {
            return selection.modelID
        }
        return ProviderCatalog.defaultModel(for: .openRouter).modelID
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ model: OpenRouterModel) -> Bool {
        let q = trimmedQuery
        guard !q.isEmpty else { return true }
        return model.id.localizedCaseInsensitiveContains(q)
            || model.name.localizedCaseInsensitiveContains(q)
    }

    /// The curated ids in curated order, each taking the live row (today's
    /// name, price, context) when the catalogue has one, else the curated
    /// row itself.
    private var recommended: [OpenRouterModel] {
        let live = Dictionary(model.openRouterModels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ProviderCatalog.openRouterCurated
            .map { live[$0.id] ?? $0 }
            .filter(matches)
    }

    private var free: [OpenRouterModel] {
        model.openRouterModels.filter { $0.isFree && matches($0) }
    }

    private var all: [OpenRouterModel] {
        model.openRouterModels.filter(matches)
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.faint)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(theme.inkColor)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("settings.modelPicker.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func section(_ title: String, _ models: [OpenRouterModel]) -> some View {
        if !models.isEmpty {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(theme.faint)
                .padding(.top, 12)
                .padding(.bottom, 2)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        theme.line.frame(height: 1)
                    }
                    row(item)
                }
            }
            .background(theme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
        }
    }

    private func row(_ item: OpenRouterModel) -> some View {
        let selected = item.id == currentID
        return Button {
            model.makeActive(kind: .openRouter, modelID: item.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.inkColor)
                    Text(item.id)
                        .font(.caption)
                        .foregroundStyle(theme.faint)
                    Text(item.pickerLine)
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.iris)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.pickerLine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.modelPicker.row.\(item.id)")
    }
}
