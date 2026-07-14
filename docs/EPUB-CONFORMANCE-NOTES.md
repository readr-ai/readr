# EPUB conformance — deliberately deferred items

Found during the 2026-07 EPUB conformance audit but left unchanged because the
fix is risky or out of scope for the launch window. Each entry says why.

- **Nested TOC hierarchy.** `TOCEntry` supports `children`, but the new nav/NCX
  parsing emits a flat list (nested navPoints/`<ol>`s are flattened in document
  order). The reader UI currently renders a flat TOC; producing hierarchy now
  would change UI behavior untested this close to launch.
- **Full HTML5 named-entity table.** The extractor now covers the XML five,
  all of Latin-1, and the HTML4 typographic set (~140 entities). The full HTML5
  list is 2,000+ entries (many with non-semicolon forms); unknown references
  are left visibly intact, which is a safe degradation.
- **Non-Latin legacy encodings (Shift-JIS, GB2312, KOI8-R, …).** `decodeText`
  honors UTF-8/UTF-16 BOMs and prolog-declared latin-1/cp1252/ascii/utf-16,
  then falls back to Latin-1 so a chapter is never dropped. Mapping more
  charset names is easy but each needs a real fixture to verify; mojibake
  fallback was judged acceptable for launch.
- **ZIP-entry lookup fallbacks in `ZipEPUBContainer` (App target).** Books
  whose OPF href case doesn't match the archive entry case (or with NFC/NFD
  differences) still miss. Fixing belongs in the app-side container and can't
  be exercised by the Linux test suite; the parser already skips the chapter
  instead of failing the book.
- **UTF-32 BOM detection.** `FF FE 00 00` collides with the UTF-16LE BOM
  prefix; UTF-32 EPUBs are effectively nonexistent in the wild.
- **`linear="no"` chapters are appended but not marked.** The model has no
  "auxiliary content" flag, so the reader can't visually separate endnotes
  appended after the main flow. Adding a Chapter field was judged too invasive
  for this pass.
- **Fixed-layout notice when *opening* an already-imported FXL book.** The
  informational alert fires once at import (AppModel.importNotice). Books
  imported before this change carry no flag (nil = reflowable), and a
  reader-open notice would need per-book "already shown" state; left as a
  follow-up.
