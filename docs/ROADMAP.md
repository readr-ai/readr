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

## Open questions / decisions to revisit
- OAuth feasibility for "log in with Claude / ChatGPT" vs. API keys only.
- SwiftData vs. GRDB for persistence.
- Local LLM runtime: MLX vs. llama.cpp vs. Ollama bridge.
