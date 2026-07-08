# Product Hunt gallery assets — Readr

Generated from CI screenshots (iPhone 1178×2556, macOS window captures) and the
app icon, using the Marginalia brand palette (Iris `#5B57C7`, warm paper
surfaces, muted literary highlight colors — see `docs/DESIGN.md`).

## Gallery slides (1270×760, upload in this order)

| # | File | Slot | Caption on slide | Screenshots used |
|---|------|------|------------------|------------------|
| 1 | `01-hero.png` | Hero / first gallery image | **Readr — Read deeper. Ask the book.** "The open-source AI ebook reader for Mac & iPhone. Highlight in one gesture, get answers with citations, and turn your notes into articles." + "EPUB · PDF · Markdown · Offline" | icon, m01 (macOS paged reader), 06 (iPhone notes panel) |
| 2 | `02-ask-the-book.png` | Feature: Ask | **Ask the book — answers with citations.** "Select a passage or ask about the whole book. Answers are grounded in the text, and every one cites the passages it came from." + "Tap a citation to see the source passage" | 16 (iPhone Ask panel with streamed answer + source chips) |
| 3 | `03-highlights-to-article.png` | Feature: Article studio | **Your highlights become an article.** "Every highlight streams into the Notes panel as you read. One tap composes them into a draft you can steer, edit, and export as clean Markdown." | 06 (notes panel + Compose article), 17 (composed article editor) |
| 4 | `04-one-gesture-highlight.png` | Feature: Annotation | **Highlight in one gesture.** "Select text and the popover is already there — one click to mark it in five muted, literary colors. Notes and questions live one tap further." | m08 (macOS scroll reader with highlights), m05 (annotation popovers, extracted) |
| 5 | `05-three-ways-to-turn-a-page.png` | Feature: Reading themes/layouts | **Three ways to turn a page.** "Scroll, single page, or a two-page spread — in Paper, Sepia & Dark." | 02 (iPhone paper scroll), 04 (iPhone sepia paged), 11 (iPhone dark paged), with theme captions |
| 6 | `06-dark-mode.png` | Feature: Dark mode | **Dark mode done properly.** "Highlights become alpha washes so the text stays luminous — Mac and iPhone." | m03 (macOS dark paged reader), 11 (iPhone dark reader) |
| 7 | `07-offline-local-llm.png` | Feature: Privacy/offline | **Fully offline with a local LLM.** "Bring Claude, ChatGPT, or an on-device model. Books, highlights, and questions never leave your device unless you choose a cloud model." + "No telemetry, no accounts — keys live in the Keychain" | 12 (iPhone AI Providers settings) |
| 8 | `08-epub-pdf-markdown.png` | Feature: Formats/library | **Reads EPUB, PDF & Markdown.** "PDFs get the same highlights, search, and Ask as any book — no lock-in." | m07 (macOS library grid with PDF/Finished badges), 15 (iPhone PDF reader) |

## Other assets

| File | Size | Slot |
|------|------|------|
| `thumbnail-240.png` | 240×240 | Product Hunt square thumbnail (from the app icon) |
| `social-preview-1280x640.png` | 1280×640 | GitHub repo social preview (Settings → Social preview) — icon, wordmark, tagline "The open-source AI ebook reader for Mac & iPhone", feature line "Ask your books · Highlights → articles · Works offline" |

## Regenerating

`generate.py` (in this directory) rebuilds every asset. It reads the raw
screenshots from the directory in `$READR_SHOTS` (see the script header for
the expected files/sizes) and the app icon from the repo, and writes here:

```sh
python3 generate.py    # needs Pillow and the DejaVu fonts
```

## Known issue: bug-affected macOS screenshots

The macOS captures m01, m02, m03 and m08 were taken while the reader had a
text-layout bug that clips lines mid-word at the page's right edge (a fix is
in flight in a separate PR). The current slides work around it:

- **01-hero** — m01's clipped right edge is hidden behind the overlapping
  iPhone frame (composition unchanged; the clipping was never visible here).
- **04-one-gesture-highlight** — the m08 window is oversized and bleeds off
  the right/bottom canvas edges, so the clipped edge and scrollbar are cropped
  away before they become visible.
- **05-three-ways-to-turn-a-page** — the m02 two-page spread (where the bug
  was most legible) was replaced entirely with three framed iPhone shots
  (Paper / Sepia / Dark).
- **06-dark-mode** — the iPhone frame was moved left to occlude m03's clipped
  right edge.

Once the fix lands and CI produces fresh macOS shots, slides 01, 04 and 06
should be regenerated (drop the shots into `$READR_SHOTS` and re-run
`generate.py`; the workaround crops/overlaps can then be relaxed), and slide
05 can optionally get its two-page-spread mac window back.

## Notes

- Devices are shown in simple rounded-rect frames with soft shadows (no
  simulated hardware); macOS captures sit in a window card with a title bar.
- Light slides use a paper→iris gradient; the dark-mode slide and the social
  preview use the dark surface with an iris glow, matching the icon.
- Typography: DejaVu Serif Bold headlines (≥52 px), DejaVu Sans body.
