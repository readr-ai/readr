#if DEBUG && os(iOS)
import Foundation
import CoreGraphics
import CoreText
import UIKit
import ReadrKit

/// Explicit developer-device integration run. Normal and release launches never
/// enter this path. Exercises production parsers, model store/provider and router.
@MainActor
enum LaunchModelSmoke {
    private static var started = false
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-launchModelSmoke"), !started else { return }
        started = true
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadrLaunchQA")
        var result: [String: String] = [:]
        func record(_ stage: String) {
            result["stage"] = stage
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"), options: .atomic) }
            catch { DiagnosticsLog.shared.record(.error, .provider, "Device QA report could not be saved", error: error) }
        }
        do {
            guard let url = Bundle.main.url(forResource: "alice-in-wonderland", withExtension: "epub") else { throw SmokeError.failed("Bundled EPUB missing") }
            let book = try await EPUBFileParser().parse(url)
            guard let chapter = book.chapters.first, chapter.text.contains("Alice") else { throw SmokeError.failed("EPUB text missing") }
            result["epubChapters"] = String(book.chapters.count)
            let spec = DownloadedModelCatalog.all[0]
            record("downloading Qwen")
            MLXModelStore.shared.download(spec.repository)
            let deadline = Date().addingTimeInterval(1200)
            while !MLXModelStore.shared.isDownloaded(spec.repository) {
                if case .failed(let message) = MLXModelStore.shared.state(for: spec.repository) { throw SmokeError.failed(message) }
                guard Date() < deadline else { throw SmokeError.failed("Qwen download timeout") }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            record("asking Qwen")
            let provider = MLXLLMProvider(info: ProviderCatalog.defaultModel(for: .downloadedModel))
            let request = ChatRequest(messages: [
                ChatMessage(role: .system, content: "Answer in one short sentence using only this passage from Alice's Adventures in Wonderland: " + String(chapter.text.prefix(2000))),
                ChatMessage(role: .user, content: "Why does Alice think her sister's book is boring?")
            ], maxOutputTokens: 128)
            let began = Date()
            var answer = ""
            for try await chunk in provider.stream(request) { answer += chunk.textDelta }
            result["qwenAnswer"] = answer
            result["qwenSeconds"] = String(Date().timeIntervalSince(began))
            guard answer.lowercased().contains("picture") || answer.lowercased().contains("conversation") else { throw SmokeError.failed("Qwen answer did not reference the supplied passage") }
            record("speaking EPUB with Kokoro")
            let router = RoutingSpeechEngine()
            let recorder = Completion()
            router.delegate = recorder
            let paragraph = "Alice was beginning to get very tired of sitting by her sister on the bank."
            try await speak(paragraph, bookID: book.id, name: "epub", router: router, recorder: recorder, root: root)
            record("testing queued speech cancellation")
            let held = try await MLXGPULease.shared.acquire()
            router.speak(SpeechRequest(text: "This queued sentence must never play.", voiceID: KokoroSpeechEngine.defaultVoiceID, language: "en-US", bookID: book.id))
            try await Task.sleep(nanoseconds: 100_000_000)
            router.stop()
            await MLXGPULease.shared.release(held)
            try await speak("The voice resumes correctly after cancellation.", bookID: book.id, name: "after-cancellation", router: router, recorder: recorder, root: root)
            let pdfURL = root.appendingPathComponent("test-book.pdf")
            try makePDF(pdfURL)
            let pdf = try await PDFKitBookParser().parse(pdfURL)
            guard pdf.chapters.count == 2, pdf.chapters[1].text.contains("second page") else { throw SmokeError.failed("PDF native/OCR pages missing") }
            for (index, page) in pdf.chapters.enumerated() {
                record("speaking PDF page \(index + 1)")
                try page.text.write(to: root.appendingPathComponent("pdf-page-\(index + 1).txt"), atomically: true, encoding: .utf8)
                try await speak(page.text, bookID: pdf.id, name: "pdf-page-\(index + 1)", router: router, recorder: recorder, root: root)
            }
            router.stop(); router.endAudioSession()
            result["status"] = "passed"
            record("complete")
        } catch {
            result["status"] = "failed"; result["error"] = String(describing: error)
            record("failed")
        }
    }
    private static func speak(_ text: String, bookID: UUID, name: String, router: RoutingSpeechEngine, recorder: Completion, root: URL) async throws {
        let request = SpeechRequest(text: text, voiceID: KokoroSpeechEngine.defaultVoiceID, language: "en-US", bookID: bookID)
        recorder.finished = false; recorder.error = nil; recorder.began = false
        router.speak(request)
        let deadline = Date().addingTimeInterval(300)
        while !recorder.finished && recorder.error == nil {
            guard Date() < deadline else { router.stop(); throw SmokeError.failed("Kokoro playback timeout") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let error = recorder.error { throw error }
        guard recorder.began, let entry = ReadrVoiceAudioCache.shared.entry(for: ReadrVoiceAudioCache.key(for: request)), entry.seconds > 0 else { throw SmokeError.failed("No played Kokoro audio") }
        let destination = root.appendingPathComponent(name + ".m4a")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: entry.url, to: destination)
    }
    private final class Completion: SpeechEngineDelegate {
        var finished = false, began = false
        var error: Error?
        func speechEngine(_ engine: any SpeechEngine, didFinish requestID: UUID) { finished = true }
        func speechEngine(_ engine: any SpeechEngine, didBeginSpeaking requestID: UUID) { began = true }
        func speechEngine(_ engine: any SpeechEngine, didFail requestID: UUID, error: any Error) { self.error = error }
    }
    private static func makePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let document = CGContext(url as CFURL, mediaBox: &box, nil) else { throw SmokeError.failed("PDF fixture creation failed") }
        func draw(_ text: String, in context: CGContext) {
            context.textPosition = CGPoint(x: 40, y: 700)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil)])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        document.beginPDFPage(nil); draw("Alice follows the white rabbit on the first page.", in: document); document.endPDFPage()
        guard let bitmap = CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw SmokeError.failed("Scan creation failed") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584)); bitmap.scaleBy(x: 2, y: 2)
        draw("The second page finishes this little story.", in: bitmap)
        guard let image = bitmap.makeImage() else { throw SmokeError.failed("Scan image missing") }
        document.beginPDFPage(nil); document.draw(image, in: box); document.endPDFPage(); document.closePDF()
    }
    private enum SmokeError: Error { case failed(String) }
}
#endif
