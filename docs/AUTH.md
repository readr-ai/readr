# Authentication & LLM Access

Readr connects to an LLM in one of **three** ways. All three sit behind the
`LLMProvider` protocol, so the rest of the app never knows which is active.

| Mode | What the user does | Where credentials live | Network |
|------|--------------------|------------------------|---------|
| **Sign in (OAuth)** | "Sign in with ChatGPT" / "Sign in with OpenRouter" in a browser | Tokens/key in **Keychain** | provider API |
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

**Implemented flows (endpoint shapes mirror working third-party
implementations; items marked NEEDS-VERIFICATION are confirmed on the first
live sign-in):**

- **ChatGPT (subscription)** — kind `.chatGPT`. Authorize
  `https://auth.openai.com/oauth/authorize`, token
  `https://auth.openai.com/oauth/token`, public Codex client id
  `app_EMoamEEZ73f0CkXaXp7hrann`, callback `http://localhost:1455/auth/callback`,
  plus the simplified-flow params (`codex_cli_simplified_flow=true`,
  `id_token_add_organizations=true`, `originator`). **The tokens do NOT work
  against api.openai.com** — `ChatGPTSubscriptionProvider` streams from
  `https://chatgpt.com/backend-api/wham/responses` (Responses-API body) with a
  `ChatGPT-Account-Id` header parsed from the access token's JWT claims
  (`chatgpt_account_id`, top-level or under `https://api.openai.com/auth`).
  Tokens auto-refresh via `ProviderManager.refreshCredentialsIfNeeded` (60s
  early skew, deduped in-flight, rejection → re-auth prompt). Verified against
  [Muesli](https://github.com/Muesli-HQ/muesli)'s working client; model slugs
  NEEDS-VERIFICATION.
- **OpenRouter** — kind `.openRouter`, the officially documented third-party
  flow. Browser `https://openrouter.ai/auth?callback_url=…&code_challenge=…&
  code_challenge_method=S256` (no client registration), callback
  `http://127.0.0.1:1456/callback`, then `POST
  https://openrouter.ai/api/v1/auth/keys` `{code, code_verifier,
  code_challenge_method}` returns **an API key** — stored as
  `Credentials.apiKey`, so the normal key plumbing (validation via `GET
  /api/v1/key`, disconnect) applies and there is nothing to refresh. Chat runs
  through `OpenAIProvider` with the `.openRouter` endpoints preset
  (OpenAI-compatible wire format).
- **OpenAI (API key)** — kind `.openAI` stays key-only by design; the
  subscription path is the separate `.chatGPT` kind so catalogs, credentials,
  and persisted selections never mix.
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
OAuthProviderConfig    // per-provider endpoints + FlowStyle
  ├─ .openAI           // authorizationCodeToken (ChatGPT sign-in)
  ├─ .openRouter       // pkceKeyExchange → Credentials.apiKey
  └─ config(for:)      // Kind → config; single truth for buttons + refresher

OAuthClient            // authorize URL, callback, exchange, refresh
OAuthCoordinator       // browser + loopback orchestration (App/)
CredentialStore        // Keychain-backed get/set/delete
ProviderManager.TokenRefresher  // injected refresh closure (composition root)
```

`LLMProvider` implementations receive `Credentials` values and never see the
raw sign-in flow.
