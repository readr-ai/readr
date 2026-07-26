# Readr

[![CI](https://github.com/readr-ai/readr/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/readr-ai/readr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey.svg)](#architecture)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](Package.swift)

An AI-powered, native **macOS & iOS** ebook reader — think Apple Books, but you can
ask the book questions and turn your highlights into articles. Open source (MIT),
built for the love of reading.

![Readr: reading with highlights, and asking the book a question with cited sources](docs/screenshots/hero-reader-ask.png)

<p align="center">
  <a href="https://github.com/readr-ai/readr/releases/latest"><b>⬇️&nbsp;&nbsp;Download for macOS</b></a>
  &nbsp;·&nbsp;
  <a href="#ios--ipad-beta-testflight">iPhone &amp; iPad beta (TestFlight)</a>
  &nbsp;·&nbsp;
  <a href="#building-from-source">Build from source</a>
  &nbsp;·&nbsp;
  <a href="https://readr-ai.github.io/">Website</a>
</p>

> Status: **feature-complete core, pre-1.0.** All features below are implemented,
> unit/integration tested, and CI builds, signs, and ships the app: notarized
> macOS releases and iPhone/iPad TestFlight builds. CI runs the UI-test suite
> on iPhone **and iPad** simulators. Remaining pre-1.0 work is tracked in
> [docs/ROADMAP.md](docs/ROADMAP.md).

## Why

When you read, you have questions. Today you copy a sentence, paste it into
Claude/ChatGPT, and ask. Readr removes that loop: select text → ask → get an
answer grounded in **the whole book**, without leaving the page — your reading
stays uninterrupted. Your highlights and notes can also be auto-composed into
a shareable article.

## Features

- 📖 Native **EPUB**, PDF, and text/Markdown reading (DRM-free).
- 📄 **Three reading layouts**: continuous scroll, **single page**, or **two
  facing pages** like an open book — with page turns via buttons or arrow keys,
  reflowing on window resize (macOS).
- 🤖 **Ask the book**: select a sentence, ask a question, get a streamed answer
  with full book context and **source citations**.
- ✍️ **Highlights → article**: auto-compose your highlights and notes into an
  editable, exportable Markdown article (streams in live).
- 🔌 **Bring your own LLM**: paste an **Anthropic** or **OpenAI** API key, or
  run a **local LLM** (Ollama) fully offline.
- 🔒 Privacy-first: no telemetry or analytics code at all; local mode talks
  only to your local Ollama server; keys live only in the Keychain.

## Screenshots

| | |
|:---:|:---:|
| ![Dark mode and sepia paged reading](docs/screenshots/reader-dark-sepia.png) | ![Notes panel with Compose article, and the appearance sheet](docs/screenshots/notes-appearance.png) |
| Paged reading in dark and sepia themes | Highlights & notes with **Compose article**; themes and layouts |
| ![Library grid and AI provider settings](docs/screenshots/library-providers.png) | ![macOS library grid](docs/screenshots/mac-library.png) ![macOS notes panel](docs/screenshots/mac-notes-panel.png) |
| Your library; connect Claude, OpenAI, or a local model | The same library and notes panel, native on macOS |

## How book context works

Readr uses an **adaptive tiered strategy** — small books are sent whole (with
prompt caching), large books use hybrid contextual retrieval, and local mode
always stays on-device. Full rationale and citations in
[docs/CONTEXT-STRATEGY.md](docs/CONTEXT-STRATEGY.md).

## Architecture

- **SwiftUI** multiplatform app (iOS 17+ / macOS 14+).
- **`ReadrKit`** — platform-agnostic Swift Package with the core logic (parsing,
  context router, RAG, LLM providers, article composer).
- Custom EPUB/text parsing in `ReadrKit`; **PDFKit** for native PDF rendering
  and markup on device.
- In-memory hybrid retrieval (BM25 + on-device embeddings) built per book on
  open; SQLite persistence is on the roadmap.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Planning

- [docs/USER-JOURNEYS.md](docs/USER-JOURNEYS.md) — the spec: user journeys +
  expected behaviour, as testable acceptance criteria.
- [docs/DEVELOPMENT-PLAN.md](docs/DEVELOPMENT-PLAN.md) — test-first milestone
  plan (tests written before code, verified against journeys after).
- [docs/AUTH.md](docs/AUTH.md) — how BYO keys and local models work, plus the
  subscription-OAuth design (currently disabled pending end-to-end
  verification).
- [docs/CONTEXT-STRATEGY.md](docs/CONTEXT-STRATEGY.md) — the adaptive
  whole-book-vs-retrieval decision.
- [docs/ROADMAP.md](docs/ROADMAP.md) — milestone checklist.
- Launch & PR materials (Product Hunt kit, TestFlight plan, launch assets)
  live in [readr-ai/PR](https://github.com/readr-ai/PR).

## Installing (macOS)

Grab `Readr.app` from the
[latest GitHub Release](https://github.com/readr-ai/readr/releases/latest)
(built by CI). From **v2.9.0** releases are **Developer-ID signed and
notarized** — download, unzip, drag to Applications, open. No security
warnings.

(Releases *older* than v2.9.0 were unsigned and need a one-time
right-click → **Open**, or **System Settings → Privacy & Security → Open
Anyway** on macOS 15+.)

## iOS & iPad beta (TestFlight)

Readr for iPhone and iPad is in beta on TestFlight.

Join with one tap:
**[testflight.apple.com/join/U5dBEsSG](https://testflight.apple.com/join/U5dBEsSG)**
— install Apple's TestFlight app first, then open the link on your iPhone or
iPad. You can also [build from source](#building-from-source) with Xcode.

## Building from source

> Requires **macOS + Xcode 16+**. (The app cannot be built on Linux.)

```sh
brew install xcodegen
xcodegen generate      # produces Readr.xcodeproj from project.yml
open Readr.xcodeproj   # run the "Readr" scheme (macOS or iOS)
```

The core package alone builds anywhere Swift runs:

```sh
swift build
swift test
```

## Contributing

This is an open-source project — contributions welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
Privacy: Readr collects nothing — see [PRIVACY.md](PRIVACY.md).
