# Architecture

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│  ReadrApp (SwiftUI, iOS + macOS)                            │
│  Library · Reader view · Ask panel · Notes · Article editor  │
└───────────────▲─────────────────────────────────────────────┘
                │ depends on
┌───────────────┴─────────────────────────────────────────────┐
│  ReadrKit (Swift Package, platform-agnostic, testable)      │
│                                                              │
│  Reader   ── BookParser (EPUB/PDF) ──▶ Book model            │
│  Context  ── ContextStrategy (Tier 1/2/3 router)            │
│  RAG      ── RAGIndex (sqlite-vec + FTS5, rerank)            │
│  LLM      ── LLMProvider (on-device: Apple, MLX / cloud)     │
│  Article  ── ArticleComposer (highlights+notes → Markdown)   │
│  Speech   ── NarrationController (segments → SpeechEngine)   │
│  Models   ── Book, Chapter, Highlight, Note, Conversation    │
└──────────────────────────────────────────────────────────────┘
```

The app talks only to `ReadrKit` protocols. Every external dependency (rendering
engine, LLM vendor, embedding model, vector store) sits behind a protocol so it
can be swapped or mocked.

## Key protocols

| Protocol | Responsibility | Default impl |
|----------|----------------|--------------|
| `BookParser` | Turn an EPUB/PDF/text file into a `Book` (chapters, text, TOC, metadata) | Native: `PlainTextBookParser`, `EPUBBookParser` (+ZIPFoundation), `PDFKitBookParser` |
| `LLMProvider` | Chat completion + streaming + token counting | Apple on-device (FoundationModels) and downloaded models (Qwen3.5 on MLX), both app layer / Anthropic / OpenAI / OpenRouter / ChatGPT / Local (Ollama) |
| `EmbeddingProvider` | Text → vectors | Hosted or on-device (MLX) |
| `RAGIndex` | Build/query the hybrid index for a book | SQLite (`sqlite-vec` + FTS5) |
| `ContextStrategy` | Assemble the optimal prompt context for a query | `AdaptiveContextStrategy` |
| `ArticleComposer` | Compose highlights + notes into an article | LLM-backed |
| `SpeechEngine` | Speak one utterance; report boundaries and completion | `AVSpeechEngine` (AVFoundation, on-device) |

## Rendering

[Readium Swift toolkit](https://github.com/readium/swift-toolkit) provides EPUB +
PDF navigation, pagination, and **decoration** APIs for highlights. We wrap it
behind `BookRenderer` so the UI is insulated from Readium specifics.

## Read-aloud

`SpeechSegmenter` splits chapter text into sentence-sized `SpeechSegment`s
addressed by character offsets into `Chapter.text` — the same coordinates
highlights use — and `SpeechPlaylist` walks them across chapters in reading
order. `NarrationController` owns every playback rule (skip, speed and voice
changes applied mid-sentence, sleep timer, auto-advance, the cancelled-utterance
race) and drives a `SpeechEngine`. All of it is pure and unit-tested on Linux
CI; only the synthesizer itself lives in the app target.

Apple's `AVSpeechSynthesizer` is the default engine: it is on-device, so
listening keeps the same zero-egress promise as reading, and it needs no
account or download. A neural on-device voice can replace it behind the same
protocol.

## Persistence

- **Library & annotations:** local DB (SwiftData or GRDB — TBD), synced via
  iCloud later.
- **RAG index:** one SQLite file per book under app support, rebuilt on demand.
- **Secrets:** API keys in the **Keychain**, never on disk in plaintext.

## Security & privacy

- Local-LLM + on-device embeddings = zero network egress mode.
- Hosted providers only ever receive the assembled context for the active query.
- No telemetry by default.

## Why a separate package?

`ReadrKit` builds and tests on any Swift platform (including Linux CI), so the
business logic is unit-testable without a simulator. The app target is a thin
SwiftUI shell.
