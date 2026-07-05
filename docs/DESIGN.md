# Readr v2 — Design Spec

The goal: **the best reader app for the Mac**. Nobody who tries Readr should want
to go back to Apple Books. This spec is the contract for the v2 redesign; it is
grounded in a teardown of Apple Books on macOS, a competitive scan of the
best-loved readers (Readwise Reader, Kindle, KOReader, Readest, Highlights.app,
LiquidText, Yomu), and verified AppKit/PDFKit implementation patterns.

## Why people will switch (the wedge)

1. **PDFs are first-class.** Apple Books on macOS cannot even open a PDF — it
   launches Preview. Readr reads, annotates, searches, and asks questions of
   PDFs natively, with the same annotation model as EPUBs.
2. **Your highlights are alive, not trapped.** Apple Books has no annotation
   export at all (its own users' most-cited complaint). In Readr every
   highlight/note streams into a Notes panel as you read, exports as clean
   Markdown in one click, and can be composed into an article by the AI.
3. **Ask the book, with receipts.** Select any passage → Ask. Answers are
   grounded in the book and cite the passages they came from.

## Design principles

- **Content first, zero merchandising.** The home screen resumes your reading;
  it never sells anything (the Kindle ad-wall is the anti-pattern).
- **One gesture to annotate.** Select text → popover appears → one click
  highlights. Not three clicks (Kindle), not a hidden right-click (Books).
- **Color is meaning.** Five highlight colors, filterable at review/export.
- **Opinionated beauty, knobs one level down.** Serif book typography and
  curated themes that are right out of the box (Yomu/Matter pattern).
- **Mac-native density and behavior.** Real sidebar, hover states, keyboard
  shortcuts with visible tooltips, per-book windows, unified toolbars.
- **No lock-in.** Files stay accessible, annotations export as Markdown,
  local-LLM path stays offline.

## Visual system ("Paper & Ink" v2)

- **Accent**: warm amber `#DE9E36` (`Color(red: 0.87, green: 0.62, blue: 0.21)`)
  — matches the app icon (open book + amber spark on warm ink). Asset catalog
  `AccentColor` + `AppTheme.accent` must agree.
- **Covers**: 2:3 jackets, radius 6, soft shadow; deterministic gradient + serif
  title placeholder when no artwork. Hover: scale 1.04 + deeper shadow +
  a subtle "Read" affordance (macOS).
- **Reading themes**: Paper, Sepia, Night (existing palette) applied to the
  full reader surface including chrome background.
- **Typography**: serif (New York) for book text and reading-related headings;
  system sans for chrome. Sizes 13–30pt, line spacing 0.45×.
- **Highlight palette** (both light + night variants, alpha ~0.35/0.25):
  yellow, green, blue, pink, purple. Note indicator uses the highlight color.

## Information architecture

```
NavigationSplitView
├── Sidebar                       (translucent source list)
│   ├── Home                      (Continue Reading + Recently Added)
│   ├── LIBRARY
│   │   ├── All Books
│   │   ├── Books                 (EPUB/text)
│   │   ├── PDFs
│   │   └── Finished
│   └── NOTES
│       └── Highlights & Notes    (review + export + article studio)
└── Detail                        (grid / home / notes review)

Reader: opens in its OWN WINDOW on macOS (WindowGroup(for: Book.ID.self),
openWindow(value:)); push navigation on iOS/compact.
```

Sidebar search field filters the library (title/author). Settings (AI
Providers) via gear in the library toolbar + macOS Settings scene.

## Screens

### Home
- **Continue Reading**: horizontally scrolling large cards (cover, title,
  progress ring/bar, "N min left in chapter" when known). One click resumes at
  the exact position. Sorted by `lastOpenedAt`.
- **Recently Added** row.
- Empty state: warm illustration + "Add your first book" (Import button + the
  whole window is a drop target). Second card nudges AI provider setup.

### Library grid
- Adaptive grid 150–200pt, hover effects, progress bar under in-progress
  covers, badges: "PDF" tag on PDFs, "Finished" checkmark.
- Sort menu: Recent / Title / Author. (List view: post-v2.)
- Context menu per book: Open, Open in New Window (macOS), Mark as
  Finished / Mark as Still Reading, Highlights & Notes, Create Article…,
  Delete Book… (confirmation; removes retained source + cover).
- Drag & drop import everywhere + Import button + File > Import (⌘I).

### Reader window
Toolbar (unifiedCompact, auto-hides in full screen):
- **Leading**: TOC popover (chapter list, current chapter bold, click to jump);
  Bookmarks menu (toggle bookmark ⌘D + list of bookmarks, click to jump).
- **Center**: book title · chapter title (window title/subtitle).
- **Trailing**: In-book search (⌘F, popover: field + result list with
  snippets, ⏎ jumps, works across chapters; PDFs use PDFKit findString);
  Appearance popover (NOT a menu): theme tiles (Paper/Sepia/Night) with
  live preview swatches, font size − / A / +, layout picker
  (Scroll / Page / Two pages), PDF: Original pages ↔ Reading view toggle;
  Ask the Book (sparkles, ⌘⇧A) — opens Ask panel with or without selection;
  Notes panel toggle (highlighter icon, ⌘⇧N) — `.inspector`.
- Footer (text modes): "Page x of y · ~N min left in chapter" (estimated from
  ~240 wpm until measured), page-turn arrows; ←/→ keys and trackpad swipe.
- Position restore: exact character offset (`ReadingPosition.characterOffset`),
  not just the chapter.

### Annotation (the core loop)
- **Text books (scroll & paged)**: selecting text and releasing the mouse
  anchors a **selection popover** at the selection rect (NSPopover on macOS via
  `firstRect(forCharacterRange:)` + `mouseUp` hook; on iOS a compact bar above
  the selection): `[● ● ● ● ●] [Note] [Ask] [Copy]` — five color dots
  highlight instantly on click; Note opens the note editor (creates the
  highlight too); Ask opens the Ask panel seeded with the selection.
- Clicking an **existing highlight** re-opens the popover with: change color,
  Edit Note, Remove Highlight, Ask.
- Highlights render in their color; a highlight with a note gets a small
  superscript note marker at its end in the highlight color.
- **PDFs (native mode)**: same popover on selection (PDFViewSelectionChanged +
  debounce). Highlights are stored in Readr's own store as page index +
  per-line page-space rects + quoted text + color + note (PDF file is never
  mutated), and re-created as PDFKit annotation overlays on load. TOC from
  `PDFOutline`, search via `findString`, thumbnails sidebar, bookmark = page.
- Every highlight (EPUB and PDF) appears in the Notes panel instantly.

### Notes panel (inspector, ⌘⇧N)
- Right-hand inspector column (min 280 / ideal 340): this book's annotations
  in reading order — color dot, quoted text (serif), note beneath, chapter/page
  locator. Click → jump to it in the book. Swipe/context: edit note, change
  color, delete. Filter chips by color; search field.
- Header: **Create Article** (prominent, accent-filled button) +
  **Export Markdown** (share/copy).

### Highlights & Notes (library sidebar section)
- Book picker (books that have annotations) → same list as the Notes panel,
  full-window, with Create Article and Export Markdown. This is the "review"
  home — annotations are never trapped inside a book.

### Article studio
- Entry: Notes panel CTA, sidebar section, book context menu.
- Flow: pick highlights (all pre-checked, color filter) → optional guidance
  field ("what should the article emphasize?") → Compose (streams) → editable
  Markdown editor → Export `.md` (fileExporter) / Copy / Share.
- Requires provider; otherwise shows the provider empty-state with a button to
  Settings.

### Ask panel
- Now openable with no selection (whole-book questions). Shows selection quote
  when present, streams the answer, citations as clickable disclosure rows
  (future: jump-to-passage). Tier badge stays ("whole book" / "passages").

## Data model (ReadrKit)

```swift
enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple
}
// Highlight gains: var color: HighlightColor? (nil decodes as .yellow)

struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID; var bookID: UUID
    var chapterIndex: Int; var characterOffset: Int   // text books
    var pdfPageIndex: Int?                            // PDFs
    var snippet: String; var createdAt: Date
}

struct PDFRect: Codable, Hashable, Sendable { var x, y, width, height: Double }
struct PDFHighlight: Identifiable, Codable, Hashable, Sendable {
    let id: UUID; var bookID: UUID
    var pageIndex: Int; var lineRects: [PDFRect]      // page-space, per line
    var quotedText: String; var color: HighlightColor
    var note: String?; var createdAt: Date
}

struct BookState: Codable, Hashable, Sendable {
    var addedAt: Date?; var lastOpenedAt: Date?; var finishedAt: Date?
}

// LibraryStore additions (implemented by InMemory + File stores):
func removeBook(id: UUID) throws
func updateHighlight(_ highlight: Highlight) throws
func bookmarks(for bookID: UUID) -> [Bookmark]
func addBookmark(_ bookmark: Bookmark) throws
func removeBookmark(id: UUID) throws
func pdfHighlights(for bookID: UUID) -> [PDFHighlight]
func addPDFHighlight(_ highlight: PDFHighlight) throws
func updatePDFHighlight(_ highlight: PDFHighlight) throws
func removePDFHighlight(id: UUID) throws
func bookState(for bookID: UUID) -> BookState?
func saveBookState(_ state: BookState, for bookID: UUID) throws
```

Also in ReadrKit (unit-tested):
- `ReadingTimeEstimator` — words→minutes (240 wpm default), "min left in
  chapter" from a character offset.
- `AnnotationMarkdownExporter` — highlights (+ PDF highlights) → Markdown
  grouped by chapter/page with quotes, notes, and color labels.

All new fields optional/additive so existing `library.json` files decode.

## Keyboard shortcuts

⌘I import · ⌘F find in book · ⌘D toggle bookmark · ⌘⇧N notes panel ·
⌘⇧A ask · ←/→ page turn · ⌘+/⌘− text size. Every toolbar control has a
`.help()` tooltip that names its shortcut.

## Out of scope for v2.0 (tracked in ROADMAP)

iCloud sync · Daily Review/spaced repetition · reading stats & wrap-ups ·
command palette · Calibre/OPDS import · spoiler-scoped ask ·
"Story so far" recap · list view · metadata editing · collections (user).
