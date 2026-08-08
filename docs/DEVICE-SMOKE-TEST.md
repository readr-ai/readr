# Device smoke test — the M6 exit gate

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

## 1. OAuth round trip — the one real unknown `[blocker]`

The in-process `SFSafariViewController` presentation is verified. The
**loopback callback and token exchange are not**, and they are the part most
likely to behave differently on a device (backgrounding, network stack,
the ephemeral listener).

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

## Not on this list, on purpose

**ChatGPT subscription sign-in.** `.chatGPT` is filtered out of the iOS build
(`SettingsModel.displayedKinds`, from #61), so it cannot be tested on iOS and
is **not an App Store blocker**. It ships only on the macOS direct download;
verify it there if and when you want that path confirmed.
