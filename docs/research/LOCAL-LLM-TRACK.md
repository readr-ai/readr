# Research: Bundling a Local LLM with Readr

> Status: research note (no code changes). Date: 2026-07-22.
> Method: codebase analysis + multi-source web research with adversarial claim
> verification (23 sources fetched, 115 claims extracted, top 25 verified by
> 3-vote panels: 21 confirmed, 4 refuted). Claims are labeled **[verified]**
> (survived adversarial verification) or **[unverified]** (extracted from
> sources but not put through the verification panel — treat as directional).

## 0. TL;DR / Recommendation

Ship local AI in two stages, because the two halves have wildly different costs:

1. **Embeddings first (cheap, high value).** Replace the FNV-1a hashing stub with
   a real on-device embedding model. This costs ~35–200 MB and ~70–200 MB RAM —
   negligible — and directly improves retrieval quality for *every* provider,
   cloud or local. Candidates: **bge-small via Apple's MLXEmbedders** (~130 MB RAM),
   **EmbeddingGemma** (308M params, <200 MB RAM quantized, needs llama.cpp/MLX
   directly since MLXEmbedders doesn't support the Gemma architecture), or
   **NLContextualEmbedding** (built into iOS 17/macOS 14, zero app-size cost,
   unproven retrieval quality).
2. **Generation second (expensive, gate it).** Use **MLX Swift** as the runtime,
   a ~3–4B 4-bit model (~2.2–2.9 GB on disk, ~3.2 GB RAM at runtime) delivered
   **post-install via the Background Assets framework** (never bundled in the
   binary, never On-Demand Resources). Restrict to Macs + iPhones/iPads with
   ≥8 GB RAM and add the increased-memory-limit entitlement. On iOS/macOS 26+
   devices, **Apple's Foundation Models framework** is a free (zero-download)
   additional provider worth wiring up, but its 4,096-token combined limit makes
   it a constrained one.

Honest counterpoint: a 4B model will answer grounded Tier-2 questions acceptably,
but **article composition quality will be visibly below cloud Opus/GPT**. The
pragmatic v1 posture is: local = embeddings + ask-the-book; article studio stays
cloud-first with local as an explicit "private mode" the user opts into knowing
the tradeoff.

## 1. What this track is (and isn't)

Readr already has a "Local" provider — but it is a **loopback Ollama client**
(`Sources/ReadrKit/LLM/Providers/LocalLLMProvider.swift`, `http://127.0.0.1:11434`).
It requires the user to install and run Ollama, works only on macOS, and is
already flagged in `docs/DEVELOPMENT-PLAN.md` (M7) as a dead end on iOS. The
research also confirms Ollama can never be the shipped runtime: App Store apps
cannot ship a separate daemon process, and Ollama has no iOS runtime at all
**[verified]**.

This track is different: **ship an inference runtime + model weights inside (or
downloaded by) the app**, so local AI works out of the box on both platforms with
zero setup and zero network egress. The Ollama provider can remain a macOS
power-user option.

Three workloads must be served:

| Workload | Today | What the bundled model must do |
|---|---|---|
| Ask-the-book Q&A | `AskService` + `AdaptiveContextStrategy` Tier 2 (8 retrieved passages + anchor) | Grounded answering over ~2–6K tokens of context, streaming |
| Highlights → article | `LLMArticleComposer.composeStreaming` | Longer-form coherent writing (1–2K output tokens) |
| Embeddings for retrieval | `LocalEmbeddingProvider` (FNV-1a hashing stub, 256 dims) | Real semantic embeddings; `docs/ARCHITECTURE.md:33` already earmarks MLX |

## 2. How it plugs into the existing architecture

The abstraction already fits — nothing in the protocol surface assumes a server:

- `LLMProvider` (`Sources/ReadrKit/LLM/LLMProvider.swift`): `stream(_:) -> AsyncThrowingStream<ChatChunk, Error>`, `countTokens`, `ProviderInfo(contextBudget:isLocal:)`. A `BundledLLMProvider` is a fourth `ProviderInfo.Kind` (or a `.local` variant).
- `AdaptiveContextStrategy` already routes local/small-context providers to Tier 2 retrieval — a bundled model with an 8K–32K budget automatically gets the retrieval path, never whole-book stuffing. No strategy changes needed.
- `EmbeddingProvider` (`Sources/ReadrKit/RAG/RAGIndex.swift`) is the swap point for a real embedding model; `HybridRAGIndex` and `Chunker` are dimension-agnostic.
- `LocalReadinessProbing` maps cleanly onto the new states: weights not downloaded / downloading / loaded / ready.

Structural constraint: the inference runtime (MLX Swift, Foundation Models, etc.)
is an Apple-platform dependency, so per CLAUDE.md it lives in `App/` behind
`ReadrKit` protocols — the `PDFKitBookParser` pattern. `ReadrKit` gets the
provider contract + tests against a fake; the app target gets the real runtime.
New moving part with no current analogue: a **weights lifecycle manager**
(download via Background Assets, verify, load/unload on memory pressure).

## 3. Runtime options

| Runtime | Verdict | Key facts |
|---|---|---|
| **MLX Swift** (Apple ml-explore) | **Default choice** | Fastest general-purpose decode on Apple Silicon: 61 tok/s vs 39 (llama.cpp) vs 28 (CoreML/ANE) on iPhone 17 Pro, Qwen 2B 4-bit; leads llama.cpp by ~20–87% for <14B models **[verified, medium confidence — single-author benchmark]**. Swift-native, active Apple org, ~13K compatible models. Ollama itself moved to an MLX backend in 2026 **[unverified]**. |
| **CoreML / ANE** | Niche: sustained generation | Under 10-min sustained load, ANE retains 67% of burst speed vs MLX-GPU's 38% — the ranking *inverts* for long jobs like article composition **[verified]**. Also far better power draw (~12.7 W vs ~24.7 W) **[unverified]**. But conversion pipeline friction is high and per-model. |
| **llama.cpp** | Fallback / ecosystem breadth | Slower decode than MLX on Apple Silicon but broadest model support (GGUF arrives days-weeks before MLX conversions) **[unverified]**. Proven App Store viability via PocketPal AI, LLM Farm **[unverified]**. |
| **Apple Foundation Models framework** | Free extra provider on OS 26+ | Requires iOS/macOS 26 + Apple Intelligence hardware + user enablement — conditional availability only for a min-iOS-17 app **[unverified]**. Zero model download, native Swift API (`LanguageModelSession`, `@Generable`, streaming, tools). Hard limit: **4,096 tokens combined input+output** — Tier-2 context (8 passages + anchor + question + answer) barely fits and needs trimming **[unverified]**. |
| **MLC LLM** | Viable alternative packaging path | Official `mlc_llm package` tool supports both bundled weights and runtime download; MLC Chat ships on the App Store, proving review viability **[verified]**. Docs are v0.1.0 — API stability not assumed. |
| **Ollama** | **Ruled out for shipping** | No iOS runtime; daemon architecture incompatible with App Store distribution **[verified]**. Keep as macOS power-user option only. |

Caution: all *specific per-runtime peak-RAM comparisons* (e.g., "CoreML uses
3–8× less memory than MLX") were **refuted** in verification — measure memory
first-party on our own devices before basing decisions on it.

## 4. Candidate generation models — all [unverified], quality claims are vendor/blog figures

| Model | Params | Q4 disk | License | Context | Notes |
|---|---|---|---|---|---|
| **Qwen3 4B** | 4B | ~2.5 GB | Apache 2.0 | 32K | Strong all-rounder; Apache license is clean for redistribution |
| **Phi-4-mini** | 3.8B | ~2.5–2.7 GB | MIT | 128K | Repeatedly the "best 3–4B for Q&A/summarization" pick; weak world knowledge (fine for grounded RAG) |
| **Gemma 3 4B** | 4B | ~2.9 GB | Gemma license | 128K | Strong reasoning; Gemma license has use restrictions to review |
| **Gemma 3n E2B/E4B** | 5–8B total, 2–4B active | ~3 GB | Gemma license | 32K | Designed for phones (selective activation); pairs with EmbeddingGemma |
| **SmolLM3-3B** | 3B | ~2 GB | Apache 2.0 | 64K–128K | Beats Llama-3.2-3B/Qwen2.5-3B across 12 benchmarks per HF; engineered long context — good for book-length RAG |
| **Llama 3.2 3B** | 3B | ~2.2 GB | Llama license | 128K | Llama license terms are the most restrictive of the set |
| Qwen3 8B | 8B | ~5 GB | Apache 2.0 | 32K→128K | Mac-only tier; impractical on today's iPhones (~3–5 tok/s for 7B class) |

**Head-to-head quality for our two tasks is the biggest research gap** — no
comparative-quality claim survived verification. Decision needs a first-party
eval: a fixed set of (book, question, retrieved-passages) triples and
highlight-sets, scored blind against cloud output. Shortlist to benchmark:
**Qwen3 4B, Phi-4-mini, SmolLM3-3B** (+ Gemma 3n if the license is acceptable).

Expected speed on-device **[unverified]**: 3.8B Q4 ≈ 10–20 tok/s on iPhone
16/17-class hardware — acceptable for streaming Q&A, slow-ish for a 1.5K-token
article (~1.5–2.5 min).

## 5. Embedding models

| Option | Size / RAM | Dims | Why / why not |
|---|---|---|---|
| **EmbeddingGemma** | 308M params; <200 MB RAM quantized (vendor figure); ~150–300 MB disk at int4/int8 | 768, Matryoshka-truncatable to 512/256/128 | **[verified]** Top open multilingual <500M model on MTEB at launch; explicitly positioned by Google for on-device mobile RAG; 2K-token context bounds chunk size (our chapter-aware chunks fit). Not supported by MLXEmbedders (BERT/NomicBERT/Qwen3 archs only) — needs llama.cpp or direct MLX **[unverified]**. |
| **bge-small via MLXEmbedders** | ~33M params, ~130 MB RAM (fp32; less quantized) | 384 | **[verified]** Apple's official mlx-swift-lm ships pre-registered configs (BGE Micro ~17M/~70 MB up to BGE M3 ~568M) with mean pooling — a Swift-native path that matches `docs/ARCHITECTURE.md`'s MLX intent. Library is "example implementations," not a hardened SDK. |
| **NLContextualEmbedding** (Apple, built-in) | 0 bytes app size — OS-managed assets, downloaded via `requestAssets` | model-defined | **[verified]** Available at exactly iOS 17/macOS 14. BERT-style contextual token embeddings; needs pooling for passage vectors; Apple steers similarity tasks to `NLEmbedding`, so retrieval quality vs purpose-built embedders is unproven. First use needs a network download — conflicts with "works fully offline" claim. |

Recommendation: benchmark **bge-small (MLXEmbedders)** vs **EmbeddingGemma** vs
the current FNV stub on our existing `HybridRAGIndex` with real books; keep
`NLContextualEmbedding` as a curiosity unless it surprises. Matryoshka truncation
to 256 dims would keep index size close to today's 256-dim stub.

Swapping embeddings changes dimensions → **all book indexes must be rebuilt**;
index versioning + background re-index needed (also unblocks the planned
sqlite-vec persistence work).

## 6. Memory implications (iPhone/iPad)

The load-bearing numbers, all **[unverified]** (no jetsam claim survived
verification — Apple doesn't document limits; must be validated first-party
with `os_proc_available_memory()` on real devices):

- Rule of thumb for a ~4B 4-bit model at runtime: **weights ~2.6 GB + KV cache
  ~0.5 GB + activations/overhead ~0.15 GB ≈ 3.2 GB RAM.**
- **6 GB devices** (iPhone 12–14 Pro class): a 3–4B model "nominally fits" but
  jetsam kills the app under any other pressure — practical ceiling ~1.7B. These
  devices should get cloud-only or a 1B-class model (quality likely too low —
  recommend: no local generation).
- **8 GB devices** (iPhone 15 Pro/16/17 class): 3–4B Q4 works. A real experiment:
  loading a 3.65 GB Gemma on an iPhone 17 Pro **crashed without the
  `com.apple.developer.kernel.increased-memory-limit` entitlement and succeeded
  36/36 runs with it** (peak 4.6–4.8 GB). The entitlement (iOS 15+) is a
  requirement for this track, not an optimization.
- **12 GB devices** (iPhone 17 Pro/Air): Metal reports
  `recommendedMaxWorkingSetSize` of 8 GB; an 8B Q4 model runs (~9 tok/s), a
  ~7.3 GB model fails to load.
- **Macs**: unified memory makes this easy — 8 GB Macs run 3–4B, 16 GB+ runs
  7–8B comfortably. macOS should ship first.
- Interaction with Readr itself: book rendering + in-memory `HybridRAGIndex` +
  a 3.2 GB model must coexist. Model should be **loaded lazily on first AI use
  and unloaded on memory-pressure notifications**; the in-memory index makes the
  planned sqlite-vec persistence more urgent.

## 7. App-size implications & weight delivery

- **Do not bundle generation weights in the binary.** Thinned-bundle cap is 4 GB
  on iOS 18+ but **2 GB for iOS 17 users** — our current floor — and a 2–3 GB
  model blows it **[verified]**. Also ~“every 6 MB of app size costs ~1% install
  conversion” **[unverified]**.
- **On-Demand Resources is dead**: never supported macOS, deprecated as of the
  iOS 27 generation with removal planned **[verified]**. Do not build on it.
- **Background Assets framework is the delivery path** (iOS 16/macOS 13 base —
  inside our minimums). The newer *Apple-Hosted* variant needs iOS/macOS 26+, so
  for iOS 17–25 users we self-host the weights (CDN) and use standard Background
  Assets downloads **[verified]**. Precedent: every surveyed local-LLM App Store
  app (Private LLM, PocketPal AI, LLM Farm, MLC Chat) downloads models
  post-install; none bundle **[unverified]**.
- **The embedding model is small enough to bundle** (~35–200 MB) — do bundle it,
  so retrieval quality never depends on a post-install download. App grows from
  ~tens of MB to ~100–250 MB; under the 200 MB cellular warning threshold if we
  pick bge-small (and since iOS 13 the threshold is a user-overridable prompt,
  not a hard block **[unverified]**).
- UX: model download is opt-in ("Enable on-device AI · ~2.5 GB download"),
  Wi-Fi-preferred, resumable, deletable in settings.

## 8. Thermal & battery **[unverified]**

- Sustained inference draws ~3–5 W ≈ 20–30% battery/hour on an iPhone 16 Pro;
  throttling starts after ~10–15 min of continuous generation (−30–50% tok/s).
- Ask-the-book (short bursts) is fine; batch article composition is where
  thermal matters — if it becomes a flagship local feature, that's the argument
  for a CoreML/ANE path later ("GPU wins the sprint, ANE wins the marathon").
- Battery impact comparable to a video call — should be surfaced in UX, not hidden.

## 9. Case study: Muesli (github.com/Muesli-HQ/muesli)

Local-first macOS dictation/meeting-transcription app (MIT, macOS 14.2+,
Swift/SwiftUI). Examined from source 2026-07-22. Not App-Store-distributed —
ships via **Sparkle** direct download, which sidesteps App Store size/review
constraints entirely. Its answers to our questions:

- **Zero models bundled in the binary.** Every model — ASR (150 MB–3.8 GB) and
  LLM alike — is downloaded post-install from Hugging Face into
  `~/.cache/muesli/models/` using plain `URLSession.download` with retry +
  exponential backoff + partial-file cleanup (`DownloadUtils.swift`, ~55 lines).
  No Background Assets, no ODR — possible only because they're outside the App
  Store and macOS-only. A "Models" tab shows size labels up front (~450 MB,
  ~2.6 GB…), `isDownloaded` state, and per-model descriptions; settings resolve
  to "first downloaded model" as fallback, and downloads are validated by a
  minimum-size check before being trusted.
- **Their local-LLM strategy is small task-specific fine-tunes, not a bundled
  generalist.** Dictation cleanup runs a **fine-tuned Qwen3.5-0.8B (Q4_K_M GGUF,
  ~505 MB)** trained on their own correction data, via `LLM.swift` (a llama.cpp
  Swift wrapper). Generalist work (meeting summaries) stays on **cloud providers
  or user-run Ollama/LM Studio** — exactly Readr's current split. Their only
  multi-GB local generalist (Gemma 4 E2B, ~2.6 GB via Google's **LiteRT-LM**
  xcframework) is explicitly labeled experimental and gated to macOS 15+.
- **Per-model runtime pragmatism**: CoreML/ANE (FluidAudio, WhisperKit) for ASR,
  llama.cpp for GGUF fine-tunes, LiteRT-LM for Gemma — three runtimes coexisting
  behind per-backend Swift abstractions rather than one blessed runtime.
- **Inference hygiene patterns worth copying**: model lazy-loaded on first use
  and cached in an actor; explicit `shutdown()`/`reconfigure()` that discards
  the loaded model; inference serialized through a gate; **deterministic
  sampling** for the correction task (temp 0, topK 1, fixed seed); and a
  fail-closed output validator that rejects suspicious LLM output and falls back
  to the deterministic path — never trusting the small model blindly.

Transferable to Readr: the download UX (sizes up front, opt-in, per-model state),
lazy-load/explicit-unload lifecycle, fail-closed validation for grounded answers,
and — most strategically — the idea that a **~0.5–1 GB fine-tuned small model on a
narrow task can substitute for a 4B generalist** (their 0.8B fine-tune beats
vanilla for their task). For Readr that maps to: a small fine-tune could plausibly
handle grounded Tier-2 Q&A phrasing, while article composition stays cloud-first.
Not transferable: the plain-URLSession delivery (App Store + iOS forces
Background Assets on us) and the no-review distribution model.

## 10. Proposed track plan (for discussion, not committed)

1. **P0 — Embedding swap**: real `EmbeddingProvider` (bge-small via MLXEmbedders
   in `App/`), index versioning + rebuild, retrieval-quality benchmark vs stub.
   Ships value on its own even if generation never ships.
2. **P1 — macOS bundled generation**: MLX Swift + one 4B model behind
   `LLMProvider`, weights via Background Assets, macOS only (loose memory
   limits, simple validation). First-party memory/thermal measurements here.
3. **P2 — iOS generation**: gate by device RAM (≥8 GB), add
   increased-memory-limit entitlement, memory-pressure unloading, opt-in
   download UX.
4. **P3 — Foundation Models provider** on OS 26+ as a zero-download option for
   short Q&A (4K token ceiling), if the OS-26 install base justifies it.
5. **Continuous**: first-party model-quality eval harness (the biggest open gap
   — see §11).

## 11. Open questions

1. **Model quality head-to-head** — no comparative claim survived verification;
   needs our own eval harness (Qwen3 4B vs Phi-4-mini vs SmolLM3 on ask-the-book
   + article composition, blind-scored vs cloud output).
2. **Real jetsam headroom** — measure `os_proc_available_memory()` with a loaded
   4B model across 6/8/12 GB devices; all published per-runtime RAM comparisons
   were refuted.
3. **Product bar for article composition** — is local output acceptable, or is
   local explicitly a "privacy mode" with a quality disclaimer?
4. **License review** — Gemma-license and Llama-license redistribution terms for
   App Store delivery vs Apache-2.0 (Qwen3, SmolLM3) / MIT (Phi-4-mini).
5. **NLContextualEmbedding retrieval quality** — worth one benchmark run given
   the zero-size upside.
6. **Deployment-floor decision** — keep iOS 17 (2 GB bundle limit, self-hosted
   Background Assets) or raise the floor when iOS-17-only share drops.
7. **Fine-tune option (from the Muesli case study, §9)** — would a fine-tuned
   ~1B model on Readr's grounded-Q&A format beat a vanilla 4B generalist at a
   quarter of the memory/size cost? Requires training data we don't have yet.

## 12. Key sources

Verified-primary: Apple ODR/size-limits reference (developer.apple.com/help/app-store-connect),
NLContextualEmbedding docs, Apple mlx-swift-lm MLXEmbedders reference, Google
EmbeddingGemma launch post + docs, MLC LLM packaging docs. Benchmarks:
github.com/john-rocky/apple-silicon-llm-bench (+ dev.to writeup — reproducible
but single-author). Memory entitlements: zenn.dev iOS memory-entitlements
article; Apple Developer Forums threads 805161 (12 GB iPhone Metal working set),
807744, 809752. Model roundups (unverified tier): BentoML, KDnuggets,
tinyweights.dev, promptquorum. One source (sitepoint.com) was flagged unreliable
(fabricated model rows) and excluded.
