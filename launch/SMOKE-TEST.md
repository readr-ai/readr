# Pre-launch smoke test (run on a Mac, ~20 min)

The provider layer is fully unit-tested against mocks, but **no auth path has
ever been exercised against a real provider** (tracked in ROADMAP M2). Run this
before the Product Hunt post goes live. Use the shipping artifact, not a debug
build: download `Readr-macOS-v2.6.0.zip` from the latest release.

## 0. First-run experience (2 min)

1. Unzip, drag to `/Applications`, double-click.
2. Expected: Gatekeeper "could not verify" dialog → Settings → Privacy &
   Security → **Open Anyway** works, app launches to the library.
3. Drop in one EPUB and one PDF. Both open and paginate.

If the app won't launch at all after Open Anyway → launch blocker, stop here.

## 1. Anthropic API key (5 min)

1. Settings → AI Providers → Anthropic → paste a real API key (`sk-ant-…`).
2. Expected: key accepted, model list populates, no key visible in
   `~/Library/Preferences` or app logs (spot-check with `defaults read` — it
   must only be in Keychain Access under the app's item).
3. Open a book → select a sentence → Ask → ask "what does this passage mean?"
4. Expected: streamed answer with source citations. Watch for: instant 401
   (wrong header shape), hang (SSE parse), or missing citations.
5. Highlight 3 passages → Compose article. Expected: streamed Markdown draft.

## 2. OpenAI API key (3 min)

Repeat step 1 with an OpenAI key (`sk-…`). Same expectations.

## 3. Sign in with ChatGPT — now DISABLED for launch

The production-readiness audit found this flow structurally unlikely to work
(the borrowed Codex-client token is sent as a Bearer to
`api.openai.com/v1/chat/completions`, and no token-refresh path is wired up),
so the "Sign in with subscription" button is **hidden as of the launch branch**
(`SettingsModel.oauthConfig(for:)` returns `nil` for `.openAI`). Verify the
button is absent from the OpenAI card; API keys + local models are the launch
story.

To test the flow later, return `.openAI` from `oauthConfig(for:)` and check
three points in order: browser reaches a real login page (not
`invalid_client`), the loopback redirect lands and the app flips to signed-in,
and a question in a book actually streams an answer (a Codex-scoped token may
be rejected by the API even after a "successful" sign-in). Before re-enabling
permanently, also note the borrowed client ID is the same ToS category the
project rejected for Anthropic (`Sources/ReadrKit/Auth/OAuthClient.swift:34`)
— it needs a properly registered client and refresh wiring
(`OAuthClient.refresh` currently has no call sites).

## 4. Local / Ollama (3 min)

1. `ollama serve` + `ollama pull llama3.2` (or any pulled model).
2. Settings → Local → connect, pick the model.
3. Turn OFF Wi-Fi. Ask a question in a book.
4. Expected: streamed answer with Wi-Fi off (the zero-egress claim in the
   README, verified live).

## 5. Relaunch persistence (new fix — verify it)

The launch branch fixes the active provider not surviving relaunch. After
step 1: quit Readr fully (⌘Q) and reopen it. Open a book and Ask — the answer
must stream without revisiting Settings. Also confirm the saved key made its
provider active *immediately* after Save in step 1 (no manual model-picker
touch needed).

## Outcome matrix

| Result | Launch posture |
| --- | --- |
| 1, 2, 4, 5 pass | Launch. Listing says: API keys + local (OAuth already hidden). |
| 1 or 2 fail | Launch blocker — the headline feature doesn't work. Debug before launching. |
| 4 fails | Remove "fully offline" claims from listing before launch. |
| 5 fails | Launch blocker — first-run users will think Ask is broken. |
