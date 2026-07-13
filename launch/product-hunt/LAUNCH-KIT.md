# Readr — Product Hunt launch kit

Prepared 2026-07-08 for v2.6.0; **revised 2026-07-13 for the v2.9.0 launch**:
the macOS download is now Developer-ID signed + notarized (no Gatekeeper
warning) and iPhone/iPad ship as a public TestFlight beta — the old "not
notarized / build iOS from source" caveats are gone. Everything below sticks
to what is actually shipped (see `README.md` and `docs/ROADMAP.md`); nothing
is invented.

> **Placeholder to fill on launch morning:** `TESTFLIGHT_JOIN_URL` — the
> public `https://testflight.apple.com/join/…` link (exists once Beta App
> Review approves the external group). Search-and-replace it below.

**Verified Product Hunt specs (checked July 2026):**

| Field | Spec |
|---|---|
| Tagline | max 60 characters |
| Description | max 260 characters |
| Thumbnail | square, 240×240 recommended, PNG or GIF, under 3 MB. GIFs animate on hover only, so the first frame must stand alone |
| Gallery images | 1270×760 recommended, minimum 2 images, PNG (or GIF for short demos), under 3 MB each |
| Topics | pick 3 relevant topics |
| Launch cycle | the Product Hunt day resets at 12:01 am Pacific; Tuesday–Thursday launches perform best |
| First comment | post the maker comment immediately after going live; respond to comments quickly through the day |

Sources: Product Hunt Help Center ("How to post a product"), producthunt.com/launch
(specs mirrored via [Smol Launch 2026 guide](https://smollaunch.com/guides/launching-on-product-hunt),
[LaunchList 2026 guide](https://getlaunchlist.com/blog/how-to-launch-on-product-hunt-2026),
[Screenhance 2026 checklist](https://screenhance.com/blog/product-hunt-launch-checklist-2026),
[framed-shot gallery specs](https://framed-shot.com/guides/product-hunt-gallery-screenshots-sizes/),
[Hackmamba dev-tool launch guide](https://hackmamba.io/developer-marketing/how-to-launch-on-product-hunt/)).
The producthunt.com pages themselves were unreachable from this environment
(egress policy), so the numbers were cross-checked across several current
third-party guides that quote the Help Center; they all agree. Re-check the
submission form fields when you actually post — the form enforces the limits.

---

## 1. Listing

**Product name:** Readr

**Tagline options** (all within 60 characters):

1. `Ask your books questions. Turn highlights into articles` (55)
2. `The ebook reader where you can ask the book anything` (52)
3. `Open-source ebook reader with ask-the-book AI, local or BYO` (59)

Recommendation: option 1. It names both features in plain words and reads well
in a feed.

**Description** (254 of 260 characters):

> Native macOS/iOS reader for DRM-free EPUB, PDF and Markdown. Select text, ask
> the book, get streamed answers with citations grounded in the whole book.
> Highlights compose into editable articles. Bring your own LLM or run fully
> offline. Open source (MIT).

**Topics** (pick 3): `Books`, `Artificial Intelligence`, `Open Source`.
Fallbacks if a topic is unavailable in the picker: `Mac`, `Productivity`,
`Privacy`. Prefer the specific over the huge — do not burn a slot on
`Productivity` if `Books` and `Open Source` are available.

**Links:**

- Website: https://readr-ai.github.io/readr/ (repo: https://github.com/readr-ai/readr)
- Download (macOS, signed + notarized): https://github.com/readr-ai/readr/releases (v2.9.0)
- iPhone & iPad beta (TestFlight): TESTFLIGHT_JOIN_URL
- Privacy policy: https://readr-ai.github.io/readr/privacy.html

**Pricing:** Free. Open source under MIT. No accounts, no tiers, no trials. AI
features use your own API key or a free local model via Ollama — Readr itself
never charges and never proxies your traffic.

**Thumbnail suggestion:** the app icon (open book + amber spark) on a plain
background at 240×240. If you use a GIF, make frame one the static icon.

**Gallery suggestions** (1270×760, at least 2, ideally 4–6):

1. Reader with text selected and the Ask panel streaming an answer with
   citation chips — the hero shot.
2. Two-page facing layout on macOS — the "it's a real reader" shot.
3. Highlights composing into the Markdown article editor.
4. Provider settings showing Anthropic / OpenAI / Ollama —
   the bring-your-own-LLM shot.
5. A PDF open in the reader (Apple Books can't even open a PDF on macOS).

---

## 2. Maker's first comment

> Hi Product Hunt — maker here.
>
> Readr exists because of a loop I couldn't stop doing: read a paragraph, get
> confused or curious, copy it, paste it into Claude or ChatGPT, type "in the
> book I'm reading, what does this mean?", read the answer, alt-tab back, find
> my place again. Every serious reading session turned into window juggling.
>
> So I built the reader I wanted. Readr is a native macOS and iOS app (SwiftUI,
> open source, MIT) for DRM-free EPUBs, PDFs and Markdown. Select any passage,
> ask a question, and the answer streams in right there — grounded in the whole
> book, with citations pointing at the passages it came from. Small books go to
> the model whole (with prompt caching); big ones use hybrid retrieval. Your
> highlights and notes can also be composed into an editable Markdown article.
>
> On the AI: you bring your own. Paste an Anthropic or OpenAI key, or point it
> at local Ollama and stay fully offline. No telemetry — there's no analytics
> code in the app at all — keys live in the Keychain, and local mode only ever
> talks to your local Ollama server.
>
> It runs everywhere I read: the macOS download is signed and notarized (no
> security warnings — download, open, read), and iPhone + iPad are in public
> beta on TestFlight (TESTFLIGHT_JOIN_URL). One honest caveat: DRM-free books
> only — it opens your EPUBs, PDFs and Markdown, not Kindle purchases.
>
> Question for you: when you hit something confusing mid-book, what do you
> actually do — push through, search the web, or ask an AI? I'd love to know
> what the reading-plus-AI workflow looks like for other people.

(~280 words. Post it the minute the launch is live.)

---

## 3. FAQ / prepared replies

**"Is the macOS build signed/notarized?"**
> Yes — releases are Developer-ID signed and notarized by Apple, built by
> public CI (you can audit exactly what goes into every build in the repo's
> Actions). Download, unzip, drag to Applications, open. No warnings.

**"Windows / Linux version?"**
> Not planned right now. Readr is deliberately native SwiftUI, and a lot of the
> value is in feeling like a real Mac app. That said, the core logic (parsing,
> context routing, RAG, providers, article composer) lives in a
> platform-agnostic Swift package, `ReadrKit`, which builds and tests on Linux
> in CI — so a non-Apple frontend is technically possible if someone wants to
> take that on. It's MIT, PRs welcome.

**"App Store or TestFlight for iOS?"**
> TestFlight today, App Store next. The iPhone & iPad beta is open to everyone:
> TESTFLIGHT_JOIN_URL (install the TestFlight app, tap the link). CI runs the
> full UI-test suite on iPhone and iPad simulators on every PR, and uploads
> every release build to TestFlight automatically. App Store submission is the
> fast-follow once beta feedback settles.

**"Which local models work?"**
> Anything Ollama serves — Readr talks to Ollama's local API over loopback and
> streams responses. Pick a model that fits your machine; larger-context models
> do better on whole-chapter questions, and smaller ones still work because
> local mode always uses retrieval rather than stuffing the whole book in.
> Embeddings for retrieval are computed on-device too, so nothing leaves your
> machine. There are tests asserting the local pipeline makes zero network
> calls.

**"How do you fit a whole book in context? Doesn't that cost a fortune?"**
> Adaptively. If the book fits the model's context budget (most novels are
> ~100–200k tokens), it's sent whole once and prompt caching makes follow-up
> questions pay only for the question, not a re-sent book. If the book is too
> big, or you're on a local/small-context model, Readr switches to hybrid
> retrieval: chapter-aware chunks, contextual embeddings, BM25 + vector search,
> reranked. Either way every query includes your selected passage, the current
> chapter and the table of contents, so the model always knows where you are.
> Full write-up with references: docs/CONTEXT-STRATEGY.md in the repo.

**"Does it work with Kindle/Kobo/Apple Books purchases (DRM)?"**
> No, and it won't. Readr only opens DRM-free files and rejects encrypted
> EPUBs/PDFs by design — stripping DRM is legally murky and out of scope. It's
> great with DRM-free stores (Standard Ebooks, Project Gutenberg, publishers
> like Tor, technical publishers, Humble Bundle) and your own PDFs.

**"How is this different from Readwise Reader / Apple Books?"**
> Different jobs, honestly. Readwise Reader is superb for web articles,
> newsletters and RSS with a subscription and cloud sync; Readr is a local-first
> book reader — your files, your keys, no account, no subscription. Versus
> Apple Books: Books on macOS can't open PDFs (it hands them to Preview), has
> no annotation export, and no AI. Readr opens PDFs natively, turns your
> highlights and notes into an exportable Markdown article, and lets you ask
> the book questions with citations. If you live in both worlds, they
> coexist fine.

**"Is my book sent to the AI provider?"**
> Only if you choose a hosted provider, and then only to the provider you
> configured with your own key — Readr has no server of its own and no
> telemetry. In local (Ollama) mode the app only ever talks to your local
> Ollama server — there is no analytics or phone-home code in the app at all
> (it's open source; check for yourself).

---

## 4. Social copy

### X/Twitter thread

**Tweet 1**
> We launched Readr on Product Hunt today.
>
> It's an open-source, native Mac ebook reader where you can select any passage
> and ask the book a question — the answer streams in with citations, grounded
> in the whole book.
>
> [PH link]

**Tweet 2**
> Why: every reader I know does the same loop — copy a paragraph, paste it into
> ChatGPT, ask, alt-tab back, lose their place.
>
> Readr removes the loop. Small books go to the model whole (prompt-cached);
> big ones use hybrid retrieval. You never leave the page.

**Tweet 3**
> The AI is yours, not ours: paste an Anthropic/OpenAI key, or run Ollama and
> stay fully offline.
>
> No telemetry — no analytics code at all. Keys in the Keychain. Local mode
> only talks to your local Ollama server. MIT licensed.

**Tweet 4**
> Get it: signed + notarized macOS download, and a public iPhone & iPad beta
> on TestFlight → TESTFLIGHT_JOIN_URL
>
> Fine print: DRM-free books only.
>
> Repo: https://github.com/readr-ai/readr
> If you read with an AI on the side, we'd love your feedback on PH today.

### LinkedIn post

> Today we're launching Readr on Product Hunt.
>
> If you read serious books, you probably know this loop: hit a confusing
> passage, copy it, paste it into ChatGPT or Claude, ask what it means, then
> hunt for your place in the book again. We built Readr to delete that loop.
>
> Readr is a native macOS and iOS ebook reader (open source, MIT) for DRM-free
> EPUBs, PDFs and Markdown. Select text, ask a question, and the answer streams
> in next to the page — grounded in the whole book, with citations to the
> passages it drew from. When you're done reading, your highlights and notes
> can be composed into an editable Markdown article.
>
> Two decisions we care about:
>
> 1. Bring your own AI. Use your Anthropic or OpenAI key, or a local model via
> Ollama — fully offline if you want.
> 2. Privacy by construction. No telemetry or analytics code, no Readr server,
> keys stored only in the Keychain, and local mode only talks to your local
> Ollama server.
>
> The macOS download is signed and notarized, and the iPhone & iPad beta is
> open to everyone on TestFlight: TESTFLIGHT_JOIN_URL. DRM-free books only.
> The code is public and contributions are welcome.
>
> We'd genuinely value your feedback and questions on Product Hunt today:
> [PH link]

---

## 5. Launch-day checklist

### Timing

- The Product Hunt day runs midnight to midnight Pacific. Launching at
  **12:01 am PT** gives the full 24-hour voting window; a launch at 4 pm PT
  competes with products that have a 16-hour head start.
- Best days: **Tuesday–Thursday**. Weekends and Mondays get less traffic.
- **If it's already mid-day PT:** don't launch today. Use PH's scheduling to
  set the launch for 12:01 am PT on the next Tuesday–Thursday, and spend the
  gap on assets and the release. A mid-day launch only makes sense if you have
  an external reason (press embargo, event) that outweighs the shortened
  window.

### Before launch (maker-only, manual)

- [ ] Confirm the **v2.9.0 GitHub release** is live with the signed +
      notarized `Readr.app` zip (release body should say "Signed and
      notarized" — the CI takes the signing path automatically once the
      `MACOS_*`/`APPLE_*` secrets are set).
- [ ] Confirm the **TestFlight public link** is approved and live; replace
      every `TESTFLIGHT_JOIN_URL` in this kit, the README, and
      `site/index.html` with the real
      `https://testflight.apple.com/join/…` URL.
- [ ] GitHub repo polish (only the maker can do this):
  - [ ] Repo **description** set (mirror the PH tagline).
  - [ ] Repo **topics** added: `ebook-reader`, `epub`, `pdf`, `swift`,
        `swiftui`, `macos`, `ios`, `ai`, `rag`, `ollama`, `open-source`.
  - [ ] **Social-preview image** uploaded (Settings → General → Social
        preview, 1280×640) so the repo link unfurls nicely on PH/X/LinkedIn.
- [ ] Prepare assets to spec: 240×240 thumbnail, 4–6 gallery images at
      1270×760, each under 3 MB, hero image first (screenshots listed in
      section 1). A short GIF of the Ask panel streaming makes a strong
      second slot.
- [ ] Create/verify your PH **maker account** (ideally active well before
      launch day — comment on other products, fill in the profile).
- [ ] Submit the product on PH: name, tagline, description, topics, links,
      pricing = Free, tick "I'm a maker", and **schedule for 12:01 am PT**.
- [ ] Draft queued and ready to paste: maker first comment (section 2), tweet
      thread, LinkedIn post.
- [ ] Smoke-test the download path on a clean Mac: download from Releases,
      unzip, open — it must launch with **no** Gatekeeper warning — then open
      an EPUB, highlight, and ask a question with a real API key. Fix the
      README if reality differs.
- [ ] Smoke-test the TestFlight path on an iPhone or iPad that isn't on the
      dev team: tap the join link, install, import an EPUB, ask a question.

### Launch day (12:01 am PT onwards)

- [ ] 12:01 am — launch is live. **Post the maker first comment immediately.**
- [ ] Post the X thread and LinkedIn post with the live PH link; add the PH
      link to the repo README top (a small "Live on Product Hunt" line, no
      badge spam).
- [ ] Tell communities you're genuinely part of (Slack/Discord groups, relevant
      subreddits within their self-promo rules). Ask for honest feedback, not
      upvotes — PH downranks vote begging.
- [ ] **Reply cadence:** aim to answer every PH comment within 30 minutes for
      the first 6–8 hours (the ranking-sensitive window), then check hourly
      until midnight PT. Use the FAQ replies in section 3 as raw material, but
      personalise each one.
- [ ] Watch GitHub too: issues and stars will spike; label and thank quickly.
      The most likely bug reports are unusual EPUBs/PDFs failing to parse and
      API-key confusion (wrong key type, org without credits) — triage those
      fast. The in-app "Get an API key" links and the actionable error
      messages should absorb most key issues.
- [ ] Watch TestFlight feedback (ASC → TestFlight → Feedback) — beta testers
      can send screenshots + notes straight from the app.

### After launch day

- [ ] Thank commenters; follow up on every unresolved question.
- [ ] Convert recurring PH questions into README/FAQ updates and GitHub issues.
- [ ] Write down what you'd change; an "App Store release" issue is probably
      the top ask — link people to it.

---

## 6. App Store Connect beta pack (paste into ASC → TestFlight)

One-time setup that unlocks the **public TestFlight link** (external testers
require Beta App Review for the first build):

1. **TestFlight → Test Information** — fill these fields:

   - **Beta App Description** (paste):

     > Readr is a native ebook reader for DRM-free EPUB, PDF, and
     > text/Markdown files — with an AI twist: select any passage and ask the
     > book a question, and the answer streams in with citations grounded in
     > the whole book. Your highlights and notes can be composed into an
     > editable Markdown article. Bring your own AI: paste an Anthropic or
     > OpenAI API key in Settings → AI Providers (the app links you to the
     > key consoles). No account, no telemetry — books and notes stay on your
     > device and keys live in the Keychain.
     >
     > What to test: import an EPUB or PDF (Files app or the in-app
     > importer), read in the paged layouts, make highlights, open the Notes
     > panel, and — with your own API key — ask the book a question and
     > compose an article from your highlights. We'd love feedback on iPad
     > split-view and rotation.

   - **Feedback Email**: your address (e.g. the account email).
   - **Privacy Policy URL**: `https://readr-ai.github.io/readr/privacy.html`
     (live once the launch PR merges and Pages redeploys).

2. **TestFlight → Internal Testing** — install the build yourself first and
   walk: import EPUB → read → highlight → ask with a real key (iPhone + iPad).

3. **TestFlight → External Testing** — create a group ("Public Beta"), toggle
   **Enable Public Link**, add the v2.9.0 build. Adding the first build
   submits it to **Beta App Review** automatically (typically 24–48 h).
   Export-compliance is pre-answered (`ITSAppUsesNonExemptEncryption: false`).

4. When approved, copy the public link and replace `TESTFLIGHT_JOIN_URL`
   everywhere (this kit, README, `site/index.html`).
