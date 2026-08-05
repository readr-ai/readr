#!/usr/bin/env python3
"""
Build docs/marketing/website-mockup.html from the Claude Design canvas file
"Readr Landing.dc.html" (screen 2a — the combined direction).

The design file is a design-canvas document: markup plus {{ bindings }} and
<sc-if> conditionals that the canvas runtime resolves. This script extracts
screen 2a and rewrites those canvas constructs into a standalone page with
real vanilla-JS interactivity.

Re-run after pulling a fresh copy of the design:
    DesignSync get_file -> /tmp/readr-landing-raw.html
    python3 build-from-design.py
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
RAW = Path("/tmp/readr-landing-raw.html")
OUT = HERE / "website-mockup.html"
REPO = "https://github.com/readr-ai/readr"


def extract_screen(doc: str, screen_id: str) -> str:
    """Pull one screen div out of the canvas by matching div depth."""
    start = doc.find(f'<div id="{screen_id}"')
    if start < 0:
        sys.exit(f"screen {screen_id} not found")
    depth, pos = 0, start
    for m in re.finditer(r"<(/?)div\b", doc[start:]):
        depth += -1 if m.group(1) else 1
        if depth == 0:
            end = doc.index(">", start + m.end()) + 1
            return doc[start:end]
    sys.exit("unbalanced markup")


def extract_helmet_css(doc: str) -> str:
    h = doc[doc.find("<helmet>") + 8 : doc.find("</helmet>")]
    return "\n".join(re.findall(r"<style>([\s\S]*?)</style>", h))


# ---------------------------------------------------------------- content
BOOKS = {
    "moby": {
        "title": "Moby-Dick",
        "kicker": "CHAPTER 96 · THE TRY-WORKS",
        "question": "What are try-works, actually?",
        "src1": "Ch. 96 · The Try-Works",
        "src2": "Ch. 98 · Stowing Down",
        "answer": (
            "Try-works were brick furnaces built into the whaler's deck — iron "
            "pots where blubber was boiled into oil at sea, so a ship could keep "
            "hunting for years without returning to port."
        ),
    },
    "frank": {
        "title": "Frankenstein",
        "kicker": "CHAPTER V",
        "question": "Could anyone actually do this now?",
        "src1": "Ch. 5",
        "src2": "Ch. 4",
        "answer": (
            "In the book: Shelley keeps the method vague — galvanism and "
            "\"instruments of life.\" Beyond it: germline editing is the real "
            "analogue, and after the 2018 CRISPR-twins case its researcher was "
            "jailed."
        ),
    },
    "origin": {
        "title": "Origin of Species",
        "kicker": "CHAPTER IV · NATURAL SELECTION",
        "question": "Has any of this been overturned since?",
        "src1": "Ch. 4",
        "src2": "Ch. 1",
        "answer": (
            "The core mechanism has held for 165 years. What changed is the "
            "substrate: Darwin had no gene, so drift, horizontal transfer and "
            "punctuated tempo all arrived later."
        ),
    },
}

ARTICLE_P1 = (
    "Knight never explains the company as a business plan. He explains it as a "
    "way of making a life legible to himself — you build the thing so you can "
    "point at it. <em>\"It was the only way I saw to make life meaningful.\"</em> "
    "Every founder story written since is a footnote to that sentence."
)
ARTICLE_P2 = (
    "What makes the line land is what surrounds it: a man describing a shoe "
    "company as <em>\"a living, breathing thing\"</em> he had carried through "
    "illness."
)


def rewrite(block: str) -> str:
    s = block

    # Outer canvas wrapper -> plain page container
    s = re.sub(r'^<div id="2a"[^>]*>', '<div class="page">', s)
    # Canvas screen-number badge
    s = re.sub(r'<div style="position: absolute; top: 14px; left: 14px; '
               r'z-index: 60;[^>]*>2a</div>\s*', "", s)

    # <sc-if> conditionals -> real elements toggled by JS
    sc_map = {
        "showMoby": '<div class="bookpane" data-book="moby">',
        "showFrank": '<div class="bookpane" data-book="frank" hidden>',
        "showOrigin": '<div class="bookpane" data-book="origin" hidden>',
        "notComposed": '<div id="composeHint">',
        "composed": '<div id="articleDraft" hidden>',
    }

    def sc_open(m):
        return sc_map[m.group(1)]

    s = re.sub(r'<sc-if value="\{\{ (\w+) \}\}"[^>]*>', sc_open, s)
    s = s.replace("</sc-if>", "</div>")

    # Book tabs: canvas handlers/colours -> data attribute + CSS class
    for key in ("Moby", "Frank", "Origin"):
        s = s.replace(f'onClick="{{{{ set{key} }}}}"',
                      f'class="tab" data-tab="{key.lower()}"')
        s = s.replace(f'background: {{{{ tabBg{key} }}}}; '
                      f'color: {{{{ tabFg{key} }}}};', "")

    # Buttons
    s = s.replace('onClick="{{ compose }}"', 'id="composeBtn"')
    s = s.replace('onClick="{{ join }}"', 'id="joinBtn"')
    s = s.replace("animation: {{ composeAnim }};", "")
    s = re.sub(r'\s*style-hover="[^"]*"', "", s)

    # Highlight reveal animation
    s = s.replace("background-size: {{ hlSize }};",
                  "background-size: var(--hl-size, 0% 100%);")

    # Text bindings -> spans JS fills
    s = s.replace("{{ bookTitle }}", '<span data-b="title">Moby-Dick</span>')
    s = s.replace("{{ bookKicker }}",
                  '<span data-b="kicker">CHAPTER 96 · THE TRY-WORKS</span>')
    s = s.replace("{{ bookQuestion }}",
                  '<span data-b="question">What are try-works, actually?</span>')
    s = s.replace("{{ stream }}", '<span data-b="stream"></span>')
    s = s.replace("{{ src1 }}", '<span data-b="src1"></span>')
    s = s.replace("{{ src2 }}", '<span data-b="src2"></span>')
    s = s.replace("{{ articleP1 }}", ARTICLE_P1)
    s = s.replace("{{ articleP2 }}", ARTICLE_P2)
    s = s.replace("{{ composeLabel }}",
                  '<span id="composeLabel">✦ Compose article</span>')
    s = s.replace("{{ joinLabel }}",
                  '<span id="joinLabel">Join the waitlist</span>')

    # Caret
    s = re.sub(r'<span style="color: #5B57C7; animation: blink 1s step-end '
               r'infinite; display: \{\{ caretDisp \}\};">▍</span>',
               '<span class="caret" data-b="caret">▍</span>', s)

    # Annotation callouts get a class so they can be hidden on narrow screens
    s = s.replace('<span style="position: absolute; left: -2',
                  '<span class="callout" style="position: absolute; left: -2')
    s = s.replace('<span style="position: absolute; right: -2',
                  '<span class="callout" style="position: absolute; right: -2')

    # Fixed display sizes -> fluid (inline styles can't be beaten by a media query)
    s = s.replace("font-size: 72px", "font-size: clamp(2.6rem, 7.2vw, 72px)")
    s = re.sub(r"font-size: (2\.[0-9]+rem); font-weight: 500",
               r"font-size: clamp(1.8rem, 4.4vw, \1); font-weight: 500", s)

    # Section anchors: the canvas leaves every link pointing at "#2a"
    for comment, sec_id in (
        ("Ask the book", "ask"),
        ("Margins → article", "margins"),
        ("Your model, your rules", "model"),
        ("Close", "waitlist"),
    ):
        s = s.replace(f"<!-- {comment} -->\n      <section",
                      f'<!-- {comment} -->\n      <section id="{sec_id}"',
                      1)
    s = s.replace('<div style="width: 414px; max-width: 100%; margin: 56px auto 0;',
                  '<div id="reader" style="width: 414px; max-width: 100%; margin: 56px auto 0;',
                  1)

    nav = {
        ">The reader<": ("#reader", ">The reader<"),
        ">Ask the book<": ("#ask", ">Ask the book<"),
        ">Margins<": ("#margins", ">Margins<"),
        ">Privacy<": ("#privacy", ">Privacy<"),
        ">GitHub<": (REPO, ">GitHub<"),
        ">Join the waitlist<": ("#waitlist", ">Join the waitlist<"),
        ">MIT License<": (REPO + "/blob/main/LICENSE", ">MIT License<"),
        ">Download for macOS<": (REPO + "/releases/latest", ">Download for macOS<"),
    }
    for label, (href, _) in nav.items():
        s = re.sub(r'href="#2a"((?:(?!</a>)[\s\S])*?' + re.escape(label) + ")",
                   lambda m, h=href: f'href="{h}"' + m.group(1), s)
    # Anything still pointing at the canvas anchor
    s = s.replace('href="#2a"', 'href="#waitlist"')

    leftover = re.findall(r"\{\{[^}]*\}\}", s)
    if leftover:
        sys.exit(f"unresolved bindings: {sorted(set(leftover))}")
    if "<sc-" in s:
        sys.exit("unresolved sc- element")
    return s


PAGE_CSS = """
  *, *::before, *::after { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background: #F7F3EB;
    color: #2E2A23;
    font-family: 'Literata', 'Iowan Old Style', Georgia, serif;
    font-size: 17px;
    line-height: 1.74;
    -webkit-font-smoothing: antialiased;
  }
  .page { position: relative; width: 100%; overflow-x: hidden; }
  img { max-width: 100%; }
  a { color: inherit; }
  a:focus-visible, button:focus-visible, input:focus-visible {
    outline: 2px solid #5B57C7; outline-offset: 3px; border-radius: 4px;
  }
  button:hover { filter: brightness(1.08); }

  /* Book tabs */
  .tab { background: #FDFAF4; color: #2E2A23; transition: background .2s, color .2s; }
  .tab[aria-selected="true"] { background: #2E2A23; color: #F7F3EB; }

  .caret { color: #5B57C7; animation: blink 1s step-end infinite; }
  @keyframes blink { 50% { opacity: 0; } }

  /* Highlight sweep, triggered when the phone scrolls into view */
  .bookpane[data-lit] { --hl-size: 100% 100%; }

  #articleDraft[hidden], #composeHint[hidden] { display: none; }

  @media (max-width: 1180px) { .callout { display: none !important; } }
  @media (max-width: 900px) {
    body { font-size: 16px; }
    .page section { padding-left: 20px !important; padding-right: 20px !important; }
    /* the canvas lays these out as fixed side-by-side columns */
    .page [style*="grid-template-columns"] { grid-template-columns: 1fr !important; }
    .page [style*="padding: 0 48px"] { padding-left: 20px !important; padding-right: 20px !important; }
  }
  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    .caret { animation: none; }
    * { transition-duration: 0.01ms !important; }
  }
"""

PAGE_JS = """
(function () {
  var BOOKS = __BOOKS__;
  var reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  var q = function (s, r) { return (r || document).querySelector(s); };
  var qa = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };

  var bind = {};
  qa('[data-b]').forEach(function (el) { bind[el.dataset.b] = el; });

  var typer = null;
  var current = null;
  function show(key, opts) {
    var b = BOOKS[key];
    if (!b) return;
    current = key;
    qa('.bookpane').forEach(function (p) { p.hidden = p.dataset.book !== key; });
    qa('.tab').forEach(function (t) {
      t.setAttribute('aria-selected', String(t.dataset.tab === key));
    });
    bind.title.textContent = b.title;
    bind.kicker.textContent = b.kicker;
    bind.question.textContent = b.question;
    bind.src1.textContent = b.src1;
    bind.src2.textContent = b.src2;
    if (opts && opts.quiet) {
      clearTimeout(typer);
      bind.stream.textContent = '';
    } else {
      stream(b.answer);
    }
    var pane = q('.bookpane[data-book="' + key + '"]');
    if (pane) requestAnimationFrame(function () { pane.dataset.lit = '1'; });
  }

  function stream(text) {
    clearTimeout(typer);
    if (reduced) {
      bind.stream.textContent = text;
      if (bind.caret) bind.caret.style.display = 'none';
      return;
    }
    bind.stream.textContent = '';
    if (bind.caret) bind.caret.style.display = '';
    var i = 0;
    (function step() {
      if (i <= text.length) {
        bind.stream.textContent = text.slice(0, i);
        i += 2;
        typer = setTimeout(step, 22);
      } else if (bind.caret) {
        bind.caret.style.display = 'none';
      }
    })();
  }

  qa('.tab').forEach(function (t) {
    t.addEventListener('click', function () { show(t.dataset.tab); });
  });

  // Render the demo's resting state immediately, then stream once it is seen.
  show('moby', { quiet: true });

  var phone = q('#reader') || q('.bookpane');
  var started = false;
  function begin() {
    if (started) return;
    started = true;
    if (current) stream(BOOKS[current].answer);
  }
  if ('IntersectionObserver' in window && phone) {
    var io = new IntersectionObserver(function (es, o) {
      if (es[0].isIntersecting) { begin(); o.disconnect(); }
    }, { threshold: 0.15 });
    io.observe(phone);
    // If it is already on screen (or scrolled past) at load, do not wait.
    var r = phone.getBoundingClientRect();
    if (r.top < innerHeight && r.bottom > 0) begin();
  } else { begin(); }

  // Compose article
  var composeBtn = q('#composeBtn');
  var label = q('#composeLabel');
  var hint = q('#composeHint');
  var draft = q('#articleDraft');
  if (composeBtn) {
    composeBtn.addEventListener('click', function () {
      if (draft && !draft.hidden) return;
      label.textContent = '✦ Composing…';
      setTimeout(function () {
        if (hint) hint.hidden = true;
        if (draft) draft.hidden = false;
        label.textContent = '✦ Compose article';
      }, reduced ? 0 : 900);
    });
  }

  // Waitlist (visual only — needs a real endpoint before launch)
  var joinBtn = q('#joinBtn');
  if (joinBtn) {
    joinBtn.addEventListener('click', function () {
      var email = q('input[type="email"]');
      if (email && !email.checkValidity()) { email.focus(); return; }
      q('#joinLabel').textContent = 'Thanks — check your inbox';
    });
  }
})();
"""


def main():
    doc = RAW.read_text()
    css = extract_helmet_css(doc)
    body = rewrite(extract_screen(doc, "2a"))

    import json
    js = PAGE_JS.replace("__BOOKS__", json.dumps(BOOKS, ensure_ascii=False))

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Readr — for the love of reading</title>
<meta name="description" content="Readr is a book reader with an AI that has read the whole book. Ask questions as you read and get cited answers in the margin. Free and open source.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,300..700;1,7..72,300..700&display=swap" rel="stylesheet">
<style>
{css}
{PAGE_CSS}</style>
</head>
<body>
{body}
<script>
{js}
</script>
</body>
</html>
"""
    OUT.write_text(html)
    print(f"wrote {OUT} ({len(html) // 1024} KiB)")


if __name__ == "__main__":
    main()
