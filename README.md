# DocSigner — Verifiable Credentials for Google Docs

A Chrome (Manifest V3) extension that turns the **content of the Google Doc
you're viewing** into a **W3C Verifiable Credential**, secured as a **JWT
(VC-JWT)** and signed with a key that **never leaves your browser**.

> _“Whatever is on this Google Doc, signed by me, provably unmodified.”_

- ✍️ **One click** to issue a credential for the current document
- 🔑 **Local keys** — an ES256 (P-256) keypair generated with WebCrypto and
  stored in `chrome.storage`; nothing is sent to any server
- 🆔 **`did:jwk` issuer** — your public key _is_ your identity, embedded in
  every credential, so verification needs no network and no registry
- 📜 **W3C VC 2.0** data model, serialized as a JWS (`ES256`)
- 🔎 **Built-in verifier** that works fully offline

---

## How it works

```
 Google Doc ──export?format=txt──▶ plain text ──SHA-256──▶ digest
                                                    │
   did:jwk (your public key) ◀─derives─ local ES256 keypair
                                                    │
                          W3C VC ── signed (ES256) ──▶  VC-JWT
                                                    │
              anyone ──paste──▶ Verify page ──checks signature──▶ ✓ / ✕
```

1. **Read.** The extension asks Google Docs for the plain-text export of the
   open document (`/document/d/<id>/export?format=txt`) using your existing
   logged-in session — so it works for any doc you can already open, with **no
   OAuth and no Google Cloud project**.
2. **Hash.** It computes the `SHA-256` of that text. This digest is the
   integrity anchor: change one character and the hash changes.
3. **Build.** It wraps the title, URL, digest, and timestamp in a W3C
   Verifiable Credential (Data Model 2.0).
4. **Sign.** It signs the credential into a compact **VC-JWT** with your local
   `ES256` key. Your issuer identity is a `did:jwk` derived from your public key.
5. **Verify.** Anyone can paste the VC-JWT into the Verify tab (or the
   standalone verifier page). It extracts the public key from the credential's
   own `did:jwk`, checks the signature, and — if the content was embedded —
   re-hashes it to confirm it matches.

### What “verifiable” means here

The signature proves two things to anyone holding the VC-JWT:

- **Authenticity** — it was signed by the holder of *that specific* private key
  (identified by the `did:jwk` issuer).
- **Integrity** — neither the credential nor the document digest was altered
  after signing; any change invalidates the signature.

By default this is a **self-asserted** credential: the `did:jwk` is an anonymous
key, not a real-world identity vouched for by a third party. To bind it to a
named organisation, publish your public key to a **directory** — see below.

---

## Directory hosting with DeDi (optional)

[DeDi](https://dedi.global) (Decentralized Directory) is a public lookup layer —
"DNS for trust" — organised as **namespace → registry → record**. An organisation
publishes things like public keys, membership lists, and revocation lists as
records under its namespace, and anyone can resolve them with a single API call.
[OpenCred](https://opencred.global) builds verifiable-credential issuance on top
of this idea.

This extension can publish **your issuer public key** as a DeDi record, which
upgrades the trust story:

- **Without DeDi:** a verifier learns the credential was signed by *some* key
  (`did:jwk`) — internally consistent, but anonymous.
- **With DeDi:** the credential carries a `directory` hint pointing at your
  record. A verifier resolves it, confirms the published key **equals** the key
  that signed the credential, and now knows it was issued by *your named
  organisation* — not just an anonymous key.

This is wired to the **DeDi v2 API** (`api/openapi.yaml` from the
[decentralized-directory-protocol](https://github.com/LF-Decentralized-Trust-labs/decentralized-directory-protocol)),
whose model is **namespace → registry → record**:

| Action | DeDi v2 endpoint | Auth |
| --- | --- | --- |
| Create namespace | `POST /dedi/create-namespace` | Bearer |
| Create registry | `POST /dedi/{namespace}/create-registry` | Bearer |
| Publish key record | `POST /dedi/{namespace}/{registry}/save-record-as-draft?publish=true` | Bearer |
| Resolve record | `GET /dedi/lookup/{namespace}/{registry}/{record}` | **public** |

### Set it up

1. Open the extension's **options** page (right-click the icon → *Options*, or
   **Identity → Manage DeDi hosting…**).
2. Enter your **issuer name**, **base URL** (default `https://api.dedi.global`;
   staging is `https://staging-api.dedi.global`), **namespace**, **registry**,
   and your **API key** — create one in your DeDi account (`/dedi/api-keys`); it
   is sent as `Authorization: Bearer …`. Endpoint templates are editable under
   *Advanced*.
3. If you don't already have a namespace, click **Create namespace**.
4. Click **Publish public key to DeDi**. You'll be asked to grant access to the
   directory's origin (the manifest requests it only optionally). The extension
   auto-creates the key registry (with a JSON Schema for the key fields), then
   publishes a record whose `details` carry your `did:jwk`, `ES256` public JWK,
   `kid`, and issuer name, and stores the resolvable **lookup URL**.

From then on, every credential you sign embeds the directory hint. In the
**Verify** page, *Verify issuer via DeDi directory* calls the **public** lookup
endpoint and confirms the hosted key matches the signing key.

> The published record holds only your **public** key and issuer name — never the
> private key, which stays in your browser. Lookups need no API key.

Docs: [DeDi](https://dedi-global.gitbook.io/docs) ·
[OpenCred](https://opencred.gitbook.io/docs)

---

## Install (load unpacked)

1. Open `chrome://extensions` in Chrome (or any Chromium browser).
2. Toggle **Developer mode** (top-right).
3. Click **Load unpacked** and select the **`extension/`** folder of this repo.
4. Open any Google Doc. Click the extension icon (or the floating **🔏 Sign**
   button) and hit **Sign this document**.

---

## Using it

- **Sign tab** — signs the current doc. Optionally tick *Embed the document
  text* to make the credential self-contained (a verifier can then confirm the
  content offline, without re-opening the doc). Copy or download the `.vc.jwt`.
- **Identity tab** — view/copy your issuer **DID** and **public key (JWK)**,
  reset to a fresh identity, or open **DeDi hosting** settings (see below).
- **Verify tab** — paste any VC-JWT to check it. A full-page verifier also lives
  at `chrome-extension://<extension-id>/src/verify.html`.

---

## Project layout

```
extension/
  manifest.json          MV3 manifest
  src/
    crypto.js            Zero-dependency WebCrypto primitives (ES256, JWS, did:jwk)
    background.js        Service worker: key custody, doc export, VC issuance, DeDi
    content.js           Floating "Sign" button injected into Google Docs
    popup.html/.css/.js  Toolbar popup: Sign / Identity / Verify
    options.html/.js     DeDi directory hosting settings + publish
    verify.html/.js      Standalone verifier (offline + DeDi issuer resolution)
  icons/                 16/48/128 px action icons
  test/crypto.test.mjs   End-to-end sign → verify → tamper test
```

## Run the tests

```bash
cd extension
node test/crypto.test.mjs
```

Covers base64url, `did:jwk` round-tripping, a known SHA-256 vector, a full
sign→verify cycle, embedded-content re-hashing, and rejection of both tampered
credentials and impostor signatures.

---

## Design notes & trade-offs

- **Why the export endpoint instead of scraping the page?** Modern Google Docs
  renders text to a `<canvas>`, so the DOM no longer contains the document text.
  The export endpoint returns the authoritative plain text and respects your
  existing permissions and cookies.
- **Why `ES256` and not Ed25519?** `ES256` is universally supported by WebCrypto
  today and is the most widely interoperable JWT algorithm. WebCrypto's ECDSA
  output is already the raw `r‖s` form JOSE expects, so no DER juggling.
- **Why `did:jwk`?** It needs no resolver, registry, or network — the key
  travels inside the credential, which keeps verification fully offline.

## Possible next steps

- **DeDi revocation/status registry** so issued credentials can be revoked.
- **`did:web`** issuer as an alternative directory binding to a domain you own.
- **Selective disclosure** (SD-JWT) to reveal only chosen fields.
- **Sign uploaded files** (PDF/DOCX) by hashing raw bytes, not just Docs.
- **Anchor** the digest to a timestamping authority or ledger for proof-of-time.

## Security

Your private key is stored unencrypted in `chrome.storage.local`, readable by
anyone with access to your browser profile. Treat it like a browser-resident
key, not an HSM. For higher assurance, move signing to a backend or cloud KMS.
