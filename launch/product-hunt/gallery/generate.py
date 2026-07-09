#!/usr/bin/env python3
"""Generate the Product Hunt gallery assets for Readr.

Outputs (written to OUT, this directory by default):
  01..08-*.png              eight 1270x760 gallery slides
  thumbnail-240.png         240x240 PH thumbnail (app icon)
  social-preview-1280x640.png

Expected inputs:
  SHOTS  directory of raw app screenshots (override with $READR_SHOTS):
           NN-<name>*.png   iPhone screenshots, 1178x2556 (iPhone 15 Pro sim)
           mNN-<name>*.png  macOS screenshots (m01/m03: 900x700, m02: 1200x760,
                            m08: 1100x760, m05: annotation popover bars,
                            m07: library grid)
         Shots are looked up by their numeric prefix, e.g. shot("04").
  ICON   the 1024px app icon from the repo (override with $READR_ICON).

Re-run:  python3 generate.py          (needs Pillow >= 10; DejaVu fonts,
                                       present by default on Debian/Ubuntu)

The shots are the post-redesign (Apple-Books-style, full-bleed paper) captures:
the paged reader fills the window with a bottom-center page label and no
clipping, so every mac window is shown un-cropped.
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS = os.environ.get(
    "READR_SHOTS",
    "/tmp/claude-0/-home-user-readr/fd3d7334-8854-59f0-a6c5-10fdb5ddac1b/scratchpad/shots2")
OUT = os.environ.get("READR_OUT", os.path.dirname(os.path.abspath(__file__)))
ICON = os.environ.get("READR_ICON",
                      "/home/user/readr/App/Assets.xcassets/AppIcon.appiconset/ios-1024.png")
os.makedirs(OUT, exist_ok=True)

W, H = 1270, 760

IRIS = (91, 87, 199)
IRIS_LIGHT = (147, 142, 233)
INK = (43, 38, 32)
INK_SOFT = (43, 38, 32, 178)
PAPER = (247, 243, 234)
PAPER_TINT = (235, 233, 246)
DARK_BG = (26, 24, 29)
DARK_BG2 = (34, 30, 27)
CREAM = (243, 239, 231)
CREAM_SOFT = (206, 199, 186)

F = "/usr/share/fonts/truetype/dejavu/"
def serif_b(s): return ImageFont.truetype(F + "DejaVuSerif-Bold.ttf", s)
def sans(s): return ImageFont.truetype(F + "DejaVuSans.ttf", s)
def sans_b(s): return ImageFont.truetype(F + "DejaVuSans-Bold.ttf", s)


def shot(name):
    import glob
    m = glob.glob(os.path.join(SHOTS, name + "*"))
    assert m, name
    return Image.open(m[0]).convert("RGB")


def rounded(im, radius):
    """Return RGBA image with antialiased rounded corners."""
    S = 4
    mask = Image.new("L", (im.width * S, im.height * S), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, im.width * S - 1, im.height * S - 1], radius * S, fill=255)
    mask = mask.resize(im.size, Image.LANCZOS)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out


def paste_shadow(canvas, size, pos, radius, blur=26, alpha=80, dy=16):
    pad = blur * 3
    s = Image.new("RGBA", (size[0] + pad * 2, size[1] + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(s)
    d.rounded_rectangle([pad, pad, pad + size[0], pad + size[1]], radius, fill=(22, 16, 10, alpha))
    s = s.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(s, (pos[0] - pad, pos[1] - pad + dy))


def phone_frame(im, height):
    """Simple rounded-rect device frame (dark bezel), no fake hardware details."""
    w = int(round(im.width * height / im.height))
    im = im.resize((w, height), Image.LANCZOS)
    r = int(w * 0.145)
    screen = rounded(im, r)
    b = max(7, int(w * 0.034))
    fw, fh = w + 2 * b, height + 2 * b
    bez = Image.new("RGB", (fw, fh), (24, 24, 28))
    bez = rounded(bez, r + b)
    # subtle bezel edge highlight
    d = ImageDraw.Draw(bez)
    d.rounded_rectangle([0, 0, fw - 1, fh - 1], r + b, outline=(255, 255, 255, 40), width=1)
    bez.alpha_composite(screen, (b, b))
    return bez


def place_phone(canvas, im, height, pos, blur=30, alpha=95):
    ph = phone_frame(im, height)
    paste_shadow(canvas, ph.size, pos, int(ph.width * 0.16), blur=blur, alpha=alpha)
    canvas.alpha_composite(ph, pos)
    return ph.size


def mac_window(im, width, dark=False, title=""):
    scale = width / im.width
    h = int(round(im.height * scale))
    im = im.resize((width, h), Image.LANCZOS)
    tb = 40
    bar = (40, 37, 34) if dark else (240, 235, 225)
    win = Image.new("RGB", (width, h + tb), bar)
    win.paste(im, (0, tb))
    d = ImageDraw.Draw(win)
    for i, c in enumerate([(236, 106, 94), (245, 191, 79), (98, 197, 84)]):
        cx, cy = 26 + i * 23, tb // 2
        d.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], fill=c)
    if title:
        f = sans(15)
        tw = d.textlength(title, font=f)
        col = (170, 163, 152) if dark else (120, 112, 100)
        d.text(((width - tw) / 2, (tb - 18) / 2), title, font=f, fill=col)
    d.line([0, tb - 1, width, tb - 1], fill=(0, 0, 0) if dark else (208, 201, 188))
    out = rounded(win, 14)
    # hairline border
    d2 = ImageDraw.Draw(out)
    d2.rounded_rectangle([0, 0, out.width - 1, out.height - 1], 14,
                         outline=(255, 255, 255, 30) if dark else (43, 38, 32, 50), width=1)
    return out


def place_window(canvas, im, width, pos, dark=False, title="", alpha=75):
    win = mac_window(im, width, dark=dark, title=title)
    paste_shadow(canvas, win.size, pos, 14, blur=24, alpha=alpha)
    canvas.alpha_composite(win, pos)
    return win.size


def spark(size, color):
    """Four-point star glyph."""
    S = 4
    im = Image.new("RGBA", (size * S, size * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size * S / 2
    s = size * S / 2
    k = 0.24
    pts = [(c, c - s), (c + s * k, c - s * k), (c + s, c), (c + s * k, c + s * k),
           (c, c + s), (c - s * k, c + s * k), (c - s, c), (c - s * k, c - s * k)]
    d.polygon(pts, fill=color)
    return im.resize((size, size), Image.LANCZOS)


def gradient(w, h, top, bottom):
    im = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        im.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return im.resize((w, h), Image.NEAREST)


def glow(canvas, center, radius, color, alpha):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius],
              fill=color + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(radius / 2.2))
    canvas.alpha_composite(layer)


def slide_bg(dark=False, hero=False):
    if dark:
        base = gradient(W, H, DARK_BG, DARK_BG2).convert("RGBA")
        glow(base, (1080, -60), 380, IRIS, 60)
        glow(base, (120, 820), 340, IRIS, 34)
    else:
        base = gradient(W, H, PAPER_TINT, PAPER).convert("RGBA")
        glow(base, (1120, -80), 420, IRIS, 42 if hero else 30)
        glow(base, (60, 830), 360, (196, 150, 60), 22)  # faint amber, bottom-left
    return base


def brand_tag(canvas, dark=False):
    d = ImageDraw.Draw(canvas)
    col = CREAM_SOFT if dark else (43, 38, 32)
    sp = spark(18, IRIS_LIGHT if dark else IRIS)
    canvas.alpha_composite(sp, (48, 40))
    f = sans_b(20)
    txt = "R E A D R"
    if dark:
        d.text((78, 40), txt, font=f, fill=col + (200,) if isinstance(col, tuple) and len(col) == 3 else col)
    else:
        d.text((78, 40), txt, font=f, fill=(43, 38, 32, 150))


def wrap(draw, text, font, maxw):
    words = text.split()
    lines, cur = [], ""
    for w_ in words:
        t = (cur + " " + w_).strip()
        if draw.textlength(t, font=font) <= maxw:
            cur = t
        else:
            if cur:
                lines.append(cur)
            cur = w_
    if cur:
        lines.append(cur)
    return lines


def text_block(canvas, x, y, headline, sub, maxw, dark=False, hsize=54, ssize=30, center=False):
    d = ImageDraw.Draw(canvas)
    hf, sf = serif_b(hsize), sans(ssize)
    hcol = CREAM if dark else INK
    scol = (206, 199, 186, 235) if dark else (43, 38, 32, 185)
    yy = y
    for line in wrap(d, headline, hf, maxw):
        lw = d.textlength(line, font=hf)
        xx = x + (maxw - lw) / 2 if center else x
        d.text((xx, yy), line, font=hf, fill=hcol)
        yy += int(hsize * 1.22)
    yy += 14
    for line in wrap(d, sub, sf, maxw):
        lw = d.textlength(line, font=sf)
        xx = x + (maxw - lw) / 2 if center else x
        d.text((xx, yy), line, font=sf, fill=scol)
        yy += int(ssize * 1.42)
    return yy


def save(canvas, name):
    canvas.convert("RGB").save(os.path.join(OUT, name), "PNG")
    print("wrote", name)


# ---------------------------------------------------------------- slide 1: hero
def hero():
    c = slide_bg(hero=True)
    # right cluster: mac window and phone side by side — the reader is now
    # full-bleed paper (text right up to the page margins), so nothing may
    # overlap the mac window without appearing to cut lines off.
    win = shot("m01")
    place_window(c, win, 470, (560, 215), title="Sample Book — Readr")
    place_phone(c, shot("06"), 460, (1040, 190))
    # left text
    icon = Image.open(ICON).convert("RGB").resize((132, 132), Image.LANCZOS)
    icon = rounded(icon, 30)
    paste_shadow(c, icon.size, (92, 128), 30, blur=18, alpha=70, dy=8)
    c.alpha_composite(icon, (92, 128))
    d = ImageDraw.Draw(c)
    d.text((248, 146), "Readr", font=serif_b(84), fill=INK)
    y = 320
    hf = serif_b(44)
    for line in ["Read deeper.", "Ask the book."]:
        d.text((96, y), line, font=hf, fill=INK)
        y += 56
    y += 18
    sf = sans(27)
    for line in wrap(d, "The open-source AI ebook reader for Mac & iPhone. "
                        "Highlight in one gesture, get answers with citations, "
                        "and turn your notes into articles.", sf, 440):
        d.text((96, y), line, font=sf, fill=(43, 38, 32, 190))
        y += 38
    y += 22
    sp = spark(20, IRIS)
    c.alpha_composite(sp, (96, y + 2))
    d.text((126, y), "EPUB  ·  PDF  ·  Markdown  ·  Offline", font=sans_b(22), fill=IRIS)
    save(c, "01-hero.png")


# ---------------------------------------------------------------- slide 2: ask
def ask():
    c = slide_bg()
    brand_tag(c)
    place_phone(c, shot("16"), 620, (860, 70))
    y = text_block(c, 96, 200, "Ask the book — answers with citations",
                   "Select a passage or ask about the whole book. Answers are "
                   "grounded in the text, and every one cites the passages it came from.",
                   640, hsize=56)
    d = ImageDraw.Draw(c)
    sp = spark(20, IRIS)
    c.alpha_composite(sp, (96, y + 26))
    d.text((126, y + 24), "Tap a citation to see the source passage", font=sans_b(23), fill=IRIS)
    save(c, "02-ask-the-book.png")


# ---------------------------------------------------------------- slide 3: article
def article():
    c = slide_bg()
    brand_tag(c)
    place_phone(c, shot("06"), 560, (700, 116))
    place_phone(c, shot("17"), 560, (990, 116))
    text_block(c, 88, 210,
               "Your highlights become an article",
               "Every highlight streams into the Notes panel as you read. "
               "One tap composes them into a draft you can steer, edit, and "
               "export as clean Markdown.",
               540, hsize=54)
    save(c, "03-highlights-to-article.png")


# ---------------------------------------------------------------- slide 4: annotate
def annotate():
    c = slide_bg()
    brand_tag(c)
    # the full-bleed m08 scroll capture is clean, so the window sits fully on
    # canvas, un-cropped
    place_window(c, shot("m08"), 720, (530, 105), title="Sample Book")
    # m05 is two white popover bars on a black backdrop — extract each bar
    m05 = shot("m05")
    gray = m05.convert("L").point(lambda p: 255 if p > 60 else 0)
    top_bb = gray.crop((0, 0, m05.width, 90)).getbbox()
    bot_bb = gray.crop((0, 90, m05.width, m05.height)).getbbox()
    bars = [m05.crop((top_bb[0], top_bb[1], top_bb[2], top_bb[3])),
            m05.crop((bot_bb[0], bot_bb[1] + 90, bot_bb[2], bot_bb[3] + 90))]
    positions = [(600, 525), (680, 640)]
    for bar, pos in zip(bars, positions):
        s = 1.55
        bar = bar.resize((int(bar.width * s), int(bar.height * s)), Image.LANCZOS)
        bar = rounded(bar, int(bar.height * 0.24))
        db = ImageDraw.Draw(bar)
        db.rounded_rectangle([0, 0, bar.width - 1, bar.height - 1], int(bar.height * 0.24),
                             outline=(43, 38, 32, 55), width=1)
        paste_shadow(c, bar.size, pos, int(bar.height * 0.24), blur=22, alpha=100)
        c.alpha_composite(bar, pos)
    text_block(c, 88, 210,
               "Highlight in one gesture",
               "Select text and the popover is already there — one click to mark "
               "it in five muted, literary colors. Notes and questions live one "
               "tap further.",
               430, hsize=54)
    save(c, "04-one-gesture-highlight.png")


# ---------------------------------------------------------------- slide 5: pages
def pages():
    # The macOS sepia two-page spread (m02) is the centerpiece, flanked by
    # iPhone scroll (paper) and single-page (dark) shots — one item per mode.
    c = slide_bg()
    brand_tag(c)
    text_block(c, 85, 46,
               "Three ways to turn a page",
               "Scroll, single page, or a two-page spread — in Paper, Sepia & Dark.",
               1100, hsize=52, ssize=27, center=True)
    d = ImageDraw.Draw(c)
    cf = sans_b(21)
    gap = 46
    win = mac_window(shot("m02"), 620, title="Sample Book")
    items = [("phone", "02", 400, 228, "Scroll · Paper"),
             ("win", None, None, 210, "Two-page spread · Sepia"),
             ("phone", "11", 400, 228, "Single page · Dark")]
    sizes = [phone_frame(shot(n), h).size if kind == "phone" else win.size
             for kind, n, h, _, _ in items]
    total = sum(s[0] for s in sizes) + gap * (len(items) - 1)
    x = (W - total) // 2
    for (kind, n, h, y, label), (fw, fh) in zip(items, sizes):
        if kind == "phone":
            place_phone(c, shot(n), h, (x, y))
        else:
            paste_shadow(c, win.size, (x, y), 14, blur=24, alpha=75)
            c.alpha_composite(win, (x, y))
        lw = d.textlength(label, font=cf)
        d.text((x + (fw - lw) / 2, 672), label, font=cf, fill=(43, 38, 32, 170))
        x += fw + gap
    save(c, "05-three-ways-to-turn-a-page.png")


# ---------------------------------------------------------------- slide 6: dark
def dark():
    c = slide_bg(dark=True)
    brand_tag(c, dark=True)
    text_block(c, 85, 46,
               "Dark mode done properly",
               "Highlights become alpha washes so the text stays luminous — Mac and iPhone.",
               1100, hsize=52, ssize=27, center=True, dark=True)
    # Side by side, no overlap — the full-bleed m03 capture is clean edge to
    # edge, so the whole mac page stays visible.
    place_window(c, shot("m03"), 620, (167, 216), dark=True, title="Sample Book", alpha=160)
    place_phone(c, shot("11"), 540, (837, 188), alpha=160)
    save(c, "06-dark-mode.png")


# ---------------------------------------------------------------- slide 7: offline
def offline():
    c = slide_bg()
    brand_tag(c)
    place_phone(c, shot("12"), 620, (860, 70))
    y = text_block(c, 96, 190,
                   "Fully offline with a local LLM",
                   "Bring Claude, ChatGPT, or an on-device model. Books, highlights, "
                   "and questions never leave your device unless you choose a cloud "
                   "model.",
                   640, hsize=56)
    d = ImageDraw.Draw(c)
    sp = spark(20, IRIS)
    c.alpha_composite(sp, (96, y + 26))
    d.text((126, y + 24), "No telemetry, no accounts — keys live in the Keychain",
           font=sans_b(23), fill=IRIS)
    save(c, "07-offline-local-llm.png")


# ---------------------------------------------------------------- slide 8: formats
def formats():
    c = slide_bg()
    text_block(c, 85, 46,
               "Reads EPUB, PDF & Markdown",
               "PDFs get the same highlights, search, and Ask as any book — no lock-in.",
               1100, hsize=52, ssize=27, center=True)
    place_window(c, shot("m07"), 700, (70, 208), title="All Books — Readr")
    place_phone(c, shot("15"), 500, (930, 208))
    save(c, "08-epub-pdf-markdown.png")


# ---------------------------------------------------------------- thumbnail
def thumbnail():
    icon = Image.open(ICON).convert("RGB").resize((240, 240), Image.LANCZOS)
    icon.save(os.path.join(OUT, "thumbnail-240.png"), "PNG")
    print("wrote thumbnail-240.png")


# ---------------------------------------------------------------- social preview
def social():
    SW, SH = 1280, 640
    c = gradient(SW, SH, (24, 22, 27), (36, 31, 27)).convert("RGBA")
    glow(c, (1150, -40), 400, IRIS, 66)
    glow(c, (80, 700), 340, IRIS, 40)
    icon = Image.open(ICON).convert("RGB").resize((300, 300), Image.LANCZOS)
    icon = rounded(icon, 68)
    d = ImageDraw.Draw(c)
    paste_shadow(c, icon.size, (110, 170), 68, blur=34, alpha=170, dy=12)
    c.alpha_composite(icon, (110, 170))
    d.text((480, 168), "Readr", font=serif_b(120), fill=CREAM)
    yy = 330
    for line in wrap(d, "The open-source AI ebook reader for Mac & iPhone", sans(40), 700):
        d.text((484, yy), line, font=sans(40), fill=(206, 199, 186, 240))
        yy += 56
    yy += 22
    feat = "Ask your books  ·  Highlights → articles  ·  Works offline"
    fs = 27
    while d.textlength(feat, font=sans_b(fs)) > 1210 - 522:
        fs -= 1
    sp = spark(22, IRIS_LIGHT)
    c.alpha_composite(sp, (484, yy + 4))
    d.text((522, yy), feat, font=sans_b(fs), fill=IRIS_LIGHT)
    c.convert("RGB").save(os.path.join(OUT, "social-preview-1280x640.png"), "PNG")
    print("wrote social-preview-1280x640.png")


if __name__ == "__main__":
    hero(); ask(); article(); annotate(); pages(); dark(); offline(); formats()
    thumbnail(); social()
    print("done")
