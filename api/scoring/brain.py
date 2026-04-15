"""Render fsaverage5 cortex with predicted TRIBE response per vertex.

Uses nilearn's pre-packaged fsaverage5 mesh. We produce a 2-hemisphere
lateral view PNG (left + right). The vertex array from TRIBE is split
10242/10242 left/right in standard fsaverage5 order.

Renders are cached to disk by sha1(preds_hash + view), so a repeated
request for the same result is free.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np

from api.config import DATA_DIR

BRAIN_CACHE = DATA_DIR / "brain_cache"
BRAIN_CACHE.mkdir(exist_ok=True)


def _cache_path(vertex_vec: np.ndarray) -> Path:
    h = hashlib.sha1(vertex_vec.tobytes()).hexdigest()[:16]
    return BRAIN_CACHE / f"cortex_{h}.png"


def render_cortex_png(preds: np.ndarray) -> Path:
    """Render a lateral-view 2-hemisphere PNG of the mean-over-time response.

    preds: (T, 20484) float array from TRIBE. We collapse over time with a
    90th percentile so we highlight peak engagement per vertex.
    """
    vertex_vec = np.percentile(preds, 90, axis=0).astype(np.float32)
    out = _cache_path(vertex_vec)
    if out.exists():
        return out

    # Deferred import so the scoring pipeline stays import-light.
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from nilearn import datasets, plotting, surface

    # Pull fsaverage5 the first time; subsequent calls are instant.
    fs = datasets.fetch_surf_fsaverage(mesh="fsaverage5")
    n = vertex_vec.shape[0]
    if n != 20484:
        # Fallback: interpolate / pad to 20484 if upstream vertex count
        # differs (e.g. a different TRIBE variant).
        reps = int(np.ceil(20484 / n))
        vertex_vec = np.tile(vertex_vec, reps)[:20484]
    left = vertex_vec[:10242]
    right = vertex_vec[10242:]

    # Normalize for display so weak signals are still visible.
    vmin = float(np.percentile(vertex_vec, 5))
    vmax = float(np.percentile(vertex_vec, 99))
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
            stat_map=data,
            hemi=hemi,
            view="lateral",
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
