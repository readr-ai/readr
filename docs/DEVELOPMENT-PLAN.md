# Implementation & Development Plan

This plan is **test-first**. For every milestone we (1) write the acceptance
tests from the user journeys *before* coding, (2) implement until they pass, and
(3) verify against the journeys *after*, including manual UI passes. The user
journeys in [USER-JOURNEYS.md](USER-JOURNEYS.md) are the spec; this document is
how we build and prove them.

## Methodology

**ATDD + TDD.** Each journey's Given/When/Then criteria become executable tests
before implementation. Work is not "done" until its tests are green **and** the
manual journey has been walked.

**Test pyramid:**

| Layer | Scope | Where | Runs on |
|-------|-------|-------|---------|
| **Unit** | Pure logic: context router, token estimate, OAuth/PKCE math, parsers, article composer prompt-building | `Tests/ReadrKitTests` | Linux + macOS CI (fast) |
| **Integration** | Components together with fakes: import→parse→index, ask→provider (mock LLM), Keychain store, retrieval over a fixture book | `Tests/ReadrKitTests` (tagged) | macOS CI |
| **UI** | SwiftUI flows in the app target | `ReadrAppUITests` | macOS CI (simulator) |
| **Manual** | Real providers, real books, feel & performance | checklist per release | local Mac |

**Test doubles (no live network in automated tests):**
- `MockLLMProvider` — scripted streamed responses + token counts.
- `FakeCredentialStore` — in-memory Keychain.
- `InMemoryRAGIndex` — deterministic retrieval over fixtures.
- `FixtureBookParser` — loads small committed EPUB/PDF samples.
- A **network sentinel** that fails any test in "local mode" if an outbound
  request is attempted (enforces J7).

**Definition of Done (per milestone):** acceptance tests written first and green;
unit coverage on new core logic; integration test for the happy path + one
failure path; manual journey walked and checked off; docs updated; CI green.

**Gates:** CI must pass `swift build` + `swift test` on every PR. UI/manual gates
apply to app-target milestones.

---

## Milestones

Each milestone lists the journeys it satisfies, the **tests written first**, the
build tasks, and the exit gate.

### M0 — Foundation ✅ (done)
Repo, docs, `ReadrKit` skeleton, context-router unit tests, CI.

### M1 — Library & reading — *J1, J2, J3*
**Tests first:**
- `[unit]` parser rejects DRM + corrupted files; computes token estimate.
- `[integration]` import fixture EPUB & PDF → `Book` with chapters/TOC.
- `[integration]` highlight persists and reloads at correct range.
- `[ui]` import → library → open → resume position.

**Build:** XcodeGen `project.yml` + SwiftUI app shell; Readium-backed
`BookParser` + `BookRenderer`; persistence (SwiftData/GRDB decision); library &
reader views; highlight/note capture.

**Exit:** a book can be imported, read, highlighted; positions/highlights survive
relaunch; all M1 tests green; manual J1–J3 walked.

### M2 — Connect an LLM — *J5*
**Tests first:**
- `[unit]` PKCE verifier/challenge (S256) correctness; `state` validation;
  token-refresh decision logic.
- `[integration]` OAuth flow against a **mock auth server** (loopback) → tokens
  in `FakeCredentialStore`.
- `[integration]` API-key save → validation call (mock) → active provider.
- `[unit]` local provider selected ⇒ network sentinel sees zero calls.

**Build:** `AuthProvider` (`OpenAIOAuthProvider`, `AnthropicOAuthProvider`,
`APIKeyProvider`), Keychain `CredentialStore`, loopback callback server, provider
settings UI, provider switcher. See [AUTH.md](AUTH.md).

**Exit:** all three connection modes work; secrets only in Keychain; refresh
handled; manual J5 walked with at least one real provider.

### M3 — Ask the book — *J4* (+ depends on M1, M2)
**Tests first:**
- `[unit]` router picks whole-book vs retrieval vs local (extend existing tests).
- `[unit]` assembled prompt always contains selection + chapter + TOC anchor.
- `[integration]` ask over fixture book with `MockLLMProvider` → streamed answer;
  follow-up reuses cached prefix (no full re-send).
- `[integration]` large-book path retrieves & cites passages.

**Build:** wire `AdaptiveContextStrategy` to real providers; RAG index
implementation (SQLite `sqlite-vec` + FTS5, contextual chunking, rerank);
on-device embeddings for local mode; select-text → Ask panel UI with streaming.

**Exit:** select → ask → grounded streamed answer on small **and** large books,
hosted **and** local; J4 tests green; manual J4 walked.

### M4 — Highlights → article — *J6*
**Tests first:**
- `[unit]` zero-highlights ⇒ guidance, no call.
- `[integration]` highlights+notes → `MockLLMProvider` → Markdown article in
  reading order, quotes preserved.
- `[ui]` compose → edit → export Markdown/PDF/share.

**Build:** `LLMArticleComposer` wired to providers; article editor UI; export.

**Exit:** highlights compose into an editable, exportable article; J6 green;
manual J6 walked.

### M5 — Privacy hardening & polish — *J7 + cross-cutting*
**Tests first:**
- `[integration]` full read→ask→compose in local mode ⇒ network sentinel zero.
- `[unit]` no telemetry emitted by default.

**Build:** zero-egress audit, accessibility (Dynamic Type, VoiceOver),
localization scaffolding, iCloud sync of library/annotations, performance pass
(first-token latency, background indexing).

**Exit:** J7 proven by test; accessibility & performance checklists pass.

### M6 — iPhone & iPad: signed builds + TestFlight pipeline
The iOS UI already exists (the app target is multiplatform and CI runs the
XCUITest suite on an iPhone simulator); this milestone makes it *shippable*.

**Tests first:**
- `[ui]` provider settings offers no OAuth sign-in button (subscription OAuth
  is not beta-ready — see SettingsModel.oauthConfig; M7 flips this test).
- `[ci]` iPad-simulator UITest lane (same suite, regular-width code paths) and
  a `generic/platform=iOS` device-SDK build on every PR.

**Build:** `project.yml` iOS release config (`info:` plist block with
export-compliance/orientations, `TARGETED_DEVICE_FAMILY`, automatic signing —
team ID never in the repo, CI injects it); `.github/workflows/testflight.yml`
(cloud signing via App Store Connect API key, `-exportArchive
destination:upload`); docs.

**Exit:** a tag/dispatch lands a build in TestFlight internal testing that
installs on a physical iPhone and iPad; import EPUB+PDF, read, highlight, and
BYOK ask-the-book all work on device; CI green including the new lanes.

### M7 — iOS platform correctness: Files-app integration + OAuth
**Tests first:**
- `[ui]` `-uiTestOpenURL <fixture>` launch argument drives the `onOpenURL`
  import path ⇒ book appears on the shelf.
- `[ui]` M6's no-OAuth test flips: the sign-in button is present again.

**Build:** `CFBundleDocumentTypes` + `LSSupportsOpeningDocumentsInPlace`
(register as an EPUB/PDF handler in the Files app); `.onOpenURL` import in
`ReadrApp`; OAuth on iOS via in-process `SFSafariViewController` (external
Safari suspends the app, killing the loopback redirect — the server and
`ReadrKit` auth stay unchanged); hide the Local provider row on iOS (loopback
Ollama is a dead end on-device).

**Exit:** tapping an EPUB in Files/Mail imports into Readr on device; OAuth
sign-in completes without leaving the app; UITests green on both simulators.

### M8 — iPad experience
**Tests first (iPad simulator):**
- `[ui]` sidebar and detail visible side by side in regular width.
- `[ui]` reader offers double-page mode on iPad.
- `[ui]` hardware-keyboard arrow keys turn pages.

**Build:** audit `#if os(iOS)` branches — `os()` for platform capability,
`horizontalSizeClass` for layout; arrow-key page turns (`.onKeyPress`);
pointer `.hoverEffect` on custom controls; iPad screenshots in the
`ci-screenshots` flow. Multi-window/Stage Manager deliberately deferred
(the macOS per-book `WindowGroup` is the template when it lands).

**Exit:** iPad TestFlight build walks J1–J6 in both orientations and Split
View; iPad UITest lane green.

### M9 — Listen (text-to-speech) — *J8*
**Tests first:**
- `[unit]` sentence segmentation: abbreviations/initials/decimals are not
  sentence ends; image placeholders and scene-break rules are never spoken;
  every segment's range addresses its chapter text exactly.
- `[unit]` playlist: "read from here" lands on the sentence at the offset;
  continuous playback skips `linear="no"` documents; chapter walls in both
  directions.
- `[unit]` every control against a mock engine: play/pause/stop, sentence and
  chapter skips, the cancelled-utterance race, mid-sentence speed and voice
  changes resuming at the word reached, sleep timer (timed + end-of-chapter,
  and pausing not burning it), auto-advance off, engine failure.
- `[ui]` Listen starts narration from the visible page, the bar carries every
  control, each is operable, closing it ends narration
  (`-uiTestSilentNarration` swaps in a soundless engine, so nothing depends on
  simulator audio).

**Build:** `ReadrKit.Speech` (`SpeechSegmenter`, `SpeechPlaylist`,
`SpeechSettings`, `VoiceSelector`, `SleepTimerState`, `NarrationController`
over a `SpeechEngine` protocol); `AVSpeechEngine` + `NarrationModel` +
`ListenBar` in the app; `UIBackgroundModes: audio` and Now Playing / remote
commands for lock-screen listening on iOS.

**Exit:** a book reads aloud from the visible page with the page following the
voice; all M9 tests green; manual J8 walked on device with the screen locked.

---

## Risk register
- **OAuth ToS** for consumer subscriptions — mitigate by defaulting to BYOK and
  labeling OAuth as opt-in (see AUTH.md). Endpoints/client-ids may change →
  covered by integration tests against a mock + a manual smoke test.
- **PDF text extraction quality** — worse than EPUB; fixture tests catch
  regressions, retrieval anchors reduce impact.
- **Large-book indexing cost/time** — background + cache; measure in M5.
- **Local embedding quality** — keep `EmbeddingProvider` swappable; benchmark.

## Tracking
Milestones map to GitHub issues/labels; each journey acceptance criterion becomes
a checklist item on its milestone. CI is the gate; no merge on red.
