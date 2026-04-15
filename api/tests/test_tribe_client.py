"""MockTribeClient smoke + determinism tests."""
import numpy as np

from api.config import settings
from api.tribe.client import MockTribeClient, TribeInput, TribePrediction


def test_mock_returns_expected_shape():
    c = MockTribeClient()
    inp = TribeInput(modality="text", content_hash="hello world")
    pred = c.predict(inp)
    assert isinstance(pred, TribePrediction)
    assert pred.preds.ndim == 2
    assert pred.preds.shape[1] == settings.n_vertices
    assert pred.duration_s > 0
    assert pred.meta["backend"] == "mock"


def test_mock_is_deterministic():
    c = MockTribeClient()
    inp = TribeInput(modality="text", content_hash="same")
    a = c.predict(inp).preds
    b = c.predict(inp).preds
    np.testing.assert_allclose(a, b)


def test_mock_varies_with_input():
    c = MockTribeClient()
    a = c.predict(TribeInput(modality="text", content_hash="aaaa")).preds
    b = c.predict(TribeInput(modality="text", content_hash="bbbb")).preds
    assert not np.allclose(a, b)


def test_modality_affects_duration():
    c = MockTribeClient()
    text = c.predict(TribeInput(modality="text", content_hash="x"))
    image = c.predict(TribeInput(modality="image", content_hash="x"))
    video = c.predict(TribeInput(modality="video", content_hash="x"))
    # Video should be longer than image, which is longer than a short text.
    assert video.duration_s >= image.duration_s
    assert image.duration_s >= text.duration_s or abs(image.duration_s - text.duration_s) < 5.0
