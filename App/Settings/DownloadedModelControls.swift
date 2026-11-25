import SwiftUI
import ReadrKit
#if os(iOS)
struct DownloadedModelControls: View {
    let modelID: String
    let onChange: () -> Void
    @ObservedObject private var store = MLXModelStore.shared
    private var spec: DownloadedModelSpec? { DownloadedModelCatalog.spec(for: modelID) }
    var body: some View {
        let state = store.state(for: modelID)
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .notDownloaded:
                Button("Download \(spec?.displayName ?? "model") · \(spec?.downloadSizeDescription ?? "")") { store.download(modelID) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("settings.download.model")
                Text("One-time download — best on Wi-Fi. Answers stay on this device. Remove the model here whenever you need the space.").font(.caption)
            case .downloading(let progress):
                ProgressView(value: progress) { Text("Downloading · \(Int(progress * 100))%") }
                Button("Cancel download") { store.cancelDownload(modelID) }.accessibilityIdentifier("settings.download.cancel")
            case .downloaded:
                HStack { Text("Ready for offline questions"); Spacer(); Button("Remove", role: .destructive) { store.delete(modelID) } }
            case .deleting:
                ProgressView("Removing model…")
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
                Button("Retry download") { store.dismissFailure(modelID); store.download(modelID) }
                Button("Remove files", role: .destructive) { store.delete(modelID) }
            }
        }
        .onChange(of: state) { _, new in
            switch new { case .downloading, .deleting: break; default: onChange() }
        }
    }
}
#endif
