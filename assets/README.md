# Readr brand assets

<img src="logo-512.png" width="128" alt="Readr logo">

The Readr mark: an open book with layered page edges and AI sparks rising
from the pages, on a deep indigo built around the brand's **Iris** accent
(see `docs/DESIGN.md`). The sparks use the amber from the "muted literary"
highlight palette.

| File | Use |
| --- | --- |
| `logo.svg` | Master vector — edit this, re-export the PNGs |
| `logo-1024.png` | GitHub org/repo avatar (upload under org **Settings → Profile picture**), app icon source |
| `logo-512.png` | Smaller raster for READMEs, social embeds |

## Colors

- Background gradient: `#26225C` → `#131130` (deep indigo around Iris `#5B57C7`)
- Pages: `#FFFEF9` → `#EAE4D2` (paper cream)
- Under-page edges: `#938EE9`, `#5B57C7` (Iris)
- Sparks: `#E9BA4F` (amber)

## Re-exporting PNGs

Any SVG rasterizer works; with headless Chromium:

```sh
chromium --headless --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot=logo-1024.png logo.svg
```
