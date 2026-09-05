import Foundation

/// A reader-facing name for a model id the catalogue has no name for — a
/// live OpenRouter pick whose list has not been registered yet, or an id
/// that arrived by hand. Catalogue rows carry their own `displayName`, and a
/// live OpenRouter list registers its names as it loads; this is the
/// fallback behind `ProviderInfo.name`, so Settings never shows a wire id as
/// a name. (September 2026 UX review, F11.)
///
/// The shape follows the catalogue's own rows, without a vendor table of its
/// own (vendor spellings live in the catalogue): `anthropic/claude-sonnet-5`
/// reads "Claude Sonnet 5", `gpt-4o-mini` reads "GPT-4o mini",
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
        var parts: [String] = []
        var versionsSeen = 0
        var previousWasVersion = false
        for word in id.split(separator: "-").map(String.init) {
            let isVersion = isNumber(word)
            if word.first?.isNumber == true, parts.last == "GPT" {
                // "GPT-5.6", "GPT-4o": the way OpenAI writes them.
                parts[parts.count - 1] = "GPT-" + word
            } else if isVersion, previousWasVersion, versionsSeen == 1,
                      word.count <= 2, !word.contains("."), parts.last?.contains(".") == false {
                // The first hyphenated version joins with a dot: `4-5` is
                // 4.5. Later runs of digits are dates and sizes, left alone.
                parts[parts.count - 1] += "." + word
            } else {
                parts.append(isVersion ? word : cased(word))
            }
            if isVersion { versionsSeen += 1 }
            previousWasVersion = isVersion
        }
        return parts.joined(separator: " ") + suffix
    }

    private static func isNumber(_ word: Substring) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func isNumber(_ word: String) -> Bool { isNumber(word[...]) }

    /// One word of an id: a family in its own casing, a size word the
    /// vendors write in lower case, a name with its version run together
    /// ("llama3" → "Llama 3" — a short code like "m3" stays whole),
    /// otherwise capitalized.
    private static func cased(_ word: String) -> String {
        if let spelled = spellings[word.lowercased()] { return spelled }
        if let firstDigit = word.firstIndex(where: \.isNumber),
           word.distance(from: word.startIndex, to: firstDigit) >= 3,
           isNumber(word[firstDigit...]) {
            return cased(String(word[..<firstDigit])) + " " + word[firstDigit...]
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The one family whose casing is not "first letter up", and the size
    /// words the vendors write in lower case.
    private static let spellings: [String: String] = [
        "gpt": "GPT", "mini": "mini", "nano": "nano", "lite": "lite",
    ]
}
