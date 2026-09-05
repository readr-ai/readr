# Device smoke test — the M6 exit gate

> **Walked 2026-08-08 against the v2.15.0 TestFlight build: passed.** That
> closed M6. Item 1 — the OAuth token exchange with a real authorization code —
> was the only path no automated lane or simulator could reach, and it works on
> device. Keep this list for the next release rather than treating it as done
> forever.

Everything here needs a **physical iPhone and iPad**. It is deliberately short:
the automated suites and a simulator walk already cover most of the app, so
this lists only what a simulator genuinely cannot prove, plus the handful of
paths that need real credentials.

Budget: **~15 minutes per device.** Tick as you go; anything that fails is a
launch blocker unless noted.

## Why these and not more

Already covered elsewhere, so deliberately absent:

- Reading, layouts, themes, highlights, notes, bookmarks, search, TOC — the
  XCUITest suites run all of this on both simulators every PR.
- The Settings/Help surfaces, the bug-report preview, and book-colour
  rendering across all three themes — walked on the iPad simulator 2026-08-06.
- OAuth sheet presentation and cancel — same walk. What is *not* covered is
  the callback returning into the app, which is the first item below.

## 1. OAuth round trip — mostly proven, one step left `[blocker]`

Verified on the iPad simulator 2026-08-08, by starting the flow and delivering
a callback to the loopback listener by hand:

- the listener really does come up on iOS (`Readr … TCP 127.0.0.1:1456
  (LISTEN)`), so the in-process sheet does **not** suspend the app — that was
  M7's stated fear
- it accepts the HTTP callback and serves its page
- the app dismisses the sheet and returns to Settings on its own
- it validates `state` (a deliberately wrong one was rejected) and shows a
  plain-language error
- the listener closes afterwards and frees the port

So the delivery mechanism is not in doubt. What is still unproven is the
**token exchange with a genuine authorization code**, which needs a real
account — and whether a device behaves like the simulator here, since
backgrounding and the network stack differ.

- [ ] Settings → OpenRouter → **Sign in with OpenRouter**
- [ ] Complete the sign-in in the sheet
- [ ] The sheet **closes by itself** and the card flips to Connected
      *(if it hangs on the callback, that is the M7 risk and it is a blocker)*
- [ ] Ask a book one question and get an answer
- [ ] Force-quit, reopen: still Connected (tokens survived in the Keychain)

## 2. Keychain on a real device `[blocker]`

The simulator Keychain is more permissive than a device's, so this path is
weakly covered by everything above.

- [ ] Settings → paste an Anthropic or OpenAI API key → Save
- [ ] Allow the Keychain prompt if one appears
- [ ] Card reaches **Connected** (not stuck on Validating…)
- [ ] Force-quit, reopen: still Connected
- [ ] Decline the prompt on a second key, if you can trigger one: the message
      should read "Readr couldn't reach your Keychain, so nothing was saved."
      and not show an `OSStatus` number

## 3. Files-app import `[blocker]`

`-uiTestOpenURL` stands in for this in CI, which exercises the import path but
not the actual system integration.

- [ ] Mail or AirDrop yourself an EPUB → share sheet → **Readr**
- [ ] Files app → long-press a PDF → Share → **Readr**
- [ ] Both land on the shelf and open

## 4. Real-book performance `[blocker if bad]`

Simulators have desktop-class CPU and memory. This is the only place a real
device is meaningfully *slower*.

- [ ] Import a large EPUB (a 500+ page book — Moby-Dick works)
- [ ] Time to open: should feel instant, not a visible stall
- [ ] Page turns stay smooth after reading a few chapters
- [ ] Ask a question: first token should arrive in a few seconds

## 5. #47 — the book this was filed against `[not a blocker]`

Format spans are computed at import, so a book already on your shelf keeps its
old rendering.

- [ ] **Re-import "The Book of Elon"**
- [ ] Contents → "Notes on This Book"
- [ ] "I am a highlight." now renders with its highlight styling
- [ ] Switch to Dark: it stays legible

## 6. iPad-specific `[blocker]`

- [ ] Sidebar and reader side by side in landscape
- [ ] Two-page spread in landscape; single page in portrait
- [ ] Hardware keyboard (if you have one): arrow keys turn pages
- [ ] Split View with another app: layout adapts, nothing clips

## 7. The new Help surfaces `[not a blocker]`

Verified on the simulator; worth ten seconds to confirm on device because the
device model string comes from a different code path.

- [ ] Settings → Help → **Report a bug** → "See exactly what will be sent"
- [ ] The device line reads a real identifier (`iPhone17,1`), **not** `arm64`
      and **not** "(simulator)"
- [ ] Settings → Help → **Share Readr** opens the share sheet with the link

## 8. Listen — the parts nothing else can reach `[blocker for 3.0]`

The narration tests deliberately run a **silent** engine
(`-uiTestSilentNarration`): against a real synthesizer a headless runner fails
the first utterance instantly and races the book to its end before a test can
tap anything. So the suites prove the *logic* and prove nothing about the
*sound*. This section is the whole of the evidence that Readr speaks.

The first pass of this list (macOS, 2026-08-17) found four defects, three of
them impossible to see any other way — an English book read aloud in a novelty
voice, every speed above 1× running at roughly double its label, and narration
hanging at the end of a book. The **second** pass, over the fixes, found two of
them incompletely fixed; the **third** found a third-order version of the same
voice bug still live. Run the whole list again after fixing anything on it; a
repaired defect is exactly where the next one hides.

**On a Mac** (needs audio out; use headphones if you like, and note that a
screen recorder may swallow ⇧⌘L as a global hotkey — drive the on-screen
control instead):

- [ ] Press Listen mid-chapter: a voice speaks, and it is a **normal** voice —
      on macOS, `Samantha` or whatever System Settings names as the default,
      never `Albert`, `Bad News`, `Bubbles` or another novelty voice
- [ ] Aa › Voice **opens on** that same sensible voice, and the joke ones are
      at the **bottom** of the list — checking only the first row misses this,
      which is how it survived one round of fixes. Open Aa › Voice on a fresh
      book **before** pressing Listen: the row already names the voice and the
      list is there (it used to be empty until the first Listen)
- [ ] Narration starts at the first sentence of the page in view, **not** the
      chapter's start and **not** a sentence that began on the previous page —
      page to the last page of a chapter first, then press Listen. Read the
      *text* it speaks against the page rather than trusting where the view
      scrolls to. If it looks wrong, capture the number: Settings → Help →
      Report a bug → "See exactly what will be sent" carries a
      `Narration start: chapter N offset M` line, and the sample book's
      paragraphs are all different, so the offset and the words should agree
- [ ] The page turns itself to follow the voice, and crosses into the next
      chapter on its own
- [ ] Change speed **mid-sentence**: it continues from about that word rather
      than restarting the sentence
- [ ] Speeds are honest — "2×" takes about half as long as "1×", not a quarter.
      Worth timing rather than eyeballing; the mapping is calibrated to a
      measurement and the constant lives in `SpeechSettings`
- [ ] Open Ask while narrating: the voice **pauses** on its sentence and the
      panel quotes that sentence; Done (or closing the panel) resumes it
      there. Then: open Ask, press ● on the card to keep listening, press ●
      again to pause, close Ask — it **stays paused**
- [ ] While narrating, open Contents and pick another chapter: the page
      turns there and the voice follows (it does not turn the page back)
- [ ] Let it run to the end of the book: it **stops** within a couple of
      seconds and the control returns to ▶, rather than sitting on ⏸ forever
- [ ] Pause, wait, play: it resumes rather than restarting the sentence

**On an iPhone** — none of this can be faked on a simulator, and none of it has
been run yet: the machine that verified 3.0.0 had no device paired to it, so
these four shipped on unit tests and the simulator alone.

- [ ] Lock the screen while narrating: playback continues
- [ ] Lock screen shows the book and author, and its play/pause works
- [ ] A headphone/AirPods pinch pauses and resumes
- [ ] Leave the app: playback continues in the background

## 9. Readr Voice on MLX — iPhone and iPad `[blocker for 3.3]`

Readr Voice on iOS runs Kokoro on the Metal GPU through MLX
(`App/Speech/MLXKokoroSpeechEngine.swift`). **None of it can run on the
simulator** — MLX aborts there (mlx#2605) — and CI proves only that it
compiles and links. Every line below is unverified until a device has done
it; two of them (the lock and the memory ceiling) are exactly where the
known failure modes live. Use an iPhone on iOS 26.4 or later, on Wi-Fi, with
Xcode attached for the memory gauge. Record the device model and iOS version
with the results.

- [ ] **First Listen waits for Readr Voice.** Fresh install (or delete the
      app first). Open Alice, press Listen: no voice starts. The card
      reads "Preparing Readr Voice… N% of 410MB, once" with a progress
      line while the weights download, then a small spinner for the
      pronunciation assets and the load; the play/pause control shows
      Pause. Open Aa › Voice: Readr Voice is the only row, checked, with
      an "Other voices…" submenu holding the Apple voices; no downloading
      note, no locked-screen note. When the model is in (one to two minutes
      on Wi-Fi) the first sentence is Readr Voice — **no Apple voice at any
      point**, no sentence repeated, none skipped — and the card shows the
      sentence. Note how long it took from pressing Listen. Press pause
      during the wait: the card flips to Play and the download carries on;
      press play: "Preparing" is back. Turn Wi-Fi off before pressing
      Listen: the card reads "Readr Voice couldn't download." with a Retry;
      turn Wi-Fi on, press Retry: preparing, then Readr Voice.
- [ ] **The buffer fills.** The card no longer shows a "ready" figure (it
      was an engineering number); the diagnostics log does — each sentence
      played from the buffer is logged with "Ns ahead". In the foreground,
      let it read a minute, then skip forward a dozen sentences: each
      arrives at once, in Readr Voice. Plug the phone in: the "ahead"
      figure climbs on past an hour, to the end of the book or two hours.
      Unplug: it stops adding, keeps what it has. Skip back a sentence:
      instant. Change speed to 1.5×: the sentence continues from where it
      is, no restart, and the figure does not drop. **Record** from the log
      how long it took to reach 10 minutes (600s) ahead.
- [ ] **Thirty minutes continuous, foreground.** Leave it reading. No quit,
      no stall, no sentence heard twice, no Apple voice at any point. Watch
      the read-along line keep pace with the audio.
- [ ] **Mandatory lock-race test — 20 times.** Prefetch now defaults to
      `.gpuWhileActive` — GPU while the app is foreground, same as
      playback, CPU only once backgrounded — so with the app foreground and
      reading normally, prefetch is a GPU sentence like any other. Read
      ahead so a sentence is regularly being synthesized right as you lock
      (skip forward past the buffer, or read as fast as the GPU/CPU
      refill), and lock the phone right after skipping past what is
      buffered (the next sentence is being synthesized as you lock),
      unlock it, and repeat for 20 total locks. MLX cannot
      cancel the one Metal graph already submitted, so diagnostics
      warning-log each lock that catches one with its elapsed milliseconds
      (every GPU use is also logged at `.info` with its duration, so the
      diagnostics file shows exactly how much exposure there was). Record
      the warning count and elapsed values. **Any crash is still a
      release blocker**; file it with the full diagnostics log.
      `readrVoice.prefetchOnCPUOnly` (default off) forces prefetch onto the
      CPU even in the foreground, for the more conservative pre-fix
      behaviour while investigating; `readrVoice.prefetchOnGPU` is a no-op
      now that GPU-while-active is the default.
- [ ] **Memory.** In Xcode's Debug navigator, the Memory gauge during that
      half hour: note the peak. It must stay **under 1GB** and must not climb
      sentence over sentence (a rising line is the MLX cache leak the 64MB
      cap is meant to stop). The on-disk buffer is not memory; check it
      separately under Settings › General › iPhone Storage › Readr (about
      30MB an hour of audio).
- [ ] **Thirty minutes locked.** After twenty minutes of foreground
      listening (the log's "ahead" figure past 1200s), lock the phone. Readr Voice keeps reading from the lock screen — the same
      voice, no gap. Leave it locked for thirty minutes with Xcode attached:
      no quit, no stall; lock-screen pause/play and the headphone pinch
      work. Unlock: still Readr Voice, no sentence twice. Then **measure**,
      from the diagnostics log (Settings › Report a bug includes it — this and
      earlier sessions — and offers the raw file; Xcode's console shows it live): the one-time `Readr Voice (MLX) CPU
      synthesis starting with MLX compilation disabled` line (should appear
      once, at the first CPU sentence — the background warm-up, if playback
      had already started before background), then the `Readr Voice (MLX)
      sentence N: cpu …` lines — every sentence now, not one in ten. Write
      down every `cpu rtf over last 5` value, the `ms for … ms of audio`
      pairs, the "s ahead" figure at lock and at unlock, and the peak
      memory during the locked half hour. An rtf under 0.8 means the CPU
      refill cannot keep up with playback on this phone and the buffer is
      what carries the locked screen.
- [ ] **CPU synthesis failure (`readrVoice.prefetchOnCPUOnly=1` on a device
      known to hit `[Compiled::eval_cpu] CPU compilation not supported on
      the platform`, or any device where the CPU throws even with
      compilation disabled).** Lock the phone with the buffer thin. A CPU
      synthesis failure logs `Readr Voice (MLX) CPU synthesis failed with
      MLX compilation disabled; CPU unavailable for the rest of this
      session` at `.warning` with the underlying error, once. **The app
      must not crash.** From then on: no further CPU attempts (no more
      `sentence N: cpu` lines), the buffer plays out normally, and once it
      runs dry the card shows "Paused — unlock Readr to keep listening" (the
      existing hold) rather than silence or an Apple voice. Unlocking
      resumes on the GPU.
- [ ] **Lock with nothing ready.** Fresh install; press Listen and lock
      the phone as soon as the first sentence is heard. The next sentence
      either arrives in Readr Voice after a CPU synthesis or narration
      pauses at the boundary with "Paused — unlock Readr to keep listening"
      on the card, the lock screen's title, and as a notification (the first
      Listen asked for permission — decline it and the diagnostics file
      should carry a "hold notification permission not granted" line). No
      Apple voice. Unlock and open Readr: it resumes on the same sentence by
      itself; the notification is gone.
- [ ] **Lock during the first download.** Fresh install again. Press
      Listen, then lock the phone immediately and leave it locked past the
      point the download would have finished (five minutes on Wi-Fi). The
      card was on "Preparing"; nothing speaks and the app does not quit —
      the GPU load waits for the foreground. Unlock: preparing finishes and
      Readr Voice reads.
- [ ] **Relaunch from the buffer.** Force-quit, reopen, press Listen at the
      same place: the sentence starts at once in Readr Voice before the
      model has loaded, and the log's "ahead" figure shows what survived.
- [ ] **Delete a book.** Delete Alice: Settings › General › iPhone Storage ›
      Readr shrinks by its audio.
- [ ] **Pause and resume.** Pause mid-sentence from the card, wait ten
      seconds, play: it resumes rather than restarting the sentence. Same
      from the lock screen and with a headphone pinch.
- [ ] **Skips and a chapter crossing.** Skip forward and back a sentence in
      Readr Voice; skip to the next chapter; let a chapter end on its own
      and roll into the next. Every one continues in Readr Voice.
- [ ] **Speed.** Change speed mid-sentence: the player applies the
      multiplier to the buffered audio (pitch preserved), so 1.5× should be
      audibly faster, still intelligible, and continue from where it was.
- [ ] **No crash logs.** After all of the above: Settings › Privacy &
      Security › Analytics & Improvements › Analytics Data. There must be no
      new `Readr-…` entry. Any that appears goes in the bug with the full
      text — the BNNS signature is `BNNSGraphContextExecute`; the MLX one
      is `[METAL] Command buffer execution failed` from
      `com.Metal.CompletionQueueDispatch`.
- [ ] **A long sentence.** Find or paste a sentence of 300+ characters (the
      segmenter's cap is 320). It is read in full, in Readr Voice, possibly
      with a small pause at a comma where it was split.

## 10. Pulling the diagnostics file off a device

`DiagnosticsLog` is an in-memory ring buffer — see its doc comment — so a
crash or a session that never got to Settings › Report a bug takes it with
it. In every build, `AppModel` also appends each event to
`Library/Caches/Diagnostics/readr.log` inside the app's own container
(`DiagnosticsFileSink`, ~1MB cap with a single rotation to a `.1` sibling).
Two `devicectl` commands get it off a connected device without touching the
app:

```sh
# List what's there (find <device-id> with `xcrun devicectl list devices`):
xcrun devicectl device info files \
  --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.readrai.app \
  --subdirectory Library/Caches/Diagnostics

# Copy it to the current directory:
xcrun devicectl device copy from \
  --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.readrai.app \
  --source Library/Caches/Diagnostics/readr.log \
  --destination .
```

- [ ] After using the app for a minute or two, both commands succeed and
      `readr.log` has lines with a timestamp, level, category and message —
      no book text, no secrets
- [ ] The first line of a fresh app container reads `launched Readr
      <version> (<build>)`

## 11. Ask with Apple's on-device model (3.4.0)

Needs an iPhone 15 Pro or later (or an M-series Mac) on iOS/macOS 26 with
Apple Intelligence on, and no provider connected. Record device, OS, and
time to first token.

- Fresh install: Settings → AI Providers shows "Apple Intelligence" first,
  status Connected, Active. No key field, no sign-in.
- Open Alice, Ask (whole book): "Why does Alice follow the White Rabbit?" —
  one or two sentences, chapter sources, footer "Answers come from this book
  only." First token within ~5 s.
- "Can I be a rabbit?" — a short answer or the line "The model couldn't find
  an answer to that in the book…". Never a sentence repeated, never a page of
  pasted dialogue, never a blank over a Sources list.
- Recap from Continue Reading works and stops at your position.
- iOS Settings → Apple Intelligence off → back in Readr: the card explains,
  Ask shows the connect-a-provider guidance. Back on: Check again → Connected.
- Airplane mode: everything above still works (no network on this path).
- Connect a key: the key's card goes Active; Apple's card stays Connected but
  not Active; Ask uses the key. Disconnect the key: Apple's model is the
  default again without relaunch.

## 12. Listen from here (3.4.0)

- EPUB: select a sentence mid-page → headphones button → narration starts at
  that sentence (not the chapter start); the page follows.
- EPUB, selection spanning two sentences: starts at the first.
- PDF (text): scroll to page 40, select a line → Listen starts there; page
  follows as narration advances; pause and Listen again resumes at the same
  place.
- PDF: with no selection, Listen starts on the page in view, not page 1.
- PDF highlight: the annotation menu's headphones starts at the highlight.
- Lock the screen after starting from a selection: audio continues; the
  saved position on return is where the voice left off.

## 13. Report a bug (3.4.0)

- Settings → Report a bug: the sheet shows the app version, OS, device, and
  recent log lines; no book text or file paths anywhere in it.
- Copy report → paste into Notes: complete, readable, under a screen.
- Share as file → Files: the log snapshot opens as tab-separated text.
- Open a GitHub issue: the browser opens with the title and body prefilled and
  nothing truncated mid-sentence (URL ≤ 6,000 bytes).
- Make an error happen first (e.g. Ask with Wi-Fi off on a cloud key): the
  error line appears in the report's evidence.

## Not on this list, on purpose

**ChatGPT subscription sign-in.** `.chatGPT` is filtered out of the iOS build
(`SettingsModel.displayedKinds`, from #61), so it cannot be tested on iOS and
is **not an App Store blocker**. It ships only on the macOS direct download;
verify it there if and when you want that path confirmed.
