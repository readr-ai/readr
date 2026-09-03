import Foundation
import AVFoundation
import CryptoKit
import ReadrKit

/// Where Readr Voice keeps the sentences it has already said or synthesized
/// ahead: compressed audio on disk, keyed by book, voice and the text's
/// hash, so a sentence is synthesized once per voice and plays from here
/// ever after — through a relaunch, a skip back, and a locked screen.
///
/// - **Format.** Mono AAC at 64kbps in an `.m4a` (about 30MB an hour), one
///   file per sentence, written through `AVAudioFile` from the model's
///   float samples. Synthesized at 1×; the player applies the reader's
///   speed, which is what lets a speed change keep the buffer.
/// - **Layout.** `Caches/ReadrVoiceAudio/<book id>/<voice>/<hash>_<ms>.m4a`.
///   The duration lives in the file name so the index is a directory
///   listing, not a pass through every file; the book directory is what a
///   deleted book takes with it. A sentence that yields no audio at all
///   (punctuation only) is an empty file with `_0`, so it is not tried again.
/// - **Bound.** Two hours of audio across all books; beyond that the oldest
///   files go first. The system may clear Caches at any time, in which case
///   the next Listen synthesizes again.
/// - **Index.** In memory only, loaded once from the directory and kept
///   current by `store` and `removeBook`. Reads are cheap and lock-guarded so
///   the engine can ask from the main thread while its actor writes.
final class ReadrVoiceAudioCache: @unchecked Sendable {
    static let shared = ReadrVoiceAudioCache()

    /// What a sentence's audio is filed under. The hash is of voice and
    /// text together, so the same words in another voice are another file.
    struct Key: Hashable, Sendable {
        let bookID: UUID
        let voice: String
        let textHash: String
    }

    struct Entry: Sendable {
        let key: Key
        let url: URL
        /// Audio duration; zero for a sentence that produced no samples.
        let seconds: TimeInterval
        let storedAt: Date
    }

    enum CacheError: Error {
        case cannotEncode
    }

    /// How much audio is kept, across every book.
    static let capacitySeconds: TimeInterval = 2 * 60 * 60
    static let bitRate = 64_000
    /// A request with no book id — none in practice; kept so the key is
    /// total rather than optional.
    private static let unfiledBookID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let root: URL
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var totalSecondsStored: TimeInterval = 0
    private var indexLoaded = false

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadrVoiceAudio", isDirectory: true)
    }

    // MARK: - Keys

    static func key(for request: SpeechRequest) -> Key {
        let voice = KokoroSpeechEngine.kokoroVoice(from: request.voiceID)
        let digest = SHA256.hash(data: Data((voice + "\n" + request.text).utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return Key(bookID: request.bookID ?? unfiledBookID, voice: voice, textHash: hex)
    }

    // MARK: - Reading

    func entry(for key: Key) -> Entry? {
        lock.withLock {
            loadIndexLocked()
            return entries[key]
        }
    }

    /// Seconds of audio on disk, all books together.
    var totalSeconds: TimeInterval {
        lock.withLock {
            loadIndexLocked()
            return totalSecondsStored
        }
    }

    /// Read the directory now rather than on the first lookup — the engine
    /// calls this off the main thread at start-up so the first `speak`
    /// doesn't pay for the listing.
    func loadIndex() {
        lock.withLock { loadIndexLocked() }
    }

    // MARK: - Writing

    /// Encode and file a sentence's samples. Written to a `.part` beside the
    /// final name and moved into place, so a crash mid-encode leaves nothing
    /// the index would mistake for audio. Evicts the oldest files beyond
    /// capacity, never the one just stored. Safe from any thread.
    @discardableResult
    func store(samples: [Float], sampleRate: Int, for key: Key) throws -> Entry {
        let seconds = samples.isEmpty ? 0 : Double(samples.count) / Double(sampleRate)
        let directory = directory(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(key.textHash)_\(Int((seconds * 1000).rounded())).m4a"
        let final = directory.appendingPathComponent(name)
        let part = directory.appendingPathComponent(".\(name).part")
        try? FileManager.default.removeItem(at: part)
        if samples.isEmpty {
            FileManager.default.createFile(atPath: part.path, contents: Data())
        } else {
            try Self.encode(samples: samples, sampleRate: sampleRate, to: part)
        }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: part, to: final)
        let entry = Entry(key: key, url: final, seconds: seconds, storedAt: Date())
        lock.withLock {
            loadIndexLocked()
            if let old = entries[key] {
                totalSecondsStored -= old.seconds
            }
            entries[key] = entry
            totalSecondsStored += seconds
            evictLocked(toSeconds: Self.capacitySeconds, keeping: key)
        }
        return entry
    }

    /// A deleted book takes its audio with it.
    func removeBook(id: UUID) {
        lock.withLock {
            loadIndexLocked()
            for (key, entry) in entries where key.bookID == id {
                entries[key] = nil
                totalSecondsStored -= entry.seconds
            }
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(id.uuidString, isDirectory: true)
            )
        }
    }

    // MARK: - Index

    private func directory(for key: Key) -> URL {
        root.appendingPathComponent(key.bookID.uuidString, isDirectory: true)
            .appendingPathComponent(key.voice, isDirectory: true)
    }

    /// `<root>/<book id>/<voice>/<hash>_<ms>.m4a`, read back from the path
    /// alone; anything that doesn't parse is ignored (and left alone).
    private func loadIndexLocked() {
        guard !indexLoaded else { return }
        indexLoaded = true
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in files where url.pathExtension == "m4a" {
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "_", maxSplits: 1)
            guard parts.count == 2, let milliseconds = Int(parts[1]) else { continue }
            let voice = url.deletingLastPathComponent().lastPathComponent
            let bookComponent = url.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent
            guard let bookID = UUID(uuidString: bookComponent) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let key = Key(bookID: bookID, voice: voice, textHash: String(parts[0]))
            let entry = Entry(
                key: key, url: url, seconds: Double(milliseconds) / 1000,
                storedAt: values?.contentModificationDate ?? .distantPast
            )
            entries[key] = entry
            totalSecondsStored += entry.seconds
        }
    }

    private func evictLocked(toSeconds capacity: TimeInterval, keeping kept: Key?) {
        guard totalSecondsStored > capacity else { return }
        let oldestFirst = entries.values.sorted { $0.storedAt < $1.storedAt }
        for entry in oldestFirst where totalSecondsStored > capacity && entry.key != kept {
            try? FileManager.default.removeItem(at: entry.url)
            entries[entry.key] = nil
            totalSecondsStored -= entry.seconds
        }
    }

    // MARK: - Encoding

    /// Float samples in, an AAC `.m4a` out. `AVAudioFile` converts on write;
    /// the file is finished when it goes out of scope.
    private static func encode(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false
        ) else { throw CacheError.cannotEncode }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let chunk = 4096
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw CacheError.cannotEncode
            }
            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}
