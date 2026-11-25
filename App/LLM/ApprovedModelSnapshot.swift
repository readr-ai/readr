import Foundation
import CryptoKit
import ReadrKit

/// A receipt is written only after streaming every approved artifact through
/// SHA-256. Fast Settings checks compare its file stamps; inference rehashes
/// before loading. The Hub never supplies or selects this receipt.
enum ApprovedModelSnapshot {
    struct Artifact: Sendable { let bytes: Int64; let sha256: String }
    struct Manifest: Sendable { let revision: String; let files: [String: Artifact] }
    private struct Stamp: Codable, Equatable { let bytes: Int64; let modified: Date }
    private struct Receipt: Codable { let revision: String; let files: [String: Stamp] }
    private static let receiptName = ".readr-approved.json"

    static func isVerified(_ directory: URL, manifest: Manifest) -> Bool {
        guard directory.lastPathComponent == manifest.revision, !manifest.files.isEmpty,
              DownloadedModelSnapshot.isComplete(directory), hasOnlyApprovedArtifacts(directory, manifest: manifest),
              let data = try? Data(contentsOf: directory.appendingPathComponent(receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.revision == manifest.revision,
              Set(receipt.files.keys) == Set(manifest.files.keys) else { return false }
        return manifest.files.allSatisfy { name, expected in
            guard let current = stamp(directory, name: name) else { return false }
            return current.bytes == expected.bytes && current == receipt.files[name]
        }
    }

    static func verifyInBackground(_ directory: URL, manifest: Manifest) async throws {
        let task = Task.detached(priority: .utility) { try verify(directory, manifest: manifest) }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }

    static func verify(_ directory: URL, manifest: Manifest) throws {
        guard directory.lastPathComponent == manifest.revision, !manifest.files.isEmpty else { throw Failure.invalid }
        var stamps: [String: Stamp] = [:]
        for (name, expected) in manifest.files {
            try Task.checkCancellation()
            guard let before = stamp(directory, name: name), before.bytes == expected.bytes else { throw Failure.invalid }
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.sha256, stamp(directory, name: name) == before else { throw Failure.invalid }
            stamps[name] = before
        }
        guard hasOnlyApprovedArtifacts(directory, manifest: manifest) else { throw Failure.invalid }
        try Task.checkCancellation()
        try JSONEncoder().encode(Receipt(revision: manifest.revision, files: stamps))
            .write(to: directory.appendingPathComponent(receiptName), options: .atomic)
    }

    private static func stamp(_ directory: URL, name: String) -> Stamp? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return nil }
        return Stamp(bytes: bytes.int64Value, modified: modified)
    }
    private static func hasOnlyApprovedArtifacts(_ directory: URL, manifest: Manifest) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        let loadable = Set(["json", "safetensors", "jinja", "txt", "model", "tiktoken"])
        return names.allSatisfy { $0 == receiptName || !loadable.contains(URL(fileURLWithPath: $0).pathExtension) || manifest.files[$0] != nil }
    }
    enum Failure: Error { case invalid }
}
