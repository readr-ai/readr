import Foundation

/// App-approved upstream commits and SHA-256 values. Updates require code review.
/// Sources: huggingface.co/mlx-community/Qwen3.5-{2B,4B}-4bit at these commits.
enum ApprovedQwenManifests {
    static func manifest(for repository: String) -> ApprovedModelSnapshot.Manifest? {
        switch repository {
        case "mlx-community/Qwen3.5-2B-4bit":
            return .init(revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207", files: [
                "chat_template.jinja": .init(bytes: 7755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
                "config.json": .init(bytes: 3113, sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
                "model.safetensors": .init(bytes: 1722271785, sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
                "model.safetensors.index.json": .init(bytes: 81722, sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
                "preprocessor_config.json": .init(bytes: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
                "processor_config.json": .init(bytes: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
                "tokenizer.json": .init(bytes: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                "tokenizer_config.json": .init(bytes: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
                "video_preprocessor_config.json": .init(bytes: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
                "vocab.json": .init(bytes: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
            ])
        case "mlx-community/Qwen3.5-4B-4bit":
            return .init(revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c", files: [
                "chat_template.jinja": .init(bytes: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                "config.json": .init(bytes: 3366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                "model.safetensors": .init(bytes: 3034300695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                "model.safetensors.index.json": .init(bytes: 101944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
                "preprocessor_config.json": .init(bytes: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
                "processor_config.json": .init(bytes: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
                "tokenizer.json": .init(bytes: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                "tokenizer_config.json": .init(bytes: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
                "video_preprocessor_config.json": .init(bytes: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
                "vocab.json": .init(bytes: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
            ])
        default: return nil
        }
    }
}
