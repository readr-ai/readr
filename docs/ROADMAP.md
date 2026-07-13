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
- [ ] SQLite (sqlite-vec + FTS5) persistence for the index (currently in-memory)
- [ ] Citations surfaced in the Ask panel; manual J4 walk on a Mac

## M4 — Highlights → article (in progress)
- [x] Order highlights by reading position; zero-highlights guidance (no LLM call)
- [x] `LLMArticleComposer` → article (tested)
- [x] Compose UI: highlights → editable Markdown editor, ShareLink export
- [ ] PDF export (Markdown share shipped; PDF is a follow-up)
- [ ] Streamed composition in the editor; manual J6 walk on a Mac

## M5 — Privacy hardening & polish (in progress)
- [x] J7 zero-egress audit: on-device pipeline needs no network; local provider
  only contacts loopback; no telemetry by default (`PrivacyAuditTests`)
- [x] Accessibility: VoiceOver labels on icon controls; Dynamic Type in the reader
- [x] Background indexing: build the RAG index on book open (faster first ask)
- [x] Citations surfaced in the Ask panel; streamed article composition
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
- [ ] Sidebar shell: Home (Continue Reading), library shelves, Highlights & Notes
- [ ] Reader chrome: TOC, bookmarks, in-book search, appearance popover,
  time-left-in-chapter, per-book windows on macOS
- [ ] Selection popover annotation (5 colors, note, ask, copy) — one gesture
- [ ] Native PDF annotation (overlay highlights, outline TOC, thumbnails, search)
- [ ] Notes panel (inspector) + Markdown export + Article studio
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
- [ ] Exit gate: TestFlight install verified on a physical iPhone and iPad
  (import, read, highlight, BYOK ask)

### M7 — iOS platform correctness
- [x] Files-app handler: `CFBundleDocumentTypes` + open-in-place +
  `.onOpenURL` import (UITest via `-uiTestOpenURL` fixture)
- [x] OAuth on iOS: in-process SFSafariViewController presentation (external
  Safari suspends the app and kills the loopback redirect) — plumbing landed;
  re-enabling `supportsOAuth` (and flipping the M6 UITest) stays gated on a
  manual on-device verification of the flow
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

## Open questions / decisions to revisit
- OAuth feasibility for "log in with Claude / ChatGPT" vs. API keys only.
- SwiftData vs. GRDB for persistence.
- Local LLM runtime: MLX vs. llama.cpp vs. Ollama bridge.
