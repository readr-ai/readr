# CLAUDE.md

Guidance for working in this repository.

## Project

**Readr** — a native iOS & macOS AI-powered ebook reader (think Apple Books, but
you can ask the book questions and turn highlights into articles).

- Core logic lives in the platform-agnostic Swift package **`ReadrKit`**
  (`Sources/ReadrKit`, tests in `Tests/ReadrKitTests`) — it builds and is tested
  on CI.
- The SwiftUI app target lives in `App/` and is generated via XcodeGen
  (`project.yml`); it builds only on **macOS + Xcode** (Network framework,
  AppKit/UIKit, PDFKit, etc.).
- Architecture, plan, and user journeys are in `docs/` — read
  `docs/ARCHITECTURE.md` and `docs/DEVELOPMENT-PLAN.md` before sizable changes.

## Workflow rules

- **Open a PR → always run `/review` and apply the fixes automatically**, unless
  the user explicitly says not to. Then push the fixes to the PR branch.
- **Test-first.** New core logic in `ReadrKit` gets tests written before/with the
  implementation (see `docs/DEVELOPMENT-PLAN.md`). Keep external dependencies
  (rendering, vendor SDKs, vector stores) behind `ReadrKit` protocols.
- Keep app-only code (anything needing Apple frameworks) out of `Sources/ReadrKit`
  so the package keeps building on CI. Mirror existing patterns
  (`PDFKitBookParser`, `ZipEPUBContainer`) under `App/`.
- Secrets only in the Keychain — never `UserDefaults`, plists, or logs. Don't add
  network calls to the local-LLM path.

## Build & test

```sh
swift build && swift test          # ReadrKit (any Swift platform)
xcodegen generate && open Readr.xcodeproj   # full app (macOS only)
```

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on PRs and on
`main`.
