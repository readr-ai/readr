# Authentication & LLM Access

Readr connects to an LLM in one of **three** ways. All three sit behind the
`LLMProvider` protocol, so the rest of the app never knows which is active.

| Mode | What the user does | Where credentials live | Network |
|------|--------------------|------------------------|---------|
| **Sign in (OAuth)** | "Sign in with ChatGPT" / "Sign in with Claude" in a browser | Tokens in **Keychain** | provider API |
| **Bring your own key** | Pastes an Anthropic / OpenAI / OpenRouter key | API key in **Keychain** | provider API |
| **Local** | Picks a local model (MLX / llama.cpp / Ollama) | none | **none (on-device)** |

## OAuth design (modeled on Muesli)

[Muesli](https://github.com/Muesli-HQ/muesli) — a native macOS app — implements
"sign in with your existing ChatGPT subscription" via **browser-based OAuth 2.0
with PKCE**, storing tokens locally with owner-only permissions and a full unit
suite around the OAuth logic. Zed, opencode, and OpenAI's own Codex CLI use the
same shape. We mirror it.

**Flow (authorization code + PKCE, S256):**

```
1. App generates code_verifier + code_challenge (S256).
2. App starts a loopback HTTP server on 127.0.0.1:<port>.
3. App opens the system browser to the provider's /authorize endpoint
   (client_id, redirect_uri=http://127.0.0.1:<port>/callback, code_challenge, scope).
4. User logs into their existing ChatGPT / Claude account and consents.
5. Provider redirects to the loopback with ?code=...
6. App exchanges code + code_verifier at the /token endpoint → access + refresh tokens.
7. Tokens stored in the Keychain; refreshed automatically before expiry.
```

**Known endpoints (to verify at build time, may change):**

- **OpenAI / ChatGPT** — authorize `https://auth.openai.com/oauth/authorize`,
  token `https://auth.openai.com/oauth/token`, public Codex client id
  `app_EMoamEEZ73f0CkXaXp7hrann`, loopback callback (Codex CLI uses
  `127.0.0.1:1455`). ([ref](https://developers.openai.com/apps-sdk/build/auth),
  [Zed PR](https://github.com/zed-industries/zed/pull/56811),
  [querymt/openai-auth](https://github.com/querymt/openai-auth))
- **Anthropic / Claude** — subscription OAuth is **not supported** in Readr.
  Anthropic's Consumer Terms prohibit using Free/Pro/Max OAuth tokens in any
  third-party product/tool/service, so we deliberately do **not** offer a
  "sign in with Claude" button — connect Anthropic with an **API key** instead.
  ([Claude Code auth](https://code.claude.com/docs/en/authentication),
  [ToS discussion](https://github.com/AndyMik90/Aperant/issues/1871))

> ⚠️ **ToS caveat — call this out to users.** Driving a third-party app with a
> *consumer subscription's* OAuth client is a gray area under provider terms,
> even though several OSS tools do it. Readr therefore makes **BYO API key the
> default, fully-supported path**, and offers subscription OAuth as a clearly
> labeled opt-in ("use your ChatGPT/Claude subscription — may be subject to the
> provider's terms"). Local mode needs no account at all.

## Security requirements

- Secrets **only** in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`), never
  in `UserDefaults`, plists, or logs.
- PKCE `code_verifier` kept in memory only; `state` param checked on callback.
- The loopback server binds `127.0.0.1`, accepts exactly one request, then closes.
- Local mode must make **zero** network calls — enforced by a test that fails if
  the local path touches the network layer.
- Refresh tokens rotated; on refresh failure the user is prompted to re-auth.

## Protocol surface

```
AuthProvider           // performs a sign-in, returns Credentials
  ├─ OpenAIOAuthProvider
  ├─ AnthropicOAuthProvider
  └─ APIKeyProvider    // trivial: wraps a pasted key

CredentialStore        // Keychain-backed get/set/delete + refresh
```

`LLMProvider` implementations take a `CredentialStore` and never see the raw
sign-in flow.
