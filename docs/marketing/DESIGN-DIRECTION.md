# Readr — Design Direction

Everything Anusree has directed, as of 24 July 2026. Compiled from the working
sessions; the live page is `docs/marketing/website-mockup.html`.

---

## 1 · The idea, in your words

> **Original thought dump:** "For the love of rabbitholing, for the love of
> reading, for serious readers. Be curious. Distraction-free reading." … "Calm,
> curious, in a space of your own with minimal distractions is the vibe."

The resolution of the apparent contradiction — rabbitholing *vs.*
distraction-free — became the site's whole argument:

> **Rabbitholes aren't the enemy of deep reading. Browsers are. Readr keeps the
> rabbithole inside the book.**

### The two pillars

1. **Be curious** — ask the book anything, stay in the book.
2. **Make it yours** — highlight, add your thoughts, walk away with an article
   in your own voice.

---

## 2 · Audience

**People who love reading** — explicitly *not* only the capital-S serious reader.

> **Correction, 23 July:** "Not just serious readers — the readers who love
> reading also."

So: the historian-at-heart and the literary annotator, but equally the person
400 pages into a fantasy doorstopper. Welcome, don't gatekeep. Much of this
audience is AI-skeptical, which shapes tone but not honesty.

---

## 3 · Voice & positioning

| Decision | Direction |
| --- | --- |
| **AI** | **DO** name it plainly where it explains the difference — "a book reader with an AI that has read the whole book." **DON'T** make AI the identity, or use hype register. |
| **Examples** | **DO** use real books, real passages, real questions. Mix classics with what people read now. **DON'T** use generic placeholders. |
| **Copy** | Book-review register, not SaaS. Run everything through the [no-ai-slop](https://github.com/petergyang/no-ai-slop) rules — the site must pass its own product's bar. |
| **Manifesto** | **CUT.** "No one has time to read all that." |

---

## 4 · Colour

The app's own palette, taken from its screenshots. **Light-only** — the site
renders cream in every viewer theme (`color-scheme: light`, no dark variant).

| Token | Hex | Use |
| --- | --- | --- |
| paper | `#F7F3EB` | page background |
| card | `#FDFAF4` | cards, app surfaces |
| ink | `#2E2A23` | body text |
| iris | `#5B57C7` | accent + primary CTA |
| amber | `#E8D5A8` | highlight |
| sage | `#C9D5BE` | highlight |
| slate | `#BFD0DE` | highlight |
| clay | `#E9CFC0` | highlight |

**HARD NO** — browns, espresso, gray-brown ink, and any dark/charcoal site
theme. Both were tried and rejected outright ("I hate all the charcoal colors",
"I hate the brown color"). Iris is the CTA colour; the app uses it for send/Done
affordances, so it carries over.

---

## 5 · Texture & imagery

### Paper texture

Modelled on [shaders.paper.design/paper-texture](https://shaders.paper.design/paper-texture)
— not a flat noise overlay. Three layers sit over the hero photo:

- **Folds / crumples** — embossed via SVG diffuse lighting, so it has real
  dimensional depth
- **Fiber** — stretched turbulence, the curly strand look
- **Roughness** — fine pixel grain

### Photography

- Real photographs only. **No AI-generated imagery** — one supplied reference
  had AI tells (garbled cover text); that failure on our own site would destroy
  the anti-slop positioning.
- **One photo**: the hero backdrop. A golden-hour reader against a tree. High
  opacity — the photo reads at near-full strength, with only a soft radial paper
  glow behind the headline for legibility.
- A secondary photo band was built and **cut**.

---

## 6 · Product mockups

**iPhone views only.** iPad and Mac mockups were built and cut — they ate too
much vertical space. Mac/iPad support is *stated, not shown* (one line under the
ask demo, a trust-strip cell, the closing CTA).

- Phones render at **true device geometry** (390pt screen) — never shrunk.
- Each mockup shows a **full page** of real reading, not two floating sentences,
  "so it feels like you are actually reading a book."
- Mockups are hand-built to resemble real app screens (the shipped screenshots
  use test content).
- The compose demo is **interactive** — tapping ✦ Compose article reveals the
  composed draft.

---

## 7 · The books on the page

All four supplied from your own shelf, quoted exactly from photographed pages:

| Book | Where | Question / use |
| --- | --- | --- |
| *Why Has Nobody Told Me This Before?* — Dr Julie Smith | Example card | "Is there real evidence behind this?" |
| *The Gene* — Siddhartha Mukherjee | Example card | "Is this the enzyme mRNA vaccines use?" — the clearest proof of book-contextual-not-book-limited answering |
| *Project Hail Mary* — Andy Weir | Example card | "Could astrophage really exist?" |
| *Shoe Dog* — Phil Knight | Compose demo | Three highlights → the article "Something I could point to". Chosen for a Product Hunt audience of founders. |

Public-domain books (Moby-Dick, Frankenstein) carry the *full-page* reading
views, since a whole page of an in-copyright book can't go on a public site.
Frankenstein also lets the page use your original CRISPR-embryo question.

---

## 8 · Product decisions that shaped the copy

- **Answers are book-contextual, not book-limited.** The AI always has the book,
  but may bring outside knowledge. The implementation said the opposite —
  tracked in [issue #54](https://github.com/readr-ai/readr/issues/54).
- **Site's job:** Product Hunt launch + waitlist. Pre-launch framing,
  near-future tense.
- **Sharing:** copy and export as Markdown/PDF is enough. No hosted or social
  layer — drop "post" from the copy.
- **Name:** Readr for now. Shortlist still open (Commonplace, Dogear,
  Marginalia, Flyleaf).

---

## 9 · Rejected — don't reintroduce

- Brown / espresso / gray-brown palettes
- Any dark or charcoal site theme
- AI-generated imagery
- The manifesto page
- The secondary photo band
- iPad and Mac mockups
- Greeked or placeholder book text
- Mac-window framing for product shots

---

## 10 · Still open

- Final name — Readr is a placeholder
- The hero photo you last sent isn't in the page yet (chat images don't reach
  the filesystem). Save it to `docs/marketing/assets/hero-reader.jpg` and it
  picks up the texture treatment automatically.
- Waitlist form needs a backend (Buttondown, Loops, or a simple endpoint)
- Literata webfont falls back on the artifact host; a real deploy gets it
- Nothing committed to git yet
