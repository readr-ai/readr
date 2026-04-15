"""End-to-end API tests via FastAPI TestClient."""
import io
import json

import pytest
from fastapi.testclient import TestClient
from PIL import Image


@pytest.fixture
def client():
    from api.main import app
    return TestClient(app)


def _png(bg=(70, 120, 200)) -> bytes:
    img = Image.new("RGB", (256, 256), bg)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_score_text_roundtrip(client):
    r = client.post("/score/text", json={"text": "score this tweet"})
    assert r.status_code == 200
    data = r.json()
    assert data["modality"] == "text"
    assert "id" in data
    # Retrieve by id
    r2 = client.get(f"/score/{data['id']}")
    assert r2.status_code == 200
    assert r2.json()["id"] == data["id"]


def test_score_text_rejects_empty(client):
    r = client.post("/score/text", json={"text": "   "})
    assert r.status_code == 400


def test_score_image(client):
    r = client.post("/score/image", files={"file": ("x.png", _png(), "image/png")})
    assert r.status_code == 200
    assert r.json()["modality"] == "image"


def test_score_ui(client):
    r = client.post("/score/ui", files={"file": ("ui.png", _png((20, 20, 30)), "image/png")})
    assert r.status_code == 200
    assert r.json()["modality"] == "ui"


def test_label_add_text(client):
    # Score a tweet then promote it to training set.
    text = "unique-tweet-for-label-test"
    r = client.post("/score/text", json={"text": text})
    result_id = r.json()["id"]
    r2 = client.post("/labeled/add", json={"id": result_id, "views": 1234, "label": "test row"})
    assert r2.status_code == 200
    assert r2.json()["ok"] is True

    # Find our row in the labeled file.
    from api.config import LABELED_DIR
    contents = (LABELED_DIR / "tweets.jsonl").read_text().splitlines()
    hit = [json.loads(l) for l in contents if text in l]
    assert hit, "row was not appended to tweets.jsonl"

    # Clean up: remove the test row so the seed dataset stays pristine.
    kept = [l for l in contents if text not in l]
    (LABELED_DIR / "tweets.jsonl").write_text("\n".join(kept) + ("\n" if kept else ""))


def test_autoresearch_current(client):
    r = client.get("/autoresearch/current")
    assert r.status_code == 200
    body = r.json()
    assert "def score(" in body["score_py"]
    assert "rubric" in body["rubric"].lower() or len(body["rubric"]) > 0


def test_labeled_stats(client):
    r = client.get("/labeled/stats")
    assert r.status_code == 200
    stats = r.json()
    assert isinstance(stats, dict)
    assert stats.get("tweets", 0) > 0
