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
- [x] On this device: Apple's on-device model (FoundationModels, iOS/macOS 26)
      as a zero-setup provider, default until the reader chooses one
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
- [x] macOS reader typography controls — the macOS bar now carries the
  same Aa popover as iOS (September 2026 UX review, F3)
- [x] Sheet-header grammar unified (Ask / Article ✦ caps, Done on the
  right, one note editor — F4). Still deferred from the Jul 2026 review:
  one typeface for AI output (ask answers are sans, composed articles
  serif); dedupe/label ask source chips; note-indicator underline parity
  across themes; PDF chrome parity with the EPUB reader toolbar

## M9 — Listen (text-to-speech)
- [x] `ReadrKit.Speech`: sentence segmentation, playlist across chapters,
  `NarrationController` over a `SpeechEngine` protocol — every playback rule
  unit-tested on Linux CI against a mock engine
- [x] `AVSpeechEngine` (Apple's on-device voices — offline, nothing to
  download, no egress), `NarrationModel`, and the reader's Listen bar
- [x] Controls: play/pause, sentence skip, speed, sleep timer (timed +
  end-of-chapter), auto-advance. *September 2026 (UX review, F6): the bar
  became a now-reading card — chapter in caps, the sentence, a progress
  hairline, ◀ ● ▶ with speed and Sleep; the voice is chosen in the Aa
  popover, chapter skips live in Contents, and the "N min ready" figure is
  gone. Ask opened while listening pauses the voice and is about the
  sentence being read; it resumes when Ask goes away.*
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
playback rule are untouched by this.

**A spike ran on 2026-08-17** (reported on
[#78](https://github.com/readr-ai/readr/pull/78)) and answered three of the
four questions below. Its own summary: *the licence blocker is cleared, but not
the way this plan assumed — and the premise is still unproven, because nobody
has listened yet.*

- [x] **Phonemization licence — was the blocker.** Confirmed dead as originally
  planned: misaki pulls `libespeak-ng.dylib` and `phonemizer-fork`, a hard
  GPL-3.0 dependency, and **misaki without espeak does not degrade — it drops
  words silently.** Measured over 400 Moby-Dick sentences: 1.62% of words
  emitted a placeholder token rather than phonemes, which is only 63 distinct
  words but lands in **24% of sentences**. Worse where it was predicted to be
  worst — 16 of 17 invented proper nouns failed outright (Queequeg, Pequod,
  Ahab, Fedallah, Cthulhu, Daenerys, Raskolnikov, Nynaeve, Galadriel,
  Voldemort, Arrakis, Kvothe; only Bilbo survived). A reader would hear the
  protagonist's name omitted, every time. Unshippable, not "slightly off".

  The way through is a **neural G2P instead of a dictionary**: FluidAudio's
  Apache-2.0 Core ML BART encoder–decoder (~1.6MB) replaces espeak entirely and
  produced plausible phonemes for those names with no silent drops. One
  question survives for a human, not an engineer: the model was trained on
  espeak-ng output, and whether that makes it a derivative work is a **legal
  question we should get answered before building on it**.
- [x] **Cost on device.** Measured on an M5 Pro with FluidAudio (Apache-2.0,
  no external dependencies, the only candidate both actively maintained and
  permissively licensed): 31.7× realtime aggregate, time-to-first-audio
  117–217ms typical and 746ms at p95, 527MB peak RSS, 104MB on disk at the
  smallest variant. The latency number is the one that matters — pressing
  Listen would wait about a fifth of a second where AVFoundation waits 11–15ms.
  Survivable, but it is a real difference and the vocoder is ~63% of it.
  **Phone numbers are still unknown** (no paired device), and there is an
  unfixed iOS BNNS crash in the port (FluidAudio#844) that would have to be
  understood first.
- [x] **Word timings.** Better than what we have, not worse: FluidAudio exposes
  `predictedDurations` per token at 25.000ms/frame, so timings are known
  *before* playback rather than arriving during it. Mapping them back to
  character ranges means preserving word boundaries through the phonemizer —
  real work, but not a degradation.
- [x] **Model delivery.** 104–325MB depending on quantization, so downloaded on
  demand rather than bundled. *v3.2.0: the fetch is automatic on the first
  English-book Listen (Readr Voice is the default), with the platform voice
  reading until it lands — so the "nothing to download" store line was retired
  and PRIVACY.md now discloses the one fixed-CDN model fetch. Still open:
  metered-connection gating (defer the automatic fetch on expensive/constrained
  networks).*
- [x] **Is it actually better? — answered 2026-08-20: yes, decisively.** The
  spike's A/B files were never actually attached to the PR; the pair was
  regenerated (same sentences, compact Apple voice vs FluidAudio Kokoro) and
  judged by ear: **"Kokoro wins hands down."**

**Wired 2026-08-20** as an opt-in voice — "Readr Voice (Beta)" in the Listen
bar's picker, English books only, never auto-selected. `KokoroSpeechEngine`
implements the `SpeechEngine` protocol (whole-sentence synthesis →
`AVAudioPlayer`; reports `.speaking` through the synthesis/download gap so the
silent-engine watchdog holds off); `RoutingSpeechEngine` routes each request
to Kokoro or `AVSpeechSynthesizer` by voice id, so `NarrationController` and
every playback rule are untouched. Verified in the iOS simulator: model
download on selection, mid-sentence voice switch, sequential sentences,
chapter crossing, pause/resume, book end.

Still open before this rides a release (tracked here deliberately — the
wiring does not close them):

- [x] **Legal read on the G2P model** — closed 2026-08-20 by the project owner:
  determined no legal issue with shipping the espeak-trained G2P.
- [x] **The iOS BNNS crash** (FluidAudio#817/#844) — sidestepped rather than
  fixed. FluidAudio#844 was closed upstream as completed on 2026-08-11, but
  late comments still report crashes. The CoreML engine stays hard-gated off
  on macOS 26.4–26.5, where Kokoro inference can crash inside Apple's
  `libBNNS`, and is never built on iOS at all. *v3.3.0: on iPhone and iPad
  Readr Voice runs on **MLX** instead — the same Kokoro-82M on the Metal GPU
  (`MLXKokoroSpeechEngine`, Blaizzy/mlx-audio-swift pinned to `d20cbd6`,
  mlx-swift 0.31.6, weights `mlx-community/Kokoro-82M-bf16`), which never
  enters BNNS; iOS is MLX-or-platform. CoreML remains the macOS runtime.
  `NarrationEnginePolicy` (ReadrKit, table-tested) picks the engine per
  sentence. Decision memo: `docs/research/MLX-KOKORO-IOS.md`.*
- [ ] **FluidAudio pin.** No FluidAudio tag newer than 0.15.6 exists; bump the
  pin when one lands.
- [ ] **A CoreML line on iOS again?** Re-enable a CoreML line only after
  FluidAudio#844's crash signature no longer reproduces on a device build —
  and only if MLX turns out to need it; today iOS has one runtime on purpose.
- [ ] **Next: the MLX background limitation.** Metal refuses GPU work from a
  backgrounded app, and MLX surfaces the refusal as a C++ exception in
  Metal's completion handler — an uncatchable abort (mlx-swift#274/#407). So
  the MLX engine never starts GPU work while the app is backgrounded (from
  `didEnterBackground` to `willEnterForeground`, plus a 1.5s head start on
  `willResignActive` for the lock; Control Center, banners and an iPad Split
  View neighbour do not count): with the screen locked an Apple voice reads,
  and Readr Voice returns at the next sentence when the reader comes back
  (the voice menu says so). A synthesis already in flight at the moment of
  the lock is the residual risk — well under a second per sentence, but not
  zero. Closing this means synthesizing ahead in the foreground and
  buffering a few sentences of audio, or iOS 26's background-GPU
  continued-processing task (a separate entitlement); either way, measure on
  a device first — the phone numbers below are still open.
- [ ] **Phone-device numbers** (latency/memory/battery) — still unmeasured.
- [ ] **Word timings** — `predictedDurations` gives exact token timestamps;
  mapping tokens back to character ranges (for read-along highlighting and
  precise mid-sentence resume) is the remaining work. Until then the Kokoro
  path follows per sentence, not per word.
- [x] **Download UX** — v3.2.0: narration starts instantly through the
  platform voice, the model downloads in the background, the switch happens at
  a sentence boundary, and the voice menu shows downloading/failed states.
  Still open: a percentage (FluidAudio exposes no download progress callback
  at 0.15.6).

Note what this *fixes* for free: Kokoro takes a speed input directly, so the
empirical AVFoundation rate calibration in `SpeechSettings` stops being
needed on that path.


## A1–A8 — Android (in progress)

Scope, measurements and the decision record are in the private Android
scoping note (2026-09-06; `docs/research/` is untracked by design). Same kit, Kotlin + Compose UI, swift-java
bridge; `android/README.md` has the build recipe.

### A1 — Foundation
- [x] `android/` Gradle project; `:readrkit` cross-compiles `ReadrKit` + the
  `ReadrAndroid` facade for arm64/x86_64 and packages the Swift runtime
- [x] Keystore-backed `SecretStore` implementing the kit's `CredentialStore`
  (AES-GCM, key in the Android Keystore, never plaintext on disk)
- [x] Library: import EPUB (Kotlin unzips with the kit's caps, kit parses) and
  plain text, sample book seeded on first launch, covers, reading position
- [x] Marginalia theme in Compose; shelf; a scrolling chapter view as the
  phase-1 reading surface
- [x] CI lane: kit XCTest suite on an x86_64 emulator + instrumented tests
- [ ] Play Console account, closed-test track

### Next
- A2 Reading: paginated surface over `Chapter.text` (selection, highlights,
  notes, bookmarks, TOC, search, appearance)
- A3 Ask: provider settings, streamed Ask with citations, Gemini Nano tier
- A4 Listen: platform `TextToSpeech` engine, media session, Listen card
- A5 PDF, A6 Readr Voice (research: CPU Kokoro measured marginal), A7 article
  studio + bug report, A8 Play production

## Open questions / decisions to revisit
- OAuth feasibility for "log in with Claude / ChatGPT" vs. API keys only.
- SwiftData vs. GRDB for persistence.
- Local LLM runtime: MLX vs. llama.cpp vs. Ollama bridge.
