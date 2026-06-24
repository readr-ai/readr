# Reader

An AI-powered, native **iOS & macOS** ebook reader — think Apple Books, but you can
ask the book questions and turn your highlights into articles.

> Status: **early scaffolding.** This repo currently contains the architecture,
> the context-strategy research, and the core `ReaderKit` package skeleton.
> The app is not yet buildable end-to-end. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Why

When you read, you have questions. Today you copy a sentence, paste it into
Claude/ChatGPT, and ask. Reader removes that loop: select text → ask → get an
answer grounded in **the whole book**, without leaving the page. Your highlights
and notes can also be auto-composed into a shareable article.

## Features (target)

- 📖 Native EPUB + PDF reading (DRM-free) with a clean, Apple-Books-like UI.
- 🤖 **Ask the book**: select a sentence, ask a question, get an answer with full
  book context.
- ✍️ **Highlights → article**: auto-compose your highlights and notes into an
  editable, exportable article.
- 🔌 **Bring your own LLM**: log in / paste a key for **Claude** or **OpenAI
  (Codex/ChatGPT)**, or run a **local LLM** fully offline.
- 🔒 Privacy-first: local-LLM mode keeps everything on device.

## How book context works

Reader uses an **adaptive tiered strategy** — small books are sent whole (with
prompt caching), large books use hybrid contextual retrieval, and local mode
always stays on-device. Full rationale and citations in
[docs/CONTEXT-STRATEGY.md](docs/CONTEXT-STRATEGY.md).

## Architecture

- **SwiftUI** multiplatform app (iOS 17+ / macOS 14+).
- **`ReaderKit`** — platform-agnostic Swift Package with the core logic (parsing,
  context router, RAG, LLM providers, article composer).
- **Readium Swift toolkit** for EPUB/PDF rendering & annotations.
- **SQLite** (`sqlite-vec` + FTS5) for the on-device RAG index.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Planning

- [docs/USER-JOURNEYS.md](docs/USER-JOURNEYS.md) — the spec: user journeys +
  expected behaviour, as testable acceptance criteria.
- [docs/DEVELOPMENT-PLAN.md](docs/DEVELOPMENT-PLAN.md) — test-first milestone
  plan (tests written before code, verified against journeys after).
- [docs/AUTH.md](docs/AUTH.md) — how "sign in with Claude/ChatGPT", BYO key, and
  local models work (OAuth+PKCE, modeled on Muesli).
- [docs/CONTEXT-STRATEGY.md](docs/CONTEXT-STRATEGY.md) — the adaptive
  whole-book-vs-retrieval decision.
- [docs/ROADMAP.md](docs/ROADMAP.md) — milestone checklist.

## Building

> Requires **macOS + Xcode 15+**. (The app cannot be built on Linux.)

```sh
brew install xcodegen
xcodegen generate      # produces Reader.xcodeproj from project.yml
open Reader.xcodeproj
```

The core package alone builds anywhere Swift runs:

```sh
swift build
swift test
```

## Contributing

This is an open-source project — contributions welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
