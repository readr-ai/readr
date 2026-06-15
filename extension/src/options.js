// options.js — configure and publish to a DeDi directory.
const $ = (id) => document.getElementById(id);
const send = (msg) => chrome.runtime.sendMessage(msg);

const FIELDS = [
  "issuerName", "baseUrl", "namespaceId", "registryName", "apiKey",
  "createNamespacePath", "createRegistryPath", "saveRecordPath", "lookupPath",
];

// Ensure the extension may reach the configured directory origin. The manifest
// only declares optional host access, so nothing is granted until the user agrees.
async function ensureOrigin(baseUrl) {
  let origin;
  try {
    origin = new URL(baseUrl).origin + "/*";
  } catch {
    show("bad", "That base URL is not valid.");
    return false;
  }
  const granted = await chrome.permissions.request({ origins: [origin] });
  if (!granted) show("bad", "Permission to reach " + origin + " was denied.");
  return granted;
}

async function load() {
  const id = await send({ type: "GET_IDENTITY" });
  if (id?.ok) $("didOut").value = id.did;

  const { config } = await send({ type: "GET_DEDI" });
  for (const f of FIELDS) if (config[f] != null) $(f).value = config[f];
  if (config.published) renderPublished(config.published);
}

function collect() {
  const patch = {};
  for (const f of FIELDS) patch[f] = $(f).value.trim();
  return patch;
}

$("saveBtn").addEventListener("click", async () => {
  await send({ type: "SET_DEDI", patch: collect() });
  show("ok", "Settings saved.");
});

$("createNsBtn").addEventListener("click", async () => {
  const patch = collect();
  if (!patch.baseUrl || !patch.namespaceId) return show("bad", "Enter the base URL and a namespace name first.");
  if (!patch.apiKey) return show("bad", "A DeDi API key is required to create a namespace.");
  await send({ type: "SET_DEDI", patch });
  if (!(await ensureOrigin(patch.baseUrl))) return;

  show("busy", "Creating namespace…");
  const res = await send({ type: "CREATE_DEDI_NAMESPACE" });
  if (!res?.ok) return show("bad", "✕ " + res.error);
  if (res.namespaceId) $("namespaceId").value = res.namespaceId;
  show("ok", `✓ Namespace ready: ${res.namespaceId}. Now publish your public key.`);
});

$("publishBtn").addEventListener("click", async () => {
  const patch = collect();
  if (!patch.baseUrl || !patch.namespaceId || !patch.registryName) {
    return show("bad", "Fill in the base URL, namespace, and registry first.");
  }
  if (!patch.apiKey) return show("bad", "A DeDi API key is required to publish.");
  await send({ type: "SET_DEDI", patch });
  if (!(await ensureOrigin(patch.baseUrl))) return;

  show("busy", "Creating the key registry (if needed) and publishing…");
  const res = await send({ type: "PUBLISH_DEDI" });
  if (!res?.ok) return show("bad", "✕ " + res.error);

  show("ok", "✓ Public key published. New credentials will point verifiers to this record.");
  renderPublished(res.published);
});

function renderPublished(p) {
  $("publishedBox").hidden = false;
  const dl = $("publishedSummary");
  dl.innerHTML = "";
  for (const [k, v] of Object.entries({
    Record: p.recordName,
    "Lookup URL": p.lookupUrl,
    Published: new Date(p.publishedAt).toLocaleString(),
  })) {
    const dt = document.createElement("dt");
    dt.textContent = k;
    const dd = document.createElement("dd");
    dd.textContent = v;
    dl.append(dt, dd);
  }
  $("openLookup").href = p.lookupUrl;
  $("copyLookup").onclick = async () => {
    await navigator.clipboard.writeText(p.lookupUrl);
    $("copyLookup").textContent = "Copied!";
    setTimeout(() => ($("copyLookup").textContent = "Copy lookup URL"), 1200);
  };
}

function show(kind, text) {
  const el = $("status");
  el.className = "status " + kind;
  el.textContent = text;
  el.hidden = false;
}

load();
