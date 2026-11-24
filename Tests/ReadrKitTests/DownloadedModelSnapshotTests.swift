import XCTest
@testable import ReadrKit
final class DownloadedModelSnapshotTests: XCTestCase {
    func testShardedSnapshotRequiresEveryReferencedShard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model-00001.safetensors"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        try Data(#"{"weight_map":{"a":"model-00001.safetensors","b":"model-00002.safetensors"}}"#.utf8).write(to: root.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertFalse(DownloadedModelSnapshot.isComplete(root))
        try Data("second shard".utf8).write(to: root.appendingPathComponent("model-00002.safetensors"))
        XCTAssertTrue(DownloadedModelSnapshot.isComplete(root))
        try Data().write(to: root.appendingPathComponent("model-00002.safetensors"))
        XCTAssertFalse(DownloadedModelSnapshot.isComplete(root))
    }
    func testInvalidIndexCannotEscapeSnapshotOrMasqueradeAsComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        XCTAssertTrue(DownloadedModelSnapshot.isComplete(root))
        for index in [#"{"weight_map":{"a":"../secret.safetensors"}}"#, "broken", #"{"weight_map":{}}"#] {
            try Data(index.utf8).write(to: root.appendingPathComponent("model.safetensors.index.json"))
            XCTAssertFalse(DownloadedModelSnapshot.isComplete(root))
        }
    }
}
