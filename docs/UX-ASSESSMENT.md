# UI/UX flow assessment — September 2026

Goal: an optimised, pretty, least-confusing, delightful Readr. This is a
read-through of every screen and flow as the code stands on `main` at
`c57fa1a` (3.3.1), against `docs/DESIGN.md` and `docs/USER-JOURNEYS.md`,
with the in-flight PRs (#92 Listen from selection, #93 bug-report evidence,
#94 on-device model) taken into account so nothing here collides with them.

**How this was done.** Source read of `App/` (library shell, Home, grid,
reader, toolbar, Appearance, annotation bar, Ask panel, Notes panel, Article
Studio, Settings, Listen bar, PDF reader), the design spec, the journeys, the
roadmap's own deferred-UX list, the 3.3.x release notes, and the six
screenshots in `docs/screenshots`. The app was **not** run on a device or
simulator for this pass (other agents are using the build machines), so
items tagged `[verify]` are inferred from layout code and should be looked at
on an iPhone before acting.

The short version: the bones are excellent. The Marginalia system is
coherent, every state has copy, every control has a tooltip and an
accessibility id, and the recent 3.3.1 work (one AI door in the reader,
"Answers from" as a choice, a connected card that stops nagging) shows the
right instincts. What is left is mostly **too many things on screen at
once**, **the same thing called by several names**, and **one structural
choice — Ask as a modal sheet — that works against the core promise**.

---

## 0. Decisions so far (owner review, 2026-09-06)

Reviewed against the before/after canvas
(https://claude.ai/code/artifact/7c934321-6430-4068-9bd2-e08d66414558).

| Finding | Decision |
|---|---|
| F1 Ask beside the page (Mac/iPad) | **Approved** — inspector tab beside Highlights, conversation kept per book |
| F1 Ask on iPhone | **Rejected** — keep today's full-height sheet; only the kept-conversation part carries over |
| F2 Home nudge and shelf | **Approved**, minutes-left removed, chapter line kept (the leaner 3b card was rejected). **Recap leaves the card** (approved 2026-09-06): the card is title · author · progress · Continue · chapter, no iris. Recap appears in the reader as a one-line welcome card above the page when the reader returns after a day or more ("Welcome back — it's been 6 days · Chapter 1 of 12 · 31% read · Recap ›"). How it knows: compare the previous `BookState.lastOpenedAt` with now on open, before `markOpened` overwrites it; a saved position is also required. When it goes: after three page turns (the reader already tracks them), or on ✕ or Recap; never persisted. Recap stays the first chip in ✦ Ask |
| F3 Mac toolbar → Aa | **Approved** |
| F4/F5 headers and vocabulary | **Approved** |
| F6 Listen bar | **Decided: Option B, the now-reading card.** The bottom bar stays underneath it (✦ Ask does not move); ✕ ends narration and keeps the place, as today; pause is the ● button; tapping the page hides the chrome but not the card |
| F9 Bookmarks / Navigate | **Decided: Option A, ribbon + Contents.** The bookmark is a toggle in the bar (filled ribbon, ⌘D); bookmarks list at the top of Contents; no bookmarks menu; Find stays its own button. The scrubber (B) was rejected |
| F10 Library grid | **Approved** |

### F6 redesign — what leaves the bar and why

- "48 min ready" was an engineering figure. Readers cannot act on it. The
  buffer state now surfaces only when it matters: "Preparing Readr Voice…"
  and "couldn't download / Retry" stay; the running figure goes.
- Previous / next **chapter** buttons go; Contents already does that.
- The voice picker leaves the bar; it is chosen once, in the ⋯ menu (A) or
  the Aa popover (B).
- The iPhone bottom bar hides while the voice reads.
- **Option A, transport only:** speed on the left, ◀ ● ▶ centred, ⋯ and ✕
  on the right. No sentence line — the page underlines the sentence being
  read (this needs the deferred read-along highlighting in
  `SelectableTextView`; until then A shows the sentence as a faint line).
- **Option B, now-reading card:** a floating card with chapter kicker, the
  sentence, a chapter progress hairline, ◀ ● ▶, speed and Sleep as text.

### Listening flow (canvas page 2) — two proposed behaviours

Drawn as eight iPhone screens: read → Listen → page follows the voice →
✦ Ask → answer → Done → voice resumes → ✕. Two things in it are proposals,
not current behaviour:

- **Opening Ask while listening pauses the voice; Done resumes it** on the
  sentence it paused on. Today the voice keeps reading under the sheet.
- **Ask opened mid-narration is seeded with the sentence being read**, so
  "this passage" refers to what the reader just heard.

Everything else in the flow (start on the visible page, page follows the
voice, ✕ keeps the place, full-height Ask sheet) is 3.3.1 behaviour.

**PDFs get the same flow** (approved 2026-09-06). On original pages: Listen
starts on the page in view (PR #92 fixes the page-1 bug), the sentence being
read is underlined on the page through the PDFKit overlay, Ask pauses the
voice and is seeded with that sentence, ✕ keeps the page. The card's kicker
is the page number, since a PDF has no chapter frontier. For bookmarks, a
PDF bookmark is a page and Contents is the outline (thumbnails when there is
none); a scrubber, if chosen, is a page slider.

### F9 redesign — no bookmarks menu at all

- In both options the bookmark is a **toggle in the toolbar** (filled ribbon
  on a bookmarked page, ⌘D). Find stays its own button.
- **Option A, ribbon + Contents:** the bookmark list sits at the top of the
  Contents popover; a chapter that holds one shows a faint ribbon. One
  popover, no tabs.
- **Option B, scrubber:** a line along the bottom of the page with chapter
  ticks and ribbon markers; drag to move through the book, tap a ribbon to
  jump. Bookmarks also list in Contents as in A.

---

## 1. What is already strong (keep)

- **One-gesture annotation.** Select → four colour dots → done. The bar is
  quiet, the note indicator is an underline, and the same bar serves EPUB and
  native PDF. This is the wedge and it feels like one.
- **Iris discipline.** One accent, reserved for AI moments. The ✦ mark reads
  as a brand signature across Home, the reader, Notes, and the Ask panel.
- **Spoiler safety as a first-class choice.** "Up to where I am / Whole book"
  with a one-line meaning under it is exactly how a scope should be shown.
- **Empty and error states.** Every dead end I found carries a sentence and
  a next step (no provider → button to Settings; scanned PDF → banner that
  names which features need text; Readr Voice download failure → Retry on the
  bar).
- **Reader defaults.** Single page first, Paper theme, serif, ~65 chars per
  line, page turns by edge tap / swipe / arrow keys, tap-to-hide chrome. All
  correct and all invisible in the good way.
- **First-run has a book.** Seeding Alice means the first screen is a
  bookshelf, not a form.

---

## 2. Findings, ranked by impact

Each finding: what it is, why it hurts, the proposed change, rough effort,
and whether it touches in-flight work.

### F1. Ask covers the book on every platform  `high`

`ReaderView` presents the Ask panel with `.sheet(item:)`. On macOS that is a
window-modal sheet: the page cannot be scrolled, selected, or read while the
answer streams. On iPad it is a centred form sheet over the text. On iPhone
it is a full-height sheet (no `presentationDetents` are set; the "medium
detent" the composer comments refer to does not exist in code). Journey J4
promises an answer "without leaving the page"; today the page leaves.

Two second-order costs follow from the same choice:

- **The conversation is thrown away on close.** `AskRequest` gives every
  opening a fresh identity by design, so closing the sheet to check the page
  and reopening it loses the transcript. A reader cannot ask, read on, and
  follow up.
- **Sheet-over-sheet.** The no-provider state opens Settings as a second
  sheet on top of the Ask sheet (iPhone).

**Proposed.**
- macOS and iPad regular width: host Ask in the **inspector column** that
  Notes already uses, as two tabs at the top of the inspector ("Notes" ·
  "✦ Ask"). One column, one toggle, and the page stays readable beside the
  answer. `.inspector` is already wired with a 280–480 width.
- iPhone: keep a sheet but give it `[.medium, .large]` detents with the drag
  indicator, opening at medium so the selected passage stays visible above
  it.
- Keep one `AskViewModel` per book for the session (owned by the reader, not
  the sheet) so reopening resumes the conversation; add a small "New
  conversation" action in the panel header.

Effort: 2–3 days. Touches `ReaderView` (which #92 also edits around the
narration start path) — schedule after #92 merges to avoid a painful rebase.

### F2. The first-run provider nudge can never appear  `high` — shipped in PR #96

`HomeView` shows the "Connect an AI provider" card only inside the
empty-library state. Since 3.2.2 the sample book is seeded on first launch,
so the library is never empty on first run and the card is dead code for the
audience it was written for. The only remaining nudge is the sidebar footer
line "No model connected", which is plain text, not a button. The first time
most readers learn there is no AI is when they tap ✦ Ask and hit an empty
state.

**Proposed.**
- Move the provider card out of the empty state to sit **under Continue
  Reading on Home** whenever `activeProvider() == nil`; it disappears the
  moment a provider is connected, so a configured app is never nagged.
- Make the sidebar footer a button that opens Settings.
- With #94, on devices that can run Apple Intelligence the card should not
  ask for a key at all; it should read "Ask is ready on this device" once, or
  simply not show. Wire this after #94 lands so the copy is derived from the
  same readiness the Settings card uses.

Effort: half a day. No conflict except the #94 sequencing note.

### F3. The macOS reader toolbar carries up to 17 controls  `high`

Trailing group: Find, three layout segments, two font-size steppers, a
Text menu, three theme dots, a PDF display menu, Listen, ✦ Ask, Notes.
Leading group: previous/next chapter, Contents, Bookmarks. In the default
780pt reader window this is dense, and it is a different model from iOS,
where the same appearance controls live behind one **Aa** button. The
inline segments and dots are pretty on a wide window and noisy on a narrow
one, and the layout segments say "Scroll · Page · Spread" here but
"Scroll · Single page · Two pages" in the popover.

**Proposed.** Use the shared `AppearancePopover` on macOS too. The toolbar
becomes: `‹ ›` (optional, see F9) · Contents · Bookmarks | Find · **Aa** ·
Listen · **✦ Ask** · Notes. ⌘+ / ⌘− stay as hidden shortcuts. The popover
already carries the PDF display switch, so the separate `doc.richtext` menu
goes too. The `reader.appearance` identifier moves to the Aa button, which
is where the iOS tests already expect it.

Effort: 1 day, mostly deleting `layoutSegmentControl`, `fontStepperControl`,
`themeDotsControl`, `typographyMenu`, `pdfDisplayMenu`. Snapshot baselines
change.

### F4. Sheet headers: six surfaces, six grammars  `medium`

Already on the roadmap's deferred list; confirming the inventory so it can
be done in one pass:

| Surface | Title treatment | Dismiss |
|---|---|---|
| Ask | principal "✦ ASK THE BOOK" caps | Done (confirmation) |
| Article Studio | nav title "Article Studio" / article title **and** principal "✦ New article" | Done (cancellation) |
| Settings | nav title "Settings" | Done (confirmation) |
| Notes panel | in-content serif "Notes" | Done (iPhone only, in content) |
| OpenRouter model picker | nav title "OpenRouter model" | Cancel |
| Report a bug | nav title "Report a bug" | Done |
| Note editor (reader) | caps "NOTE" card | Cancel / Save, in content |
| Note editor (Notes list) | nav title "Note" | Cancel / Save, in toolbar |

**Proposed.** One `SheetHeader(title:, isAI:)` component: serif title for
reading surfaces, ✦ caps for AI surfaces, Done on the trailing edge, never
two titles. And one note editor: `NoteEditor` and `NoteEditSheet` do the
same job with different chrome; keep the card one.

Effort: 1 day. Touches Settings, so land after #94 or coordinate.

### F5. One object, five names  `medium` — shipped in PR #96

The reader toolbar button is labelled **Highlights**. It opens a panel
titled **Notes** that counts **annotations**. The sidebar calls the same
thing **Highlights & Notes**. The AI action is **Create Article** on the
button, **Create Article…** in the context menu, **New article** in the
studio header, **Article Studio** in its nav title, **Compose** on its
primary button, and **Regenerate** / **Rewrite** for the same re-run
action. The README screenshot still says "Compose article".

**Proposed vocabulary.** *Highlight* is the object; a *note* is text attached
to one. So: toolbar "Highlights", panel "Highlights", count "N highlights"
("3 highlights · 1 note" if you want the second number), sidebar
"Highlights". The article flow is "Article" everywhere: button "✦ Create
Article", sheet title "✦ ARTICLE", primary "Compose", re-run "Compose again".

Effort: hours. Touches UI-test string lookups (`staticTexts`), so run the
suites.

### F6. The Listen bar has no compact layout  `medium` `[verify]`

`ListenBar` is one `HStack`: five transport buttons, the sentence line,
"N min ready", speed, voice, sleep, close. On a 393pt iPhone that is roughly
300pt of controls before the sentence gets any width, and the bar sits on
top of the iPhone bottom bar (Contents · Bookmarks · Find · Listen · Ask),
so two rows of small controls stack at the thumb. #92 adds a Listen entry in
the annotation bar as well.

**Proposed.** On compact width: row one = ‹ sentence › play/pause and the
sentence line; row two = speed · voice · sleep · "N min ready" · ✕. Drop
previous/next-chapter from compact (they are in Contents). Alternatively
fold speed/voice/sleep into one "…" menu on compact. Either way the bar
should hide the iPhone bottom bar while narration runs, since Listen and Ask
are already reachable from the bar and the chrome tap.

Effort: 1 day. The voice-picker and MLX agents are in `NarrationModel` and
the voice menu; the layout change is separable but coordinate the file.

### F7. Theme is global and has no "match system"  `medium`

`readingTheme` drives `preferredColorScheme` for every window, so choosing
Dark for the page darkens the library, and Paper at night is a bright
library at bedtime. There is no Auto. Apple Books keeps the library on the
system appearance and lets the page have its own theme.

**Proposed.** Add **Auto** as the first theme option (Paper by day, Dark by
night, from the system appearance), and let the library follow Auto
independently of a reader override. Persisted raw values are untouched.

Effort: 1 day (theme resolution becomes a function of stored value +
`colorScheme` environment; every `ReadingTheme(rawValue:)` site already goes
through one accessor, so add a helper and use it).

### F8. Notes cards are not tappable; only their link is  `low` — shipped in PR #96

The spec says "click → jump to it in the book". In `AnnotationListView` the
card is inert and the jump is an underlined "Show in book" caption in the
corner. On a phone that is a small target; on a Mac it is a surprise.

**Proposed.** Whole card tappable (jump), keep "Show in book" for VoiceOver,
and move Edit / Colour / Delete to a hover ⋯ on macOS with swipe on iOS (the
swipe is already there).

Effort: hours.

### F9. Bookmarks are a menu of submenus  `low`

Each bookmark is a nested `Menu` with "Go to Bookmark" and "Remove". Two
clicks to jump, and on iPhone a menu inside a bottom-bar menu. Chapter
chevrons in the macOS toolbar duplicate the page-edge chevrons and Contents.

**Proposed.** One **Navigate** popover with tabs Contents · Bookmarks
· Search (the Apple Books pattern): tapping a bookmark jumps, ✕ removes.
That turns three toolbar buttons into one on the iPhone bottom bar and lets
the chapter chevrons go on macOS. If that is too big a change, the minimum
is: tap a bookmark row = jump, remove via a trailing ✕.

Effort: 1–2 days for the tabbed popover, hours for the minimum.

### F10. Library: small frictions that add up  `low` — shipped in PR #96

- **Sort** is an icon with no indication of the current order. Make it a
  labelled menu: "Recent ⌄".
- **Import** accepts one file at a time (`allowsMultipleSelection: false`).
  Allow many; the import loop already handles a list.
- **"Books" vs "All Books".** In a sidebar that also lists "All Books", a
  shelf called "Books" meaning "not PDFs" is ambiguous. "Ebooks" or drop the
  split and keep All Books · PDFs · Finished.
- **Recently Added duplicates Continue Reading** for any library under a
  dozen books (every book is in both rows). Show Recently Added only for
  books with no reading position, or hide the row when it adds nothing.
- **"Not started"** under every unopened cover is a label for the absence
  of information. Show nothing until there is progress.
- **Delete** is context-menu only. Fine on macOS; on iOS a long-press is the
  only path. Acceptable, but an Edit mode or swipe on the grid would match
  expectations.

Effort: hours each.

### F11. Settings model rows show raw ids  `low` — shipped in the Settings-names PR

*Shipped:* every catalogue row carries a display name (`ProviderInfo.name`,
with `ModelDisplayName` deriving one for ids the catalogue has never seen);
the Claude / OpenAI pickers list names with the id as a monospaced caption,
and the sheet opens with "Ask uses Claude Opus 5 · Claude (Anthropic)" (or
"— not connected", or "no model yet"). The text below is the original
finding.

The Claude and OpenAI pickers list `claude-opus-4-8`, `gpt-4.1`. OpenRouter
already shows a name and price per row. Give every catalogue entry a display
name and show the id as a caption. With #94 adding a fourth card and a
runtime default, the "which one is Ask actually using" question deserves one
line at the top of the sheet: "Ask uses: Claude · claude-opus-4-8".

Effort: hours. Do after #94.

### F12. Article Studio edits raw Markdown  `low`

The composed article streams in as plain text and then opens in a
`TextEditor` showing `#` and `**` markup, while the Ask answer renders
through `AnswerMarkdownView`. The toolbar label "Markdown" for "save as
file" is unclear next to "Copy" and "Share…".

**Proposed.** Render the draft with the same Markdown view in a read mode
with an Edit toggle; label the export "Save as Markdown…". The roadmap's
"one typeface for AI output" note belongs to the same pass.

Effort: 1 day.

### F13. PDF "Original pages ↔ Reading view" is hidden and consequential  `low`

The switch lives behind a `doc.richtext` menu on macOS and inside the
Appearance popover on iOS, but it changes the annotation model: highlights
made on pages are `PDFHighlight`s and highlights made in Reading view are
text `Highlight`s, and each view shows only its own kind on the page (both
appear in the Notes list). A reader who flips views thinks their highlights
vanished.

**Proposed.** A visible two-segment control in the PDF toolbar, "Pages ·
Text", and a one-time note the first time a reader switches with highlights
present. Longer term, map page highlights to text ranges when a text layer
exists so one highlight shows in both views.

Effort: hours for the control; the mapping is a separate project.

### F14. Starter chips insert instead of send  `low` — shipped in PR #96

The Ask suggestion chips put text in the field; a second tap sends. The
chips are complete questions. Tapping one should send it (Recap already
behaves that way from Home).

Effort: minutes.

### F15. The docs screenshots are a release behind  `low`

`docs/screenshots` and the README show iris-tinted chrome, chapter chevrons
in the iPhone nav bar, no Listen button, "Compose article", and an "AI
Providers" sheet title. The current app has ink chrome, a back chevron, a
Listen button, "Create Article", and "Settings". Regenerate from the
`ci-screenshots` flow after F3–F5 land so it is done once.

### F16. The annotation bar is about to be nine items  `[watch]`

Four dots · Note · ✦ Ask · Copy today; #92 adds Listen-from-here, and edit
mode adds ✕. On iPhone this floats as one capsule above the thumb. Not a
problem yet, but it is the next control to hit the wall. When #92 lands,
consider Copy behind a long-press or a ⋯, and keep the bar at ≤ 7 items.

---

## 3. Suggested order

Aim: ship the cheap clarity fixes now, do the two structural changes once
the in-flight PRs are in, and leave the rest for a polish release.

**Now — no overlap with #92/#93/#94, each under a day**

1. F5 terminology (Highlights / Article) and F14 chips send on tap.
2. F2 Home provider card outside the empty state; sidebar footer as a button.
3. F8 tappable Notes cards.
4. F10 sort label, multi-file import, hide "Not started", dedupe Recently Added.
5. F3 collapse the macOS toolbar to Aa (deletes code; snapshot baselines change).

**Next — after #92 and #94 merge**

6. F1 Ask in the inspector (mac/iPad) with detents (iPhone), conversation kept per book.
7. F4 one sheet header, one note editor (touches Settings, so after #94).
8. F6 Listen bar compact layout (coordinate with the voice-picker branch).
9. F11 model display names and an "Ask uses:" line (after #94) — shipped.

**Later — polish release**

10. F7 Auto theme and library-follows-system.
11. F9 Navigate popover (Contents · Bookmarks · Search).
12. F12 rendered article draft; F13 PDF Pages · Text control.
13. F15 regenerate screenshots once the chrome has settled.

---

## 4. Things I chose not to recommend

- **Onboarding screens.** The sample book plus a visible provider card (F2)
  and the guided Ask empty state do the job; a wizard would be a step
  backwards from "content first".
- **A second Recap door in the reader.** The 3.3.1 decision (one ✦ in the
  toolbar, Recap as the first chip) is right; F14 makes that chip one tap.
- **Bringing the iOS reader chrome to macOS** or vice versa beyond F3. The
  platforms differ where they should (bottom bar on iPhone, per-book windows
  on macOS).
- **Removing gestures** (tap-to-hide, edge taps, swipe). They are the Apple
  Books conventions readers already know.
