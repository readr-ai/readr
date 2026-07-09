# Product Hunt gallery assets — Readr

Generated from CI screenshots (iPhone 1178×2556, macOS window captures) and the
app icon, using the Marginalia brand palette (Iris `#5B57C7`, warm paper
surfaces, muted literary highlight colors — see `docs/DESIGN.md`). The captures
show the redesigned Apple-Books-style paged reader (full-bleed paper that fills
the window, bottom-center page label), so every mac window and phone screen is
shown un-cropped, with no clipping workarounds.

## Gallery slides (1270×760, upload in this order)

| # | File | Slot | Caption on slide | Screenshots used |
|---|------|------|------------------|------------------|
| 1 | `01-hero.png` | Hero / first gallery image | **Readr — Read deeper. Ask the book.** "The open-source AI ebook reader for Mac & iPhone. Highlight in one gesture, get answers with citations, and turn your notes into articles." + "EPUB · PDF · Markdown · Offline" | icon, m01 (macOS paged reader), 06 (iPhone notes panel) |
| 2 | `02-ask-the-book.png` | Feature: Ask | **Ask the book — answers with citations.** "Select a passage or ask about the whole book. Answers are grounded in the text, and every one cites the passages it came from." + "Tap a citation to see the source passage" | 16 (iPhone Ask panel with streamed answer + source chips) |
| 3 | `03-highlights-to-article.png` | Feature: Article studio | **Your highlights become an article.** "Every highlight streams into the Notes panel as you read. One tap composes them into a draft you can steer, edit, and export as clean Markdown." | 06 (notes panel + Compose article), 17 (composed article editor) |
| 4 | `04-one-gesture-highlight.png` | Feature: Annotation | **Highlight in one gesture.** "Select text and the popover is already there — one click to mark it in five muted, literary colors. Notes and questions live one tap further." | m08 (macOS scroll reader with highlights), m05 (annotation popovers, extracted) |
| 5 | `05-three-ways-to-turn-a-page.png` | Feature: Reading themes/layouts | **Three ways to turn a page.** "Scroll, single page, or a two-page spread — in Paper, Sepia & Dark." | m02 (macOS sepia two-page spread, centerpiece), 02 (iPhone paper scroll), 11 (iPhone dark single page), with mode · theme captions |
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

## Notes

- Devices are shown in simple rounded-rect frames with soft shadows (no
  simulated hardware); macOS captures sit in a window card with a title bar.
- Light slides use a paper→iris gradient; the dark-mode slide and the social
  preview use the dark surface with an iris glow, matching the icon.
- Typography: DejaVu Serif Bold headlines (≥52 px), DejaVu Sans body.
