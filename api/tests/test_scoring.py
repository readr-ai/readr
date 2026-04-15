"""Scoring head smoke tests."""
from api.scoring.rois import ROI_NAMES, get_roi_masks
from api.scoring.score import score
from api.tribe.client import MockTribeClient, TribeInput


def test_roi_masks_partition_vertices():
    masks = get_roi_masks()
    assert set(masks.keys()) == set(ROI_NAMES)
    # Each vertex belongs to exactly one ROI.
    import numpy as np
    stacked = np.stack([masks[n] for n in ROI_NAMES], axis=0).sum(axis=0)
    assert int(stacked.min()) == 1
    assert int(stacked.max()) == 1


def test_score_produces_valid_shape():
    c = MockTribeClient()
    pred = c.predict(TribeInput(modality="video", content_hash="demo"))
    vs = score(pred)
    assert 0.0 <= vs.score <= 100.0
    assert set(vs.roi_breakdown.keys()) == set(ROI_NAMES)
    assert all(0.0 <= v <= 1.0 for v in vs.roi_breakdown.values())
    assert len(vs.engagement_timeline) == pred.n_timesteps
    assert all(0.0 <= t <= 1.0 for t in vs.engagement_timeline)
    for (s, e) in vs.dead_zones + vs.hotspots:
        assert e > s >= 0
    assert len(vs.suggested_edits) >= 1


def test_score_is_deterministic_per_input():
    c = MockTribeClient()
    pred = c.predict(TribeInput(modality="text", content_hash="fixed"))
    a = score(pred)
    b = score(pred)
    assert a.score == b.score
