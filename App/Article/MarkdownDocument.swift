import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` so composed articles can be saved as `.md` via
/// `fileExporter` on both platforms.
struct MarkdownDocument: FileDocument {
    /// The system Markdown type when it's registered (macOS/iOS declare
    /// `net.daringfireball.markdown`), else plain text so export still works.
    static let markdownType: UTType = UTType("net.daringfireball.markdown") ?? .plainText

    static var readableContentTypes: [UTType] { [markdownType, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
