"""FastAPI service: scoring + autoresearch + history + labeling.

Endpoints:
  POST /score/text         body: {"text": "..."}                     -> ScoreResponse
  POST /score/image        multipart: file=<image>                   -> ScoreResponse
  POST /score/ui           multipart: file=<screenshot>              -> ScoreResponse
  POST /score/video        multipart: file=<mp4>                     -> ScoreResponse
  GET  /score/{id}                                                   -> cached ScoreResponse
  GET  /score/{id}/brain.png                                         -> fsaverage5 cortex render
  POST /labeled/add        body: {"id": ..., "views": ..., "label"}  -> appends to dataset
  GET  /autoresearch/history                                         -> list of experiments
  POST /autoresearch/run?budget=5&offline=true                       -> SSE stream
  GET  /autoresearch/current                                         -> {score_py, rubric}
  GET  /healthz                                                      -> status
"""
from __future__ import annotations

import asyncio
import hashlib
import importlib
import json
import shutil
import tempfile
from pathlib import Path
from typing import Literal

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from api.autoresearch.runner import EXPERIMENTS_LOG, run_autoresearch
from api.config import ASSETS_DIR, DATA_DIR, LABELED_DIR, SCORING_DIR, settings
from api.ingest import ingest_any
from api.scoring.score import ViralityScore
from api.tribe.cache import cache_key
from api.tribe.client import get_client

app = FastAPI(title="CBT Virality API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.cors_origin, "http://localhost:3000", "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

RESULTS_DIR = DATA_DIR / "results"
INPUTS_DIR = DATA_DIR / "inputs"          # persisted original content for labeling
PREDS_DIR = DATA_DIR / "preds"            # persisted TRIBE preds per result id (npy)
for p in (RESULTS_DIR, INPUTS_DIR, PREDS_DIR):
    p.mkdir(exist_ok=True)


class TextIn(BaseModel):
    text: str


class LabelIn(BaseModel):
    id: str
    views: float
    label: str = ""


def _vs_to_dict(vs: ViralityScore, extra: dict) -> dict:
    return {
        "score": vs.score,
        "roi_breakdown": vs.roi_breakdown,
        "engagement_timeline": vs.engagement_timeline,
        "dead_zones": vs.dead_zones,
        "hotspots": vs.hotspots,
        "suggested_edits": vs.suggested_edits,
        "meta": vs.meta,
        **extra,
    }


def _reload_score_mod():
    import sys
    if "api.scoring.score" in sys.modules:
        return importlib.reload(sys.modules["api.scoring.score"])
    return importlib.import_module("api.scoring.score")


def _persist_input(modality: str, result_id: str, *, text: str | None,
                   content_bytes: bytes | None, suffix: str) -> None:
    """Save the raw input next to the result so it can later become a
    training example via POST /labeled/add."""
    if modality == "text":
        (INPUTS_DIR / f"{result_id}.txt").write_text(text or "", encoding="utf-8")
    else:
        assert content_bytes is not None
        (INPUTS_DIR / f"{result_id}{suffix}").write_bytes(content_bytes)


def _input_path_for(result_id: str) -> Path | None:
    for p in INPUTS_DIR.glob(f"{result_id}.*"):
        return p
    return None


def _run_pipeline(
    modality: str,
    workdir: Path,
    *,
    text: str | None = None,
    image_bytes: bytes | None = None,
    video_bytes: bytes | None = None,
) -> dict:
    score_mod = _reload_score_mod()
    kwargs: dict = {}
    if text is not None:
        kwargs["text"] = text
    if image_bytes is not None:
        kwargs["image_bytes"] = image_bytes
    if video_bytes is not None:
        kwargs["video_bytes"] = video_bytes
    ing = ingest_any(modality, workdir=workdir, **kwargs)
    client = get_client()
    pred = client.predict_cached(ing.tribe_input)
    vs = score_mod.score(pred)

    result_id = ing.raw_hash
    # Persist preds so /brain.png can render later without re-running TRIBE.
    np.save(PREDS_DIR / f"{result_id}.npy", pred.preds.astype(np.float16))

    # Persist raw input.
    if modality == "text":
        _persist_input(modality, result_id, text=text, content_bytes=None, suffix=".txt")
    elif modality in ("image", "ui"):
        _persist_input(modality, result_id, text=None, content_bytes=image_bytes, suffix=".bin")
    elif modality == "video":
        _persist_input(modality, result_id, text=None, content_bytes=video_bytes, suffix=".mp4")

    payload = _vs_to_dict(
        vs,
        extra={
            "id": result_id,
            "modality": modality,
            "duration_s": pred.duration_s,
            "sampling_hz": settings.sampling_hz,
            "backend": pred.meta.get("backend"),
            "input_preview": (text if modality == "text" else None),
        },
    )
    (RESULTS_DIR / f"{result_id}.json").write_text(json.dumps(payload))
    return payload


# --- Scoring endpoints ------------------------------------------------------


@app.get("/healthz")
def health():
    return {"ok": True, "backend": settings.tribe_backend}


@app.post("/score/text")
def score_text(body: TextIn):
    if not body.text.strip():
        raise HTTPException(400, "empty text")
    with tempfile.TemporaryDirectory() as td:
        return _run_pipeline("text", Path(td), text=body.text)


@app.post("/score/image")
async def score_image(file: UploadFile = File(...)):
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")
    with tempfile.TemporaryDirectory() as td:
        return _run_pipeline("image", Path(td), image_bytes=data)


@app.post("/score/ui")
async def score_ui(file: UploadFile = File(...)):
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")
    with tempfile.TemporaryDirectory() as td:
        return _run_pipeline("ui", Path(td), image_bytes=data)


@app.post("/score/video")
async def score_video(file: UploadFile = File(...)):
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty upload")
    with tempfile.TemporaryDirectory() as td:
        return _run_pipeline("video", Path(td), video_bytes=data)


@app.get("/score/{result_id}")
def get_result(result_id: str):
    fp = RESULTS_DIR / f"{result_id}.json"
    if not fp.exists():
        raise HTTPException(404, "unknown result id")
    return json.loads(fp.read_text())


@app.get("/score/{result_id}/brain.png")
def get_brain(result_id: str):
    """Render the fsaverage5 cortex coloured by this result's peak response."""
    npy = PREDS_DIR / f"{result_id}.npy"
    if not npy.exists():
        raise HTTPException(404, "no cached preds for this result")
    preds = np.load(npy).astype(np.float32)
    try:
        from api.scoring.brain import render_cortex_png
        png_path = render_cortex_png(preds)
    except ImportError as e:
        raise HTTPException(500, f"nilearn/matplotlib not installed: {e}")
    return FileResponse(png_path, media_type="image/png")


# --- Labeling (add-to-training-set) -----------------------------------------


@app.post("/labeled/add")
def add_label(body: LabelIn):
    """Promote a scored result into the labeled dataset used by autoresearch."""
    result_fp = RESULTS_DIR / f"{body.id}.json"
    if not result_fp.exists():
        raise HTTPException(404, "unknown result id")
    result = json.loads(result_fp.read_text())
    modality = result["modality"]
    input_fp = _input_path_for(body.id)

    row: dict = {"modality": modality, "views": float(body.views), "label": body.label or ""}

    if modality == "text":
        if input_fp is None:
            raise HTTPException(404, "original text not persisted")
        row["content"] = input_fp.read_text(encoding="utf-8")
        row["asset"] = None
        target = LABELED_DIR / "tweets.jsonl"
    else:
        if input_fp is None:
            raise HTTPException(404, "original asset not persisted")
        # Copy the asset into data/labeled/assets/<modality>/<id>.<ext>
        ext_map = {"image": ".jpg", "ui": ".png", "video": ".mp4"}
        # Preserve whatever suffix we stored (.bin or .mp4) but map to a
        # friendly extension based on modality.
        target_ext = ext_map[modality]
        dst_rel = f"{modality}/{body.id}{target_ext}"
        dst_abs = ASSETS_DIR / dst_rel
        dst_abs.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(input_fp, dst_abs)
        row["content"] = None
        row["asset"] = dst_rel
        jsonl_name = {"image": "images.jsonl", "ui": "ui.jsonl", "video": "reels.jsonl"}[modality]
        target = LABELED_DIR / jsonl_name

    with target.open("a") as f:
        f.write(json.dumps(row) + "\n")
    return {"ok": True, "written_to": str(target.relative_to(DATA_DIR.parent))}


@app.get("/labeled/stats")
def labeled_stats():
    out: dict[str, int] = {}
    for jf in sorted(LABELED_DIR.glob("*.jsonl")):
        out[jf.stem] = sum(1 for _ in jf.read_text().splitlines() if _.strip())
    return out


# --- Autoresearch -----------------------------------------------------------


@app.get("/autoresearch/history")
def history():
    if not EXPERIMENTS_LOG.exists():
        return []
    out = []
    for line in EXPERIMENTS_LOG.read_text().splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


@app.get("/autoresearch/current")
def current_scoring():
    return {
        "score_py": (SCORING_DIR / "score.py").read_text(),
        "rubric": (SCORING_DIR / "rubric.md").read_text(),
    }


@app.post("/autoresearch/run")
async def run_experiments(budget: int = 5, offline: bool = False):
    async def event_stream():
        loop = asyncio.get_event_loop()
        gen = await loop.run_in_executor(
            None, lambda: list(run_autoresearch(budget=budget, offline=offline))
        )
        for entry in gen:
            yield {"event": "experiment", "data": json.dumps(entry)}
        yield {"event": "done", "data": "{}"}

    return EventSourceResponse(event_stream())
