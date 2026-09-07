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
- **Android** lives in `android/` (Kotlin + Jetpack Compose). It links the
  same `ReadrKit`, cross-compiled with the Swift SDK for Android and reached
  through swift-java's generated JNI bindings; the Swift facade is
  `android/readrkit/Sources/ReadrAndroid` and must stay small (JSON/String
  boundary — see the rules in its `Package.swift`). Kotlin implements the
  kit's platform protocols (`SecretStore` over the Android Keystore today).
  Nothing Android-specific goes into `Sources/ReadrKit`.
- Secrets only in the Keychain — never `UserDefaults`, plists, or logs. Don't add
  network calls to the local-LLM path.

## Build & test

```sh
swift build && swift test          # ReadrKit (any Swift platform)
xcodegen generate && open Readr.xcodeproj   # full app (build env: macOS only)
```

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test`, the macOS
app build + snapshot tests, an iOS device-SDK build, and the XCUITest suite on
iPhone **and iPad** simulators, on PRs and on `main`.
`.github/workflows/android.yml` cross-compiles the kit, runs its XCTest suite
on an Android emulator, and runs the app's instrumented tests. Android setup
and build commands: `android/README.md`.

## Releases

- **macOS**: `.github/workflows/release.yml` — Developer-ID sign + notarize
  (secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`,
  `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`).
- **iOS → TestFlight**: `.github/workflows/testflight.yml` — cloud automatic
  signing via App Store Connect API key (secrets `APP_STORE_CONNECT_KEY_ID`,
  `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`, plus
  `APPLE_TEAM_ID`). The team ID is never committed to the repo.
- Both trigger on `v*` tags or manual dispatch. iOS/iPad milestones: M6–M8 in
  `docs/DEVELOPMENT-PLAN.md`.
