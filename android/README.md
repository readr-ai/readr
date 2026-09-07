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

The chrome is two bars, as the iOS reader's compact layout has it: what you
are reading up top (back, title, ✦ Ask, Aa, highlights) and what you do with
the book along the bottom, under the thumb (contents, the bookmark ribbon,
find in book). Seven controls in one bar left the title nothing and put the
two most used at the far end of a reach. Both bars come and go together with
a tap on the page. A reader-facing message (a link Readr cannot open, an
annotation that would not save) sits above the bottom bar while the chrome is
up and at the foot of the window when it is down, and over the bar either
way — a message the bar covers is a message nobody reads.

The bar is chrome over the window, not over the page: while it is shown the
surface sits below the top bar and above the bottom one, so the page is
shorter than with the chrome hidden.
Those are two geometries the reader flips between all day, which is what the
multi-slot `PaginationCache` is for; the place is the anchor and the page
index is re-derived from it, so nothing jumps when the geometry changes.

Appearance (`ReaderSettings`) is plain `SharedPreferences` under the keys the
iOS app uses — `readingTheme`, `readingFontSize`, `readingFont`,
`readingLineSpacing`, `readingJustified`, `readerLayout`, and
`lastHighlightColor` (the colour "Note" reaches for, deliberately outside
`ReaderAppearance` so it can never re-paginate a chapter).

## AI providers

`ui/settings/` is the provider screen, and every sentence on it comes from
the kit: `AndroidProviders` (the facade) answers one `providersJSON()` with
the ask-uses line, the active selection (and the reader's own explicit one),
the status line each card shows, and a card per vendor, built from
`ProviderVendor.displayed(forKinds:)` over the four methods this build has —
Gemini Nano, OpenAI, OpenRouter and Anthropic. ChatGPT's subscription path
and Ollama are not offered here (an unofficial backend, and a loopback server
no phone runs), and Apple's system model is not a thing an Android phone has.
There is no browser sign-in yet, so the card badges and connect hints say
"API key" rather than repeating the kit's "sign in or key".

Gemini Nano's readiness is Kotlin's to answer: `kit/NanoProbe` implements the
facade's `OnDeviceProbe` and reports one bare token — `ready`, `unavailable`
or `unsupported` (a bridged protocol method may not throw or return an
optional). The *sentence* a reader sees is the kit's
(`ProviderManager.ProviderError.notConfigured(.geminiNano)`), supplied by the
facade, so Kotlin writes no copy. It is asked on every read of the selection —
cached for five seconds, since one settings payload asks several times — so
the phone's own model is the default *while* the phone can run it and the
reader is back to "nothing chosen" the moment it cannot.

What the probe can see is the system: Android 14+ and an installed, non-stub
`com.google.android.aicore` (declared in the manifest's `<queries>`, or
Android 11+ hides the package). It still answers `unsupported` until A3c
brings ML Kit's own check and the model: this build cannot drive Nano, and a
card that could be made active would point Ask at a provider that can only
refuse. A card is offerable at all only when a check came back *ready* (an
on-device one) or a key is stored (a cloud one).

Saving a key does not choose a provider: `AndroidProviders.connect` runs the
kit's own rule — `requestActivation` then `validateAndActivate` — so an
unproven key may take a slot nothing usable holds, an accepted key (or one
whose check could not complete) may take it from a working provider, and a
rejected key never does. Every selection write, including the ones the manager
makes inside those calls, goes through one facade function that also writes
`provider-selection.json`; the manager's own `persistingIn` is nil, because
`UserDefaults` on Android is a plist in a directory nobody owns. `disconnect`
takes the key, the cached check, and — when it named that card — the selection
with it. The screen's on-open sweep is `validateIfStale(kind, 300)`: a
credential check posts a paid one-token completion, and walking in and out of
Settings must not repeat it.

## Ask

`ui/ask/` is "Ask the book": a full-height sheet over the reader, opened by
the ✦ in the bar (about the book, at the reader's place) or by the capsule's
✦ Ask (about the passage). One conversation per book for the life of the
process, kept in `ReadrApplication` the way the Apple app keeps one per
session, so closing the sheet and opening it two chapters later carries on
rather than starting again.

The whole pipeline is the kit's. `AndroidLibrary.ask` builds a per-book
`HybridRAGIndex` over `LocalEmbeddingProvider` (an LRU of two — the book in
hand and the one before it), routes through `AdaptiveContextStrategy`, and
runs `AskService` against `AndroidProviders`' active provider. The index is
built off the critical path: `prepareAsk` starts it when the book opens, on a
detached task, and a question asked before it lands waits on that same task
rather than starting a second one. Neither builds it at all when the book
would route whole-book anyway — decided on `AdaptiveContextStrategy`'s own
numbers (a non-local provider, and a text inside 60% of its context budget),
because that tier never asks for a passage. That rule is *copied* from the
strategy, so a test pins the two together (`KIT FOLLOW-UP` in `Ask.swift`)
until the kit exposes the decision itself.

An index and the build filling it are **one entry** in that LRU: evicting
drops both, and a question always takes the index from the same entry it
takes the build from. Kept apart, a third book opening could drop the index
while its build ran on — and the question that then waited for that build
would be answered from an empty index, grounded in nothing, with no error to
show for it.

Streaming crosses the bridge the way the spike found works: a Swift protocol
Kotlin implements (`AskSink`), called from the streaming task — `indexing`
when there is a build to wait for, then `contextAssembled` with
`{tier, providesCitations}` (the kit's own answer about the tier, so the
sheet's caption never promises citations the whole-book tier cannot deliver),
then `citations`, then a `token` per delta, then exactly one of `completed`
or `failed`. `ask` hands back an `Int64` handle and `cancelAsk` stops that
task; a cancelled ask reports **neither** ending, because the Kotlin side
asked for the stop and owns what the sheet shows from there. `AskRepository`
turns those calls into a `Flow` with an **unlimited** buffer — the sink cannot
suspend, so a full channel would drop the middle of a fast answer — starts the
ask under `NonCancellable` (the call hands back the handle that owns the Swift
task, and losing it would leave a stream nothing could stop), and always
reaches `awaitClose`. Collecting it on the main thread is what puts the events
on the main thread. Scope, selection and history cross as JSON with
every offset in UTF-16, converted per chapter exactly as everything else is
(`TextOffsets.swift`).

Every sentence a reader could be alarmed by comes from the kit: a failure is
`errorDescription` plus `recoverySuggestion` (so a rejected key reads "Your
API key was rejected… The provider said: …", never a status code or a Swift
case name), and the "Chapter 7 of 24 · 31% · The Whale" caption is
`positionSummaryJSON` calling the kit's own `ReadingPositionSummary` — the
same line the model is given, so the sheet and the prompt never disagree.

Answers are spoiler-scoped by default: the frontier is the reader's anchor
(the whole chapter in a scroll), pushed forward to cover a selected passage,
and the ANSWERS FROM control lifts it for the questions that follow. What the
sheet promises follows the routing tier rather than being written down —
the whole-book tier returns no passages, so it shows the honest "no passage
retrieval, no citation list" note instead of a SOURCES row, and an on-device
model is promised no wider knowledge than the book. A citation that carries a
chapter and an offset offers "Show in book", which jumps and dismisses.

`AnswerMarkdown.kt` is the answer renderer, and the *structure* is the kit's:
`AndroidLibrary.answerBlocksJSON` wraps `AnswerMarkdown.blocks(from:)`, so
paragraphs, headings, quotes, code and ordered/unordered lists are cut by the
same parser the Apple panel uses. Inline `**bold**` stays here, which is the
half the kit deliberately leaves to the platform.

That parse is **off the hot path**: a streaming answer is drawn as
paragraphs by the Kotlin half alone, and the kit's blocks are cut once, on
`Dispatchers.Default`, when the answer is finished (and for turns restored
into a reopened sheet) and stored on the exchange. Composition therefore
never crosses the bridge — a bridge call per delta, on the thread laying the
sheet out, is what a streamed answer used to cost. The transcript is a keyed
`LazyColumn` over `@Immutable` exchanges — everything drawn comes off the
exchange, so nothing unstable is handed to a turn and a state write elsewhere
skips it — streamed deltas are coalesced into at most one state write per
50 ms, and one conflated `snapshotFlow` (new turns and the answer's length
together) follows the newest answer down.

The empty state's guidance is the facade's sentence, which names only the
doors this phone has; it starts on "Add an API key to ask questions." and is
replaced only by a sentence that says something, so the heading is never over
a blank line.

`AndroidProviders.overrideEndpoint` is a debug and test hook: it swaps the
origin of a vendor's requests for a **loopback** one — `127.0.0.1`,
`localhost` or `10.0.2.2`, and anything else is refused — keeping the path the
provider built, which is how the instrumented tests stream a real SSE answer
from a `ServerSocket` on the device without a key or a network. One shared
`URLSession` sits behind every provider the factory builds, redirected or not,
so resolving a provider per question does not throw away a connection pool.

## Layout on device

`filesDir/library.json` (FileLibraryStore), `filesDir/Books/<uuid>.epub|txt`
(originals), `filesDir/Covers/`, `filesDir/.sample-seeded`,
`filesDir/provider-selection.json` (the chosen provider and model — the
facade's own file, since `UserDefaults` on Android is a plist in a directory
nobody owns) and `filesDir/OpenRouterModels.json` (the cached catalogue).
Provider secrets: AES-GCM under an Android Keystore key that is usable only
while the device is unlocked, ciphertext in `secrets` preferences — never
plaintext on disk. One file per Keystore alias (`secrets.<alias>` for anything
but the reader's own key), so an instrumented test writing under a test alias
cannot leave unreadable entries in the reader's file, nor delete the reader's
keys tidying up after itself. Presence is answered from the preferences file
(`SecretStore.has`), so drawing the settings screen never decrypts a key. The app holds `INTERNET` for one reason: the provider the
reader connected. Nothing else is called.

Every packaged Swift library is checked against the facade's `DT_NEEDED`
entries (transitively) at build time, so a new Foundation module the kit
starts using fails the build instead of the app's first launch.
