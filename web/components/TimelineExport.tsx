"use client";
import { useState } from "react";
import { timelineUrl } from "@/lib/api";

export default function TimelineExport({
  id,
  modality,
  hotspots,
  deadZones,
}: {
  id: string;
  modality: string;
  hotspots: number;
  deadZones: number;
}) {
  const [fps, setFps] = useState(30);
  // Only makes sense for time-based modalities.
  if (modality !== "video" && modality !== "ui") return null;
  return (
    <div className="card">
      <div className="label">Export timeline markers</div>
      <div className="text-xs text-muted mt-1">
        {hotspots} hotspot{hotspots === 1 ? "" : "s"} + {deadZones} dead zone
        {deadZones === 1 ? "" : "s"} → import into Final Cut / Premiere / Resolve.
      </div>
      <div className="flex items-center gap-3 mt-3">
        <label className="text-xs text-muted flex items-center gap-1">
          fps
          <input
            type="number"
            className="w-14 bg-panel2 border border-border rounded px-2 py-1 text-xs"
            value={fps}
            min={12}
            max={120}
            onChange={(e) => setFps(Math.max(12, Math.min(120, +e.target.value)))}
          />
        </label>
        <a
          className="btn-ghost text-xs"
          href={timelineUrl(id, "fcpxml", fps)}
          download={`cbt_${id}.fcpxml`}
        >
          ↓ FCPXML
        </a>
        <a
          className="btn-ghost text-xs"
          href={timelineUrl(id, "csv", fps)}
          download={`cbt_${id}.csv`}
        >
          ↓ CSV markers
        </a>
      </div>
    </div>
  );
}
