# Readr Privacy Policy

_Last updated: July 2026. Also available at
<https://readr-ai.github.io/readr/privacy.html>._

Readr is a local-first ebook reader. This policy is short because the app is
built not to collect anything.

## What Readr collects

**Nothing.** Readr has no analytics, telemetry, or crash-reporting code, no
accounts, and no server of its own. The app never phones home. (Readr is open
source under the MIT license — you can verify this in the code at
<https://github.com/readr-ai/readr>.)

## Where your data lives

- **Books, highlights, notes, and reading positions** are stored only on your
  device, in the app's own storage. Deleting the app deletes them.
- **API keys** you paste in are stored only in the system **Keychain** on your
  device — never in preference files, logs, or any server.

## When data leaves your device

Only when you explicitly connect a cloud AI provider and ask it something:

- If you add an **Anthropic** or **OpenAI** API key and ask the book a
  question (or compose an article), the relevant book text, your highlights,
  and your question are sent **directly to that provider** using your own key.
  Readr does not proxy, inspect, or retain this traffic. The provider's own
  privacy policy governs that data
  ([Anthropic](https://www.anthropic.com/legal/privacy),
  [OpenAI](https://openai.com/policies/privacy-policy)).
- In **local model** mode (Ollama on your Mac), requests go only to the local
  Ollama server on your machine. Readr's test suite asserts this path makes
  zero network calls.
- If no AI provider is connected, Readr makes no network requests at all.

## Your choices

- Use Readr with no AI provider: everything works offline except
  ask-the-book and article composition.
- Disconnect a provider at any time in **Settings → AI Providers**; this
  removes the key from the Keychain.

## Children's privacy

Readr collects no data from anyone, including children.

## Changes

If this policy ever changes, the update will appear in this file's git
history and on the website. Since the app collects nothing, changes would
only ever describe new user-initiated features.

## Contact

Questions: open an issue at <https://github.com/readr-ai/readr/issues>.
