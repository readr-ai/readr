#!/usr/bin/env python3
"""Build the sample book Readr seeds into an empty library.

Readr ships one book so that a fresh install is never a dead end. Apple's
App Review hit exactly that dead end on 2026-09-01 (guideline 2.1(a)): the
reviewer opened Readr on an iPad, saw "Your library is empty", and had no
file on the device to import. A new user on a new phone has the same problem.

The text is Lewis Carroll's *Alice's Adventures in Wonderland* (1865), which
is in the public domain worldwide. It is sourced from Project Gutenberg but
every trace of Gutenberg's own wrapper -- the header, the licence, the
trademark boilerplate -- is stripped, so what ships is the bare public-domain
work and none of Gutenberg's terms attach to it.

Alice earns the slot on merit: twelve short chapters exercise the table of
contents, chapter skip and two-page spreads; the prose is famous enough that
a reviewer recognises it instantly; and at ~160KB it costs the bundle almost
nothing.

Regenerate with:  python3 scripts/make_sample_epub.py
"""
from __future__ import annotations

import html
import pathlib
import re
import sys
import urllib.request
import zipfile

SOURCE = "https://www.gutenberg.org/ebooks/11.txt.utf-8"
OUT = pathlib.Path("App/Resources/alice-in-wonderland.epub")
# A stable identifier, not a random UUID: regenerating the file must not look
# like a different book to anything that keys off the OPF id.
BOOK_ID = "urn:uuid:2f9a1c50-7d3e-4b8a-9c21-alice000wonder"
TITLE = "Alice's Adventures in Wonderland"
AUTHOR = "Lewis Carroll"

START = "*** START OF THE PROJECT GUTENBERG EBOOK"
END = "*** END OF THE PROJECT GUTENBERG EBOOK"
CHAPTER_RE = re.compile(r"^CHAPTER [IVXL]+\.$")


def fetch() -> str:
    with urllib.request.urlopen(SOURCE, timeout=90) as r:
        return r.read().decode("utf-8")


def strip_wrapper(raw: str) -> list[str]:
    """Return the body lines, with Gutenberg's header and footer removed."""
    lines = raw.splitlines()
    starts = [i for i, l in enumerate(lines) if l.startswith(START)]
    ends = [i for i, l in enumerate(lines) if l.startswith(END)]
    if not starts or not ends:
        sys.exit("Gutenberg markers not found -- the source layout changed.")
    return lines[starts[0] + 1 : ends[0]]


def split_chapters(body: list[str]) -> list[tuple[str, list[str]]]:
    """Split into (title, lines). Everything before chapter one is front
    matter -- Gutenberg's own contents list and edition note -- and is dropped,
    because Readr builds its own table of contents from the spine."""
    starts = [i for i, l in enumerate(body) if CHAPTER_RE.match(l.strip())]
    if len(starts) < 2:
        sys.exit("No chapter headings found -- the source layout changed.")
    chapters = []
    for n, begin in enumerate(starts):
        stop = starts[n + 1] if n + 1 < len(starts) else len(body)
        block = body[begin:stop]
        # "CHAPTER I." then the chapter's own title on the next non-blank line.
        number = block[0].strip().rstrip(".")
        rest = [l for l in block[1:3] if l.strip()]
        name = rest[0].strip() if rest else ""
        title = f"{number}. {name}" if name else number
        text = block[1 + (1 if rest else 0):]
        chapters.append((title, text))
    return chapters


def to_xhtml(title: str, lines: list[str]) -> str:
    """Paragraphs are blank-line separated; Gutenberg marks italics as _word_."""
    paragraphs, buf = [], []
    for line in lines:
        if line.strip():
            buf.append(line.strip())
        elif buf:
            paragraphs.append(" ".join(buf))
            buf = []
    if buf:
        paragraphs.append(" ".join(buf))

    body = []
    for p in paragraphs:
        p = html.escape(p)
        p = re.sub(r"_([^_]+)_", r"<em>\1</em>", p)
        body.append(f"    <p>{p}</p>")
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">\n'
        f"  <head><title>{html.escape(title)}</title>"
        '<meta charset="utf-8"/></head>\n'
        "  <body>\n"
        f"    <h1>{html.escape(title)}</h1>\n"
        + "\n".join(body)
        + "\n  </body>\n</html>\n"
    )


def build(chapters: list[tuple[str, list[str]]]) -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    items, spine, nav = [], [], []
    for i, (title, _) in enumerate(chapters, 1):
        items.append(
            f'    <item id="ch{i}" href="ch{i}.xhtml" media-type="application/xhtml+xml"/>'
        )
        spine.append(f'    <itemref idref="ch{i}"/>')
        nav.append(f'      <li><a href="ch{i}.xhtml">{html.escape(title)}</a></li>')

    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">{BOOK_ID}</dc:identifier>
    <dc:title>{html.escape(TITLE)}</dc:title>
    <dc:creator>{html.escape(AUTHOR)}</dc:creator>
    <dc:language>en</dc:language>
    <dc:rights>Public domain.</dc:rights>
    <meta property="dcterms:modified">2026-09-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
{chr(10).join(items)}
  </manifest>
  <spine>
{chr(10).join(spine)}
  </spine>
</package>
"""
    navdoc = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
  <head><title>Contents</title><meta charset="utf-8"/></head>
  <body>
    <nav epub:type="toc" id="toc">
      <h1>Contents</h1>
      <ol>
{chr(10).join(nav)}
      </ol>
    </nav>
  </body>
</html>
"""
    container = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
    with zipfile.ZipFile(OUT, "w") as z:
        # The mimetype entry must be first and stored uncompressed (OCF spec).
        z.writestr(
            zipfile.ZipInfo("mimetype"), "application/epub+zip", zipfile.ZIP_STORED
        )
        z.writestr("META-INF/container.xml", container, zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", navdoc, zipfile.ZIP_DEFLATED)
        for i, (title, lines) in enumerate(chapters, 1):
            z.writestr(f"OEBPS/ch{i}.xhtml", to_xhtml(title, lines), zipfile.ZIP_DEFLATED)


def main() -> None:
    chapters = split_chapters(strip_wrapper(fetch()))
    build(chapters)
    size = OUT.stat().st_size
    print(f"{OUT}: {len(chapters)} chapters, {size:,} bytes")
    for title, _ in chapters:
        print(f"  - {title}")
    # The whole point is that no Gutenberg terms ride along with the text.
    with zipfile.ZipFile(OUT) as z:
        blob = b"".join(z.read(n) for n in z.namelist()).decode("utf-8", "ignore")
    for banned in ("Project Gutenberg", "gutenberg.org", "PROJECT GUTENBERG"):
        if banned.lower() in blob.lower():
            sys.exit(f"FAIL: '{banned}' survived the strip -- fix the filter.")
    print("clean: no Project Gutenberg boilerplate in the output")


if __name__ == "__main__":
    main()
