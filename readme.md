# CBT — Brain-Predicted Virality

Score tweets, images, UI screenshots, and reels against **Meta FAIR's TRIBE v2**
(an open-source foundation model that predicts fMRI responses to video, audio,
and text), then let a **Karpathy-style autoresearch loop** improve the scoring
head overnight.

```
/CBT
├── api/              FastAPI + TRIBE wrapper + ingest + scoring + autoresearch
├── web/              Next.js 15 frontend (score UI + autoresearch dashboard)
├── data/             Labeled dataset, TRIBE prediction cache, result cache
└── infra/            Modal GPU deploy target
```

## Quick start (mock backend, no GPU, no secrets)

### Docker (one command)
```bash
docker compose up --build
```
Open http://localhost:3000.

### Manual
```bash
# Backend
cd api
python -m venv .venv && source .venv/bin/activate
pip install -e .
uvicorn api.main:app --reload --port 8000

# Frontend (separate terminal)
cd web
npm install --legacy-peer-deps
npm run dev
```

Open http://localhost:3000. The `mock` TRIBE backend produces deterministic
synthetic brain responses so you can exercise the full pipeline — ingest,
scoring, and autoresearch — without a GPU.

## Upgrading to real TRIBE v2

### Option A — Local CUDA
```bash
pip install -e '.[tribe]'
pip install git+https://github.com/facebookresearch/tribev2
export HF_TOKEN=hf_...    # needs Llama 3.2-3B access approved
export TRIBE_BACKEND=local
```

### Option B — Modal GPU endpoint
```bash
pip install modal
modal token new
modal secret create hf-token HF_TOKEN=hf_...
modal deploy api/tribe/modal_app.py
export MODAL_TRIBE_ENDPOINT=https://<your-modal-url>
export TRIBE_BACKEND=modal
```

Either way, predictions are content-addressed and cached under
`data/tribe_cache/`, so the autoresearch loop re-runs only the scoring head
(milliseconds per experiment) against pre-computed TRIBE outputs.

## Autoresearch

- `api/scoring/score.py` is the **agent-editable scoring head** (Karpathy's
  `train.py` analogue).
- `api/scoring/rubric.md` documents the scoring intent.
- `api/autoresearch/runner.py` is the keep-or-revert loop:
  ```
  python -m api.autoresearch.runner --budget 10 --offline     # no API key needed
  python -m api.autoresearch.runner --budget 50                # uses ANTHROPIC_API_KEY
  ```
- Metric: **Spearman rank correlation** between predicted `score` and
  `log1p(views)` on a held-out split of `data/labeled/*.jsonl`.
- Offline mode cycles through a deterministic set of tweaks so you can see
  the keep/revert mechanics without spending API credits.

## Endpoints

| method | path                                         | purpose                              |
|--------|----------------------------------------------|--------------------------------------|
| POST   | /score/text                                  | JSON `{text}` → score                |
| POST   | /score/{image,ui,video}                      | multipart `file` → score             |
| POST   | /compare/text                                | JSON `{variants}` → ranked results   |
| POST   | /compare/upload                              | multipart: rank image/ui/video batch |
| GET    | /score/{id}                                  | cached result by id                  |
| GET    | /score/{id}/brain.png?view=&roi=             | nilearn fsaverage5 rendering (lateral/medial, per-ROI filter) |
| GET    | /score/{id}/timeline.{csv,fcpxml}?fps=30     | marker track for Final Cut / Premiere / Resolve |
| POST   | /labeled/add                                 | promote a result into training set   |
| POST   | /labeled/import_csv                          | bulk import X analytics / generic CSV |
| GET    | /labeled/stats                               | per-modality labeled row counts      |
| POST   | /calibration/refit                           | refit score → views regression       |
| GET    | /calibration/status                          | current calibration summary          |
| GET    | /autoresearch/history                        | experiment log                       |
| GET    | /autoresearch/current                        | current `score.py` + rubric          |
| POST   | /autoresearch/run?budget=5                   | SSE stream of experiments (phased)   |

## Seed dataset

Ships with 50 labeled tweets + 10 images + 8 UI screenshots + 4 reel videos
(72 rows total) under `data/labeled/*.jsonl` with assets in
`data/labeled/assets/`. Regenerate or extend the non-text assets with:

```bash
python scripts/generate_seed_assets.py
```

The result page has an **Add to training set** form — any content you score
through the app can be promoted into the labeled dataset with its actual
view count, and the autoresearch agent will see it on the next run.

## Tests

```bash
cd api
pytest -q     # 21 tests covering TRIBE mock, ingest, scoring, eval,
              # runner, and all FastAPI endpoints (incl. the add-label loop)
```

## Credits

- [TRIBE v2 paper](https://ai.meta.com/research/publications/a-foundation-model-of-vision-audition-and-language-for-in-silico-neuroscience)
- [Karpathy autoresearch](https://github.com/karpathy/autoresearch)
- Seed idea from @fuckgrowth on X.
