import Foundation
import ReadrKit
import CoreGraphics
import CoreText

/// App-level state for M1: the library, import, reading position, and
/// highlights. AI features (ask, article) attach to this in later milestones.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var highlightsByBook: [UUID: [Highlight]] = [:]
    @Published private(set) var pdfHighlightsByBook: [UUID: [PDFHighlight]] = [:]
    @Published private(set) var bookmarksByBook: [UUID: [Bookmark]] = [:]
    @Published private(set) var statesByBook: [UUID: BookState] = [:]
    /// Saved reading positions, published so a Home card's "Chapter 7 of
    /// 24" is current the moment the reader saves — the store alone is not
    /// observable, and a card computed before the save would stay stale
    /// until something else happened to re-render it.
    @Published private(set) var positionsByBook: [UUID: ReadingPosition] = [:]
    @Published var importError: String?
    /// Informational notice from the last import (e.g. a fixed-layout book
    /// that will be shown as extracted text). Same alert-binding pattern as
    /// `importError`, but the import itself succeeded.
    @Published var importNotice: String?
    /// A book the library asked to open straight into a recap (the Continue
    /// Reading card's Recap action). The reader for that book consumes it on
    /// appearance — or on change, when its window is already open — and
    /// presents Ask with the recap already sent. Nil the rest of the time.
    @Published var pendingRecapBookID: UUID?

    private let store: any LibraryStore
    private let parsers: BookParserRegistry
    private let highlightService = HighlightService()
    /// Chapter lengths per book, measured once (`ReadingLengthTable`). Read
    /// from body by Home's cards and the reader's footer, and by the context
    /// router off the main actor — hence a lock-guarded cache, not a
    /// `@Published` dictionary.
    private let lengthCache = ReadingLengthCache()

    /// Credential storage + the active-LLM selector (used by Settings and, from
    /// M3, by "ask the book").
    let credentialStore: any CredentialStore
    let providerManager: ProviderManager

    /// - Parameter seedsSampleBook: whether a never-used library gets the
    ///   bundled sample on this launch. The app entry point decides from the
    ///   launch arguments; tests and previews pass `false`.
    init(
        store: (any LibraryStore)? = nil,
        parsers: BookParserRegistry? = nil,
        seedsSampleBook: Bool
    ) {
        // Diagnostics-to-file, in ALL builds (not gated on any UI-test
        // launch argument): `DiagnosticsLog` is in-memory only by design —
        // see its doc comment — and on a device the in-app bug report is the
        // only way to read it. This sink appends every event to
        // Library/Caches/Diagnostics/readr.log, where `xcrun devicectl` can
        // pull it off between sessions or after a crash — the exact commands
        // are in docs/DEVICE-SMOKE-TEST.md. Installed first, so nothing
        // recorded during the rest of this initializer (sample-book seeding,
        // state restore) is missed.
        Self.installDiagnosticsFileSink()
        DiagnosticsLog.shared.record(.info, .app, "launched Readr \(Self.appVersionAndBuild)")

        // `-uiTestEmptyLibrary`: a throwaway EMPTY store, so the empty-library
        // guidance can be asserted without inheriting whatever books happen to
        // sit in this device's on-disk library. Without it the test read the
        // real store and passed only on a never-used simulator — green on CI
        // (fresh runners), failing for anyone who had imported a book locally,
        // and silently able to mask a regression in the guidance itself.
        // Checked before `-uiTestSeed`: the two describe opposite worlds.
        if store == nil, ProcessInfo.processInfo.arguments.contains("-uiTestEmptyLibrary") {
            self.store = InMemoryLibraryStore()
        } else if store == nil, ProcessInfo.processInfo.arguments.contains("-uiTestSeed") {
            let seeded = InMemoryLibraryStore()
            for book in Self.sampleBooks { try? seeded.add(book) }
            Self.seedFixtureState(into: seeded)
            Self.seedFixturePDF(into: seeded)
            self.store = seeded
        } else {
            self.store = store ?? Self.makeDefaultStore()
        }
        self.parsers = parsers ?? Self.makeDefaultRegistry()
        self.books = self.store.allBooks()

        let credentials = Self.makeCredentialStore()
        self.credentialStore = credentials
        self.providerManager = ProviderManager(
            store: credentials,
            factory: DefaultProviderFactory.factory(),
            persistingIn: .standard,
            tokenRefresher: { kind, stored in
                // Only kinds with an OAuth config can renew; anything else
                // reaching here holds unrefreshable tokens → re-auth.
                guard let config = OAuthProviderConfig.config(for: kind) else {
                    throw AuthError.refreshFailed
                }
                return try await OAuthClient(config: config).refresh(stored)
            }
        )

        // All stored properties are initialized above — only now may init
        // touch self freely (Swift definite-initialization rule). Cache only
        // the states that exist: getters fall through to the store for the
        // rest, and must never write the cache themselves (see bookState).
        // `self.store` explicitly: the bare name is the optional `store`
        // parameter, which shadows the stored property inside init.
        for book in books {
            if let state = self.store.bookState(for: book.id) {
                statesByBook[book.id] = state
            }
            if let position = self.store.position(for: book.id) {
                positionsByBook[book.id] = position
            }
        }

        // `-uiTestOpenURL <path>`: deterministic stand-in for the Files-app /
        // Finder open-in flow. XCUITest can't drive the system Files UI, so a
        // UI test passes a fixture path and we import it through the exact same
        // `importBook` path `.onOpenURL` uses. Xcode maps `-key value` launch
        // arguments into `UserDefaults.standard`, so the path reads back via
        // the defaults key. Requires `-uiTestSeed` too, so the import lands in
        // the throwaway in-memory store — never the real on-disk library
        // (which would leak the imported book + its copied source across runs).
        if ProcessInfo.processInfo.arguments.contains("-uiTestOpenURL"),
           ProcessInfo.processInfo.arguments.contains("-uiTestSeed"),
           let path = UserDefaults.standard.string(forKey: "uiTestOpenURL") {
            let url = URL(fileURLWithPath: path)
            Task { await self.importBook(at: url) }
        }

        // `-uiTestFreshDefaults`: forget the persisted reader-layout choice so
        // a UI test can assert the true first-run default — the suite's
        // simulator reuses UserDefaults across runs, and an earlier test's
        // Aa-popover toggle would otherwise leak into the assertion.
        if ProcessInfo.processInfo.arguments.contains("-uiTestFreshDefaults") {
            UserDefaults.standard.removeObject(forKey: "readerLayout")
        }

        // `-uiTestSeedProviderKeys`: mark both remote providers as configured
        // (with obvious non-secret placeholder values — NOT real or realistic
        // API keys) and make Anthropic the active selection, so provider-
        // switching UI tests need no keyboard input (typing into a second
        // SecureField mid-sheet is a chronic XCUITest focus flake).
        // Isolation: requires `-uiTestInMemoryCredentials`, which swaps the
        // store for `InMemoryCredentialStore` — these placeholders can never
        // reach the real Keychain, and the flag pair only exists in UI-test
        // launches.
        if ProcessInfo.processInfo.arguments.contains("-uiTestSeedProviderKeys"),
           ProcessInfo.processInfo.arguments.contains("-uiTestInMemoryCredentials") {
            try? credentials.save(.apiKey("uitest-placeholder-not-a-secret"), for: .anthropic)
            try? credentials.save(.apiKey("uitest-placeholder-not-a-secret"), for: .openAI)
            providerManager.setActive(kind: .anthropic)
        }

        if seedsSampleBook {
            seedSampleBookIfNeeded()
        }
    }

    /// Puts one book in the library the first time Readr runs, so a fresh
    /// install opens onto something readable rather than an empty shelf with
    /// an Import button and nothing to import. See `SampleBookSeeder` for why
    /// this exists and why it only ever fires once — and only into a library
    /// that has never been written (`LibraryStore.hasPersistedLibrary`).
    private func seedSampleBookIfNeeded() {
        let defaults = UserDefaults.standard
        guard SampleBookSeeder.shouldSeed(
            hasSeededBefore: defaults.bool(forKey: Self.sampleBookSeededKey),
            hasPersistedLibrary: store.hasPersistedLibrary,
            existingBookCount: books.count
        ) else { return }

        guard let url = Bundle.main.url(
            forResource: "alice-in-wonderland", withExtension: "epub"
        ) else {
            // The resource fell out of the bundle. An empty library is a poor
            // first run, but it is a working one — never a launch crash.
            assertionFailure("bundled sample book is missing from the app bundle")
            return
        }

        Task { @MainActor in
            do {
                // The same path a file the user opens takes (`ingest`): the
                // sample gets its retained source, cover file, added-on date
                // and diagnostics entry like any other book.
                let seeded = try await SampleBookSeeder.seedIfNeeded(
                    into: store,
                    hasSeededBefore: defaults.bool(forKey: Self.sampleBookSeededKey)
                ) {
                    try await self.ingest(url)
                }
                // The flag records that a book was actually seeded — nothing
                // else. A launch that decided not to seed, or a failed
                // import, leaves it unset so the decision is made afresh.
                if seeded != nil {
                    defaults.set(true, forKey: Self.sampleBookSeededKey)
                }
            } catch {
                // Same reasoning as above: a broken sample costs the user the
                // sample, not the app.
                DiagnosticsLog.shared.record(
                    .error, .importer, "could not seed the bundled sample book", error: error
                )
            }
        }
    }

    private static let sampleBookSeededKey = "hasSeededSampleBook"

    // MARK: Diagnostics

    /// Installs the file sink once per process. Idempotent (re-running it —
    /// a second `AppModel`, an Xcode preview — just replaces the closure
    /// with an equivalent one pointed at the same file), so it's safe to
    /// call unconditionally from `init`.
    private static func installDiagnosticsFileSink() {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return }
        let logURL = cachesDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("readr.log")
        let fileSink = DiagnosticsFileSink(fileURL: logURL)
        DiagnosticsLog.shared.sink = { event in fileSink.write(event) }
    }

    private static var appVersionAndBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func makeCredentialStore() -> any CredentialStore {
        // `-uiTestInMemoryCredentials`: keep the Ask refresh-on-connect UI test
        // (A1) off the real Keychain — deterministic and leak-free — while
        // still exercising the genuine save → activate → resolve path.
        if ProcessInfo.processInfo.arguments.contains("-uiTestInMemoryCredentials") {
            return InMemoryCredentialStore()
        }
        #if canImport(Security)
        // Wrapped so each kind's secret is read from the Keychain once per
        // launch. On macOS a signature/ACL mismatch turns every read into a
        // "Readr wants to use your confidential information" prompt, and the
        // settings surface reads each kind three or more times per refresh —
        // see `KeychainReadCache`. The cache must wrap the store the WHOLE app
        // shares (the settings layer writes credentials directly), which is
        // exactly what this composition root hands out.
        return KeychainReadCache(wrapping: KeychainCredentialStore())
        #else
        return InMemoryCredentialStore()
        #endif
    }

    /// Deterministic fixtures for UI tests and screenshots (seeded via the
    /// `-uiTestSeed` arg). The first book keeps the titles the UI tests assert
    /// on; the extra books fill the shelf so screenshots look like a library.
    static let sampleBooks: [Book] = {
        let paragraph = """
        It was a bright cold day in April, and the clocks were striking \
        thirteen. Winston Smith, his chin nuzzled into his breast in an effort \
        to escape the vile wind, slipped quickly through the glass doors of \
        Victory Mansions, though not quickly enough to prevent a swirl of \
        gritty dust from entering along with him.
        """
        // Six DISTINCT paragraphs, not six copies of one. Identical paragraphs
        // made a real narration bug undiagnosable: narration correctly started
        // 81% into the chapter, but the sentence it spoke was character-for-
        // character the same as the one near the top, so a device test read it
        // as "narration restarted the chapter" and the investigation went after
        // the wrong thing entirely. A fixture that repeats itself cannot tell
        // you where you are. The first paragraph is untouched — the seeded
        // highlights and the UI tests match phrases in it.
        let chapterOne = [
            paragraph,
            """
            The hallway smelt of boiled cabbage and old rag mats. At one end \
            of it a coloured poster, too large for indoor display, had been \
            tacked to the wall. It depicted simply an enormous face, more than \
            a metre wide.
            """,
            """
            Winston made for the stairs. It was no use trying the lift. Even \
            at the best of times it was seldom working, and at present the \
            electric current was cut off during daylight hours.
            """,
            """
            The flat was seven flights up, and Winston, who was thirty-nine \
            and had a varicose ulcer above his right ankle, went slowly, \
            resting several times on the way.
            """,
            """
            Outside, even through the shut window-pane, the world looked cold. \
            Down in the street little eddies of wind were whirling dust and \
            torn paper into spirals, and the sun shone with no warmth at all.
            """,
            """
            The blackmoustachio'd face gazed down from every commanding \
            corner. There was one on the house-front immediately opposite. \
            BIG BROTHER IS WATCHING YOU, the caption said.
            """,
        ].joined(separator: "\n\n")
        let sample = Book(
            metadata: BookMetadata(
                title: "Sample Book", authors: ["Test Author"],
                // A real nav TOC so the Contents sheet's real-TOC path is on
                // every seeded run: "Part I" exists ONLY here (no chapter has
                // that title), proving the sheet reads the TOC, not the spine.
                tableOfContents: [
                    TOCEntry(title: "Part I", chapterIndex: 0, children: [
                        TOCEntry(title: "Chapter One", chapterIndex: 0),
                        TOCEntry(title: "Chapter Two", chapterIndex: 1),
                    ]),
                    TOCEntry(title: "Notes", chapterIndex: 2),
                ]
            ),
            chapters: [
                Chapter(title: "Chapter One", order: 0, text: chapterOne),
                Chapter(title: "Chapter Two", order: 1, text: "The clocks were striking thirteen.\n\n" + paragraph),
                // linear="no" notes document: reachable from Contents, but
                // skipped by continuous next/previous navigation.
                Chapter(
                    title: "Notes", order: 2,
                    text: "1. The thirteenth strike is the reader's first clue.",
                    isLinear: false
                ),
            ],
            estimatedTokenCount: 500
        )
        let voyage = Book(
            metadata: BookMetadata(title: "A Voyage North", authors: ["I. Larsen"]),
            chapters: [Chapter(title: "Departure", order: 0, text: paragraph)],
            estimatedTokenCount: 90
        )
        let letters = Book(
            metadata: BookMetadata(title: "Letters on Design", authors: ["M. Ortiz"]),
            chapters: [Chapter(title: "On Type", order: 0, text: paragraph)],
            estimatedTokenCount: 90
        )
        return [sample, voyage, letters]
    }()

    /// The `-uiTestSeed` world as a directly constructible model, for tests
    /// that can't pass launch arguments (the macOS snapshot suite renders
    /// views offscreen inside the app-hosted unit bundle). Same fixtures the
    /// UI tests and CI screenshots see.
    static func uiTestSeededModel() -> AppModel {
        let seeded = InMemoryLibraryStore()
        for book in sampleBooks { try? seeded.add(book) }
        seedFixtureState(into: seeded)
        seedFixturePDF(into: seeded)
        return AppModel(store: seeded, seedsSampleBook: false)
    }

    /// Layers lifecycle state and annotations over `sampleBooks` so seeded
    /// runs exercise the whole v2 surface: Home gets a Continue Reading card
    /// (saved position + `lastOpenedAt` on "Sample Book"), the Finished shelf
    /// has an entry, Recently Added has a fresh import, and the notes screens
    /// have colored highlights to show. UI tests and CI screenshots both
    /// launch with `-uiTestSeed`, so this is exactly what they see.
    private static func seedFixtureState(into store: InMemoryLibraryStore) {
        let now = Date()
        let books = sampleBooks
        guard books.count >= 3 else { return }
        let sample = books[0]
        let voyage = books[1]
        let letters = books[2]

        // "Sample Book" is mid-read: halfway down chapter one, opened just
        // now — it leads Home's Continue Reading row with a visible progress
        // bar and a minutes-left estimate.
        if let chapter = sample.chapters.first {
            try? store.savePosition(
                ReadingPosition(chapterIndex: 0, characterOffset: chapter.text.count / 2),
                for: sample.id
            )
            try? store.saveBookState(
                BookState(addedAt: now.addingTimeInterval(-3 * 86_400), lastOpenedAt: now),
                for: sample.id
            )

            // A few colored highlights (one with a note) so the Notes panel,
            // Highlights & Notes review, and Article Studio have real content.
            let marks: [(phrase: String, color: HighlightColor, note: String?)] = [
                ("It was a bright cold day in April", .yellow, nil),
                ("the clocks were striking thirteen", .blue,
                 "Something is off from the very first line."),
                ("a swirl of gritty dust", .green, nil),
            ]
            for (index, mark) in marks.enumerated() {
                guard let range = characterRange(of: mark.phrase, in: chapter.text) else { continue }
                try? store.addHighlight(Highlight(
                    bookID: sample.id,
                    chapterID: chapter.id,
                    range: range,
                    quotedText: mark.phrase,
                    note: mark.note,
                    createdAt: now.addingTimeInterval(Double(index - 3) * 60),
                    color: mark.color
                ))
            }
        }

        // "A Voyage North" is a fresh import (leads Recently Added) …
        try? store.saveBookState(
            BookState(addedAt: now.addingTimeInterval(-3_600)),
            for: voyage.id
        )
        // … and "Letters on Design" is finished, populating the Finished
        // shelf and the checkmark badge (finished books stay out of
        // Continue Reading even though they were opened).
        try? store.saveBookState(
            BookState(
                addedAt: now.addingTimeInterval(-14 * 86_400),
                lastOpenedAt: now.addingTimeInterval(-7 * 86_400),
                finishedAt: now.addingTimeInterval(-6 * 86_400)
            ),
            for: letters.id
        )
    }

    /// Seeded PDF fixture: renders a real two-page PDF into the books
    /// directory and registers a matching book, so UI tests and the CI
    /// screenshot walk cover the native PDF reader (J1/J2 for PDFs) — the
    /// only journey class the text-only fixtures couldn't reach. The library
    /// treats it exactly like an imported PDF: `sourceFilename` resolves via
    /// `sourceURL(for:)` and `isPDF` keys off the extension.
    private static func seedFixturePDF(into store: InMemoryLibraryStore) {
        let pageOne = """
        Field notes are a promise to your future self: what you saw, what \
        you doubted, and what you decided while the light was still good.
        """
        let pageTwo = """
        Read them back a season later and the gaps speak loudest — the \
        questions you forgot to ask are the ones worth a second trip.
        """
        guard let dir = try? booksDirectory() else { return }
        let url = dir.appendingPathComponent("field-notes.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        for text in [pageOne, pageTwo] {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 16, nil)
                ]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: 0),
                CGPath(rect: mediaBox.insetBy(dx: 72, dy: 72), transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()

        let book = Book(
            metadata: BookMetadata(title: "Field Notes", authors: ["R. Calder"]),
            chapters: [
                Chapter(title: "Field Notes", order: 0, text: pageOne + "\n\n" + pageTwo)
            ],
            estimatedTokenCount: 80,
            sourceFilename: "field-notes.pdf"
        )
        try? store.add(book)
        // Freshest import: leads Recently Added (a PDF card on Home) and
        // takes the grid's top slot, where the walk can reach it without
        // scrolling — stateless books sort to the end of `recentlyAdded`,
        // which would push the PDF below the fold on a phone.
        try? store.saveBookState(BookState(addedAt: Date()), for: book.id)

        // A native-PDF highlight on page 2 (with a note) so the Notes list has
        // a PDF annotation to review: exercises the jump-to-page path (R1) and
        // the overlay-reconciling edit/delete (R2) in the UI tests. Page-space
        // rect sits in the text block of the 612×792 page (72pt margins).
        let now = Date()
        try? store.addPDFHighlight(PDFHighlight(
            bookID: book.id,
            pageIndex: 1,
            lineRects: [PDFRect(x: 72, y: 690, width: 468, height: 20)],
            quotedText: "the gaps speak loudest",
            color: .yellow,
            note: "Come back to this next season.",
            createdAt: now
        ))
    }

    /// Character-offset range of `phrase` in `text`. Highlights address
    /// chapter text by character offsets (matching the reader's
    /// `Array(chapter.text)` indexing), not by `String.Index`.
    private static func characterRange(of phrase: String, in text: String) -> Range<Int>? {
        guard let match = text.range(of: phrase) else { return nil }
        let lower = text.distance(from: text.startIndex, to: match.lowerBound)
        return lower..<(lower + phrase.count)
    }

    // MARK: Defaults

    private static func makeDefaultStore() -> any LibraryStore {
        if let url = try? FileLibraryStore.defaultURL() {
            return FileLibraryStore(fileURL: url)
        }
        return InMemoryLibraryStore()
    }

    private static func makeDefaultRegistry() -> BookParserRegistry {
        var parsers: [any BookParser] = [PlainTextBookParser()]
        #if canImport(PDFKit)
        parsers.append(PDFKitBookParser())
        #endif
        #if canImport(ZIPFoundation)
        parsers.append(EPUBFileParser())
        #endif
        return BookParserRegistry(parsers: parsers)
    }

    // MARK: Import

    /// Files whose import is in flight, keyed by standardized URL. Guards
    /// against the same file being imported twice concurrently — `onOpenURL`
    /// can deliver one URL to more than one library scene (e.g. two macOS
    /// windows), and since `Book.id` is random per parse the store can't
    /// dedupe after the fact.
    private var importingURLs: Set<URL> = []

    func importBook(at url: URL) async {
        // Idempotent against concurrent duplicate delivery. The check-and-insert
        // is atomic on the main actor (no await before it); the key clears when
        // this import finishes, so a deliberate later re-import still works.
        let importKey = url.standardizedFileURL
        guard !importingURLs.contains(importKey) else { return }
        importingURLs.insert(importKey)
        defer { importingURLs.remove(importKey) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let book = try await ingest(url)
            if book.metadata.isFixedLayout == true {
                importNotice = """
                “\(book.metadata.title)” is a fixed-layout book. Readr shows it \
                as extracted text for now — fixed-layout rendering is on the \
                roadmap.
                """
            } else if book.metadata.isImageOnly == true {
                // The reader repeats the short form as a banner each open.
                importNotice = ScannedPDFCopy.importNotice(title: book.metadata.title)
            }
        } catch {
            // `readerFacingMessage` carries the recovery suggestion too — the
            // banner is one string, and the next step is the half that matters
            // (#48). Every error ReadrKit throws here is a `LocalizedError`.
            importError = error.readerFacingMessage
            // The extension, never the filename — that's usually title+author
            // and a report is a public issue (#41).
            DiagnosticsLog.shared.recordImportFailure(
                fileExtension: url.pathExtension.lowercased(), error: error
            )
        }
    }

    /// The one way a file becomes a book in the library: parse, retain the
    /// source, write the cover file, add it, stamp `addedAt`, and record the
    /// diagnostics entry. `importBook(at:)` wraps it for files the user
    /// opens (security scope, duplicate delivery, the error banner);
    /// first-run seeding calls it for the bundled sample, so the sample is
    /// indistinguishable from an import. Throws on a parse or store failure
    /// with the library untouched.
    @discardableResult
    private func ingest(_ url: URL) async throws -> Book {
        var book = try await parsers.parse(url)
        let bookID = book.id
        let needsCover = book.coverImageData == nil
        // File copy + PDF thumbnail rendering happen OFF the main actor —
        // large books would otherwise freeze the UI right after import.
        // The caller's security scope is still held: we await before returning.
        let assets = await Task.detached(priority: .userInitiated) {
            let retained = try? Self.retainSource(url, for: bookID)
            let cover = needsCover ? Self.pdfCoverThumbnail(for: url) : nil
            return (retained, cover)
        }.value
        book.sourceFilename = assets.0
        if let cover = assets.1 { book.coverImageData = cover }

        // Covers live as files, not inside library.json: the store rewrites
        // its whole JSON on every position save, so embedded image data
        // would make each page turn re-serialize megabytes.
        if let cover = book.coverImageData {
            try? Self.saveCoverFile(cover, for: book.id)
            book.coverImageData = nil
        }
        try store.add(book)
        var state = store.bookState(for: book.id) ?? BookState()
        state.addedAt = Date()
        try? store.saveBookState(state, for: book.id)
        statesByBook[book.id] = state
        books = store.allBooks()
        DiagnosticsLog.shared.recordBookOpened(
            book, format: url.pathExtension.lowercased()
        )
        return book
    }

    // MARK: Covers

    private let coverCache = NSCache<NSUUID, PlatformImage>()

    nonisolated static func coversDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Readr/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func saveCoverFile(_ data: Data, for bookID: UUID) throws {
        let url = try coversDirectory().appendingPathComponent("\(bookID.uuidString).img")
        try data.write(to: url, options: .atomic)
    }

    /// Decoded cover artwork, cached so shelf scrolling doesn't re-decode PNGs
    /// on every cell render. Sources: in-memory data (seeded books) or the
    /// cover file written at import.
    func coverImage(for book: Book) -> PlatformImage? {
        if let cached = coverCache.object(forKey: book.id as NSUUID) { return cached }
        var data = book.coverImageData
        if data == nil,
           let url = try? Self.coversDirectory()
               .appendingPathComponent("\(book.id.uuidString).img"),
           FileManager.default.fileExists(atPath: url.path) {
            data = try? Data(contentsOf: url)
        }
        guard let data, let image = PlatformImage(data: data) else { return nil }
        coverCache.setObject(image, forKey: book.id as NSUUID)
        return image
    }

    /// Copy the imported file into the app's Books directory as `<id>.<ext>`.
    nonisolated static func retainSource(_ url: URL, for bookID: UUID) throws -> String {
        let dir = try booksDirectory()
        let filename = "\(bookID.uuidString).\(url.pathExtension.lowercased())"
        let destination = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return filename
    }

    nonisolated static func booksDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Readr/Books", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute URL of a book's retained source file, if any.
    func sourceURL(for book: Book) -> URL? {
        guard let filename = book.sourceFilename,
              let dir = try? Self.booksDirectory() else { return nil }
        let url = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Inline images

    /// Decoded inline chapter images, keyed by their character offset in the
    /// chapter text. Cached per archive entry so re-renders (page turns, theme
    /// changes) don't re-open the ZIP or re-decode bytes.
    private let inlineImageCache = NSCache<NSString, PlatformImage>()

    func inlineImages(for book: Book, chapter: Chapter) -> [Int: InlineImage] {
        guard let images = chapter.images, !images.isEmpty else { return [:] }
        var result: [Int: InlineImage] = [:]
        for image in images {
            // The cache holds decoded bitmaps per archive entry; the declared
            // display size is per placement (the same bitmap can appear at
            // several offsets with different markup sizes), so it's attached
            // outside the cache.
            let key = "\(book.id)/\(image.archivePath)" as NSString
            let decoded: PlatformImage
            if let cached = inlineImageCache.object(forKey: key) {
                decoded = cached
            } else {
                guard let src = sourceURL(for: book),
                      let data = Self.loadArchiveImageData(bookURL: src, path: image.archivePath),
                      let fresh = PlatformImage(data: data)
                else { continue }
                inlineImageCache.setObject(fresh, forKey: key)
                decoded = fresh
            }
            result[image.offset] = InlineImage(
                image: decoded,
                displayWidth: image.displayWidth.map { CGFloat($0) },
                displayHeight: image.displayHeight.map { CGFloat($0) }
            )
        }
        return result
    }

    /// Bytes of one entry inside the book's retained source archive (EPUB),
    /// or nil when the archive can't be opened or the entry is missing.
    nonisolated private static func loadArchiveImageData(bookURL: URL, path: String) -> Data? {
        #if canImport(ZIPFoundation)
        guard let container = try? ZipEPUBContainer(url: bookURL) else { return nil }
        return try? container.data(at: path)
        #else
        return nil
        #endif
    }

    /// First-page thumbnail for PDFs (nil for other formats).
    nonisolated private static func pdfCoverThumbnail(for url: URL) -> Data? {
        #if canImport(PDFKit)
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        return PDFCoverRenderer.firstPageThumbnail(url: url)
        #else
        return nil
        #endif
    }

    // MARK: Removal

    /// Deletes a book everywhere: library entry (with its positions and
    /// annotations), the retained source file, and the cover file.
    func removeBook(_ book: Book) {
        try? store.removeBook(id: book.id)
        // Its Readr Voice audio goes with it.
        ReadrVoiceAudioCache.shared.removeBook(id: book.id)
        if let source = sourceURL(for: book) {
            try? FileManager.default.removeItem(at: source)
        }
        if let cover = try? Self.coversDirectory()
            .appendingPathComponent("\(book.id.uuidString).img") {
            try? FileManager.default.removeItem(at: cover)
        }
        coverCache.removeObject(forKey: book.id as NSUUID)
        lengthCache.invalidate(bookID: book.id)
        highlightsByBook[book.id] = nil
        pdfHighlightsByBook[book.id] = nil
        bookmarksByBook[book.id] = nil
        statesByBook[book.id] = nil
        positionsByBook[book.id] = nil
        books = store.allBooks()
    }

    // MARK: Reading position

    /// Called from body — reads the published cache first (see
    /// `positionsByBook`), falling through to the store for a book whose
    /// position was saved before this model existed.
    func position(for book: Book) -> ReadingPosition? {
        positionsByBook[book.id] ?? store.position(for: book.id)
    }

    func savePosition(_ position: ReadingPosition, for book: Book) {
        try? store.savePosition(position, for: book.id)
        positionsByBook[book.id] = position
    }

    // MARK: Chapter lengths

    /// Per-chapter character and word counts for a book, measured once and
    /// kept — what Home's "Chapter 7 of 24 · 31%" and "~N min left", the
    /// reader's footer estimate and the Ask panel's caption are built from.
    /// Safe to call from body: the cache is not `@Published`.
    func readingLengths(for book: Book) -> ReadingLengthTable {
        lengthCache.table(for: book)
    }

    // MARK: Book state (Home / Finished)

    /// SwiftUI body calls this, so it must not mutate `@Published` state —
    /// writing the cache here would publish during a view update (and, for a
    /// book with no saved state, re-publish on every render). The cache is
    /// populated by init and by every mutation path instead; the store
    /// fallback is a cheap in-memory dictionary read.
    func bookState(for book: Book) -> BookState? {
        statesByBook[book.id] ?? store.bookState(for: book.id)
    }

    /// Record that the reader opened this book (drives "Continue Reading").
    func markOpened(_ book: Book) {
        var state = bookState(for: book) ?? BookState()
        state.lastOpenedAt = Date()
        try? store.saveBookState(state, for: book.id)
        statesByBook[book.id] = state
    }

    func setFinished(_ finished: Bool, for book: Book) {
        var state = bookState(for: book) ?? BookState()
        state.finishedAt = finished ? Date() : nil
        try? store.saveBookState(state, for: book.id)
        statesByBook[book.id] = state
    }

    /// Books to resume, most recently opened first (unfinished only).
    var continueReading: [Book] {
        books
            .filter { statesByBook[$0.id]?.lastOpenedAt != nil }
            .filter { statesByBook[$0.id]?.isFinished != true }
            .sorted {
                (statesByBook[$0.id]?.lastOpenedAt ?? .distantPast)
                    > (statesByBook[$1.id]?.lastOpenedAt ?? .distantPast)
            }
    }

    /// Most recently imported books first (books without a recorded addedAt
    /// keep library order at the end).
    var recentlyAdded: [Book] {
        books.sorted {
            (statesByBook[$0.id]?.addedAt ?? .distantPast)
                > (statesByBook[$1.id]?.addedAt ?? .distantPast)
        }
    }

    /// True when the book is a PDF. The image-only parser verdict remains
    /// authoritative if retaining the source copy failed and left no filename.
    func isPDF(_ book: Book) -> Bool {
        book.metadata.isImageOnly == true
            || book.sourceFilename?.lowercased().hasSuffix(".pdf") == true
    }

    // MARK: Bookmarks

    /// Called from body — no `@Published` writes here (see bookState). The
    /// add/remove paths below keep the cache fresh.
    func bookmarks(for book: Book) -> [Bookmark] {
        bookmarksByBook[book.id] ?? store.bookmarks(for: book.id)
    }

    func addBookmark(_ bookmark: Bookmark) {
        try? store.addBookmark(bookmark)
        bookmarksByBook[bookmark.bookID] = store.bookmarks(for: bookmark.bookID)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        try? store.removeBookmark(id: bookmark.id)
        bookmarksByBook[bookmark.bookID] = store.bookmarks(for: bookmark.bookID)
    }

    // MARK: PDF highlights

    /// Called from body — no `@Published` writes here (see bookState). The
    /// add/update/remove paths below keep the cache fresh.
    func pdfHighlights(for book: Book) -> [PDFHighlight] {
        pdfHighlightsByBook[book.id] ?? store.pdfHighlights(for: book.id)
    }

    func addPDFHighlight(_ highlight: PDFHighlight) {
        try? store.addPDFHighlight(highlight)
        pdfHighlightsByBook[highlight.bookID] = store.pdfHighlights(for: highlight.bookID)
    }

    func updatePDFHighlight(_ highlight: PDFHighlight) {
        try? store.updatePDFHighlight(highlight)
        pdfHighlightsByBook[highlight.bookID] = store.pdfHighlights(for: highlight.bookID)
    }

    func removePDFHighlight(_ highlight: PDFHighlight) {
        try? store.removePDFHighlight(id: highlight.id)
        pdfHighlightsByBook[highlight.bookID] = store.pdfHighlights(for: highlight.bookID)
    }

    // MARK: Export

    /// Markdown for all of a book's annotations, or nil when it has none.
    func annotationsMarkdown(for book: Book) -> String? {
        AnnotationMarkdownExporter().markdown(
            book: book,
            highlights: highlights(for: book),
            pdfHighlights: pdfHighlights(for: book)
        )
    }

    // MARK: Highlights

    /// Called from body — no `@Published` writes here (see bookState). The
    /// add/update/remove paths below keep the cache fresh.
    func highlights(for book: Book) -> [Highlight] {
        highlightsByBook[book.id] ?? store.highlights(for: book.id)
    }

    @discardableResult
    func addHighlight(
        in book: Book,
        chapter: Chapter,
        range: Range<Int>,
        note: String? = nil,
        color: HighlightColor = .yellow
    ) -> Highlight? {
        do {
            var highlight = try highlightService.makeHighlight(
                in: book, chapter: chapter, range: range, note: note, createdAt: Date()
            )
            highlight.color = color
            try store.addHighlight(highlight)
            highlightsByBook[book.id] = store.highlights(for: book.id)
            return highlight
        } catch {
            // Empty selection or persistence error — nothing to add.
            return nil
        }
    }

    /// Persist note/color edits to an existing highlight.
    func updateHighlight(_ highlight: Highlight) {
        try? store.updateHighlight(highlight)
        highlightsByBook[highlight.bookID] = store.highlights(for: highlight.bookID)
    }

    func removeHighlight(_ highlight: Highlight, in book: Book) {
        try? store.removeHighlight(id: highlight.id)
        highlightsByBook[book.id] = store.highlights(for: book.id)
    }

    // MARK: Ask the book (M3)

    private let ragIndex = HybridRAGIndex()
    private let embeddings = LocalEmbeddingProvider()

    /// An `AskService` bound to the active provider, or nil if none is configured.
    func makeAskService() -> AskService? {
        guard let provider = activeProvider() else { return nil }
        return AskService(
            strategy: AdaptiveContextStrategy(index: ragIndex, lengths: lengthCache),
            provider: provider
        )
    }

    /// Renew the active provider's OAuth tokens if they're at expiry, so a
    /// provider built right after holds fresh credentials. No-op for API-key
    /// and local providers. Await this before `activeProvider()` on the
    /// AI-request paths (ask, compose); render-time nil-checks stay sync.
    func refreshActiveProviderCredentialsIfNeeded() async {
        guard let kind = providerManager.selection?.kind else { return }
        await providerManager.refreshCredentialsIfNeeded(kind)
    }

    /// `refreshActiveProviderCredentialsIfNeeded()` + `activeProvider()` in
    /// one await — the provider handed back is built from post-refresh
    /// credentials.
    func refreshedActiveProvider() async -> LLMProvider? {
        await refreshActiveProviderCredentialsIfNeeded()
        return activeProvider()
    }

    /// The active LLM provider, or nil if none is configured.
    /// `-uiTestStubLLM` (CI screenshot walk only) substitutes a canned local
    /// provider so the Ask flow can be exercised deterministically offline.
    func activeProvider() -> LLMProvider? {
        if ProcessInfo.processInfo.arguments.contains("-uiTestStubLLM") {
            return UITestStubProvider()
        }
        return try? providerManager.activeProvider()
    }

    /// Build the retrieval index for a book if it hasn't been built yet. Cheap to
    /// call repeatedly; the index is reused across questions.
    func ensureIndexed(_ book: Book) async {
        if await ragIndex.isBuilt(bookID: book.id) { return }
        try? await ragIndex.build(for: book, embeddings: embeddings)
    }

    /// Build a `Selection` (quote + surrounding context) from a character range.
    func makeSelection(in chapter: Chapter, range: Range<Int>) -> Selection {
        let characters = Array(chapter.text)
        let lower = max(0, range.lowerBound)
        let upper = min(characters.count, range.upperBound)
        let quoted = lower < upper ? String(characters[lower..<upper]) : ""
        let contextLower = max(0, lower - 240)
        let contextUpper = min(characters.count, upper + 240)
        let surrounding = String(characters[contextLower..<contextUpper])
        return Selection(
            chapterID: chapter.id,
            quotedText: quoted,
            surroundingText: surrounding,
            chapterTitle: chapter.title
        )
    }

}
