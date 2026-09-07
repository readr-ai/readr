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

### The instrumented run cannot hang

Two guards, both in `app/build.gradle.kts`'s `defaultConfig`.

`ReadrTestRunner` switches the phone to `NoInputMethod` — a keyboard with no
window — for the length of the run, and puts the reader's own back at the
end. Nothing here types on a soft keyboard (`performTextInput` hands Compose
the characters), but the keyboard's *show* transition intermittently never
finishes on CI's 320×640 emulator: `ViewRootImpl` goes on scheduling frames
for a resize that never lands, so the main looper never reports idle, and
Compose's `waitForIdle` — inside every `performClick`, `performScrollToNode`,
`assertExists` — waits on `Espresso.onIdle()`, which has no timeout. Run
34167244349 sat on one `AskSheetTest` case for 74 minutes that way, until the
job's own cap killed it. To see it locally, boot an AVD at the emulator's
default 320×640 (`hw.lcd.width=320`, `hw.lcd.height=640`, density 160) rather
than a phone profile; the 1080×2400 AVDs this is usually developed on never
reproduce it.

`timeout_msec` is the second guard: any test that outlives three minutes
fails and names itself. It is what makes the *next* unbounded wait a red
build in minutes rather than an hour of silence.

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

### On this phone: Gemini Nano

The phone's own model is Kotlin's to drive, because AICore is an Android API.
`kit/NanoModel` implements the facade's `OnDeviceModel` — one object for all
three questions the facade has: whether this phone can run the model, how much
it can hold, and what it says when asked something.

**Readiness** is one bare token, never a sentence: `ready`, `unavailable` (with
an optional reason code after a colon — `unavailable:downloading`) or
`unsupported` (a bridged protocol method may not throw or return an optional).
The *sentence* a reader sees is written on the Swift side — the kit's
`ProviderManager.ProviderError.notConfigured(.geminiNano)` for a phone that
cannot run it, `OnDevice.swift`'s own line for one still downloading — so
Kotlin writes no reader-facing copy. It is asked on every read of the
selection, cached for five seconds since one settings payload asks several
times, so the phone's own model is the default *while* the phone can run it and
the reader is back to "nothing chosen" the moment it cannot. "Check again"
throws the cached answer away first, so it really asks the phone.

A phone whose model is `DOWNLOADABLE` — offered, but not on the device — is
one `download()` away from ready, and ML Kit fetches nothing until an app asks.
So `readiness` asks, once, and reports `unavailable:downloading` either way:
saying "still downloading" without starting one left a reader watching a card
that would never change. The **progress is deliberately ignored**. AICore owns
the schedule from there — when to fetch, over which network, on whose
battery — and a percentage this app cannot influence is not something a reader
can act on. A download that fails is not a crash: the next readiness read asks
AICore again.

**The window** is not the budget. `windowTokens()` is what the runtime reports
(`GenerativeModel.getTokenLimit()`, asked once and cached, `0` when it cannot
say — the facade then falls back to 4,096, the figure Apple's FoundationModels
answers with). `ProviderCatalog.geminiNanoModels`' `contextBudget` of 2,000 is
a different number entirely: how much of the book `AdaptiveContextStrategy` may
*gather*, deliberately below the window so that the passages still leave room
for the conversation, the instructions and the answer. Spent as if it were the
window, a five-turn conversation over a long book was answered from passages
`SmallModelPrompt.fit` had trimmed away.

**Every call into ML Kit runs on a leash.** `checkStatus`, `getTokenLimit` and
the cancellation join all bind to AICore, and a phone with a broken or
half-installed one can sit inside that bind without ever suspending — which a
coroutine timeout cannot interrupt. Each runs on a thread of its own and is
waited for with a bounded `join` (five seconds; two for a cancel), so the Swift
caller — a cooperative thread, and sometimes a settings screen — is never held
longer than that.

**Eligibility**, plainly: Android 14 or newer; a flagship whose
`com.google.android.aicore` is installed and is not the do-nothing stub
(declared in the manifest's `<queries>`, or Android 11+ hides the package);
ML Kit's own `GenerativeModel.checkStatus()` answering `AVAILABLE`; and Readr
on screen — AICore refuses a backgrounded app, so a generation started from the
background fails with a sentence rather than hanging for the timeout. Anything
else is `unsupported`, and a card is offerable at all only when a check came
back *ready* (an on-device one) or a key is stored (a cloud one). Every ML Kit
call is wrapped: a check that cannot be made is not a model that can answer.
Emulators and Firebase Test Lab devices all ship the stub, which is why nothing
in CI ever generates for real.

**Privacy**: nothing leaves the phone. AICore runs the model locally, there is
no key and no account, and the passages a question carries — the book the
reader is holding — are never sent anywhere. The app's `INTERNET` permission is
for the cloud provider a reader connected, and the on-device path makes no
request at all.

#### What `genai-prompt` brings, and what it is licensed under

`com.google.mlkit:genai-prompt:1.0.0-beta4` is pinned, and it is **not open
source**: it, `genai-common` and `mlkit:common` ship under Google's
[ML Kit Terms of Service](https://developers.google.com/ml-kit/terms), a
proprietary licence. The rest of what it pulls in is
`play-services-basement`/`-base`/`-tasks` (Android SDK Licence),
`firebase-components`/`-annotations`/`-encoders`/`-encoders-json` and Guava
(Apache 2.0), `genai-schema`, and `datatransport:transport-api`. That is the
whole Google closure on the runtime classpath, and it is written down here
because an app that promises the on-device path sends nothing anywhere owes the
reader a plain answer about what it links against.

**Two datatransport modules are excluded on purpose** (`app/build.gradle.kts`):
`transport-backend-cct` and `transport-runtime`, Google's own event-upload
stack. Merging them put `ACCESS_NETWORK_STATE`, a `TransportBackendDiscovery`
service naming the CCT logging backend, a `JobInfoSchedulerService` and an
alarm receiver into Readr's manifest — an upload path a reader can read in the
permission list, for events this app never sends. Readr registers no transport;
with both excluded the permission and all three components are gone from the
merged manifest, ML Kit's initialiser still runs, and `NanoModel.readiness()`
still answers on an emulator without throwing (`NanoModelTest`). Anything ML
Kit itself needs from datatransport would fail loudly at build time, and
`transport-api` — interfaces only — is still there.

**Answering** is the kit's recipe and Kotlin's model call, exactly the split
the Apple app's `FoundationModelsProvider` makes. `NanoProvider` (Swift) runs
`SmallModelPrompt.plan` — the tier, the one-word off-topic classifier hop, the
answer-style rules, and the window arithmetic against the model's own window —
then generates through `NanoModel` and feeds the answer into
`SnapshotAnswerStream`, which is what decides the reader sees settled sentences
only, no repeats (`RepetitionGuard`), and nothing pasted out of the passages.
The classifier hop is **greedy** and three tokens wide — it is a routing
decision, and warmth there only turns one word into another — while the answer
keeps a temperature of 0.5, because greedy decoding is what sends a small model
round the same sentence. `isSystemPromptAvailable` is asked once per client:
instructions ride in ML Kit's system slot where the model has one and are
folded into the prompt where it does not.

**Deltas travel; Swift accumulates.** ML Kit's callback is `onNewText`, and the
argument is read as what its name says — the new text. `OnDeviceSink.delta`
adds it to the answer so far, because `SnapshotAnswerStream` reads the whole
answer, and the accumulating happens once, on the side that owns the shape. The
AAR carries no javadoc and publishes neither a sources nor a javadoc jar, so
the name is the whole documentation; the one hedge is a chunk that begins with
everything already sent and is longer, which is a cumulative snapshot and would
double every word — its tail is taken instead, and the fact is logged once.

**Cancelling.** `cancel` returns only once the Kotlin job is cancelled and the
sink can no longer be called (`cancelAndJoin`, bounded), which is what lets the
facade let go of that sink. A cancelled generation reports **neither** ending —
and ML Kit's own `CANCELLED` is read the same way, as no report at all, since a
reader who stopped an answer must not then be shown a failure.

`OnDeviceSink` is the one callback that travels Swift → Kotlin, so unlike
`SecretStore`, `AskSink` and `OnDeviceModel` it is a **class** rather than a
protocol: jextract can only carry a concrete jextracted type into a
Java-implemented method. Failures come back through it as reason codes
(`background`, `busy`, `declined`, `tooLong`, `unavailable`) that the facade
turns into sentences.

Its **lifetime is the facade's**, and stated rather than assumed:
`OnDeviceModelBox` keeps a strong reference to each live generation's sink and
drops it when an ending arrives or when `cancel` comes back. jextract's
generated thunk allocates an `UnsafeMutablePointer<OnDeviceSink>` per call and
hands the address to a Java wrapper registered with swift-java's *auto* arena;
it exposes no way to free that allocation, and when the wrapper is collected
the arena calls `SwiftObjects.destroy` on the value it points at. So without a
reference of our own the object's life would be the Java wrapper's, decided by
a garbage collector — which is not a thing a late callback can be reasoned
about against.

### Keys, and what choosing a provider means

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

## Listen

`ui/listen/` is the book read aloud: the ✦-less half of the AI story, and the
one place the phone's own hardware does the work. Every playback rule is the
kit's — `NarrationController` decides which sentence is next, what a skip does
to a completion that was already in flight, how a speed change picks a sentence
back up mid-word, and when the sleep timer burns. The Android half is three
pieces around it.

`Narration.swift` is the facade. `AndroidNarration` builds the controller for a
book and answers one `stateJSON()` the card draws from — status, hold, the
sentence, the chapter's progress, the sleep timer, the speed. Offsets cross in
UTF-16 like everything else (`TextOffsets.swift`), including the word
boundaries. `NarrationObserver` is the Kotlin-implemented protocol it pushes
changes to, reporting only what actually changed: the card is redrawn from
these, and a once-a-second tick that republished the same sentence would be a
recomposition a second for as long as the book is read. Everything is called
from the **main thread** — the controller is main-thread-confined and there is
no queue on the Swift side to hop with, since Swift's main thread here *is* the
Android main looper.

Two things the facade names for itself. **The failure sentence:** an utterance
the phone's voice refuses is not one of the kit's `NarrationHoldReason` cases
(on Apple it is a Retry the bar offers, not a state), so `BridgedSpeechEngine`
keeps the engine's last failure and `state()` turns a pause nobody pressed into
`holdReason: "engineFailed"` with the words the card shows. Kotlin reports an
engine code to the log and no further, as everywhere else. (The *system* taking
the audio is not this: it is a real kit hold, `NarrationHoldReason
.audioInterrupted`, reached through `NarrationEvents.suspended` — see the audio
focus note below.) **The voice:** the
phone cannot say which voices it has until its engine has started up, which is
after the session is built — so the kit's choice (`VoiceSelector`, the book's
language over the device's) is made lazily, retried on every control and on the
tick, and settled for good once `NarrationEvents.voicesReady` arrives. Resolved
once in `init` against the empty list it always found there, it read every book
in whatever the device's default was. `AndroidNarration.optionsJSON()` is
static and answers the kit's own fixed lists — the speed steps and their
labels, the sleep durations and theirs — so Kotlin draws the controls from
`SpeechSettings.rateSteps` and `SleepTimer.minuteOptions` rather than from a
copy of them that goes quietly stale.

`kit/PlatformSpeechBackend` is `android.speech.tts.TextToSpeech` behind the
kit's engine protocol. **There is no pause**, on the phone or in here.
`TextToSpeech` cannot pause, so `BridgedSpeechEngine` answers the kit's
`SpeechEngine.pausesInPlace` with `false`, and `NarrationController` stops the
backend on a pause and re-speaks the sentence from the last word boundary — as
a *fresh request* — on play. That is the same path a sleep-timer stop already
resumes by, it is unit-tested in the kit against a mock engine, and it is the
reason this class no longer fakes a pause of its own: it used to stop the
utterance, remember the boundary, re-speak the tail under the same request id
and add the cut back into every boundary it reported afterwards, so the kit was
never told the text had been shortened. Now word boundaries are plain offsets
into the string handed over, `state()` never answers `paused`, and the platform
is given the request id itself — the controller never speaks one request twice,
so an id is enough to tell a late report from a stopped utterance apart from the
one in flight.

Two other rules live here. An engine that **fails to start** kills the backend:
it is shut down, and every later request is refused on the spot rather than
parked waiting for a readiness that is not coming (the card then holds with the
facade's explanation, instead of sitting on Pause with a sentence and no word
about why). And the **resolved voice is cached** per (voice, language):
resolving walks `tts.voices`, which is every voice installed on the phone, and
the answer cannot change between two sentences of one book — while an engine
left with no language it has data for refuses the sentence rather than taking it
and saying nothing. Network voices are never offered — reading is a zero-egress
promise (PRIVACY.md), and a voice that needs a connection would send the
sentence to a server. The speed reaches the engine on the platform's own scale:
Android documents that scale as proportional, and the facade's ceiling constant
is a calibration chosen so the kit's AVFoundation-shaped curve comes back out
straight — a 1.5× label really is 1.5×.

`ui/listen/ListenCard` is the post-#101 now-reading card, insetting the reading
surface from the bottom rather than floating over it — the page turns itself to
follow the voice, so nothing may cover the words. Chapter in caps, the sentence
in serif italic, a 2 dp progress hairline, and one row: speed, ◀ ● ▶, sleep,
with ✕ in the corner. Its measured height goes back into the surface as an
inset, which is a second page geometry and therefore another `PaginationCache`
slot.

In the reader, the bar's Listen button starts at the top of the visible page
(`nextSentenceStart`) and the capsule's Listen starts on the sentence the
reader's finger is in (`sentenceContaining`) — the page rule would skip the very
words they pointed at. A selection start that lies on the page *before* the one
in view holds the page until the voice reaches it, so a control that promised to
read from here cannot throw the reader back a spread; the held page still saves
the sentence being read.

Every jump the reader makes — Contents, search, a bookmark, a highlight, "Show
in book" on a citation — goes through one `jumpTaking`, which takes the voice
into a *different* chapter (re-pausing it if it was paused) and leaves it alone
inside the chapter it is already reading: looking something up two pages on is
not a request to start again, and restarting would re-arm the sleep timer.
Opening Ask pauses narration and dismissing it resumes — only if it was Ask that
paused it — and a question with no selection while the voice reads is about the
sentence being read.

What gets written down as the reading position is the **sentence start**, not
the page top: that is where pressing Listen again picks the book back up. It is
kept with the chapter it belongs to, so a reader who crosses back out of the
chapter the voice is in saves their own page rather than an offset from a
chapter they have left. In the scroll layout the list echoes the line at the top
of its viewport on every frame, and that echo is *not* a page turn when it is
the voice's own move coming back.

Narration outlives the composition on purpose — a rotation, or the trip to the
provider settings Ask's empty state offers, must not cut the voice off
mid-sentence — so it is released by a `NarrationLease`, a `ViewModel` on the
reader's `NavBackStackEntry`, rather than in an `onDispose`. Leaving the book
stops the voice and hands the synthesizer back.

### With the screen off

`ui/listen/NarrationSession` is the book on the lock screen: one media3
`MediaSession` over the voice, carried by `NarrationService`, a
`MediaSessionService` that runs in the foreground for exactly as long as a
voice is reading. That is what keeps the reading going with the screen off,
and it is what puts the transport in the notification shade, on the lock
screen, and under a headset button.

There is no `ExoPlayer` and no audio file — the phone's synthesizer makes the
sound, sentence by sentence, and every playback rule is still the kit's. What
the session publishes is a `NarrationPlayer`: a `SimpleBasePlayer` that owns no
playback and only *describes* `NarrationModel`. Commands go straight back to
the model: play/pause to the kit's own, stop to `stopListening`. Nothing here
has a duration or a timeline, and the position is a **constant** zero rather
than a bare `0` — media3 extrapolates a plain number with the wall clock, and
⏮ then means "start this chapter again" three seconds in, which is not what the
button says.

**No book text reaches the notification.** The book is the title and the album,
the chapter is the artist line, and the sentence being read is nowhere in any
of it — it stays on the card, inside the app. A media notification is not a
private surface: the lock screen shows it to whoever picks the phone up and the
shade keeps it in its history, and the sentence used to be the media item's
title. A *hold* still takes the title line ("Paused — another app is using the
sound"), because that is the app's own words about the app's own state and the
lock screen is exactly where the reader is when the voice stops by itself.

The playlist is the chapters the kit **will read**
(`AndroidNarration.nowPlayingJSON`, which names the book, its author, and
`Book.narratableChapterIndices` with the kit's own headings — Kotlin writes
none). A `linear="no"` spine entry is not a track, because auto-advance would
refuse to play it; each row carries its own chapter index in the book, so the
row's position and the chapter's number are different numbers and the current
row is a lookup, not an offset. Titles come from
`chapterDisplayTitlesInStoredOrder` — narration counts in `chapters` array
positions and `chapterDisplayTitle` counts in reading order, and a playlist
titled through the wrong one is a row out of step.

A seek is read from the **command**, not from the index: ⏭/⏮ map to the kit's
chapter skips and a queue pick maps to `listen(chapter, 0)`. ⏮ mid-chapter is
the kit's rule — restart this chapter, then cross back from its start — which
is a seek to the row already playing, and comparing indices saw "nothing
moved" and did nothing. `availableCommands` is built per state, so the last
chapter offers no ⏭ rather than a control that does nothing. The rows are
cached on `(chapters, holdText, title)`: `getState()` runs once a sentence and
once a second, and a playlist rebuilt each time is a new timeline every second
— a flicker in the shade. Sentence skips stay on the card, where a reader can
see what they are skipping.

The session's lifetime is the voice's, so the `NarrationLease` rule is intact:
background playback means the screen is off or another app is in front, never
that the reader left the book behind. Opening the session starts the service;
letting it go stops it. A swipe of Readr off the recents list stops the voice
too, which is what leaving the book means.

**Audio focus** is `AudioManager`'s, asked for as speech (`USAGE_MEDIA`,
`CONTENT_TYPE_SPEECH`), and it follows the *status*: `holdFocus()` when
narration is under way, `dropFocus()` when it is not, both idempotent, so a
paused book has no claim on the phone's sound.

**Kotlin owns the focus; the kit owns the pause.** Every interruption — a
transient loss, a permanent one, and a request the phone simply refuses — goes
to `AndroidNarration.audioInterrupted()`, which suspends the kit's engine and
leaves narration held with `NarrationHoldReason.audioInterrupted`. That reason
is the whole mechanism: it is what the card and the notification explain
("Paused — another app is using the sound"), it is what a `GAIN` checks before
resuming, and `NarrationController.pause()` clears it the moment the reader
takes the pause over — so a reader who pressed pause during a call, or opened
Ask, is not read at by the regain. Kotlin used to keep a `pausedForFocus` flag
of its own beside the kit's state, and the two could disagree. A refused
request is not a log line and a book that reads anyway: the voice holds. The
one thing `dropFocus` will not do is abandon the request *during* an
interruption — that registration is the only way the regain reaches us.
Ducking is ignored: a quieter voice under someone else's music is not
listenable, and pausing is what a real loss already does. The focus sits behind
`NarrationAudioFocus`, because "a call came in" is a thing the system does to
an app rather than a thing a test can provoke; the service is started and
stopped with two `ContextCompat` lines and needs no seam, since
`NarrationService.running` already says what a test wants to know.

`POST_NOTIFICATIONS` is asked for the **first time Listen starts** and never
again — a permission sheet on the way into a book nobody has asked to hear yet
is a question out of nowhere. Refusing costs nothing audible: a media-playback
foreground service posts its own notification either way, so the voice keeps
reading and only the shade's other messages are lost. The app's permissions are
otherwise unchanged; media3 brings `ACCESS_NETWORK_STATE` for ExoPlayer's
bandwidth meter, which nothing here builds, and the manifest takes it back out
(`tools:node="remove"`) so the permission list stays the one sentence it has
always been.

### The voice

The narrator is chosen in the **Appearance sheet**, as it is in the Apple app's
Aa popover and for the same reason: it is a decision made once, not a control
reached for mid-sentence. `ui/listen/VoicePicker` draws it, and decides nothing
— `AndroidNarration.voicesJSON()` answers the whole payload: the voices for the
book's own language first, everything else behind "Other voices", which voice
is reading, which one the kit *recommends* (`VoiceSelector` with no stored
preference — marked, and not the same thing as the row that is checked), and
the sentence for a list with nothing in it. Every ordering is the kit's
`VoiceSelector`, the same ranking the Apple picker lists by and the same rule
narration resolves the reading voice with; Kotlin re-ranks nothing and words
nothing.

**One language for the picker and the reader.** `AndroidNarration` takes the
device's language tag from Kotlin (`Locale.getDefault().toLanguageTag()` —
Foundation's current locale on Android is not the reader's) and
`narrationLanguage` is the book's own if it declares one, else that. Both
`voicesJSON()` and `resolveVoiceIfNeeded()` use it. They used to differ: an
untagged book was grouped under the reader's locale with a row marked
"Recommended", and then read in whatever the engine's default was — so on a
phone whose default is French, an English file was listed in English and read
in French, with the tick nowhere near the recommendation.

**Two silences, two sentences.** `SpeechBackend.voicesJSON()` answers
`{"ready":…,"voices":[…]}`, because "the engine has not started up yet" and
"this phone has no voice data" are both an empty list and want opposite words.
The facade emits `emptyText` only when the engine has answered with nothing,
and a `looking` flag with "Looking for voices…" otherwise; sending a reader to
a settings screen while the list is on its way is simply wrong.

**The row costs nothing to draw, and nothing polls.** `VoiceRow` names the
voice from the preferences file — `narrationVoiceID2` (the iOS key) with
`narrationVoiceName` beside it (Android's own key: the id is a machine name and
the readable half is composed from the phone's list), falling back to the
facade's "Phone's default voice" out of the static `optionsJSON()`. Only the
tap that *opens the picker* calls `prepareVoices()`, which is what builds a
listening session and starts a `TextToSpeech` engine; doing that when the row
merely appeared started one on every trip to the Appearance sheet. When the
engine reports in, `PlatformSpeechBackend` fires `NarrationEvents.voicesReady`
unconditionally (it used to sit below an early return for "no sentence was
waiting", which is exactly the picker's case), the facade pushes
`NarrationObserver.voicesChanged()`, and the row fills in — where it used to
ask twenty-four times a quarter-second apart because there was nothing to wait
on. Picking applies mid-sentence through the kit's settings path.

Android gives a voice a machine name and no human one, in two shapes —
`en-us-x-sfg#female_1-local`, where a `#` marks the variant, and
`en-us-x-tpd-local`, where nothing does; Google's engine ships nine local
English voices of the second shape, so `PlatformSpeechBackend` reads the `x-`
token as well, or the picker is nine rows that cannot be told apart.

Not yet: the read-along underline. Two follow-ups worth doing. `NarrationModel`
both is pushed to (`NarrationObserver`) and pulls (`refresh()` after every
control, and once a second), so the same state arrives twice by two routes —
one push path would be less to reason about. And that voice display name is
still composed on the Kotlin side (`displayName`/`variant` above): it is the
one reader-facing string here that the facade does not own, and moving the
composition behind `voicesJSON()` would finish the rule.

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
reader connected. Nothing else is called. The other three permissions are
Listen's — `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` and
`POST_NOTIFICATIONS` — and they are what lets the voice keep reading with the
screen off; none of them reaches the network.

Every packaged Swift library is checked against the facade's `DT_NEEDED`
entries (transitively) at build time, so a new Foundation module the kit
starts using fails the build instead of the app's first launch.
