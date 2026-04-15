"""Ingest smoke tests for each modality."""
import io
import tempfile
from pathlib import Path

from PIL import Image

from api.ingest import ingest_any


def _png_bytes(color=(200, 120, 60)) -> bytes:
    img = Image.new("RGB", (200, 200), color)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def test_text_ingest():
    with tempfile.TemporaryDirectory() as td:
        r = ingest_any("text", text="tweet content", workdir=Path(td))
        assert r.tribe_input.modality == "text"
        assert r.tribe_input.text_path is not None
        assert r.tribe_input.text_path.exists()


def test_image_ingest_produces_video():
    with tempfile.TemporaryDirectory() as td:
        r = ingest_any("image", image_bytes=_png_bytes(), workdir=Path(td))
        assert r.tribe_input.modality == "image"
        assert r.tribe_input.video_path is not None
        assert r.tribe_input.video_path.exists()
        assert r.tribe_input.video_path.stat().st_size > 0
        assert r.preview_path is not None and r.preview_path.exists()


def test_ui_ingest_produces_scanpath():
    with tempfile.TemporaryDirectory() as td:
        r = ingest_any("ui", image_bytes=_png_bytes((30, 30, 45)), workdir=Path(td))
        assert r.tribe_input.modality == "ui"
        assert r.tribe_input.video_path is not None
        assert r.tribe_input.video_path.exists()


def test_video_ingest_accepts_mp4():
    # Build a tiny real mp4 with imageio.
    import imageio.v2 as imageio
    import numpy as np
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "src.mp4"
        w = imageio.get_writer(path, fps=10, codec="libx264", quality=6, macro_block_size=1)
        try:
            for i in range(20):
                frame = np.full((120, 120, 3), i * 10 % 255, dtype=np.uint8)
                w.append_data(frame)
        finally:
            w.close()
        r = ingest_any("video", video_bytes=path.read_bytes(), workdir=Path(td))
        assert r.tribe_input.modality == "video"
        assert r.tribe_input.video_path is not None
        assert r.tribe_input.video_path.exists()
