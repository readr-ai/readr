import Foundation
import ReadrKit

#if os(macOS)
import AppKit

/// The knowledge base: what "Save to knowledge base" writes, and what the
/// reader's Knowledge tab lists back.
///
/// Plain Markdown in a folder of the reader's own (`~/Documents/Readr
/// Knowledge`) rather than rows in Readr's database, deliberately. A saved
/// answer is worth more than the app that produced it: this way it opens in
/// Obsidian, Bear or TextEdit, it can be searched with `grep`, synced, backed
/// up and read after Readr is gone — and the reader can see and move their own
/// files, which a database cannot offer.
///
/// One answer is one file, filed under the book it came from:
///
///     Books/<book title>/notes/<date>-<title>.md
///
/// with layered YAML front matter (the book, the passage, the model), a
/// structured body, and `[[wiki links]]` between notes — the shape the
/// reader's previous reading app used, so the folders stay interchangeable.
/// Front matter is written to survive a round trip through Obsidian: quoted
/// scalars, one nested level, inline arrays.
///
/// Writes are the only thing that can fail (disk full, folder permissions);
/// reads are forgiving by design — a file the reader edited by hand, or moved
/// into the folder themselves, is listed rather than rejected, and a file
/// whose front matter is missing falls back to its filename and its own text.
struct KnowledgeBaseStore {

    /// One saved answer, as the Knowledge tab shows it.
    struct Entry: Identifiable, Hashable {
        /// The file path is the identity: it is what the reader sees in the
        /// Finder, and what a reveal or a delete has to act on.
        var id: String { path }
        let path: String
        /// The note's name — the model's title when it gave one, else the
        /// question, else the filename.
        let title: String
        /// What the reader asked.
        let question: String
        let book: String
        let chapter: String?
        let tags: [String]
        /// `[[…]]` targets this note points at, in the order they appear.
        let links: [String]
        let savedAt: Date?
        let model: String?
        /// Body with the front matter stripped — what the reader reads.
        let body: String

        var url: URL { URL(fileURLWithPath: path) }
        /// The book's own name when the front matter has one; otherwise the
        /// folder it was found under.
        var displayBook: String { book.isEmpty ? (url.deletingLastPathComponent().lastPathComponent) : book }
    }

    /// The whole folder as the tab needs it: the notes, plus who links to
    /// whom. Built by scanning the files every time, because the folder is the
    /// source of truth and the reader may have edited it behind Readr's back —
    /// a cache would be stale exactly when it mattered.
    struct Index {
        var notes: [Entry] = []
        /// Note path → the `[[…]]` targets it mentions.
        var outgoing: [String: [String]] = [:]
        /// Link term (normalized) → the paths of the notes mentioning it.
        var references: [String: [String]] = [:]

        /// Notes that mention `term` — what tapping a `[[link]]` shows. This is
        /// the backlink side of the pair: a note does not have to *exist* under
        /// that name for its mentions to be findable.
        func notes(referencing term: String) -> [Entry] {
            (references[Index.key(term)] ?? [])
                .compactMap { path in notes.first { $0.path == path } }
        }

        /// The terms this note points at, and the notes pointing back at it —
        /// matched by title, which is how a reader thinks of a note.
        func mentioned(by entry: Entry) -> [Entry] {
            notes(referencing: entry.title).filter { $0.path != entry.path }
        }

        /// Record that `path` mentions `term`, once — the link graph is what
        /// the tab counts, so a note must not be listed twice for repeating
        /// itself in its own text.
        mutating func addReference(to term: String, path: String) {
            let key = Index.key(term)
            guard !key.isEmpty else { return }
            guard references[key]?.contains(path) != true else { return }
            references[key, default: []].append(path)
        }

        static func key(_ term: String) -> String {
            term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
    /// Where the knowledge base lives unless the app is told otherwise.
    /// `Documents` on purpose — see the note above about the reader owning it.
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Readr Knowledge", isDirectory: true)
    }

    /// Announce a write, a rename or a delete, so an open Knowledge tab can
    /// re-read the folder without the store holding a reference to the view.
    static let changedNotification = Notification.Name("readr.knowledgeBaseChanged")

    let root: URL

    init(root: URL = KnowledgeBaseStore.defaultRoot) {
        self.root = root
    }

    /// The folder itself, for the tab's empty state (so "saved nothing yet"
    /// still says where things will land).
    var folderPath: String { root.path }

    // MARK: - Writing

    /// Write one answer, immediately: the file exists before this returns, so a
    /// failed naming call downstream can never lose the note.
    @discardableResult
    func save(
        question: String,
        answer: String,
        quote: String?,
        bookTitle: String,
        author: String?,
        chapter: String?,
        model: String?,
        now: Date = Date()
    ) throws -> Entry {
        let notes = try notesFolder(forBook: bookTitle)
        let day = Self.dayFormatter.string(from: now)
        let stem = "\(day)-\(Self.sanitize(question))"
        var url = notes.appendingPathComponent("\(stem).md")
        // Two questions on one day must not silently overwrite each other.
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = notes.appendingPathComponent("\(stem)-\(suffix).md")
            suffix += 1
        }

        try Self.write(
            to: url, title: question, question: question, answer: answer, quote: quote,
            bookTitle: bookTitle, author: author, chapter: chapter, model: model,
            tags: [], links: [bookTitle], createdAt: now, updatedAt: now
        )
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        return Self.entry(at: url, bookFolderName: url.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent)
    }

    /// Rewrite a note with the names the model gave it — title, tags, the
    /// concepts it is about — and move it to a filename carrying that title.
    ///
    /// Called after `save` returns, so the reader never waits for a second
    /// model call to have their note on disk. A failure here leaves the note
    /// exactly as `save` wrote it: named after the question, which is a
    /// perfectly good name.
    @discardableResult
    func applyMetadata(
        title: String?, tags: [String], links: [String], to path: String
    ) throws -> Entry {
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fields = Self.frontMatter(of: text).scalars
        let question = fields["ai.question"] ?? fields["question"]
            ?? url.deletingPathExtension().lastPathComponent
        let body = Self.body(of: text)
        let answer = Self.answerSection(of: body) ?? body

        let cleanTitle = Self.cleanTitle(title)
        let finalTitle = cleanTitle ?? question
        let finalLinks = Self.mergedLinks(existing: Self.links(in: body), with: links, book: fields["book.title"])

        // Rename to carry the new title, keeping the date prefix and staying in
        // the same folder. A collision (the same title saved twice) takes the
        // next free suffix rather than overwriting the other note.
        var destination = url
        let day = Self.dayFormatter.string(from: Self.parseDate(fields["created"]) ?? Date())
        let stem = "\(day)-\(Self.sanitize(finalTitle))"
        destination = url.deletingLastPathComponent().appendingPathComponent("\(stem).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path), destination.path != url.path {
            destination = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(suffix).md")
            suffix += 1
        }

        try Self.write(
            to: destination,
            title: finalTitle,
            question: question,
            answer: answer,
            quote: Self.quoteSection(of: body),
            bookTitle: fields["book.title"] ?? "",
            author: fields["book.author"],
            chapter: fields["book.chapter"],
            model: fields["ai.model"],
            tags: tags,
            links: finalLinks,
            createdAt: Self.parseDate(fields["created"]) ?? Date(),
            updatedAt: Date()
        )
        if destination.path != url.path {
            try? FileManager.default.removeItem(at: url)
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        return Self.entry(at: destination, bookFolderName: destination.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent)
    }

    /// The file's text: layered YAML front matter, then the passage it was
    /// asked about, the question, the answer, an empty place for the reader's
    /// own annotation, and the links out. Front matter first so a tool that
    /// only understands Markdown still shows the answer.
    static func file(
        title: String, question: String, answer: String, quote: String?,
        bookTitle: String, author: String?, chapter: String?,
        model: String?, tags: [String], links: [String],
        createdAt: Date, updatedAt: Date
    ) -> String {
        var front: [String] = ["---"]
        front.append("title: \(yaml(title))")
        front.append("aliases: []")
        front.append("type: qa")
        front.append("created: \(isoFormatter.string(from: createdAt))")
        front.append("updated: \(isoFormatter.string(from: updatedAt))")
        front.append("status: seedling")
        front.append("")
        front.append("book:")
        front.append("  title: \(yaml(bookTitle))")
        front.append("  author: \(yaml(author ?? ""))")
        front.append("  chapter: \(yaml(chapter ?? ""))")
        front.append("")
        front.append("source:")
        front.append("  quote: \(yaml(quote ?? ""))")
        front.append("")
        front.append("ai:")
        front.append("  model: \(yaml(model ?? ""))")
        front.append("  question: \(yaml(question))")
        front.append("  answered_at: \(isoFormatter.string(from: createdAt))")
        front.append("")
        front.append("tags: [\(tags.map(yamlListValue).joined(separator: ", "))]")
        front.append("links: [\(links.map { yaml("[[\($0)]]") }.joined(separator: ", "))]")
        front.append("---")
        front.append("")

        var body: [String] = []
        if let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append("## 原文")
            body.append("")
            for line in quote.split(separator: "\n", omittingEmptySubsequences: false) {
                body.append("> \(line)")
            }
            body.append("")
        }
        body.append("## 问题")
        body.append("")
        body.append(question)
        body.append("")
        body.append("## AI 回答")
        body.append("")
        body.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        body.append("")
        body.append("## 我的批注")
        body.append("")
        body.append("")
        body.append("## 相关")
        body.append("")
        for link in links {
            body.append("- [[\(link)]]")
        }
        body.append("")

        return front.joined(separator: "\n") + body.joined(separator: "\n")
    }

    private static func write(
        to url: URL, title: String, question: String, answer: String, quote: String?,
        bookTitle: String, author: String?, chapter: String?, model: String?,
        tags: [String], links: [String], createdAt: Date, updatedAt: Date
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let text = file(
            title: title, question: question, answer: answer, quote: quote,
            bookTitle: bookTitle, author: author, chapter: chapter, model: model,
            tags: tags, links: links, createdAt: createdAt, updatedAt: updatedAt
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func notesFolder(forBook bookTitle: String) throws -> URL {
        let notes = root
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(Self.sanitize(bookTitle.isEmpty ? "Untitled book" : bookTitle),
                                    isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        return notes
    }

    // MARK: - Reading

    /// Every saved answer, newest first, plus the link graph between them.
    func index() -> Index {
        var result = Index()
        let fileManager = FileManager.default
        let booksFolder = root.appendingPathComponent("Books", isDirectory: true)
        guard let bookFolders = try? fileManager.contentsOfDirectory(
            at: booksFolder, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return result }

        for bookFolder in bookFolders {
            let notes = bookFolder.appendingPathComponent("notes", isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(
                at: notes, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension.lowercased() == "md" {
                result.notes.append(Self.entry(at: file, bookFolderName: bookFolder.lastPathComponent))
            }
        }

        // Newest first, and — for a set saved in the same second, or from an
        // unparseable front matter — by name, so the list never reorders
        // unpredictably between two reads of the same folder.
        result.notes.sort {
            switch ($0.savedAt, $1.savedAt) {
            case let (a?, b?) where a != b: return a > b
            default: return $0.path > $1.path
            }
        }

        for note in result.notes {
            let mentions = Self.links(in: note.body)
            result.outgoing[note.path] = mentions
            // A note is recorded once per term, however many times it mentions
            // it — the indexes are about which notes share a subject, and a
            // note listed twice would make the count a lie.
            for term in mentions {
                result.addReference(to: term, path: note.path)
            }
            // A note answers to its own title as a link target too, so
            // `[[The Whale]]` finds the notes filed under it.
            result.addReference(to: note.title, path: note.path)
        }
        return result
    }

    /// Just the notes — for callers that do not need the link graph.
    func entries() -> [Entry] { index().notes }

    func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.url)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Show the file in the Finder — the one thing a folder-of-files store can
    /// offer that a database cannot, and the escape hatch when the reader
    /// wants to move a note somewhere else.
    static func reveal(_ entry: Entry) {
        reveal(path: entry.path)
    }

    /// Same, for a caller that holds the path (the row under an answer, which
    /// knows where it saved but not the whole entry).
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// One file, as an `Entry` — shared by `save`, `applyMetadata` and the
    /// folder scan, so a note reads the same however it was found.
    static func entry(at url: URL, bookFolderName: String) -> Entry {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let front = frontMatter(of: text)
        let body = body(of: text)
        let question = front.scalars["ai.question"] ?? front.scalars["question"] ?? ""
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let booksLinks = links(in: body)
        return Entry(
            path: url.path,
            title: front.scalars["title"]?.isEmpty == false
                ? (front.scalars["title"] ?? fallbackTitle)
                : (question.isEmpty ? fallbackTitle : question),
            question: question.isEmpty ? fallbackTitle : question,
            book: front.scalars["book.title"] ?? bookFolderName,
            chapter: front.scalars["book.chapter"].flatMap { $0.isEmpty ? nil : $0 },
            tags: front.arrays["tags"] ?? [],
            links: booksLinks,
            savedAt: parseDate(front.scalars["created"])
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate),
            model: front.scalars["ai.model"].flatMap { $0.isEmpty ? nil : $0 },
            body: body
        )
    }

    // MARK: - Front matter

    /// The front matter, split the way it is written: scalars (with nested
    /// keys dotted, `book.title`) and inline arrays (`tags:`). Enough YAML for
    /// what Readr writes and for what Obsidian hands back; not a YAML parser.
    struct FrontMatter {
        var scalars: [String: String] = [:]
        var arrays: [String: [String]] = [:]
    }

    static func frontMatter(of text: String) -> FrontMatter {
        var result = FrontMatter()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        lines = Array(lines.dropFirst())

        var currentMap: String?
        for line in lines {
            let raw = String(line)
            if raw.trimmingCharacters(in: .whitespaces) == "---" { break }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let isNested = raw.hasPrefix(" ") || raw.hasPrefix("\t")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if rawValue.isEmpty {
                // `book:` — the keys under it belong to this map.
                currentMap = key
                continue
            }
            if isNested, let map = currentMap, !map.isEmpty {
                result.scalars["\(map).\(key)"] = unquote(rawValue)
            } else if rawValue.hasPrefix("[") {
                result.arrays[key] = arrayValues(rawValue)
                currentMap = nil
            } else {
                result.scalars[key] = unquote(rawValue)
                currentMap = nil
            }
        }
        return result
    }

    /// An inline flow sequence: `["[[A]]", "B"]`, `[]`, `[a, b]`. Handles
    /// quoted members with commas inside, and strips the `[[…]]` a links list
    /// is written with so callers see bare terms.
    static func arrayValues(_ raw: String) -> [String] {
        var inner = raw
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }

        var items: [String] = []
        var current = ""
        var inQuotes = false
        for character in inner {
            switch character {
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "," where !inQuotes:
                items.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        items.append(current)

        return items
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .map(stripWikiBrackets)
            .filter { !$0.isEmpty }
    }

    /// The text after the closing `---` of the front matter.
    static func body(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The first `---` after the opening fence ends the front matter;
        // everything after it is the reader's text.
        for (index, line) in lines.enumerated().dropFirst()
        where line.trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(index + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No closing fence: the file is malformed, so show it as it is rather
        // than pretending most of it does not exist.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wiki links

    /// Every `[[target]]` in a chunk of Markdown, in order of appearance, with
    /// an optional `|display` alias dropped. This is the link graph's only
    /// source: what the reader sees in the file is what is indexed.
    static func links(in text: String) -> [String] {
        guard let regex = wikiLinkRegex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let targetRange = Range(match.range(at: 1), in: text) else { continue }
            let term = stripWikiBrackets(String(text[targetRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, !found.contains(term) { found.append(term) }
        }
        return found
    }

    private static let wikiLinkRegex = try? NSRegularExpression(
        pattern: "\\[\\[([^\\[\\]|]+)(?:\\|[^\\[\\]]*)?\\]\\]"
    )

    private static func stripWikiBrackets(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[[") { value.removeFirst(2) }
        if value.hasSuffix("]]") { value.removeLast(2) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// The note's outgoing links: what it already had, plus what the model
    /// named, plus the book it came from — never duplicated, book last.
    static func mergedLinks(existing: [String], with new: [String], book: String?) -> [String] {
        var merged: [String] = []
        for term in existing + new {
            let clean = stripWikiBrackets(term).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            guard !merged.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { continue }
            merged.append(clean)
        }
        if let book, !book.isEmpty,
           !merged.contains(where: { $0.caseInsensitiveCompare(book) == .orderedSame }) {
            merged.append(book)
        }
        return merged
    }

    // MARK: - Body sections

    /// The text under `## <heading>`, up to the next `##`. Used to put a note
    /// back together after the model renamed it: the title is re-written, the
    /// reader's own prose must survive.
    static func section(_ heading: String, in body: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var collected: [Substring] = []
        var inside = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if inside { break }
                inside = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading
                continue
            }
            if inside { collected.append(line) }
        }
        guard inside || !collected.isEmpty else { return nil }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func answerSection(of body: String) -> String? { section("AI 回答", in: body) }
    static func quoteSection(of body: String) -> String? {
        guard let quoted = section("原文", in: body) else { return nil }
        return quoted
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
    }

    // MARK: - Odds and ends

    /// A title the model gave, made safe for a filename and a YAML scalar:
    /// no brackets, no quotes, no trailing punctuation, no runaway length.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        title = stripWikiBrackets(title)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’。，,.:;!?！？、-— "))
        if title.hasPrefix("Title:") {
            title = String(title.dropFirst("Title:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard title.count >= 2 else { return nil }
        return String(title.prefix(60))
    }

    /// A filename the filesystem and every editor can take: no path
    /// separators, no control characters, short enough to read in a listing.
    static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Untitled" }
        return String(trimmed.prefix(60))
    }

    private static func yaml(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// Inside a flow sequence a bare word is fine, but anything with a comma,
    /// a bracket or a quote needs wrapping to survive a YAML reader.
    private static func yamlListValue(_ value: String) -> String {
        let needsQuotes = value.contains(where: { ",[]\"".contains($0) })
        return needsQuotes ? yaml(value) : value
    }

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
#endif
