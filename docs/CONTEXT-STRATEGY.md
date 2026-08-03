# Context Strategy: Giving the LLM the Whole Book

**Goal:** Answer a reader's question with full awareness of a book that may be a
20-page pamphlet or a 1,000-page epic — optimally on cost, latency, and quality,
across hosted *and* local models.

## TL;DR — Adaptive tiered retrieval

There is no universal winner between "stuff the whole book in the prompt" and
"retrieve relevant passages." The research consensus is that the right choice
depends on document size, model, and budget — and a **hybrid/adaptive** system
beats either pure approach. So Readr **routes each query** to the cheapest
method that preserves quality.

```
On import:  parse → estimate token count → build RAG index in background
On query:   route by (book tokens, model context budget, provider mode)
```

### Tier 1 — Whole-book in context (+ prompt caching)
- **When:** `bookTokens + overhead ≤ usableContextBudget(model)` and the provider
  is hosted. Most novels (~100–200k tokens) fit Claude (200k, 1M beta) and Gemini (1M).
- **How:** Send the full text once; use **prompt caching** so follow-up questions
  only pay for the question, not the re-sent book.
- **Why:** Highest answer fidelity when the book fits; avoids retrieval misses.

### Tier 2 — Contextual Retrieval (hybrid RAG)
- **When:** Book exceeds the budget, OR the user is on a small-context / local model.
- **How:**
  1. **Chapter-aware chunking** (respect structure; overlapping windows).
  2. **Contextual embeddings** — prepend a short situating blurb (chapter title +
     local summary) to each chunk before embedding.
  3. **Hybrid search** — vector similarity **+** BM25 (FTS5) lexical match.
  4. **Rerank** the top candidates, keep top-K.
- **Why:** Anthropic's Contextual Retrieval reduced retrieval failures up to **67%**
  vs. naive chunking. Scales to arbitrarily large books at bounded cost.

### Tier 3 — Always-injected anchor (both tiers)
Every query also includes:
- the **selected sentence** + surrounding paragraphs,
- the **current chapter** heading / position,
- **book metadata + table of contents**.

This guarantees the model always knows *where the reader is*, even when retrieval
or truncation drops the rest.

### Conversation history (both tiers)
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

### Local-LLM mode
Always Tier 2, with **on-device** embeddings (e.g. MLX embedding model) and a
local SQLite vector store. Nothing leaves the device.

## Why not pick one approach?

| Approach | Strength | Weakness |
|----------|----------|----------|
| Long-context (whole book) | Best fidelity when it fits; no retrieval misses | Quadratic cost; "lost in the middle"; impossible for huge books or local models |
| Pure RAG | Cheap, fast, scales to any size | Retrieval misses; weaker on holistic/whole-book questions |
| **Adaptive (ours)** | Uses the best tool per book/query/model | More engineering, but isolated behind one interface |

## Implementation surface

All of this lives behind `ContextStrategy` in `ReadrKit` (see
`Sources/ReadrKit/Context/`). The reader UI just calls
`assembleContext(for: query, in: book, selection:history:)` and gets a
ready-to-send payload; the routing is invisible to callers and swappable. A
convenience overload drops `history:` for one-shot questions.

## References

- Anthropic — *Introducing Contextual Retrieval* — https://www.anthropic.com/news/contextual-retrieval
- *Long Context vs. RAG for LLMs: An Evaluation and Revisits* — https://arxiv.org/abs/2501.01880
- RAGFlow — *From RAG to Context: 2025 year-end review* — https://ragflow.io/blog/rag-review-2025-from-rag-to-context
- SuperAnnotate — *RAG vs. Long-context LLMs* — https://www.superannotate.com/blog/rag-vs-long-context-llms
