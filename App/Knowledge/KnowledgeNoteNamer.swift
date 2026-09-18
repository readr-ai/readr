import Foundation
import ReadrKit

#if os(macOS)

/// Names a saved note: a short title, a few tags, and the concepts it links to.
///
/// Asked **after** the note is already on disk (see
/// `KnowledgeBaseStore.applyMetadata`), so the reader never waits for a second
/// model call to have their note, and a naming that fails — no provider,
/// offline, a reply that is not JSON — leaves the initial date plus answer
/// excerpt intact.
///
/// One call for all three, because they are one judgement: what is this note
/// about? JSON rather than three prose answers so the reply can be used
/// verbatim, and forgivingly parsed (first `{` to last `}`) so a chatty model
/// that prefaces its JSON still works.
enum KnowledgeNoteNamer {

    struct Metadata: Equatable {
        var title: String?
        var tags: [String]
        var links: [String]
    }

    /// Ask `provider` to name the note. Returns nil when it could not be
    /// reached or said nothing usable.
    static func metadata(
        question: String, answer: String, book: String, provider: LLMProvider
    ) async -> Metadata? {
        let request = ChatRequest(
            messages: [
                ChatMessage(role: .system, content: systemPrompt),
                ChatMessage(role: .user, content: userPrompt(question: question, answer: answer, book: book)),
            ],
            // A title, four tags and three links — small, and bounded so a
            // model that decides to write an essay is cut off early.
            maxOutputTokens: 220
        )

        var reply = ""
        do {
            for try await chunk in provider.stream(request) { reply += chunk.textDelta }
        } catch {
            return nil
        }
        return parse(reply)
    }

    /// The reply as metadata, or nil when there is nothing usable in it.
    static func parse(_ reply: String) -> Metadata? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let title = KnowledgeBaseStore.cleanTitle(object["title"] as? String)
        let tags = clean(object["tags"], limit: 4, longest: 24)
        let links = clean(object["links"], limit: 3, longest: 40)
        guard title != nil || !tags.isEmpty || !links.isEmpty else { return nil }
        return Metadata(title: title, tags: tags, links: links)
    }

    private static func clean(_ value: Any?, limit: Int, longest: Int) -> [String] {
        let raw = (value as? [Any])?.compactMap { $0 as? String } ?? []
        var seen: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= longest else { continue }
            guard !seen.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            seen.append(trimmed)
            if seen.count == limit { break }
        }
        return seen
    }

    private static let systemPrompt = """
    You file a reader's saved notes from their reading app.

    Reply with JSON only. No prose, no explanation, no code fence:
    {"title": "...", "tags": ["..."], "links": ["..."]}

    title: 2 to 6 words naming this note, in the same language as the question. \
    No quotes, no trailing period, not a full sentence.
    tags: 2 to 4 short topical tags, in the same language as the question.
    links: 0 to 3 names of the concepts, people, works or places the answer is \
    actually about — bare names, no brackets.
    """

    private static func userPrompt(question: String, answer: String, book: String) -> String {
        """
        Book: \(book)
        Question: \(question)

        Answer:
        \(String(answer.prefix(2_400)))
        """
    }
}
#endif
