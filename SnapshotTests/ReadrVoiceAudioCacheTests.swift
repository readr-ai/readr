import XCTest
@testable import Readr

final class ReadrVoiceAudioCacheTests: XCTestCase {
    func testCapacityEvictsBehindPlaybackBeforeProtectedLookahead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReadrVoiceAudioCache(root: root, capacity: 2)
        let bookID = UUID()
        let behind = key("behind", bookID: bookID)
        let next = key("next", bookID: bookID)
        let later = key("later", bookID: bookID)
        try seed(behind, milliseconds: 1_000, storedAt: Date(timeIntervalSince1970: 1), root: root)
        try seed(next, milliseconds: 1_000, storedAt: Date(timeIntervalSince1970: 2), root: root)
        try seed(later, milliseconds: 1_000, storedAt: Date(timeIntervalSince1970: 3), root: root)
        cache.loadIndex()
        cache.trimToCapacity(protecting: [next, later])

        XCTAssertNil(cache.entry(for: behind))
        XCTAssertNotNil(cache.entry(for: next))
        XCTAssertNotNil(cache.entry(for: later))
        XCTAssertEqual(cache.totalSeconds, 2, accuracy: 0.001)
    }

    func testConcurrentStoreThenRemoveCannotResurrectDeletedBook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reachedCommit = DispatchSemaphore(value: 0)
        let allowCommit = DispatchSemaphore(value: 0)
        let cache = ReadrVoiceAudioCache(root: root) {
            reachedCommit.signal()
            allowCommit.wait()
        }
        let bookID = UUID()
        let key = ReadrVoiceAudioCache.Key(
            bookID: bookID,
            voice: "af_heart",
            textHash: "sentence"
        )

        let write = Task.detached {
            try cache.store(samples: [], sampleRate: 24_000, for: key)
        }
        XCTAssertEqual(reachedCommit.wait(timeout: .now() + 2), .success)
        cache.removeBook(id: bookID)
        allowCommit.signal()

        do {
            _ = try await write.value
            XCTFail("The write that began before deletion must be rejected")
        } catch ReadrVoiceAudioCache.CacheError.bookWasRemoved {
            // Expected.
        }
        XCTAssertNil(cache.entry(for: key))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        XCTAssertNil(files?.nextObject(), "No final or temporary audio file survives")
    }

    private func key(_ hash: String, bookID: UUID) -> ReadrVoiceAudioCache.Key {
        ReadrVoiceAudioCache.Key(bookID: bookID, voice: "af_heart", textHash: hash)
    }

    private func seed(
        _ key: ReadrVoiceAudioCache.Key,
        milliseconds: Int,
        storedAt: Date,
        root: URL
    ) throws {
        let directory = root.appendingPathComponent(key.bookID.uuidString, isDirectory: true)
            .appendingPathComponent(key.voice, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(key.textHash)_\(milliseconds).m4a")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: storedAt], ofItemAtPath: url.path)
    }
}
