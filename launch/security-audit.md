# Readr — Pre-Launch Security & Privacy Audit

Date: 2026-07-08 · Scope: `Sources/ReadrKit`, `App/`, `Tests/`, CI/release
workflows, `Package.swift`/`project.yml`. Method: source review against the
marketing claims ("no telemetry", "keys live only in the Keychain", "local mode
is proven zero-egress by tests").

**Bottom line:** No credential-leak or remote-code-execution defect was found.
The privacy posture is *substantially* real — but two of the three headline
claims are only *partially* backed by the tests that are said to prove them, and
that gap is the most likely thing to get called out publicly. One robustness
issue (a hostile EPUB can OOM-crash the app) is worth fixing before a Product
Hunt crowd starts feeding it random files.

Severity legend: Critical = exploitable now, data loss/leak or RCE · High =
serious, likely to be hit · Medium = real but bounded/needs local access ·
Low = hardening.

---

## Critical

None found.

---

## High

### H-1 — "Zero-egress / no telemetry is proven by tests" is over-stated; the tests are near-tautological
**Claim under test:** README.md:45–46 "no telemetry; local mode is proven
zero-egress by tests." Settings UI repeats it (ProviderSettingsView.swift:35).

**Evidence of the gap:**
- `Telemetry.isEnabled` is a hard-coded `false` constant
  (Telemetry.swift:15). The "proof" is `XCTAssertFalse(Telemetry.isEnabled)`
  (PrivacyAuditTests.swift:52–54) — i.e. `assertFalse(false)`. It asserts the
  literal, not that any code path is inhibited. It would still pass if the app
  shipped a full analytics SDK, because nothing consults `Telemetry.isEnabled`
  anywhere (no reads outside the test).
- `testLocalProviderOnlyContactsLoopback` (PrivacyAuditTests.swift:69–94)
  constructs `LocalLLMProvider(http: sentinel)` with the **default** `baseURL`
  and asserts the sentinel only saw `127.0.0.1`. But `baseURL` is a public,
  overridable init parameter (LocalLLMProvider.swift:16). The test pins the
  default; it does not prove the shipping app can never point local mode at a
  remote host. (In practice `DefaultProviderFactory.make` never passes a custom
  `baseURL` — DefaultProviderFactory.swift:26–30 — so the *app* is loopback-only
  today; the *test* just doesn't guarantee it.)
- No test asserts the absence of `URLSession`/egress across `App/`.

**Adversarial reading:** The strongest HN/PH comment writes itself — "their
'zero-egress proven by tests' is `XCTAssertFalse(false)`." The underlying code
*is* clean (I found no analytics, update-check, or phone-home anywhere — grep for
analytics/Sentry/Firebase/Sparkle/telemetry across `App/` + `Sources/` returns
only UI copy and the `Telemetry` enum itself), so this is a **claim-integrity**
problem, not an egress defect.

**Minimal fix:** (a) Soften the wording to "no telemetry code ships" (provable by
inspection) OR make it real: route any future opt-in through `Telemetry.isEnabled`
and add a test that greps the built product / asserts no `URLSession` symbol in
the on-device modules. (b) Make the local-egress claim structural: mark
`LocalLLMProvider.baseURL` non-overridable in production, or add a guard that
rejects a non-loopback host, and assert *that* in the test.

### H-2 — Malicious EPUB decompression bomb: unbounded in-memory extraction → OOM crash (DoS)
A user importing an attacker-supplied `.epub` (the entire threat model of a
reader) can crash the app with no size ceiling anywhere in the pipeline.

**Evidence:**
- `ZipEPUBContainer.data(at:)` extracts a whole zip entry into a growing
  in-memory `Data` with no cap (EPUBFileParser.swift:19–26).
- `EPUBBookParser.parse` reads **every** spine document fully into a `String`
  (EPUBBookParser.swift:29–33) and then joins the entire book into one
  `fullText` (EPUBBookParser.swift:57). Cover + inline images are likewise read
  whole (EPUBBookParser.swift:103; AppModel.swift:396–400).
- ZIPFoundation performs no ratio/size limiting by default.

**Exploit:** Ship a 50 KB `.epub` whose spine entry inflates to multiple GB
(classic zip bomb), or thousands of spine items. `data(at:)` allocates until the
process is killed. Import is user-initiated but "open this book" is the app's
core action.

**Minimal fix:** Enforce a per-entry uncompressed cap and a cumulative budget in
`ZipEPUBContainer.data(at:)` (stream `extract` into a counter, throw
`BookParserError.corrupted` past the limit), plus a spine-count ceiling in
`EPUBBookParser`.

---

## Medium

### M-1 — Loopback OAuth server listens on all interfaces, not just 127.0.0.1
`NWListener(using: .tcp, on: nwPort)` (LoopbackHTTPServer.swift:31) is created
with no `requiredLocalEndpoint`/interface restriction, so Network.framework binds
the callback port (1455) on **all** interfaces (0.0.0.0/::), not loopback only.
During the OAuth window any host on the same LAN can reach the port.

**Impact / bound:** Non-callback paths get a 404 (LoopbackHTTPServer.swift:97–100)
and — critically — PKCE means an intercepted `code` is useless without the
`code_verifier`, which never leaves the process (verifier is generated in
`OAuthCoordinator.signIn`, OAuthCoordinator.swift:17, and only sent on the token
exchange, OAuthClient.swift:120). So this is exposure/robustness, not a working
code-theft. Still, a public server socket that should be loopback-only is a bad
look and a real attack surface.

**Minimal fix:** Set `let params = NWParameters.tcp;
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port:
nwPort)` and listen with `params`. Also validate the `Host` header is loopback.

### M-2 — Unbounded request-line buffer in the loopback server
`readRequestLine` accumulates bytes until it sees `\r\n`, with no size cap
(LoopbackHTTPServer.swift:60–82). A local/LAN client (see M-1) that opens the
port and never sends a CRLF makes `buffer` grow without limit → memory DoS during
the auth window.

**Minimal fix:** Abort the connection once `buffer` exceeds a few KB without a
complete request line.

### M-3 — Keychain items are backup/sync-eligible (`AfterFirstUnlock`, not `…ThisDeviceOnly`)
`KeychainCredentialStore.save` uses
`kSecAttrAccessibleAfterFirstUnlock` (KeychainCredentialStore.swift:35). Without
the `…ThisDeviceOnly` variant, the item is eligible for inclusion in encrypted
device backups and can be restored onto a *different* device. This directly
softens the "keys live only in the Keychain / stay on this device" framing
(README.md:46, ProviderSettingsView.swift:39–41): a copied backup carries the API
keys and OAuth tokens off the original device.

**Minimal fix:** Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (and, on
macOS, consider `kSecUseDataProtectionKeychain: true` for consistent, non-synced
storage). `kSecAttrSynchronizable` is already unset (good).

---

## Low

### L-1 — XXE is safe only by default, not asserted
OPF and `META-INF/container.xml` are parsed with `XMLParser`
(EPUBBookParser.swift:151, 172). `XMLParser.shouldResolveExternalEntities`
defaults to `false`, so external-entity/DTD XXE is **not** exploitable — but the
code relies on the default rather than setting it explicitly, and there is no
test pinning it. A future refactor that flips it would silently open XXE.
**Fix:** set `parser.shouldResolveExternalEntities = false` explicitly at both
call sites and add a fixture test with an external entity that asserts no
resolution. (`XHTMLTextExtractor` is regex-based, not an XML parser, so it is not
an XXE vector — XHTMLTextExtractor.swift:79–101.)

### L-2 — PKCE RNG falls back to non-CSPRNG if `SecRandomCopyBytes` fails
`PKCE.randomBytes` falls through to `UInt8.random(in:)` if SecRandom fails
(PKCE.swift:79–84). On iOS/macOS SecRandom never fails, so this is theoretical,
but the fallback would degrade verifier/state entropy silently.
**Fix:** treat SecRandom failure as fatal rather than falling back.

### L-3 — Token-exchange failure surfaces the raw provider response body to the UI
On a non-2xx token response, the entire response body is wrapped into
`AuthError.tokenExchangeFailed(body)` (OAuthClient.swift:167–168) and shown in
the Settings error alert (SettingsModel.swift:57). Not a credential leak (it is
the *server's* error body, not the request), but it echoes untrusted upstream
text verbatim into the UI. **Fix:** log/display a bounded, sanitized message.

### L-4 — Supply chain: floating minimum version + Package.resolved is git-ignored
`project.yml:18–20` pins ZIPFoundation `from: "0.9.19"` (a *minimum*, allowing any
`0.9.x`+ up to the next major), and `.gitignore` excludes `Package.resolved`, so
the app's dependency graph is not locked in-repo — CI/release resolve to whatever
is newest in range, so a compromised future 0.9.x could be pulled unreviewed.
ReadrKit itself has **zero** third-party dependencies (Package.swift:13–17) —
good. ZIPFoundation (`weichsel/ZIPFoundation`) is maintained. **Fix:** pin an
exact version (or a revision) for the sole app dependency and commit
`Package.resolved` for the app target.

### L-5 — Hostile PDF handling relies on PDFKit
`PDFKitBookParser` opens untrusted PDFs via `PDFDocument(url:)`, returning `nil`
on failure (PDFKitBookParser.swift:15) and rejecting locked docs
(PDFKitBookParser.swift:18). Parser robustness is delegated to the system
framework; acceptable, no app-side mitigation needed beyond the existing nil
guard.

---

## Things verified *clean* (counters to the brief's suspicions)

- **`FileLibraryStore` does not touch secrets.** Its `State` persists only
  `books`, `positions`, `highlights`, `bookmarks`, `pdfHighlights`, `bookStates`
  (FileLibraryStore.swift:8–17) — no `Credentials` type is reachable from `Book`
  or any stored model. Credentials are a separate `enum` persisted **only** by
  `KeychainCredentialStore` (Auth.swift:3–14, KeychainCredentialStore.swift:24–43).
- **No secrets in logs.** No `print`/`os_log`/`NSLog`/`Logger` calls exist
  anywhere in `Sources/` or `App/` (grep returns nothing). Request headers
  carrying `x-api-key`/`Authorization` (AnthropicProvider.swift:73–78,
  OpenAIProvider.swift:73–76) are never logged.
- **No secrets in `UserDefaults`/`@AppStorage`.** Every `@AppStorage`/`UserDefaults`
  key is UI state (`readingTheme`, `readerLayout`, `lastHighlightColor`, …);
  none holds credentials (grep across `App/`).
- **PKCE S256 is correct.** `codeChallenge = base64url(SHA256(verifier))`
  unpadded (PKCE.swift:35–50); verified against the RFC 7636 Appendix B vector in
  tests (PKCETests.swift:10–13). `state` is 32 random bytes
  (PKCE.swift:53–55) and validated on callback (OAuthClient.swift:95–97).
- **Token exchange is HTTPS-only.** Both token endpoints are `https://`
  (OAuthClient.swift:28, 41); only the loopback *redirect* is `http://127.0.0.1`
  (RFC 8252-compliant).
- **Loopback callback validates the path.** Only `url.path == expectedPath`
  completes the flow; everything else 404s (LoopbackHTTPServer.swift:97–100), and
  absolute-URL request targets fail the `redirectBase + target` parse
  (LoopbackHTTPServer.swift:92–96).
- **Zip-slip is not reachable.** The container only reads entry bytes into memory
  (`ZipEPUBContainer.data(at:)`, EPUBFileParser.swift:19–26); nothing writes zip
  entry contents to attacker-controlled filesystem paths. `EPUBBookParser.resolve`
  normalizes `..`/`.` (EPUBBookParser.swift:132–146) but even a traversing path
  only selects which in-archive entry to read, not a filesystem location.
- **On-device retrieval is structurally offline.** `HybridRAGIndex`,
  `Chunker`, and `LocalEmbeddingProvider` take no `HTTPClient`
  (LocalEmbeddingProvider.swift:9–19, PrivacyAuditTests.swift:56–67); embeddings
  are a deterministic FNV-1a hashing trick with no network
  (LocalEmbeddingProvider.swift:23–77).

---

## Privacy claims verification

| # | Claim (source) | Verdict | Evidence |
|---|---|---|---|
| 1 | "no telemetry" (README.md:45) | **True (by inspection); test is a tautology** | No analytics/crash/phone-home code anywhere (`App/`+`Sources/` grep). But the enforcing test is `XCTAssertFalse(Telemetry.isEnabled)` over a hard-coded `false` (Telemetry.swift:15, PrivacyAuditTests.swift:52–54) — proves the constant, not the behavior. See H-1. |
| 2 | "keys live only in the Keychain" (README.md:46) | **Partial** | Only `KeychainCredentialStore` persists secrets (KeychainCredentialStore.swift:24–43); none in UserDefaults/plists/logs/`FileLibraryStore` (verified). BUT items use `kSecAttrAccessibleAfterFirstUnlock` (KeychainCredentialStore.swift:35) — backup/restore-eligible to another device, so not strictly "only on this device." See M-3. |
| 3 | "local mode is proven zero-egress by tests" (README.md:45) | **Partial** | Retrieval pipeline takes no `HTTPClient` and cannot egress (PrivacyAuditTests.swift:56–67). Local LLM test asserts loopback-only — but only for the **default** `baseURL`; `baseURL` is an overridable public param (LocalLLMProvider.swift:16) with no test/guard forbidding a remote value. The telemetry half of "zero-egress" is the tautology in H-1. Shipping app never sets a remote `baseURL` (DefaultProviderFactory.swift:26–30), so *behavior* is zero-egress; the *test* under-proves it. |
| 4 | "no accounts" (ProviderSettingsView.swift:35) | **True** | No account system; only per-provider API keys/OAuth tokens in the Keychain. |
| 5 | "questions leave [the device] only when you choose a cloud model" (ProviderSettingsView.swift:35) | **True** | Only `AnthropicProvider`/`OpenAIProvider` hit remote HTTPS endpoints (AnthropicProvider.swift:12, OpenAIProvider.swift:11); Local/embeddings/retrieval have no non-loopback network path. |
| 6 | "API keys and tokens are stored in your device Keychain" (ProviderSettingsView.swift:39) | **True (with M-3 caveat)** | Persisted solely via `KeychainCredentialStore`; see caveat on device-only scoping. |
| 7 | "Secrets only in Keychain, `kSecAttrAccessibleAfterFirstUnlock`" (docs/AUTH.md:57) | **True to the doc; doc itself under-hardened** | Code matches the doc exactly (KeychainCredentialStore.swift:35). The recommendation itself should be `…ThisDeviceOnly` (M-3). |

---

## Recommended pre-launch actions (ordered)

1. **H-1:** Reword the two README claims to what the code actually guarantees, or
   make the tests real (grep-for-egress + non-loopback guard). Highest reputational risk.
2. **H-2:** Add EPUB size/entry caps (zip-bomb defense).
3. **M-3:** Switch Keychain accessibility to `…ThisDeviceOnly`.
4. **M-1/M-2:** Bind the loopback server to 127.0.0.1 and cap the request buffer.
5. **L-1/L-4:** Set `shouldResolveExternalEntities = false` explicitly; pin the
   ZIPFoundation version and commit `Package.resolved` for the app.
