# App Store listing copy

One field per file, applied by `scripts/asc_metadata.py` via the App Store
metadata workflow. Character limits are checked before any API call.

## Plain text: dropped, then reinstated

**Resolved 2026-08-08 — plain text is back.** The paginator fix landed (#71)
and ships in v2.15.1: an unspaced 100 KB chapter went from 1,877 ms to under
300 ms, and a novel-sized spaced chapter from ~4,600 ms to ~230 ms. The
listing may advertise the format again because the build it points at can
deliver it.

The rule below is kept, because it is the rule and not just the incident:
**the listing describes the attached build, not `main`.** A fix that is merged
but not yet in an uploaded build does not entitle the listing to claim it.

### The original reason for dropping it

Readr reads `.txt` perfectly well, and the in-app messages say so. The App
Store description deliberately doesn't advertise it.

`LayoutPaginator` is O(n²) in chapter length and runs on the main thread. A
plain `.txt` has no headings, so the whole book becomes a single chapter —
a Gutenberg novel is one 300–600 KB chapter and takes 4.4–4.8 s to paginate,
freezing the reader. Normal EPUB chapters (~25 KB) are unaffected, which is
why it survived to launch: the format most testing used never hits it.

Grabbing a free Gutenberg `.txt` is exactly what a curious first-time user
does, so advertising the format points people at the worst path. Markdown
stays: a heading-less `.md` hits the same code, but real Markdown files are
small — a 300 KB one is rare, a 300 KB novel is not.

Put it back once the paginator fix ships. The listing is version-controlled
and applied by a workflow, so that is a one-line change and a dispatch, not a
retype.
