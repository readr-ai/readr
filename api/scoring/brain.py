"""Render fsaverage5 cortex with predicted TRIBE response per vertex.

Uses nilearn's pre-packaged fsaverage5 mesh. Output is a dark-background
PNG rendered off-screen via matplotlib's Agg backend.

Supports:
- view: "lateral" (default) or "medial" -- switches the camera angle.
- roi:  None means full-cortex peak response; otherwise one of
        {visual, attention, language, emotion, reward} and vertices
        outside that ROI are masked to zero.

Renders are cached on disk by sha1(vertex_vec + view + roi).
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np

from api.config import DATA_DIR

BRAIN_CACHE = DATA_DIR / "brain_cache"
BRAIN_CACHE.mkdir(exist_ok=True)


def _cache_path(vertex_vec: np.ndarray, view: str, roi: str | None) -> Path:
    key = hashlib.sha1(vertex_vec.tobytes() + view.encode() + (roi or "all").encode()).hexdigest()[:16]
    return BRAIN_CACHE / f"cortex_{view}_{roi or 'all'}_{key}.png"


def render_cortex_png(
    preds: np.ndarray, view: str = "lateral", roi: str | None = None
) -> Path:
    """Render a 2-hemisphere PNG of the per-vertex response.

    preds: (T, 20484) float array from TRIBE.
    view:  'lateral' | 'medial'
    roi:   'visual' | 'attention' | 'language' | 'emotion' | 'reward' | None
    """
    vertex_vec = np.percentile(preds, 90, axis=0).astype(np.float32)

    if roi is not None:
        from api.scoring.rois import get_roi_masks
        masks = get_roi_masks()
        if roi not in masks:
            raise ValueError(f"Unknown ROI: {roi}")
        mask = masks[roi]
        # Zero out non-ROI vertices so they fall below vmin and render dark.
        vertex_vec = np.where(mask, vertex_vec, np.nan)

    out = _cache_path(np.nan_to_num(vertex_vec, nan=-1e9), view, roi)
    if out.exists():
        return out

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from nilearn import datasets, plotting

    fs = datasets.fetch_surf_fsaverage(mesh="fsaverage5")
    n = vertex_vec.shape[0]
    if n != 20484:
        reps = int(np.ceil(20484 / n))
        vertex_vec = np.tile(vertex_vec, reps)[:20484]
    left = vertex_vec[:10242]
    right = vertex_vec[10242:]

    finite = vertex_vec[np.isfinite(vertex_vec)]
    if finite.size == 0:
        vmin, vmax = 0.0, 1.0
    else:
        vmin = float(np.percentile(finite, 5))
        vmax = float(np.percentile(finite, 99))
        if vmax - vmin < 1e-6:
            vmax = vmin + 1.0

    fig, axes = plt.subplots(
        1, 2, figsize=(6, 3), subplot_kw={"projection": "3d"}, facecolor="#0a0a0f"
    )
    for ax, hemi, data, bg_mesh, sulc in (
        (axes[0], "left", left, fs.infl_left, fs.sulc_left),
        (axes[1], "right", right, fs.infl_right, fs.sulc_right),
    ):
        plotting.plot_surf_stat_map(
            bg_mesh,
            stat_map=np.nan_to_num(data, nan=vmin - 1e3),
            hemi=hemi,
            view=view,
            bg_map=sulc,
            bg_on_data=True,
            colorbar=False,
            cmap="magma",
            vmin=vmin,
            vmax=vmax,
            axes=ax,
            figure=fig,
        )
        ax.set_facecolor("#0a0a0f")
    plt.subplots_adjust(left=0, right=1, top=1, bottom=0, wspace=0)
    fig.savefig(out, dpi=120, facecolor="#0a0a0f", bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)
    return out
