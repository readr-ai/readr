"use client";
import { useState } from "react";
import { importLabeledCsv, refitCalibration } from "@/lib/api";

type Status =
  | { state: "idle" }
  | { state: "uploading" }
  | { state: "refitting"; added: number }
  | { state: "ok"; added: number; skipped: number; warnings: string[] }
  | { state: "err"; msg: string };

export default function CsvImport({ onDone }: { onDone?: () => void }) {
  const [status, setStatus] = useState<Status>({ state: "idle" });

  async function onFile(f: File | null) {
    if (!f) return;
    setStatus({ state: "uploading" });
    try {
      const r = await importLabeledCsv(f);
      setStatus({ state: "refitting", added: r.added });
      await refitCalibration().catch(() => null);
      setStatus({
        state: "ok",
        added: r.added,
        skipped: r.skipped,
        warnings: r.warnings ?? [],
      });
      onDone?.();
    } catch (e) {
      setStatus({ state: "err", msg: String(e) });
    }
  }

  return (
    <div className="card">
      <div className="label">Bulk import labels (CSV)</div>
      <div className="text-xs text-muted mt-1">
        X analytics export or any CSV with <span className="kbd">content</span>
        {" + "}
        <span className="kbd">views</span> columns. Each row becomes a new
        training example. Calibration refits automatically.
      </div>
      <label className="mt-3 inline-block border-2 border-dashed border-border rounded-md px-4 py-3 text-sm cursor-pointer hover:border-accent2 transition">
        <input
          type="file"
          accept="text/csv,.csv"
          className="hidden"
          onChange={(e) => onFile(e.target.files?.[0] ?? null)}
        />
        {status.state === "idle" && "Drop CSV"}
        {status.state === "uploading" && "Uploading…"}
        {status.state === "refitting" && `Imported ${status.added} rows, refitting…`}
        {status.state === "ok" && `✓ Added ${status.added} · skipped ${status.skipped}`}
        {status.state === "err" && "Retry"}
      </label>
      {status.state === "ok" && status.warnings.length > 0 && (
        <details className="mt-2 text-xs text-muted">
          <summary className="cursor-pointer">warnings ({status.warnings.length})</summary>
          <ul className="list-disc pl-5 mt-1 space-y-0.5">
            {status.warnings.map((w, i) => (
              <li key={i} className="font-mono">{w}</li>
            ))}
          </ul>
        </details>
      )}
      {status.state === "err" && (
        <div className="text-bad text-xs font-mono mt-2 whitespace-pre-wrap">{status.msg}</div>
      )}
    </div>
  );
}
