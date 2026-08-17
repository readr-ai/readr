# Roadmap

The first milestone builds the reader and **both** AI features (ask-the-book and
highlights→article) together, per project direction.

## M0 — Foundation ✅
- [x] Repo, license, docs, architecture
- [x] Context strategy research + decision
- [x] `ReadrKit` package skeleton with core protocols & models
- [x] XcodeGen `project.yml` + SwiftUI app shell
- [x] CI building the package

## M1 — Reading (in progress)
- [x] Library shelf + basic reader view (SwiftUI)
- [x] Import plain-text / Markdown (parser + registry, tested)
- [x] Import PDF via PDFKit (rejects encrypted/locked; tested on device)
- [x] Reading position persistence (store + reader wiring)
- [x] Highlights & notes — service + on-disk persistence (`FileLibraryStore`, tested)
- [x] Highlight/note capture UI in the reader (selectable text view)
- [x] UI test: open seeded book → navigate chapters (`-uiTestSeed`)
- [x] EPUB import — container/OPF/spine/TOC parser in `ReadrKit` (tested) +
  ZIPFoundation archive adapter in the app; DRM (encryption.xml) rejected

### M1 done. Optional polish carried forward:
- [ ] Readium paginated navigator (reflow/fonts/decorations) as a rendering upgrade
- [ ] TOC/outline-aware chaptering for PDFs
- [ ] iCloud-synced store (SwiftData/GRDB) to replace the JSON file store

## M2 — Connect an LLM (in progress)
- [x] PKCE (S256) + OAuth client (authorize/callback/token exchange/refresh)
- [x] Credential stores: in-memory + Keychain
- [x] Providers: Anthropic, OpenAI, Local (Ollama) with SSE streaming
- [x] Provider catalog + manager (selection, factory, local-mismatch guard)
- [x] Provider settings UI: API key, OAuth sign-in, local model, model picker
- [x] Loopback OAuth server + browser coordinator (app)
- [ ] Verify Anthropic OAuth client id/endpoints (placeholder today)
- [ ] Manual J5 walk on a Mac with a real provider; token-refresh-on-expiry wiring

## M3 — Ask the book (in progress)
- [x] Adaptive context router exercised end-to-end (Tier 1 whole-book + caching)
- [x] RAG: chapter-aware chunking + hybrid BM25/vector retrieval + rerank
  (`HybridRAGIndex`, in-memory)
- [x] On-device deterministic embeddings (`LocalEmbeddingProvider`, zero-network)
- [x] `AskService`: assemble context → stream answer → emit tier (tested)
- [x] Select text → Ask panel → streamed answer (app)
- [x] Answers are book-*contextual*, not book-*limited*: questions reaching past
  the book get answered from world knowledge, labelled inline, with the
  no-invention guarantee scoped to claims about the book (#54)
- [ ] SQLite (sqlite-vec + FTS5) persistence for the index (currently in-memory)
- [ ] Citations surfaced in the Ask panel; manual J4 walk on a Mac

## M4 — Highlights → article (in progress)
- [x] Order highlights by reading position; zero-highlights guidance (no LLM call)
- [x] `LLMArticleComposer` → article (tested)
- [x] Compose UI: highlights → editable Markdown editor, ShareLink export
- [ ] PDF export (Markdown share shipped; PDF is a follow-up)
- [ ] Streamed composition in the editor; manual J6 walk on a Mac

## M5 — Privacy hardening & polish (in progress)
- [x] J7 privacy audit: on-device retrieval pipeline takes no network client;
  local provider is asserted to contact loopback only; no telemetry by default
  (`PrivacyAuditTests`)
- [x] Accessibility: VoiceOver labels on icon controls; Dynamic Type in the reader
- [x] Background indexing: build the RAG index on book open (faster first ask)
- [x] Citations surfaced in the Ask panel; streamed article composition
- [x] Reader-facing error copy: every error type carries a plain-language
  sentence plus a next step, with codes/wire detail split off into
  `diagnosticSummary` for triage (#48)
- [x] In-app bug report with redacted session diagnostics, and a Share Readr
  action (#41, #40) — Settings → Help
- [ ] iCloud sync of library/annotations
- [ ] Localization (`Localizable.strings`), issue templates, release process
- [ ] SQLite (`sqlite-vec` + FTS5) RAG persistence; PDF article export
- [ ] Manual passes on a Mac (J1–J7)

## v2.0 — The redesign (in progress; spec: docs/DESIGN.md)

Goal: the best reader app for the Mac — nobody goes back to Apple Books.

- [x] Research: Apple Books teardown, competitive scan, verified Mac patterns
- [x] App icon + asset catalog (open book + amber spark), accent color
- [x] Data model: highlight colors, bookmarks, native PDF highlights,
  book state (continue reading / finished), book deletion
- [x] Sidebar shell: Home (Continue Reading), library shelves, Highlights & Notes
- [x] Reader chrome: TOC, bookmarks, in-book search, appearance popover,
  time-left-in-chapter, per-book windows on macOS
- [x] Selection popover annotation (5 colors, note, ask, copy) — one gesture
- [x] Native PDF annotation (overlay highlights, outline TOC, thumbnails, search)
- [x] Notes panel (inspector) + Markdown export + Article studio
- [ ] UI tests + screenshot verification of every new surface

### Deferred v2 review cleanups (tracked, deliberately not blocking v2.0)
- Unify the three note-editor sheets and the two annotation-popover hosting
  stacks (text vs PDF) behind shared helpers
- Move the notes-panel reading-order sort next to `AnnotationMarkdownExporter`
  so review and export can't drift
- Make `Selection.chapterID` a locator enum (chapter vs PDF page) instead of a
  synthetic UUID for PDF selections
- Structural ⌘F/⌘D command routing (host-owned toolbar dispatching to the
  active reading surface) instead of per-mode toolbar coordination
- Shared snippet/excerpt helper (search results, bookmarks, PDF search)

### Post-v2 (from the research; not scheduled)
- Reading stats, streaks, shareable wrap-ups; measured reading speed
- Daily Review (spaced repetition over highlights)
- Command palette (⌘K); spoiler-scoped ask; "story so far" recap
- kosync (KOReader) progress-sync interop; Calibre/OPDS import
- List view + metadata editing; user collections; parallel read (two books)

## M6–M8 — iPhone & iPad: TestFlight beta (shipped; device walks pending)

The iOS UI already exists (multiplatform target, iPhone-simulator UITests in
CI); these milestones make it shippable on real devices. Spec:
docs/DEVELOPMENT-PLAN.md §M6–M8.

### M6 — Signed builds + TestFlight pipeline
- [x] UITest locking OAuth hidden in the beta (flips in M7)
- [x] project.yml iOS release config (export compliance, orientations, device
  family, automatic signing — team ID injected by CI, never in the repo)
- [x] CI: iPad-simulator UITest lane + `generic/platform=iOS` device build
- [x] `.github/workflows/testflight.yml` — archive with cloud signing (App
  Store Connect API key) and upload straight to TestFlight
- [x] One-time App Store Connect setup (bundle ID `com.readrai.app`, app
  record, API key, GitHub secrets) — see the workflow header for secret names
- [x] First upload live: v2.8.0 accepted by App Store Connect (unsigned
  archive + sign-at-export + Xcode 26 recipe proven on `main`)
- [x] Exit gate: TestFlight install verified on a physical iPhone and iPad
  (import, read, highlight, BYOK ask) — walked 2026-08-08 against the v2.15.0
  TestFlight build and passed. Walkthrough: `docs/DEVICE-SMOKE-TEST.md`

### M7 — iOS platform correctness
- [x] Files-app handler: `CFBundleDocumentTypes` + open-in-place +
  `.onOpenURL` import (UITest via `-uiTestOpenURL` fixture)
- [x] OAuth on iOS: in-process SFSafariViewController presentation (external
  Safari suspends the app and kills the loopback redirect). Shipping — the
  OpenRouter card offers sign-in on iOS and the UITest asserts the button is
  present, so the "stays gated on manual verification" note here was stale.
  Verified on the iPad simulator 2026-08-06: the sheet presents in-process,
  loads the authorize page, and cancelling returns to Settings cleanly with
  no spurious error. **Still unverified: the loopback callback and token
  exchange**, which need a real account — see the exit gate below.
- [x] Hide the Local provider row on iOS (loopback Ollama is a dead end
  on-device; LAN host + ATS exception is a fast-follow)

### M8 — iPad experience
- [x] Size-class audit of `#if os(iOS)` branches (`os()` = capability,
  `horizontalSizeClass` = layout); iPad UITests (split view, double-page,
  hardware-keyboard page turns)
- [x] Pointer `.hoverEffect`s; arrow-key page turns via `.onKeyPress`
- [x] iPad screenshots in the `ci-screenshots` flow
- [ ] Deferred: multi-window / Stage Manager (macOS per-book WindowGroup is
  the template); iCloud sync (seam: `LibraryStore` behind
  `AppModel.makeDefaultStore()`)
- [ ] Deferred: macOS UI for the reader typography controls (font /
  line-spacing / justification live in the iOS Appearance popover; macOS
  renders the shared defaults but its inline toolbar has no pickers yet)
- [ ] Deferred (UX review, Jul 2026): unify sheet-header grammar (Ask /
  Article Studio / Notes / Settings each style their title+Done
  differently — one shared header component; touches UITest hooks so it
  needs its own pass); one typeface for AI output (ask answers are sans,
  composed articles serif); dedupe/label ask source chips; note-indicator
  underline parity across themes; PDF chrome parity with the EPUB reader
  toolbar

## M9 — Listen (text-to-speech)
- [x] `ReadrKit.Speech`: sentence segmentation, playlist across chapters,
  `NarrationController` over a `SpeechEngine` protocol — every playback rule
  unit-tested on Linux CI against a mock engine
- [x] `AVSpeechEngine` (Apple's on-device voices — offline, nothing to
  download, no egress), `NarrationModel`, and the reader's Listen bar
- [x] Controls: play/pause, sentence and chapter skip, speed, voice, sleep
  timer (timed + end-of-chapter), auto-advance
- [x] The page follows the voice, and the position it persists is where the
  reader listened to
- [x] iOS background audio: `UIBackgroundModes: audio`, Now Playing, and
  lock-screen/headphone remote commands
- [x] XCUITests over the bar (`-uiTestSilentNarration` keeps them off
  simulator audio)
- [ ] Deferred: highlighting the spoken sentence in the page itself (the
  reading surfaces cache their attributed string per page and rebuilding it
  each sentence would reset the reader's selection — it needs its own pass on
  `SelectableTextView`'s render cache)

## M10 — A better voice (Kokoro-82M), proposed

The "if" in the deferred note below has been answered. Apple's voices were
judged not good enough for long listening — poor enunciation and flat
modulation — so the neural voice moves from a contingency to a plan.
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) is the candidate:
82M parameters, Apache-2.0 weights, and several working Apple-silicon ports
(a Core ML pipeline reported at 4–4.5x realtime on A17 Pro; MLX Swift ports
around 3.3x on an iPhone 13 Pro, with memory-watchdog trouble on 4GB devices).

`SpeechEngine` is already the seam, so `NarrationController` and every
playback rule are untouched by this. What is *not* settled, and what a spike
has to answer before any engine code is written:

- [ ] **Phonemization licence — the blocker.** Kokoro's usual path is misaki →
  **espeak-ng, which is GPL-3.0**. Readr is MIT and ships on the App Store;
  linking it would relicense the app and walks into the familiar GPLv3/App
  Store conflict. (espeak-ng's own iOS app isolates it in a GPLv3 Audio Unit
  behind XPC to keep its front end MIT — a real pattern, but heavy for
  something on narration's critical path.) Is there a permissive G2P route,
  and **how bad is it on invented proper nouns**? A novel is full of names no
  dictionary has, which is precisely where a dictionary-plus-fallback scheme
  is weakest. If the answer is "espeak or nothing", the honest outcome is a
  macOS-only option, not an App Store feature.
- [ ] **Cost on device.** Realtime factor, memory on a 4GB phone, and battery
  and heat over a genuine hour of listening — 3–4.5x realtime means a
  sustained duty cycle, not a burst.
- [ ] **Word timings.** `willSpeak` drives read-along and resume-at-the-word
  after a speed change. Kokoro returns audio, not timings; its duration
  predictor makes them derivable in principle, but whether a port exposes them
  is unknown. If not, that behaviour degrades to sentence granularity.
- [ ] **Model delivery.** 80–330MB depending on quantization, so downloaded on
  demand rather than bundled — and the store copy's "nothing to download" line
  then holds only for the Apple-voice default.

Note what this *fixes* for free: Kokoro takes a speed input directly, so the
empirical AVFoundation rate calibration in `SpeechSettings` stops being
needed on that path.


## Open questions / decisions to revisit
- OAuth feasibility for "log in with Claude / ChatGPT" vs. API keys only.
- SwiftData vs. GRDB for persistence.
- Local LLM runtime: MLX vs. llama.cpp vs. Ollama bridge.
