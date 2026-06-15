// background.js — the service worker.
//
// Responsibilities:
//   1. Own the signing keypair (generate once, persist in chrome.storage.local).
//   2. Fetch the current Google Doc's text via Docs' own export endpoint,
//      using the user's existing session cookies (no OAuth required).
//   3. Build a W3C Verifiable Credential and sign it into a VC-JWT.

import {
  generateKeyPairJwk,
  importPrivateKey,
  didJwkFromPublicJwk,
  toPublicJwk,
  signCompactJws,
  sha256Hex,
  b64uEncode,
} from "./crypto.js";

const KEY_STORAGE = "docsigner.key.v1";
const DEDI_STORAGE = "docsigner.dedi.v1";

// DeDi (Decentralized Directory — https://dedi.global) lets an organisation
// publish public keys, membership lists, etc. as records under a namespace, so
// they can be resolved and trusted by anyone. We host the issuer's public key
// there so a credential's anonymous did:jwk can be bound to a named directory
// entry. Paths follow the DeDi v2 API (api/openapi.yaml) but stay configurable.
const DEDI_DEFAULTS = {
  enabled: false,
  baseUrl: "https://api.dedi.global", // staging: https://staging-api.dedi.global
  apiKey: "", // a DeDi API key / bearer token with write access
  namespaceId: "",
  registryName: "docsigner-keys",
  issuerName: "",
  // DeDi v2 endpoint templates. {namespace}/{registryName}/{recordName} are filled in.
  createNamespacePath: "/dedi/create-namespace",
  createRegistryPath: "/dedi/{namespace}/create-registry",
  saveRecordPath: "/dedi/{namespace}/{registryName}/save-record-as-draft",
  lookupPath: "/dedi/lookup/{namespace}/{registryName}/{recordName}",
  published: null, // { recordName, lookupUrl, publishedAt, namespaceId }
};

// JSON Schema for the registry that holds signing keys. The record `details`
// must conform to this (DeDi validates server-side).
const KEY_REGISTRY_SCHEMA = {
  $schema: "http://json-schema.org/draft-07/schema#",
  type: "object",
  required: ["did", "alg", "publicKeyJwk"],
  properties: {
    did: { type: "string" },
    name: { type: "string" },
    type: { type: "string" },
    alg: { type: "string" },
    kid: { type: "string" },
    publicKeyJwk: { type: "object" },
  },
};

// ---------------------------------------------------------------------------
// Key lifecycle
// ---------------------------------------------------------------------------

async function getStoredKey() {
  const out = await chrome.storage.local.get(KEY_STORAGE);
  return out[KEY_STORAGE] || null;
}

async function getOrCreateKey() {
  let stored = await getStoredKey();
  if (!stored) {
    const { privateJwk, publicJwk } = await generateKeyPairJwk();
    stored = {
      privateJwk,
      publicJwk: toPublicJwk(publicJwk),
      did: didJwkFromPublicJwk(publicJwk),
      createdAt: new Date().toISOString(),
    };
    await chrome.storage.local.set({ [KEY_STORAGE]: stored });
  }
  return stored;
}

async function resetKey() {
  await chrome.storage.local.remove(KEY_STORAGE);
  return getOrCreateKey();
}

// ---------------------------------------------------------------------------
// DeDi directory hosting
// ---------------------------------------------------------------------------

async function getDediConfig() {
  const out = await chrome.storage.local.get(DEDI_STORAGE);
  return { ...DEDI_DEFAULTS, ...(out[DEDI_STORAGE] || {}) };
}

async function setDediConfig(patch) {
  const next = { ...(await getDediConfig()), ...patch };
  await chrome.storage.local.set({ [DEDI_STORAGE]: next });
  return next;
}

function fillTemplate(tpl, vars) {
  return tpl.replace(/\{(\w+)\}/g, (_, k) => encodeURIComponent(vars[k] ?? ""));
}

function dediHeaders(cfg) {
  const h = { "Content-Type": "application/json", Accept: "application/json" };
  if (cfg.apiKey) h["Authorization"] = "Bearer " + cfg.apiKey;
  return h;
}

// POST helper that surfaces DeDi's JSON `message` on failure.
async function dediPost(url, cfg, body) {
  const res = await fetch(url, { method: "POST", headers: dediHeaders(cfg), body: JSON.stringify(body) });
  let payload = null;
  const text = await res.text();
  try { payload = JSON.parse(text); } catch { /* non-JSON error body */ }
  return { res, payload, text };
}

function dediMessage(payload, text, fallback) {
  return (payload && (payload.message || payload.error)) || text?.slice(0, 200) || fallback;
}

// Create the namespace that will hold the issuer's key (DeDi v2:
// POST /dedi/create-namespace). Returns the server-assigned namespace_id.
async function createDediNamespace() {
  const cfg = await getDediConfig();
  if (!cfg.namespaceId) throw new Error("Enter a namespace name first.");
  const base = cfg.baseUrl.replace(/\/+$/, "");
  const { res, payload, text } = await dediPost(base + cfg.createNamespacePath, cfg, {
    name: cfg.namespaceId,
    description: cfg.issuerName ? `${cfg.issuerName} — DocSigner keys` : "DocSigner signing keys",
    version_count: 1,
  });
  if (!res.ok && res.status !== 409) {
    throw new Error(`Could not create namespace (HTTP ${res.status}). ${dediMessage(payload, text)}`);
  }
  // Adopt the canonical namespace_id if the server returned one.
  const nsId = payload?.data?.namespace_id;
  if (nsId && nsId !== cfg.namespaceId) await setDediConfig({ namespaceId: nsId });
  return { namespaceId: nsId || cfg.namespaceId, created: res.ok };
}

// Idempotently ensure the key registry exists (409 = already there).
async function ensureDediRegistry(cfg) {
  const base = cfg.baseUrl.replace(/\/+$/, "");
  const url = base + fillTemplate(cfg.createRegistryPath, { namespace: cfg.namespaceId });
  const { res, payload, text } = await dediPost(url, cfg, {
    registry_name: cfg.registryName,
    description: "Public keys used to sign document credentials",
    schema: KEY_REGISTRY_SCHEMA,
  });
  if (!res.ok && res.status !== 409) {
    throw new Error(`Could not create registry (HTTP ${res.status}). ${dediMessage(payload, text)}`);
  }
}

// Publish the issuer's public key as a DeDi record and remember its lookup URL.
// DeDi v2: POST /dedi/{ns}/{registry}/save-record-as-draft?publish=true.
async function publishKeyToDedi() {
  const cfg = await getDediConfig();
  const key = await getOrCreateKey();
  if (!cfg.baseUrl || !cfg.namespaceId || !cfg.registryName) {
    throw new Error("Set the DeDi base URL, namespace, and registry first.");
  }
  if (!cfg.apiKey) throw new Error("A DeDi API key is required to publish.");

  await ensureDediRegistry(cfg);

  const base = cfg.baseUrl.replace(/\/+$/, "");
  const recordName = cfg.published?.recordName || "key-" + key.did.slice(-12);
  const vars = { namespace: cfg.namespaceId, registryName: cfg.registryName, recordName };
  const lookupUrl = base + fillTemplate(cfg.lookupPath, vars);

  // The record's `details` must conform to KEY_REGISTRY_SCHEMA.
  const details = { did: key.did, type: "JsonWebKey", alg: "ES256", kid: key.did + "#0", publicKeyJwk: key.publicJwk };
  if (cfg.issuerName) details.name = cfg.issuerName;

  const url = base + fillTemplate(cfg.saveRecordPath, vars) + "?publish=true";
  const { res, payload, text } = await dediPost(url, cfg, {
    record_name: recordName,
    description: `Document-signing public key for ${cfg.issuerName || "issuer"}`,
    details,
    meta: {},
  });
  // 409 = a record with this name already holds our key; treat as success.
  if (!res.ok && res.status !== 409) {
    throw new Error(`DeDi rejected the record (HTTP ${res.status}). ${dediMessage(payload, text)}`);
  }

  const published = { recordName, lookupUrl, namespaceId: cfg.namespaceId, publishedAt: new Date().toISOString() };
  await setDediConfig({ enabled: true, published });
  return published;
}

// Resolve a public record (no auth — lookup is public in DeDi v2) and return
// its key. Run from the worker so granted host permission applies (no CORS).
async function resolveDedi(lookupUrl) {
  const res = await fetch(lookupUrl, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`Directory lookup failed (HTTP ${res.status}).`);
  const json = await res.json();
  const details = json?.data?.details || json?.details; // DeDi v2 returns { message, data: Record }
  const publicKeyJwk = details?.publicKeyJwk;
  if (!publicKeyJwk) throw new Error("No public key found in the directory record.");
  return {
    publicKeyJwk,
    did: details.did,
    name: details.name,
    state: json?.data?.state,
    digest: json?.data?.digest,
    raw: json,
  };
}

// ---------------------------------------------------------------------------
// Reading a Google Doc
// ---------------------------------------------------------------------------

export function docIdFromUrl(url) {
  const m = /\/document\/d\/([a-zA-Z0-9_-]+)/.exec(url || "");
  return m ? m[1] : null;
}

// Pull the plain-text export of a doc. Cookies are attached automatically
// because docs.google.com is in host_permissions, so this works for any doc
// the signed-in user can already open.
async function fetchDocText(docId) {
  const url = `https://docs.google.com/document/d/${docId}/export?format=txt`;
  const res = await fetch(url, { credentials: "include" });
  if (!res.ok) {
    throw new Error(
      `Could not read the document (HTTP ${res.status}). Make sure you're signed in and have access.`
    );
  }
  const ct = res.headers.get("content-type") || "";
  const body = await res.text();
  // A redirect to the login/consent page comes back as HTML, not text/plain.
  if (!ct.includes("text/plain") && /<html/i.test(body)) {
    throw new Error("Got a sign-in page instead of the document. Open the doc and sign in, then retry.");
  }
  return body;
}

// ---------------------------------------------------------------------------
// Credential construction
// ---------------------------------------------------------------------------

async function buildAndSignCredential({ docId, docUrl, title, text, embedContent }) {
  const key = await getOrCreateKey();
  const privateKey = await importPrivateKey(key.privateJwk);
  const dedi = await getDediConfig();
  const hosted = dedi.enabled && dedi.published ? dedi : null;

  const hashHex = await sha256Hex(text);
  const now = new Date();
  const nowIso = now.toISOString();
  const nowSec = Math.floor(now.getTime() / 1000);
  const credentialId = "urn:uuid:" + crypto.randomUUID();
  const subjectId = `https://docs.google.com/document/d/${docId}`;

  const credentialSubject = {
    id: subjectId,
    type: "DigitalDocument",
    name: title || "Untitled document",
    url: docUrl || subjectId,
    encodingFormat: "text/plain",
    contentLength: text.length,
    // The integrity anchor: re-export the doc, hash the text, compare.
    digestSRI: "sha256-" + hashHex,
    sha256: hashHex,
  };
  if (embedContent) {
    // Self-contained verification: the exact signed bytes travel with the VC.
    credentialSubject.encodedContent = "base64url," + b64uEncode(text);
  }

  // The issuer is the did:jwk; when a directory record exists we name the issuer
  // and attach a resolution hint so verifiers can bind the key to that record.
  const issuer = hosted
    ? {
        id: key.did,
        name: hosted.issuerName || undefined,
        directory: {
          type: "DeDiDirectory",
          lookupUrl: hosted.published.lookupUrl,
          namespace: hosted.namespaceId,
          registry: hosted.registryName,
          record: hosted.published.recordName,
        },
      }
    : key.did;

  // W3C Verifiable Credentials Data Model 2.0 payload.
  const vc = {
    "@context": ["https://www.w3.org/ns/credentials/v2"],
    type: ["VerifiableCredential", "VerifiableDocumentCredential"],
    issuer,
    validFrom: nowIso,
    credentialSubject,
  };

  // JOSE/JWT envelope (VC secured with JOSE — "Securing VCs using JOSE & COSE").
  const header = {
    alg: "ES256",
    typ: "vc+jwt",
    kid: hosted ? hosted.published.lookupUrl : key.did + "#0",
  };
  const payload = {
    iss: key.did,
    sub: subjectId,
    nbf: nowSec,
    iat: nowSec,
    jti: credentialId,
    vc,
  };

  const jwt = await signCompactJws(header, payload, privateKey);
  return { jwt, vc, header, payload, hashHex, signedAt: nowIso, did: key.did };
}

// ---------------------------------------------------------------------------
// Message routing
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    try {
      switch (msg?.type) {
        case "GET_IDENTITY": {
          const key = await getOrCreateKey();
          sendResponse({
            ok: true,
            did: key.did,
            publicJwk: key.publicJwk,
            createdAt: key.createdAt,
          });
          break;
        }
        case "RESET_KEY": {
          const key = await resetKey();
          sendResponse({ ok: true, did: key.did, publicJwk: key.publicJwk, createdAt: key.createdAt });
          break;
        }
        case "GET_DEDI": {
          sendResponse({ ok: true, config: await getDediConfig() });
          break;
        }
        case "SET_DEDI": {
          sendResponse({ ok: true, config: await setDediConfig(msg.patch || {}) });
          break;
        }
        case "CREATE_DEDI_NAMESPACE": {
          const result = await createDediNamespace();
          sendResponse({ ok: true, ...result });
          break;
        }
        case "PUBLISH_DEDI": {
          const published = await publishKeyToDedi();
          sendResponse({ ok: true, published });
          break;
        }
        case "RESOLVE_DEDI": {
          const result = await resolveDedi(msg.lookupUrl);
          sendResponse({ ok: true, ...result });
          break;
        }
        case "SIGN_DOC": {
          const docId = msg.docId || docIdFromUrl(msg.docUrl);
          if (!docId) throw new Error("That tab is not a Google Doc.");
          const text = await fetchDocText(docId);
          if (!text.trim()) throw new Error("The document appears to be empty.");
          const result = await buildAndSignCredential({
            docId,
            docUrl: msg.docUrl,
            title: msg.title,
            text,
            embedContent: !!msg.embedContent,
          });
          sendResponse({ ok: true, ...result });
          break;
        }
        default:
          sendResponse({ ok: false, error: "Unknown message type: " + msg?.type });
      }
    } catch (err) {
      sendResponse({ ok: false, error: err?.message || String(err) });
    }
  })();
  return true; // keep the message channel open for the async response
});
