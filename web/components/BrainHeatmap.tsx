"use client";
import { useEffect, useState } from "react";
import { brainPngUrl } from "@/lib/api";

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
  const [pngOk, setPngOk] = useState<boolean | null>(null);
  useEffect(() => {
    if (!resultId) return setPngOk(false);
    // HEAD would be cleaner, but the endpoint streams files — fetch and
    // inspect status.
    fetch(brainPngUrl(resultId), { method: "GET" })
      .then((r) => setPngOk(r.ok))
      .catch(() => setPngOk(false));
  }, [resultId]);

  if (resultId && pngOk) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={brainPngUrl(resultId)}
        alt="fsaverage5 cortex rendering"
        className="w-full rounded bg-bg"
      />
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
