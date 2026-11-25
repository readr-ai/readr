import XCTest
import CryptoKit
@testable import Readr

final class ApprovedModelSnapshotTests: XCTestCase {
    private func fixture() throws -> (URL, ApprovedModelSnapshot.Manifest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("approved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("x".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let names = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        for name in names { try data.write(to: root.appendingPathComponent(name)) }
        return (root, .init(revision: "approved", files: Dictionary(uniqueKeysWithValues: names.map { ($0, .init(bytes: 1, sha256: digest)) })))
    }
    func testNonemptyArtifactsAreNotReadyWithoutHashVerification() throws {
        let (root, manifest) = try fixture(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertFalse(ApprovedModelSnapshot.isVerified(root, manifest: manifest))
        try ApprovedModelSnapshot.verify(root, manifest: manifest)
        XCTAssertTrue(ApprovedModelSnapshot.isVerified(root, manifest: manifest))
        try Data("y".utf8).write(to: root.appendingPathComponent("config.json"))
        XCTAssertFalse(ApprovedModelSnapshot.isVerified(root, manifest: manifest))
        XCTAssertThrowsError(try ApprovedModelSnapshot.verify(root, manifest: manifest))
    }
    func testUnapprovedRevisionsAndExtraLoadableFilesAreRejected() throws {
        let (root, manifest) = try fixture(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let other = ApprovedModelSnapshot.Manifest(revision: "mutable-main", files: manifest.files)
        XCTAssertFalse(ApprovedModelSnapshot.isVerified(root, manifest: other))
        XCTAssertThrowsError(try ApprovedModelSnapshot.verify(root, manifest: other))
        try Data("x".utf8).write(to: root.appendingPathComponent("generation_config.json"))
        XCTAssertFalse(ApprovedModelSnapshot.isVerified(root, manifest: manifest))
        XCTAssertThrowsError(try ApprovedModelSnapshot.verify(root, manifest: manifest))
    }
}
