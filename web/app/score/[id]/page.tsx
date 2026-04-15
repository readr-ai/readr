"use client";
import { use, useEffect, useState } from "react";
import Link from "next/link";
import { getResult, ScoreResponse } from "@/lib/api";
import EngagementTimeline from "@/components/EngagementTimeline";
import ROIBars from "@/components/ROIBars";
import BrainHeatmap from "@/components/BrainHeatmap";
import ScoreDial from "@/components/ScoreDial";
import AddToTrainingSet from "@/components/AddToTrainingSet";

export default function ResultPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const [data, setData] = useState<ScoreResponse | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    getResult(id).then(setData).catch((e) => setErr(String(e)));
  }, [id]);

  if (err)
    return (
      <div className="card text-bad font-mono text-sm whitespace-pre-wrap">{err}</div>
    );
  if (!data) return <div className="text-muted">Loading result…</div>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <Link href="/" className="text-muted text-sm hover:text-accent">
            ← new prediction
          </Link>
          <h1 className="text-2xl font-semibold mt-1">
            {capital(data.modality)} score
          </h1>
          <div className="text-xs text-muted mt-1">
            TRIBE v2 · {data.backend} · {data.duration_s.toFixed(1)}s ·{" "}
            <span className="kbd">{id}</span>
          </div>
        </div>
        <ScoreDial score={data.score} />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="card">
          <div className="label mb-2">Engagement timeline</div>
          <EngagementTimeline
            timeline={data.engagement_timeline}
            samplingHz={data.sampling_hz}
            deadZones={data.dead_zones}
            hotspots={data.hotspots}
          />
        </div>
        <div className="card">
          <div className="label mb-2">ROI breakdown</div>
          <ROIBars data={data.roi_breakdown} />
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <div className="card lg:col-span-2">
          <div className="label mb-2">Suggested edits</div>
          <ul className="space-y-2">
            {data.suggested_edits.map((e, i) => (
              <li
                key={i}
                className="text-sm flex gap-2 items-start leading-relaxed"
              >
                <span className="text-accent mt-0.5">▸</span>
                <span>{e}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="card">
          <div className="label mb-2">Cortex heatmap</div>
          <BrainHeatmap rois={data.roi_breakdown} resultId={id} />
          <div className="text-[11px] text-muted mt-2">
            fsaverage5 surface · colored by per-vertex peak response (90th
            percentile over time). Falls back to symbolic view if nilearn is
            unavailable.
          </div>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-4 text-sm">
        <Metric label="Hotspots" value={data.hotspots.length.toString()} />
        <Metric label="Dead zones" value={data.dead_zones.length.toString()} />
        <Metric
          label="Duration"
          value={`${data.duration_s.toFixed(1)} s`}
        />
      </div>

      <AddToTrainingSet id={id} modality={data.modality} />
    </div>
  );
}

function capital(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="card">
      <div className="label">{label}</div>
      <div className="mt-1 text-xl font-semibold">{value}</div>
    </div>
  );
}
