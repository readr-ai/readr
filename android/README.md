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

## The reader

`ui/reader/` is the paginated reading surface. `LayoutPaginator` lays the
chapter out with Compose's `TextMeasurer` at the page width (in
paragraph-aligned chunks) and cuts pages on whole lines that fit the page
height; a page is drawn from the same styled text at the same width, so what
was measured is what is shown. `ChapterStyling` turns the kit's format spans
into the `AnnotatedString` — every kit paragraph is one Compose paragraph,
with the closing newline drawn as a space so offsets keep their meaning.

`PageSelection` is the selection on that page — long press for the word,
drag to extend, two handles to adjust — in page-local offsets that become
chapter offsets through the page's `textStart`. `AnnotationCapsule` is the
four colour dots and copy that float over the bottom of the text area, and a
highlight is drawn as a background span (underlined when it carries a note),
never an inserted glyph, so marking a passage cannot move a line break.

A note lives on a highlight: "Note" on a plain selection highlights it in the
colour last used and opens `NoteEditor`, and cancelling there takes that
highlight away again. `HighlightsSheet` is the book's highlights in reading
order — colour chips, a search over quote and note, and a card that jumps to
the passage. The ribbon in the bar bookmarks *the visible page* (the first
bookmark whose offset falls in the page's range is "the" one), and the
Contents sheet lists bookmarks above the table of contents, marking the rows
whose stretch of the book holds one.

Offsets cross the bridge as **UTF-16** (what Kotlin and Compose index); the
Swift facade converts to and from the kit's character offsets with the
chapter text in hand (`TextOffsets.swift`). Positions, contents rows,
anchors and spans all follow that rule.

Appearance (`ReaderSettings`) is plain `SharedPreferences` under the keys the
iOS app uses — `readingTheme`, `readingFontSize`, `readingFont`,
`readingLineSpacing`, `readingJustified`, and `lastHighlightColor` (the colour
"Note" reaches for, deliberately outside `ReaderAppearance` so it can never
re-paginate a chapter).

## Layout on device

`filesDir/library.json` (FileLibraryStore), `filesDir/Books/<uuid>.epub|txt`
(originals), `filesDir/Covers/`, `filesDir/.sample-seeded`. Provider secrets:
AES-GCM under an Android Keystore key that is usable only while the device is
unlocked, ciphertext in `secrets` preferences — never plaintext on disk.

Every packaged Swift library is checked against the facade's `DT_NEEDED`
entries (transitively) at build time, so a new Foundation module the kit
starts using fails the build instead of the app's first launch.
