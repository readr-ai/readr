# Context Strategy: the reader's neighborhood, plus what retrieval finds

**Goal:** answer a reader's question with the book behind the answer — without
paying for the whole book on every question, and without pretending a model
reads a 300-page novel the way a person remembers one.

## TL;DR

The reader names the scope — the panel's **"Answers from"**, three options,
`Nearby` selected by default:

```
Nearby (default): the passage + its surrounding paragraphs (the neighborhood)
                  + hybrid-retrieved passages, citeable. Never the book.
Read so far:      everything up to the reader's place, sent whole when the
                  model can hold it — retrieval when it cannot.
Whole book:       the whole text, including past the reader's place.
Always:           selection, chapter, position, and the table of contents.
```

The scope says how much text was *asked for*, and it also sets the cap:
`Nearby` is capped by `defaultSmallBookTokenCap` (so a reader 12 pages in still
gets the whole read-so-far text — it costs about what retrieval would, and it
cannot miss), the two text scopes by `defaultWholeBookBudgetFraction ×
contextBudget`. A text that does not fit its cap falls back to retrieval.

**Why this changed (September 2026).** The router used to choose the whole-book
tier whenever the book fit 60% of the model's context budget. Against a 200k
budget that is *almost every book*, so nearly every question re-sent the entire
text — including the parts the question was not about. Measured on a book read
to 300,000 characters: ~75,000 input tokens per question before, ~3,000–4,000
after (window + 8 passages + anchor), with citations that point at the passages
the answer actually used. The scope then became something the reader can name
rather than a rule they have to trust.

## Why a neighborhood at all

The analogy that drove this is the reader's, and it is worth stating precisely
because it is easy to overstate:

- **Working memory holds a handful of chunks** — Cowan's estimate is ~4, down
  from the older 7±2 — not chapters. A reader asked about a sentence has that
  sentence's paragraph and a few before it in mind.
- **But comprehension of a long text is not that window.** Readers build a
  *situation model* over the text, and when a coherence gap appears they **go
  back and look** — long-range regression / reinstatement, described by the
  Landscape Model and friends. Retrieval is the machine version of going back.
- So the two halves are: **a small window** (what you are holding) **plus
  retrieval** (what you went back for). Sending the whole book is neither, and
  the long-context literature adds its own reason not to: recall inside a huge
  prompt is not uniform ("lost in the middle").
- **Honest counterpoint, worth keeping in mind:** individual differences in
  comprehension track working-memory *capacity* rather than context *scope*
  (CAS, 2020). The analogy is a design heuristic here, not a claim about brains.

## The text tiers — when the model is sent the text itself

- **When:** the scope is `Read so far` (`.upTo`) or `Whole book`
  (`.wholeBook`), and the text fits `defaultWholeBookBudgetFraction ×
  contextBudget`. The `Nearby` scope reaches this tier only while the read
  text is ≤ `defaultSmallBookTokenCap`.
- **How:** the text rides along as `cacheableSystemPrefix` (prompt caching where
  the provider supports it — `supportsPromptCaching`), the question as the user
  message. Under `.upTo` that text is `book.textRead(upTo:)`; under
  `.wholeBook` it is `book.fullText`.
- **Why the small case is not an optimization but a correction:** below the cap,
  the whole text costs about what a handful of retrieved passages costs, and it
  cannot miss. Retrieving from five pages to save nothing would be worse work
  for a worse answer.
- **Why the scope carries the decision and nothing else does:** a native PDF
  page has no reading position, so it passes `.window(nil)` — "nearby, with
  nothing to bound it" — rather than `.wholeBook`. Before the three scopes
  existed there was a separate `wholeBookRequested` flag to keep "the reader
  asked for the whole book" apart from "this page has no position to offer";
  the scope now says which it is, and the flag is gone.

## Tier 2 — the neighborhood + hybrid retrieval (the `Nearby` default)

- **When:** the `Nearby` scope (the default), and any text scope whose text does
  not fit its cap — plus every local/small-window model, which never qualifies.
- **How:**
  1. **Neighborhood**: `ParagraphWindow` expands the selection to the
     paragraphs around it — three before, one after by default. Sent as the
     anchor, so the model always sees the passage in question in full context.
  2. **Retrieval**: chapter-aware chunks (1,200 characters, 200 overlap) →
     vector + BM25 (FTS5) hybrid search → top-K (8 by default) → as many as the
     provider's budget holds, best first.
  3. **Citations**: the passages that were sent are exactly the ones the reader
     can tap, each carrying chapter index and character offset.
  4. **`nearbyOnlyNote`**: because the system prompt promises "the book below",
     this tier adds a line saying the model was handed passages, not the book.
- **Why:** bounded cost per question regardless of book size, and an answer that
  can be checked against the passages it used.

## Tier 3 — the anchor (both tiers)

Every query also includes:
- the **selected sentence** + the **paragraphs around it** (`ParagraphWindow`),
- the **current chapter** heading / reading position,
- **book metadata + table of contents**.

This is what guarantees the model knows *where the reader is*, and in Tier 2 it
is also the local context the question is actually about.

## Reading frontier — spoiler-free answers (both tiers)

The reader is usually mid-book, and "recap what I've read so far" is only
honest if the model cannot see past where they are. `ReadingFrontier`
(chapter index in reading order + character offset) is that boundary, and the
app passes the reader's current anchor as the frontier on every Ask from a
text book.

With a frontier in force:

- **Tier 1** sends `book.textRead(upTo:)` — earlier chapters in full, the
  current chapter up to the offset — instead of `fullText`, and budgets on
  that text.
- **Tier 2** drops every retrieved passage past the frontier before it is
  quoted or cited. The current chapter's passages are withheld until the
  reader has finished it; passages of unknown position are withheld too.
- **The prompt** gains `spoilerGuard`: nothing after the frontier may be
  revealed, from the text *or from what the model knows about the book*, and
  a recap means "so far, in reading order, stopping where the reader stopped".

Native PDFs pass no frontier (there is no text position to offer), so nothing
bounds retrieval — but the scope is still `.window(nil)` (nearby), so a large
PDF is answered from passed-with-citations extracts rather than a
whole-document prompt.

## Conversation history (both tiers)

Ask is a conversation, so the earlier turns of the same session ride along as
plain user/assistant messages between the system prompt and the new question.
Without them a follow-up ("but roads are technically 3D") reaches the model
with nothing to object to.

Two bounds keep the chat from crowding out the book, which is the point of the
context: only the most recent `maxHistoryTurns` answered turns are replayed,
and each earlier answer is abridged to `maxHistoryAnswerCharacters` — it is
context for what was already said, not evidence. Turns still streaming, or that
failed, carry no answer and are skipped, so the model is never handed a
question that looks unanswered.

## Local-LLM mode

Always Tier 2, with **on-device** embeddings (e.g. MLX embedding model) and a
local SQLite vector store. Nothing leaves the device.

## The knobs, and where they live

| Knob | Where | Default |
|------|-------|---------|
| Nearby: small-read cap | `AdaptiveContextStrategy.defaultSmallBookTokenCap` | 6,000 tokens |
| Text scopes: budget share | `defaultWholeBookBudgetFraction` | 0.6 |
| Neighborhood | `ParagraphWindow.defaultBefore` / `.defaultAfter` | 3 paragraphs before, 1 after |
| Neighborhood ceiling | `ParagraphWindow.defaultMaxCharacters` | 2,000 characters |
| Retrieved passages | `assembleContext` (limit) | 8 |
| Chunk size | `Chunker.init(targetCharacters:overlapCharacters:)` | 1,200 / 200 characters |
| History | `maxHistoryTurns` / `maxHistoryAnswerCharacters` | 6 turns / 700 characters |
| Default scope | `AskViewModel.answersFrom` | `.nearby` |

The neighborhood ceiling matters more than it looks: a PDF page or a
plain-text book can have no blank lines at all, and there a "paragraph" is the
whole page or chapter — which would put that whole text into every question.
When the paragraphs around the selection exceed the ceiling, the window is
trimmed to it, centred on the selection.

## Measured

On a book read to 300,000 characters, one question, the same provider:

| | Prompt sent |
|---|---|
| The text tier, which the old rule chose on every question | ≈ 75,000 tokens |
| Tier 2 (neighborhood + 8 passages + anchor) | ≈ 3,000 tokens |

with the added benefit that the answer's citations point at the eight passages
it actually read.

## Why not pick one approach?

| Approach | Strength | Weakness |
|----------|----------|----------|
| Long-context (whole book) | Best fidelity when the text is small; no retrieval misses | Cost scales with the book on *every* question; non-uniform recall; impossible for huge books or local models |
| Pure RAG | Cheap, fast, scales to any size | Retrieval misses; weaker without any local context |
| **Neighborhood + RAG (ours)** | The passage is always in full context; retrieval covers the long range; bounded cost | Two mechanisms to keep honest, but isolated behind one interface |

## Implementation surface

All of this lives behind `ContextStrategy` in `ReadrKit` (see
`Sources/ReadrKit/Context/`). The reader UI just calls
`assembleContext(for:in:selection:history:scope:provider:)` and gets a
ready-to-send payload; the routing is invisible to callers and swappable.
A convenience overload drops `history:` for one-shot questions.

The app's side of the contract is one choice: `AskViewModel.AnswersFrom`
(`nearby` / `readSoFar` / `wholeBook`) maps to `ReadingScope` (`.window(frontier)` /
`.upTo(frontier)` / `.wholeBook`), and `ReaderView.askScope` supplies the
frontier. The scope is session state on the conversation, deliberately not
persisted: a "Whole book" left over from yesterday would quietly re-send the
entire book on the next launch.

## References

- Cowan, N. — *The magical number 4 in short-term memory* (2001) — https://pubmed.ncbi.nlm.nih.gov/11515286/
- Van den Broek et al. — the Landscape Model of reading; long-range regression
  / reinstatement — https://www.frontiersin.org/articles/10.3389/fnhum.2014.00765/full
- CAS Institute of Psychology — *Working memory capacity and semantic
  integration* (2020) — https://english.cas.cn/newsroom/research_news/life/202004/t20200423_235186.shtml
- Anthropic — *Introducing Contextual Retrieval* — https://www.anthropic.com/news/contextual-retrieval
- *Long Context vs. RAG for LLMs: An Evaluation and Revisits* — https://arxiv.org/abs/2501.01880
