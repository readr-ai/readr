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
| **Unit** | Pure logic: context router, token estimate, OAuth/PKCE math, parsers, article composer prompt-building | `Tests/ReaderKitTests` | Linux + macOS CI (fast) |
| **Integration** | Components together with fakes: import→parse→index, ask→provider (mock LLM), Keychain store, retrieval over a fixture book | `Tests/ReaderKitTests` (tagged) | macOS CI |
| **UI** | SwiftUI flows in the app target | `ReaderAppUITests` | macOS CI (simulator) |
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
Repo, docs, `ReaderKit` skeleton, context-router unit tests, CI.

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
