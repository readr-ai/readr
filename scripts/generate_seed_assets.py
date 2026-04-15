"""Generate a varied seed dataset of image/UI/video assets.

These are synthetic but stylistically diverse: different palettes,
compositions, text densities. Each gets a plausible view count so the
autoresearch loop has signal to chew on for the non-text modalities.

Run once:
    python scripts/generate_seed_assets.py

Outputs to data/labeled/assets/{image,ui,video}/ and appends JSONL rows
to data/labeled/{images,ui,reels}.jsonl.
"""
from __future__ import annotations

import json
import math
import random
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "data" / "labeled" / "assets"
LABELED = REPO / "data" / "labeled"
for sub in ("image", "ui", "video"):
    (ASSETS / sub).mkdir(parents=True, exist_ok=True)


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]:
        if Path(candidate).exists():
            try:
                return ImageFont.truetype(candidate, size)
            except Exception:
                continue
    return ImageFont.load_default()


# ---------------------------------------------------------------------------
# Image variants (meme-like content)
# ---------------------------------------------------------------------------

IMAGE_CONFIGS = [
    {
        "name": "loud_meme",
        "bg": (255, 60, 100),
        "text_top": "WHEN YOUR MODEL",
        "text_bottom": "ACTUALLY WORKS",
        "views": 142000,
        "label": "High contrast, caps meme format",
    },
    {
        "name": "minimal_announce",
        "bg": (18, 18, 24),
        "text_top": "new",
        "text_bottom": "tribe v2",
        "views": 68000,
        "label": "Minimal branded announcement",
    },
    {
        "name": "cluttered_infographic",
        "bg": (240, 240, 245),
        "text_top": "",
        "text_bottom": "",
        "overlay": "info",
        "views": 8200,
        "label": "Cluttered infographic, low engagement",
    },
    {
        "name": "gradient_stat",
        "bg": None,
        "gradient": ((120, 30, 200), (240, 70, 120)),
        "text_top": "221,100",
        "text_bottom": "views",
        "views": 95000,
        "label": "Big number on gradient",
    },
    {
        "name": "blank_empty",
        "bg": (230, 230, 230),
        "text_top": "",
        "text_bottom": "",
        "views": 400,
        "label": "Empty beige -- nothing to see",
    },
    {
        "name": "dark_tweet_screenshot",
        "bg": (20, 22, 28),
        "text_top": "so meta just open-sourced",
        "text_bottom": "a brain response model.",
        "views": 187000,
        "label": "Screenshot-style hook text",
    },
    {
        "name": "chart_no_caption",
        "bg": (255, 255, 255),
        "overlay": "chart",
        "text_top": "",
        "text_bottom": "",
        "views": 6100,
        "label": "Chart without narrative caption",
    },
    {
        "name": "face_silhouette",
        "bg": (25, 10, 40),
        "overlay": "face",
        "text_top": "",
        "text_bottom": "",
        "views": 73000,
        "label": "Face silhouette draws fusiform attention",
    },
    {
        "name": "warm_quote",
        "bg": (250, 200, 100),
        "text_top": "\"ship the thing\"",
        "text_bottom": "— every founder",
        "views": 42000,
        "label": "Warm quote card",
    },
    {
        "name": "tech_spec_boring",
        "bg": (245, 245, 250),
        "overlay": "specs",
        "text_top": "",
        "text_bottom": "",
        "views": 2400,
        "label": "Pure spec sheet",
    },
]


def _gradient(size, start, end):
    img = Image.new("RGB", size)
    px = img.load()
    w, h = size
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(start[0] * (1 - t) + end[0] * t)
        g = int(start[1] * (1 - t) + end[1] * t)
        b = int(start[2] * (1 - t) + end[2] * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def _draw_chart(draw: ImageDraw.ImageDraw, w: int, h: int):
    pad = 50
    pts = [(pad + i * (w - 2 * pad) // 10, h - pad - int(80 + 40 * math.sin(i))) for i in range(11)]
    draw.line(pts, fill=(0, 120, 240), width=3)
    draw.rectangle([pad, h - pad, w - pad, h - pad + 2], fill=(120, 120, 120))
    draw.rectangle([pad, pad, pad + 2, h - pad], fill=(120, 120, 120))


def _draw_face(draw: ImageDraw.ImageDraw, w: int, h: int):
    cx, cy = w // 2, h // 2
    r = min(w, h) // 4
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(200, 180, 220), width=4)
    draw.ellipse([cx - r // 2, cy - r // 4, cx - r // 2 + 12, cy - r // 4 + 12], fill=(200, 180, 220))
    draw.ellipse([cx + r // 2 - 12, cy - r // 4, cx + r // 2, cy - r // 4 + 12], fill=(200, 180, 220))
    draw.arc([cx - r // 2, cy, cx + r // 2, cy + r // 2], 0, 180, fill=(200, 180, 220), width=3)


def _draw_info(draw: ImageDraw.ImageDraw, w: int, h: int, font):
    labels = ["USERS", "GROWTH", "CHURN", "MRR", "CAC", "LTV", "NPS"]
    for i, lab in enumerate(labels):
        x = 40 + (i % 3) * 200
        y = 40 + (i // 3) * 100
        draw.rectangle([x, y, x + 150, y + 70], outline=(80, 80, 90), width=2)
        draw.text((x + 10, y + 10), lab, fill=(40, 40, 40), font=font)
        draw.text((x + 10, y + 40), f"{random.randint(10, 99)}%", fill=(40, 40, 40), font=font)


def _draw_specs(draw: ImageDraw.ImageDraw, w: int, h: int, font):
    rows = [
        "Dim: 2048", "Heads: 32", "Layers: 40",
        "Seq: 8192", "Dtype: bf16", "Tokens/s: 1800",
    ]
    for i, r in enumerate(rows):
        draw.text((40, 40 + i * 40), r, fill=(40, 40, 40), font=font)


def build_images() -> list[dict]:
    size = (640, 640)
    font_big = _font(84)
    font_small = _font(36)
    rows: list[dict] = []
    for cfg in IMAGE_CONFIGS:
        if cfg.get("gradient"):
            img = _gradient(size, *cfg["gradient"])
        else:
            img = Image.new("RGB", size, cfg["bg"])
        draw = ImageDraw.Draw(img)
        if cfg.get("overlay") == "chart":
            _draw_chart(draw, *size)
        elif cfg.get("overlay") == "face":
            _draw_face(draw, *size)
        elif cfg.get("overlay") == "info":
            _draw_info(draw, *size, font=font_small)
        elif cfg.get("overlay") == "specs":
            _draw_specs(draw, *size, font=font_small)
        if cfg.get("text_top"):
            draw.text((40, 80), cfg["text_top"], fill=(255, 255, 255) if sum(cfg["bg"] or (255, 255, 255)) < 400 else (20, 20, 20), font=font_big)
        if cfg.get("text_bottom"):
            draw.text((40, 440), cfg["text_bottom"], fill=(255, 255, 255) if sum(cfg["bg"] or (255, 255, 255)) < 400 else (20, 20, 20), font=font_big)

        rel = f"image/{cfg['name']}.jpg"
        (ASSETS / "image" / f"{cfg['name']}.jpg").parent.mkdir(parents=True, exist_ok=True)
        img.save(ASSETS / rel, quality=85)
        rows.append({
            "modality": "image",
            "content": None,
            "asset": rel,
            "views": cfg["views"],
            "label": cfg["label"],
        })
    return rows


# ---------------------------------------------------------------------------
# UI screenshot variants
# ---------------------------------------------------------------------------

UI_CONFIGS = [
    {"name": "landing_clean",      "palette": "indigo",  "density": "low",    "views": 84000,  "label": "Clean landing, strong hierarchy"},
    {"name": "landing_cluttered",  "palette": "gray",    "density": "high",   "views": 3600,   "label": "Cluttered landing, weak hierarchy"},
    {"name": "dashboard_data",     "palette": "slate",   "density": "charts", "views": 21000,  "label": "Data-dense dashboard"},
    {"name": "pricing_aligned",    "palette": "purple",  "density": "pricing","views": 48000,  "label": "Clean three-tier pricing"},
    {"name": "dark_admin",         "palette": "black",   "density": "charts", "views": 12000,  "label": "Dark admin panel"},
    {"name": "launch_hero",        "palette": "magenta", "density": "hero",   "views": 132000, "label": "Launch hero with huge CTA"},
    {"name": "form_wall",          "palette": "gray",    "density": "form",   "views": 1900,   "label": "Wall of form fields"},
    {"name": "mobile_onboard",     "palette": "cyan",    "density": "low",    "views": 56000,  "label": "Mobile onboarding card"},
]

PALETTES = {
    "indigo":  ((79, 70, 229), (238, 242, 255), (30, 27, 75)),
    "gray":    ((107, 114, 128), (243, 244, 246), (17, 24, 39)),
    "slate":   ((51, 65, 85), (226, 232, 240), (15, 23, 42)),
    "purple":  ((147, 51, 234), (250, 245, 255), (59, 7, 100)),
    "black":   ((30, 30, 36), (17, 17, 24), (234, 234, 241)),
    "magenta": ((219, 39, 119), (255, 240, 245), (80, 7, 36)),
    "cyan":    ((6, 182, 212), (236, 254, 255), (22, 78, 99)),
}


def _ui_canvas(palette: str):
    accent, bg, fg = PALETTES[palette]
    img = Image.new("RGB", (1280, 800), bg)
    return img, accent, fg


def build_ui() -> list[dict]:
    font_xxl = _font(56)
    font_lg = _font(32)
    font_md = _font(22)
    font_sm = _font(14)
    rows: list[dict] = []
    for cfg in UI_CONFIGS:
        img, accent, fg = _ui_canvas(cfg["palette"])
        draw = ImageDraw.Draw(img)
        # Top nav
        draw.rectangle([0, 0, 1280, 64], fill=accent)
        draw.text((32, 18), "● brand", fill=(255, 255, 255), font=font_md)
        for i, link in enumerate(["Product", "Pricing", "Docs", "Login"]):
            draw.text((900 + i * 90, 22), link, fill=(255, 255, 255), font=font_sm)

        if cfg["density"] == "low":
            draw.text((80, 180), "Predict before you post.", fill=fg, font=font_xxl)
            draw.text((80, 260), "Brain-response scoring for creators.", fill=fg, font=font_lg)
            draw.rounded_rectangle([80, 360, 300, 420], radius=10, fill=accent)
            draw.text((112, 378), "Try it free", fill=(255, 255, 255), font=font_md)
        elif cfg["density"] == "high":
            for row in range(6):
                for col in range(4):
                    x, y = 60 + col * 300, 100 + row * 110
                    draw.rectangle([x, y, x + 260, y + 90], outline=accent, width=1)
                    draw.text((x + 12, y + 12), f"Feature {row * 4 + col + 1}", fill=fg, font=font_md)
                    draw.text((x + 12, y + 48), "lorem ipsum dolor sit amet", fill=fg, font=font_sm)
        elif cfg["density"] == "charts":
            for i in range(3):
                x = 80 + i * 380
                draw.rounded_rectangle([x, 120, x + 340, 360], radius=12, fill=(255, 255, 255, 30), outline=accent, width=1)
                _draw_chart(draw, 340, 240)  # positioned in a local sense; fine for seed asset
                draw.text((x + 16, 132), f"Metric {i + 1}", fill=fg, font=font_md)
            # table
            for i in range(6):
                draw.rectangle([80, 420 + i * 48, 1200, 420 + i * 48 + 40], outline=accent, width=1)
                draw.text((100, 430 + i * 48), f"Row {i + 1}   ·   value {100 - i * 7}", fill=fg, font=font_sm)
        elif cfg["density"] == "pricing":
            tiers = [("Starter", "$0"), ("Pro", "$29"), ("Team", "$99")]
            for i, (name, price) in enumerate(tiers):
                x = 160 + i * 340
                draw.rounded_rectangle([x, 180, x + 280, 600], radius=16, fill=(255, 255, 255), outline=accent, width=2)
                draw.text((x + 24, 208), name, fill=fg, font=font_lg)
                draw.text((x + 24, 270), price, fill=accent, font=font_xxl)
                for j in range(5):
                    draw.text((x + 24, 380 + j * 36), f"✓ feature {j + 1}", fill=fg, font=font_sm)
        elif cfg["density"] == "hero":
            draw.text((80, 200), "SCORE ANYTHING", fill=accent, font=font_xxl)
            draw.text((80, 280), "Your brain on content.", fill=fg, font=font_lg)
            draw.rounded_rectangle([80, 400, 400, 480], radius=12, fill=accent)
            draw.text((120, 422), "Start scoring →", fill=(255, 255, 255), font=font_lg)
        elif cfg["density"] == "form":
            fields = ["Email", "Password", "First name", "Last name", "Company", "Role", "Team size", "Country", "Phone", "Referral source"]
            for i, lab in enumerate(fields):
                y = 110 + i * 60
                draw.text((100, y), lab, fill=fg, font=font_sm)
                draw.rounded_rectangle([260, y - 6, 900, y + 30], radius=6, outline=accent, width=1)

        rel = f"ui/{cfg['name']}.png"
        img.save(ASSETS / rel)
        rows.append({
            "modality": "ui",
            "content": None,
            "asset": rel,
            "views": cfg["views"],
            "label": cfg["label"],
        })
    return rows


# ---------------------------------------------------------------------------
# Short video variants via imageio + ffmpeg
# ---------------------------------------------------------------------------

VIDEO_CONFIGS = [
    {"name": "flash_cuts_pink",  "palette": [(255, 60, 100), (255, 140, 60), (60, 220, 255)], "tempo": "fast",  "views": 198000, "label": "Fast pink/orange flash cuts"},
    {"name": "slow_gradient",    "palette": [(20, 10, 40), (40, 20, 80), (80, 30, 140)],        "tempo": "slow",  "views": 7200,   "label": "Slow dark gradient, low motion"},
    {"name": "punchy_text",      "palette": [(0, 0, 0), (255, 255, 255)],                        "tempo": "medium", "views": 83000, "label": "B&W text pop, medium tempo"},
    {"name": "greenscreen_glow", "palette": [(0, 255, 128), (30, 200, 80), (10, 100, 40)],      "tempo": "fast",   "views": 54000, "label": "Neon green flicker"},
]


def build_videos() -> list[dict]:
    import imageio.v2 as imageio
    import numpy as np
    W, H, fps = 480, 480, 15
    rows: list[dict] = []
    for cfg in VIDEO_CONFIGS:
        seconds = 6
        frames = []
        for i in range(int(seconds * fps)):
            t = i / (seconds * fps)
            palette = cfg["palette"]
            if cfg["tempo"] == "fast":
                c = palette[i % len(palette)]
            elif cfg["tempo"] == "medium":
                c = palette[(i // 5) % len(palette)]
            else:
                a = palette[0]
                b = palette[-1]
                c = tuple(int(a[k] * (1 - t) + b[k] * t) for k in range(3))
            frame = np.full((H, W, 3), c, dtype=np.uint8)
            # Add a drifting circle for motion
            cx = int(W / 2 + 0.3 * W * math.sin(6 * t * math.pi))
            cy = int(H / 2 + 0.2 * H * math.cos(4 * t * math.pi))
            yy, xx = np.ogrid[:H, :W]
            mask = (xx - cx) ** 2 + (yy - cy) ** 2 < (W // 8) ** 2
            frame[mask] = (255 - c[0], 255 - c[1], 255 - c[2])
            frames.append(frame)
        out = ASSETS / f"video/{cfg['name']}.mp4"
        out.parent.mkdir(parents=True, exist_ok=True)
        writer = imageio.get_writer(out, fps=fps, codec="libx264", quality=6, macro_block_size=1)
        try:
            for fr in frames:
                writer.append_data(fr)
        finally:
            writer.close()
        rows.append({
            "modality": "video",
            "content": None,
            "asset": f"video/{cfg['name']}.mp4",
            "views": cfg["views"],
            "label": cfg["label"],
        })
    return rows


def main() -> int:
    random.seed(20260415)
    img_rows = build_images()
    ui_rows = build_ui()
    vid_rows = build_videos()

    def write_jsonl(path: Path, rows: list[dict]) -> None:
        path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")

    write_jsonl(LABELED / "images.jsonl", img_rows)
    write_jsonl(LABELED / "ui.jsonl", ui_rows)
    write_jsonl(LABELED / "reels.jsonl", vid_rows)

    print(f"Wrote {len(img_rows)} image, {len(ui_rows)} UI, {len(vid_rows)} video rows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
