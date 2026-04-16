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


def test_compare_text_ranks_results(client):
    r = client.post(
        "/compare/text",
        json={
            "variants": [
                "a short greeting",
                "here's a thread of 10 things that will change your 2026",
                "reading the new paper.",
            ]
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["modality"] == "text"
    assert "winner_id" in body
    assert len(body["results"]) == 3
    # Ranks must be 1..N and scores monotonically non-increasing.
    ranks = [r["rank"] for r in body["results"]]
    assert ranks == [1, 2, 3]
    scores = [r["score"] for r in body["results"]]
    for a, b in zip(scores, scores[1:]):
        assert a >= b


def test_compare_rejects_empty(client):
    r = client.post("/compare/text", json={"variants": ["   "]})
    assert r.status_code == 400


def test_predicted_views_attached_to_scoring(client):
    r = client.post("/score/text", json={"text": "some scorable content"})
    data = r.json()
    assert "predicted_views" in data
    v = data["predicted_views"]
    assert "low" in v and "mid" in v and "high" in v and "n" in v


def test_calibration_status(client):
    r = client.get("/calibration/status")
    assert r.status_code == 200
    body = r.json()
    assert body["n"] > 0


def test_csv_import_generic_schema(client):
    import io
    csv_bytes = (
        "content,views,label\n"
        "imported tweet A,12345,csv-a\n"
        "imported tweet B,67890,\n"
        ",100,empty-content-skipped\n"
        "bad row,not-a-number,also-skipped\n"
    ).encode()
    r = client.post(
        "/labeled/import_csv",
        files={"file": ("x.csv", csv_bytes, "text/csv")},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["added"] == 2
    assert body["skipped"] == 2

    # Clean up: remove the rows we just added.
    from api.config import LABELED_DIR
    lines = (LABELED_DIR / "tweets.jsonl").read_text().splitlines()
    kept = [l for l in lines if "imported tweet" not in l]
    (LABELED_DIR / "tweets.jsonl").write_text("\n".join(kept) + ("\n" if kept else ""))


def test_csv_import_x_analytics_schema(client):
    csv_bytes = b'"Tweet text","impressions"\n"hello world from X",5000\n'
    r = client.post(
        "/labeled/import_csv",
        files={"file": ("x.csv", csv_bytes, "text/csv")},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["added"] == 1

    from api.config import LABELED_DIR
    lines = (LABELED_DIR / "tweets.jsonl").read_text().splitlines()
    kept = [l for l in lines if "hello world from X" not in l]
    (LABELED_DIR / "tweets.jsonl").write_text("\n".join(kept) + ("\n" if kept else ""))


def test_csv_import_rejects_missing_columns(client):
    r = client.post(
        "/labeled/import_csv",
        files={"file": ("bad.csv", b"foo,bar\na,b\n", "text/csv")},
    )
    assert r.status_code == 400


def test_timeline_csv_export(client):
    r = client.post("/score/text", json={"text": "timeline export test"})
    rid = r.json()["id"]
    r2 = client.get(f"/score/{rid}/timeline.csv")
    assert r2.status_code == 200
    assert r2.headers["content-type"].startswith("text/csv")
    body = r2.text
    # First line is the header.
    assert body.splitlines()[0].startswith("start_tc,end_tc")


def test_timeline_fcpxml_export(client):
    r = client.post("/score/text", json={"text": "fcpxml export test"})
    rid = r.json()["id"]
    r2 = client.get(f"/score/{rid}/timeline.fcpxml")
    assert r2.status_code == 200
    body = r2.text
    assert body.startswith("<?xml")
    assert "<fcpxml" in body
    assert "sequence" in body


def test_timeline_404_for_unknown(client):
    r = client.get("/score/does-not-exist/timeline.csv")
    assert r.status_code == 404
