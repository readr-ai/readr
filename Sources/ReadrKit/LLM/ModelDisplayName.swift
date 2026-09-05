import Foundation

/// A reader-facing name for a model id the catalogue has no name for — a
/// live OpenRouter pick before its catalogue row is on disk, or an id that
/// arrived by hand. Catalogue rows carry their own `displayName`; this is
/// the fallback behind `ProviderInfo.name`, so Settings never shows a wire
/// id as a name. (September 2026 UX review, F11.)
///
/// The shape follows the catalogue's own rows: `anthropic/claude-sonnet-5`
/// reads "Claude Sonnet 5", `gpt-4.1-mini` reads "GPT-4.1 mini",
/// `minimax/minimax-m3:free` reads "Minimax M3 (free)".
public enum ModelDisplayName {

    public static func name(for modelID: String) -> String {
        var id = modelID
        guard !id.isEmpty else { return "" }
        // The vendor namespace is the card's job ("OpenRouter"), not the row's.
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        var suffix = ""
        if let colon = id.firstIndex(of: ":") {
            suffix = " (\(id[id.index(after: colon)...]))"
            id = String(id[..<colon])
        }
        let words = id.split(separator: "-").map(String.init)
        var parts: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if isNumber(word) {
                // Hyphenated version parts join with a dot: `4-5` is 4.5.
                var version = word
                while index + 1 < words.count, isNumber(words[index + 1]) {
                    index += 1
                    version += "." + words[index]
                }
                if let family = parts.last, family == "GPT" {
                    // "GPT-5.6", the way OpenAI writes it.
                    parts[parts.count - 1] = family + "-" + version
                } else {
                    parts.append(version)
                }
            } else {
                parts.append(readable(word))
            }
            index += 1
        }
        return parts.joined(separator: " ") + suffix
    }

    private static func isNumber(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// One word of an id: a known family in its own casing, a trailing
    /// number split off ("llama3" → "Llama 3"), otherwise capitalized.
    private static func readable(_ word: String) -> String {
        if let spelled = spellings[word.lowercased()] { return spelled }
        // "llama3", "qwen2.5": a family name then its version, no hyphen.
        // Short codes stay whole: "m3", "k3", "v4" are the name.
        if let firstDigit = word.firstIndex(where: \.isNumber),
           word.distance(from: word.startIndex, to: firstDigit) >= 3,
           word[firstDigit...].allSatisfy({ $0.isNumber || $0 == "." }) {
            return readable(String(word[..<firstDigit])) + " " + word[firstDigit...]
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// Families whose casing is not "first letter up", and size words the
    /// vendors write in lower case.
    private static let spellings: [String: String] = [
        "gpt": "GPT", "glm": "GLM", "deepseek": "DeepSeek", "xai": "xAI",
        "mini": "mini", "nano": "nano", "lite": "lite",
    ]
}
