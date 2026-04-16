"""Bulk ingest of labeled (content, views) pairs from CSV.

Supported schemas (auto-detected by header):
  - Generic:             content, views [, label]
  - X/Twitter export:    "Tweet text", "impressions"  (2025+ analytics CSV)
  - X/Twitter legacy:    "Tweet text", "views" / "Impressions"

Only appends text rows — image/ui/video bulk import would require the
raw assets, which users need to upload separately.
"""
from __future__ import annotations

import csv
import io
import json
from dataclasses import dataclass
from pathlib import Path

from api.config import LABELED_DIR


TEXT_COLS = ["content", "text", "tweet text", "Tweet text"]
VIEW_COLS = ["views", "impressions", "Impressions", "view_count", "views_count"]
LABEL_COLS = ["label", "note", "tag"]


@dataclass
class ImportResult:
    added: int
    skipped: int
    warnings: list[str]


def _pick(header: list[str], candidates: list[str]) -> str | None:
    lowered = {h.strip().lower(): h for h in header}
    for c in candidates:
        if c.lower() in lowered:
            return lowered[c.lower()]
    return None


def import_text_csv(raw: bytes) -> ImportResult:
    """Parse a CSV in memory, append matching rows to tweets.jsonl.

    Lenient: unknown columns ignored, missing label tolerated, malformed
    rows skipped with a warning. Does not dedupe (caller can pre-clean).
    """
    text = raw.decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(text))
    header = reader.fieldnames or []
    text_col = _pick(header, TEXT_COLS)
    view_col = _pick(header, VIEW_COLS)
    label_col = _pick(header, LABEL_COLS)
    if text_col is None or view_col is None:
        raise ValueError(
            f"Need content + views columns. Got header: {header!r}. "
            f"Accepted content columns: {TEXT_COLS}; view columns: {VIEW_COLS}"
        )

    out_path = LABELED_DIR / "tweets.jsonl"
    added = 0
    skipped = 0
    warnings: list[str] = []
    with out_path.open("a") as f:
        for i, row in enumerate(reader):
            content = (row.get(text_col) or "").strip()
            if not content:
                skipped += 1
                continue
            raw_views = (row.get(view_col) or "").replace(",", "").replace(" ", "").strip()
            try:
                views = float(raw_views)
            except ValueError:
                warnings.append(f"row {i + 2}: could not parse views={raw_views!r}")
                skipped += 1
                continue
            if views < 0:
                warnings.append(f"row {i + 2}: negative views ignored")
                skipped += 1
                continue
            label = (row.get(label_col) or "").strip() if label_col else ""
            rec = {
                "modality": "text",
                "content": content,
                "asset": None,
                "views": views,
                "label": label or "imported",
            }
            f.write(json.dumps(rec) + "\n")
            added += 1
    return ImportResult(added=added, skipped=skipped, warnings=warnings[:20])
