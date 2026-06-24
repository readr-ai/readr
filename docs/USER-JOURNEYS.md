# User Journeys & Expected Behaviour

These are the canonical journeys Reader must satisfy. Each has acceptance
criteria in Given/When/Then form — they are the **specification we test
against** (see `docs/DEVELOPMENT-PLAN.md` for how). Each criterion is tagged
with the test layer that owns it: `[unit]`, `[integration]`, `[ui]`, `[manual]`.

---

## J1 — Add a book to the library
**As a reader, I want to import an EPUB or PDF so I can read it.**

- **Given** a DRM-free EPUB/PDF file, **when** I import it, **then** it appears
  in my library with title, author, and cover. `[integration]`
- **Given** a DRM-protected file, **when** I import it, **then** I get a clear
  "DRM-protected books aren't supported" message and nothing is added. `[unit]`
- **Given** a corrupted file, **when** I import it, **then** I get a friendly
  error and the app does not crash. `[unit]`
- **Expected:** import parses chapters + TOC and computes an estimated token
  count once, stored with the book. `[unit]`

## J2 — Read a book
**As a reader, I want a clean, paginated reading view.**

- **Given** an opened book, **when** I read, **then** text reflows to my font
  size and my position is remembered across launches. `[ui][manual]`
- **Given** I reopen the app, **when** I tap the book, **then** I resume exactly
  where I left off. `[integration]`

## J3 — Highlight & note
**As a reader, I want to highlight text and attach notes.**

- **Given** selected text, **when** I tap Highlight, **then** a persistent
  highlight is created anchored to that range. `[integration]`
- **Given** a highlight, **when** I add a note, **then** the note is saved and
  shown with the highlight. `[integration]`
- **Given** highlights exist, **when** I reopen the book, **then** they render in
  the right place. `[integration]`

## J4 — Ask the book (the core feature)
**As a reader, I want to select a sentence and ask a question, answered with full
book context, without leaving the page.**

- **Given** no provider configured, **when** I ask, **then** I'm guided to set up
  a provider first. `[unit][ui]`
- **Given** a small book + hosted provider, **when** I ask, **then** the router
  chooses **whole-book** context and I get a streamed answer. `[unit]`
- **Given** a very large book, **when** I ask, **then** the router chooses
  **retrieval** and the answer cites relevant passages. `[unit][integration]`
- **Given** any question, **then** the prompt always includes my selected
  sentence, its surrounding text, the chapter, and the book's TOC. `[unit]`
- **Given** the answer isn't in the book, **then** the model is instructed to say
  so rather than invent. `[manual]`
- **Expected:** answers stream token-by-token; a follow-up question reuses cached
  book context (Tier 1) without re-sending the whole book. `[integration]`

## J5 — Connect an LLM
**As a reader, I want to sign in with Claude/ChatGPT, paste a key, or use a local
model.** (See `docs/AUTH.md`.)

- **Given** I choose "sign in", **when** the browser OAuth (PKCE) completes,
  **then** tokens are saved to the Keychain and the provider is active. `[integration]`
- **Given** I paste an API key, **when** I save, **then** it's stored in the
  Keychain and validated with a test call. `[integration]`
- **Given** I pick a local model, **when** I ask a question, **then** **no**
  network request leaves the device. `[unit]`
- **Given** an expired OAuth token, **when** I ask, **then** it refreshes
  silently; if refresh fails I'm prompted to re-auth. `[unit]`

## J6 — Highlights → article
**As a reader, I want my highlights and notes auto-composed into an article.**

- **Given** ≥1 highlight, **when** I tap "Compose article", **then** I get an
  editable Markdown article that preserves my quotes in reading order. `[integration]`
- **Given** a composed article, **when** I edit and export, **then** I can save
  as Markdown/PDF or share it. `[ui][manual]`
- **Given** zero highlights, **when** I tap compose, **then** I'm told to
  highlight something first. `[unit]`

## J7 — Privacy
**As a privacy-conscious reader, I want a fully on-device mode.**

- **Given** local model + on-device embeddings, **when** I read, ask, and
  compose, **then** the network layer records zero outbound calls. `[unit][integration]`
- **Expected:** no telemetry is sent by default. `[unit]`

---

## Cross-cutting non-functional expectations
- **Performance:** ask-the-book first token < 3s on a hosted model for a typical
  book; index build for a 500-page book is backgrounded and non-blocking.
- **Resilience:** network failure during ask shows a retry, never loses the
  question.
- **Accessibility:** reader view supports Dynamic Type and VoiceOver.
