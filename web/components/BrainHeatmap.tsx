"use client";
import { useEffect, useState } from "react";
import clsx from "clsx";
import { brainPngUrl } from "@/lib/api";

type View = "lateral" | "medial";
type Roi = null | "visual" | "attention" | "language" | "emotion" | "reward";

const ROIS: { id: Roi; label: string }[] = [
  { id: null, label: "All" },
  { id: "reward", label: "Reward" },
  { id: "emotion", label: "Emotion" },
  { id: "attention", label: "Attention" },
  { id: "language", label: "Language" },
  { id: "visual", label: "Visual" },
];

const ROI_PATCHES: {
  roi: string;
  color: string;
  d: string;
}[] = [
  { roi: "visual", color: "#22c55e", d: "M175,115 q20,0 22,25 q-2,22 -22,22 q-20,0 -22,-22 q2,-25 22,-25 Z" },
  { roi: "attention", color: "#7c5cff", d: "M125,70 q25,-5 42,20 q0,22 -26,27 q-22,2 -28,-22 q2,-20 12,-25 Z" },
  { roi: "language", color: "#22d3ee", d: "M75,125 q10,-22 55,-18 q8,20 -18,30 q-30,8 -40,-6 q-2,-4 3,-6 Z" },
  { roi: "emotion", color: "#f59e0b", d: "M95,105 q20,-8 35,6 q4,14 -14,20 q-22,4 -24,-12 q-2,-10 3,-14 Z" },
  { roi: "reward", color: "#ff4d88", d: "M48,98 q20,-18 50,-8 q4,18 -20,25 q-28,6 -32,-8 q0,-5 2,-9 Z" },
];

type Props = {
  rois: Record<string, number>;
  resultId?: string;
};

export default function BrainHeatmap({ rois, resultId }: Props) {
  const [view, setView] = useState<View>("lateral");
  const [roi, setRoi] = useState<Roi>(null);
  const [pngOk, setPngOk] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!resultId) return setPngOk(false);
    setLoading(true);
    fetch(brainPngUrl(resultId, { view, roi }), { method: "GET" })
      .then((r) => setPngOk(r.ok))
      .catch(() => setPngOk(false))
      .finally(() => setLoading(false));
  }, [resultId, view, roi]);

  if (resultId && pngOk) {
    return (
      <div>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={brainPngUrl(resultId, { view, roi })}
          alt={`fsaverage5 cortex, ${view} view${roi ? ", " + roi + " only" : ""}`}
          className={clsx("w-full rounded bg-bg transition-opacity", loading && "opacity-60")}
        />
        <div className="mt-3 flex flex-wrap gap-1.5">
          {(["lateral", "medial"] as View[]).map((v) => (
            <button
              key={v}
              onClick={() => setView(v)}
              className={clsx(
                "px-2 py-1 text-[11px] rounded border transition",
                view === v
                  ? "bg-accent2 text-white border-accent2"
                  : "border-border text-muted hover:text-text",
              )}
            >
              {v}
            </button>
          ))}
          <div className="w-px bg-border mx-1" />
          {ROIS.map((r) => (
            <button
              key={r.id ?? "all"}
              onClick={() => setRoi(r.id)}
              className={clsx(
                "px-2 py-1 text-[11px] rounded border transition",
                roi === r.id
                  ? "bg-accent text-white border-accent"
                  : "border-border text-muted hover:text-text",
              )}
            >
              {r.label}
            </button>
          ))}
        </div>
      </div>
    );
  }

  return (
    <svg viewBox="0 0 220 180" className="w-full h-auto">
      <defs>
        <radialGradient id="skull" cx="50%" cy="50%" r="60%">
          <stop offset="0%" stopColor="#20202a" />
          <stop offset="100%" stopColor="#111118" />
        </radialGradient>
      </defs>
      <path
        d="M35,95 q0,-50 70,-55 q75,-5 85,50 q5,55 -55,65 q-70,12 -90,-12 q-15,-20 -10,-48 Z"
        fill="url(#skull)"
        stroke="#24242f"
        strokeWidth="2"
      />
      <path
        d="M160,145 q8,15 0,25 q-10,5 -15,-4 q-2,-9 4,-17 z"
        fill="#111118"
        stroke="#24242f"
      />
      {ROI_PATCHES.map((p) => {
        const v = Math.max(0, Math.min(1, rois[p.roi] ?? 0));
        return (
          <path
            key={p.roi}
            d={p.d}
            fill={p.color}
            fillOpacity={0.15 + 0.75 * v}
            stroke={p.color}
            strokeOpacity={0.8}
            strokeWidth={1}
          >
            <title>{`${p.roi}: ${v.toFixed(2)}`}</title>
          </path>
        );
      })}
    </svg>
  );
}
