# App Store screenshots

Captured 2026-08-08 from the v2.15.0 build on simulators, at exactly the sizes
App Store Connect requires. Every file is size-checked — see the validation
snippet at the bottom.

| Folder | Size | Device | Required? |
|---|---|---|---|
| `iphone-6.9/` | 1320 × 2868 | iPhone 17 Pro Max | **yes** |
| `ipad-13/` | 2064 × 2752 | iPad Pro 13-inch (M5) | **yes**, since the app supports iPad |

Apple accepts up to 10 per size and uses the **first** as the one shown in
search results — hence the ordering below.

## iPhone (6.9")

1. `01-home.png` — Continue Reading with progress and time-left
2. `02-reader.png` — the reading page, justified serif on paper
3. `03-ask.png` — **the headline shot**: a question, a formatted answer, and
   the SOURCES citation chips
4. `04-appearance.png` — themes, font, spacing, layout controls
5. `05-reader-dark.png` — the same page in Dark

## iPad (13")

1. `01-library.png` — sidebar and library side by side
2. `02-reader-sidebar.png` — reading in Dark with highlights in three colours
3. `03-ask.png` — Ask over the reader

## How these were made

Seeded content, stubbed provider — no real key, no network:

```sh
xcrun simctl launch <udid> com.readrai.app -uiTestSeed -uiTestStubLLM
xcrun simctl io <udid> screenshot appstore/screenshots/<folder>/<name>.png
```

The stub answer is deterministic (`UITestStubProvider`), so the Ask shot is
reproducible rather than whatever a live model happened to say.

## Before uploading

- The status-bar clock reads 9:41 on its own in the simulator, which is what
  Apple's own marketing uses. No editing needed.
- Screenshots have **no public API** — upload them by hand in ASC, or via a
  tool like fastlane's `deliver`. `scripts/asc_metadata.py` deliberately does
  not attempt them.
- If you localize later, each locale needs its own set.

## Validating sizes

```sh
python3 - <<'PY'
import struct, pathlib
EXPECT = {"iphone-6.9": {(1320,2868),(1290,2796)},
          "ipad-13": {(2064,2752),(2048,2732)}}
for folder, sizes in EXPECT.items():
    for f in sorted(pathlib.Path("appstore/screenshots", folder).glob("*.png")):
        w, h = struct.unpack('>II', f.read_bytes()[16:24])
        print(f"{'OK ' if (w,h) in sizes else 'BAD'} {folder}/{f.name}: {w}x{h}")
PY
```
