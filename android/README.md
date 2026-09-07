# Readr for Android

Kotlin + Jetpack Compose app over the same `ReadrKit` Swift package the iOS
and macOS apps use. The kit is cross-compiled with the official Swift SDK for
Android and reached from Kotlin through swift-java's generated JNI bindings
(`com.readrai.readr.kit`, produced from `readrkit/Sources/ReadrAndroid`).
Design rationale and measurements: the Android scoping note of 2026-09-06
(private research folder; summarised in `docs/ROADMAP.md` A1–A8).

## Modules

| Module | What |
|---|---|
| `:readrkit` | Android library: cross-compiles `ReadrKit` + the `ReadrAndroid` facade, runs jextract, packages the Swift runtime into `jniLibs`. |
| `:app` | The app (`com.readrai.readr`). |

## Prerequisites

1. **swiftly** with the open-source Swift toolchain matching `SWIFT_VERSION`
   in `readrkit/build.gradle.kts` (6.3.3): `swiftly install 6.3.3`.
   Xcode's toolchain cannot cross-compile for Android.
2. **Swift SDK for Android**, same version, plus NDK r27d wired in with the
   bundle's `scripts/setup-android-sdk.sh` (see
   swift.org/documentation/articles/swift-sdk-for-android-getting-started).
3. **Android SDK** (`platforms;android-35`, `build-tools;35.0.0`,
   platform-tools, emulator) and JDK 17 for Gradle. `ANDROID_HOME` set, or
   `local.properties` with `sdk.dir`.
4. **swift-java's Java runtime** in the local Maven repository (it is not
   published yet): `./gradlew :readrkit:publishSwiftKit` — needs JDK 25+ on
   `JAVA_HOME_25` (or `JAVA_HOME`) for that one task.

macOS note: SwiftPM's plugin sandbox blocks the Gradle step swift-java's
plugin runs inside `swift build`. `:readrkit:publishSwiftKit` builds
SwiftKitCore once with the real wrapper (kept as `gradlew.real`) and then
installs a no-op `gradlew` in the checkout; re-run it after
`swift package reset` or a swift-java bump. Linux (CI) has no such sandbox.

## Build and run

```sh
cd android
./gradlew :app:installDebug            # both ABIs; READR_ANDROID_ABIS=x86_64 for an emulator-only build
./gradlew :app:connectedDebugAndroidTest
./gradlew :app:assembleRelease         # cross-compiles the Swift half with -c release
```

The kit's own XCTest suite runs on an emulator too — see
`.github/workflows/android.yml` for the push-and-run recipe.

## Layout on device

`filesDir/library.json` (FileLibraryStore), `filesDir/Books/<uuid>.epub|txt`
(originals), `filesDir/Covers/`, `filesDir/.sample-seeded`. Provider secrets:
AES-GCM under an Android Keystore key that is usable only while the device is
unlocked, ciphertext in `secrets` preferences — never plaintext on disk.

Every packaged Swift library is checked against the facade's `DT_NEEDED`
entries (transitively) at build time, so a new Foundation module the kit
starts using fails the build instead of the app's first launch.
