import Foundation

/// Validates local model artifacts without consulting a Hub/network client.
public enum DownloadedModelSnapshot {
    public static func isComplete(_ directory: URL) -> Bool {
        let manager = FileManager.default
        func hasBytes(_ name: String) -> Bool {
            guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return false }
            let url = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path),
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            return ((try? handle.seekToEnd()) ?? 0) > 0
        }
        guard ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy(hasBytes) else { return false }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if manager.fileExists(atPath: index.path) {
            struct Index: Decodable { var weight_map: [String: String] }
            guard let data = try? Data(contentsOf: index),
                  let parsed = try? JSONDecoder().decode(Index.self, from: data), !parsed.weight_map.isEmpty else { return false }
            return Set(parsed.weight_map.values).allSatisfy { $0.hasSuffix(".safetensors") && hasBytes($0) }
        }
        return hasBytes("model.safetensors")
    }
}
