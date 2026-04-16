"""Modal deployment for TRIBE v2 GPU inference.

Deploy:
    modal secret create hf-token HF_TOKEN=hf_xxx
    modal deploy api/tribe/modal_app.py

Then point the API at it:
    export TRIBE_BACKEND=modal
    export MODAL_TRIBE_ENDPOINT=https://<yourapp>--predict.modal.run

The endpoint expects multipart form fields video, audio, text (any
subset) + `modality`. Returns {preds: [[...]], segments: [...], meta}.

Local dev without Modal: leave TRIBE_BACKEND=mock.
"""
from __future__ import annotations

try:
    import modal  # type: ignore
except ImportError:
    modal = None  # type: ignore


if modal is not None:
    image = (
        modal.Image.debian_slim(python_version="3.11")
        .apt_install("ffmpeg", "git")
        .pip_install(
            "torch>=2.4",
            "transformers>=4.45",
            "huggingface-hub>=0.25",
            "fastapi",
            "numpy",
            "pandas",
            "git+https://github.com/facebookresearch/tribev2",
        )
    )

    app = modal.App("cbt-tribe", image=image)
    hf_secret = modal.Secret.from_name("hf-token")

    # Keep the model warm across requests. Cold start is minutes, warm is
    # single-digit seconds per inference on a T4.
    @app.cls(
        gpu="T4",
        timeout=900,
        secrets=[hf_secret],
        container_idle_timeout=300,
        keep_warm=0,
    )
    class TribeService:
        @modal.enter()
        def load(self):
            from tribe import TribeModel  # type: ignore
            import os
            # Cache on Modal's persistent volume so we don't redownload.
            os.environ.setdefault("HF_HOME", "/root/.cache/huggingface")
            self.model = TribeModel.from_pretrained("facebook/tribev2")

        @modal.method()
        def predict(self, video: bytes | None, audio: bytes | None,
                    text: bytes | None, modality: str) -> dict:
            import tempfile
            from pathlib import Path
            import numpy as np

            tmp = Path(tempfile.mkdtemp())
            kwargs: dict = {}
            if video:
                p = tmp / "in.mp4"
                p.write_bytes(video)
                kwargs["video_path"] = str(p)
            if audio:
                p = tmp / "in.wav"
                p.write_bytes(audio)
                kwargs["audio_path"] = str(p)
            if text:
                p = tmp / "in.txt"
                p.write_bytes(text)
                kwargs["text_path"] = str(p)
            if not kwargs:
                return {"error": "no input modalities provided"}

            df = self.model.get_events_dataframe(**kwargs)
            preds, segments = self.model.predict(events=df)
            arr = preds.detach().cpu().numpy() if hasattr(preds, "detach") else np.asarray(preds)
            segs = (
                segments if isinstance(segments, list)
                else segments.to_dict(orient="records")
            )
            return {
                "preds": arr.astype("float16").tolist(),
                "segments": segs,
                "meta": {"modality": modality, "shape": list(arr.shape)},
            }

    @app.function()
    @modal.web_endpoint(method="GET", docs=True)
    def healthz() -> dict:
        return {"ok": True, "service": "cbt-tribe"}

    @app.function(timeout=900)
    @modal.web_endpoint(method="POST", docs=True)
    def predict(
        video: bytes | None = None,
        audio: bytes | None = None,
        text: bytes | None = None,
        modality: str = "video",
    ) -> dict:
        return TribeService().predict.remote(video, audio, text, modality)
