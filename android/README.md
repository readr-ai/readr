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
the passage. `SearchSheet` is find-in-book: the kit's `BookSearcher` over every chapter, a
fifth of a second after the typing stops, each hit shown as its chapter over
the line it sits on with the searched-for words in bold. The query and its
results live in `ReaderViewModel`, so the sheet reopens where it was left.
The ribbon in the bar bookmarks *the visible page* (the first
bookmark whose offset falls in the page's range is "the" one), and the
Contents sheet lists bookmarks above the table of contents, marking the rows
whose stretch of the book holds one.

An inline image is a U+FFFC in the chapter text and an entry path into the
book's own `.epub` (the facade reports its absolute path on `BookSummary`,
existence-checked there) — the bytes never cross the bridge. `ChapterImages`
does the work in two halves. `place()` opens the archive **once** and reads
nothing but each entry's *header* (`inJustDecodeBounds` over the zip stream),
which is what fixes the placeholder sizes and therefore the pagination; a path
that names no entry is remembered as missing, so a broken chapter does not
re-open the archive on every geometry change. `load()` then decodes the
bitmaps afterwards, a few at a time behind a `Semaphore`, into a
`LocalInlineBitmaps` map the page draws from — deliberately not part of the
`PageKey`, so a picture landing fills a box that is already the right size and
no line moves.

A decode targets the column width and no more: the sample is the largest power
of two leaving at least the column across (so the bitmap lands in
`[column, 2·column)`), doubled again if the pixels would take more than a
quarter of the ~24 MB cache. Eviction recycles nothing — Compose may still be
drawing the bitmap. Sizing follows the Apple reader's `fittedBounds`: both
dimensions declared means the markup states the shape, one declared means the
other comes back through the source's aspect, neither means the image's own
pixels as dp; then the column, then the page ceiling (a 4 dp margin shared with
the surface as `ChapterImages.pageMargin`). The paragraph holding an image
declares that picture's height as its line height, since Compose forces a line
to the height its paragraph names. An entry that cannot be read takes a
one-line placeholder holding its alt text.

A tap on a link beats a highlight and the page-turn zones both — a link is a
control the author put on the page — but only when it lands on an actual
glyph: a tap on the white past a short line falls through to the turn zones.
One into the book resolves its archive path against `ChapterSummary.sourcePath`
(exact, then case-insensitively, then on the file name) and its fragment
through the facade's `anchorOffset` (one id, so a tap does not ship every
format span in the target document across the bridge). A noteref is answered
from the footnotes of the document its *path* names — the current chapter when
it names none — and only there, as `ReaderView.resolveFootnote` does: note ids
recur document by document, so a cross-document link is never hijacked into a
same-id note from the chapter in hand.

A link out of the book is asked about first, and only three kinds are ever
handed on: `http`/`https` (named by their host, which `android.net.Uri` — the
parser the intent will use — has to be able to give), `mailto:` ("Send an email
to…") and `tel:` ("Call…"). `file`, `content`, `intent`, `javascript`, `data`,
`market` and everything unknown say "Readr can't open that kind of link." and
never reach `startActivity`, as does any URL carrying a backslash, whitespace
or a control character. `startActivity` itself is wrapped against
`RuntimeException`, so a missing app, an exposed-file refusal or a permission
denial is one sentence rather than a crash. Internal links are iris; external
ones are iris and underlined.

Offsets cross the bridge as **UTF-16** (what Kotlin and Compose index); the
Swift facade converts to and from the kit's character offsets with the
chapter text in hand (`TextOffsets.swift`). Positions, contents rows,
anchors and spans all follow that rule.

Three layouts, keyed as `readerLayout` (the kit's `PageLayout`): a single
page, two facing pages, or a scroll. In a spread the column block is at most
two measures wide, the two columns share it minus a 1 dp spine in
`palette.line`, a spread starts on an even page index and a turn advances by
two, and the label reads "Pages 3–4 of 11" (the last spread of an odd chapter
draws the spine and an empty facing page, so the spine stays centred). Each
column is its own `Text` with its own layout, so selection, links and the
capsule work on both. Two pages are offered only from 600 dp of width — the
same test that picks the regular insets — and on a narrower window a stored
`doublePage` *reads* as a single page without the preference being rewritten.
The scroll runs no paginator at all: the chapter is cut into the paginator's
own paragraph-aligned chunks (`LayoutPaginator.chunks`) and drawn as the rows
of a `LazyColumn`, each row by the same composable a cut page is drawn by, so
selection, highlights, links and the capsule work per chunk exactly as they do
on a page. Its `PageKey` names no page height — the bar comes and goes all day
and must not re-measure a chapter — and the picture ceiling it does name is the
surface with the chrome down. There is no page label: a 2 dp progress track for
the book, and what is left of the chapter counted with
`LayoutPaginator.wordCount` from the anchor down, with chapter buttons at
either end. The anchor is the first visible chunk's first fully visible line,
reported only when it actually changes; nothing clears a selection there but a
new chapter.

The bar is chrome over the window, not over the page: while it is shown the
surface sits below it, so the page is shorter than with the chrome hidden.
Those are two geometries the reader flips between all day, which is what the
multi-slot `PaginationCache` is for; the place is the anchor and the page
index is re-derived from it, so nothing jumps when the geometry changes.

Appearance (`ReaderSettings`) is plain `SharedPreferences` under the keys the
iOS app uses — `readingTheme`, `readingFontSize`, `readingFont`,
`readingLineSpacing`, `readingJustified`, `readerLayout`, and
`lastHighlightColor` (the colour "Note" reaches for, deliberately outside
`ReaderAppearance` so it can never re-paginate a chapter).

## Layout on device

`filesDir/library.json` (FileLibraryStore), `filesDir/Books/<uuid>.epub|txt`
(originals), `filesDir/Covers/`, `filesDir/.sample-seeded`. Provider secrets:
AES-GCM under an Android Keystore key that is usable only while the device is
unlocked, ciphertext in `secrets` preferences — never plaintext on disk.

Every packaged Swift library is checked against the facade's `DT_NEEDED`
entries (transitively) at build time, so a new Foundation module the kit
starts using fails the build instead of the app's first launch.
