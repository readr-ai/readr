"""Autoresearch runner + eval smoke tests."""
import pytest

from api.autoresearch import run_autoresearch
from api.autoresearch.eval import run_eval
from api.autoresearch.runner import EXPERIMENTS_LOG
from api.config import SCORING_DIR


@pytest.fixture
def isolated_scoring():
    """Snapshot score.py and experiments.jsonl so the test can mutate them."""
    score_py = SCORING_DIR / "score.py"
    score_snap = score_py.read_text()
    log_snap = EXPERIMENTS_LOG.read_text() if EXPERIMENTS_LOG.exists() else ""
    try:
        yield
    finally:
        score_py.write_text(score_snap)
        EXPERIMENTS_LOG.write_text(log_snap)


def test_eval_runs_and_returns_metrics():
    r = run_eval(backend="mock")
    assert r.n > 0
    assert -1.0 <= r.spearman <= 1.0
    assert r.mae >= 0.0
    assert 0.0 <= r.precision_at_topk <= 1.0


def test_runner_offline_keeps_or_reverts(isolated_scoring):
    """Runner must produce log entries that carry the expected fields."""
    results = list(run_autoresearch(budget=2, offline=True))
    assert len(results) >= 2
    for entry in results:
        assert "experiment" in entry
        if "error" in entry:
            continue
        assert "hypothesis" in entry
        assert "kept" in entry
        assert "spearman" in entry
