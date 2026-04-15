"use client";
import { useState } from "react";
import { addLabel } from "@/lib/api";

export default function AddToTrainingSet({
  id,
  modality,
}: {
  id: string;
  modality: string;
}) {
  const [views, setViews] = useState("");
  const [label, setLabel] = useState("");
  const [status, setStatus] = useState<
    { state: "idle" } | { state: "submitting" } | { state: "ok"; to: string } | { state: "err"; msg: string }
  >({ state: "idle" });

  async function submit() {
    const n = Number(views.replace(/[,_ ]/g, ""));
    if (!Number.isFinite(n) || n < 0) {
      setStatus({ state: "err", msg: "views must be a non-negative number" });
      return;
    }
    setStatus({ state: "submitting" });
    try {
      const r = await addLabel(id, n, label);
      setStatus({ state: "ok", to: r.written_to });
    } catch (e) {
      setStatus({ state: "err", msg: String(e) });
    }
  }

  return (
    <div className="card space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <div className="label">Add to training set</div>
          <div className="text-xs text-muted mt-0.5">
            Teach the autoresearch agent — give this {modality} its actual view count.
          </div>
        </div>
      </div>
      <div className="flex gap-2">
        <input
          type="text"
          inputMode="numeric"
          placeholder="Actual views (e.g. 221100)"
          className="flex-1 bg-panel2 border border-border rounded px-3 py-2 text-sm focus:outline-none focus:border-accent2"
          value={views}
          onChange={(e) => setViews(e.target.value)}
        />
        <input
          type="text"
          placeholder="Optional note"
          className="flex-1 bg-panel2 border border-border rounded px-3 py-2 text-sm focus:outline-none focus:border-accent2"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
        />
        <button
          className="btn-primary"
          onClick={submit}
          disabled={status.state === "submitting" || !views.trim()}
        >
          {status.state === "submitting" ? "Adding…" : "Add"}
        </button>
      </div>
      {status.state === "ok" && (
        <div className="text-ok text-xs">Added to {status.to}.</div>
      )}
      {status.state === "err" && (
        <div className="text-bad text-xs font-mono whitespace-pre-wrap">{status.msg}</div>
      )}
    </div>
  );
}
