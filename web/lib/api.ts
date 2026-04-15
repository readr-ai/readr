export const API = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";

export type ScoreResponse = {
  id: string;
  modality: "text" | "image" | "ui" | "video";
  score: number;
  roi_breakdown: Record<string, number>;
  engagement_timeline: number[];
  dead_zones: [number, number][];
  hotspots: [number, number][];
  suggested_edits: string[];
  duration_s: number;
  sampling_hz: number;
  backend: string;
  input_preview?: string | null;
  meta?: Record<string, unknown>;
};

export function brainPngUrl(id: string) {
  return `${API}/score/${id}/brain.png`;
}

export async function addLabel(id: string, views: number, label: string) {
  const r = await fetch(`${API}/labeled/add`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id, views, label }),
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json() as Promise<{ ok: boolean; written_to: string }>;
}

export async function labeledStats(): Promise<Record<string, number>> {
  const r = await fetch(`${API}/labeled/stats`, { cache: "no-store" });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function scoreText(text: string): Promise<ScoreResponse> {
  const r = await fetch(`${API}/score/text`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function scoreFile(
  modality: "image" | "ui" | "video",
  file: File,
): Promise<ScoreResponse> {
  const fd = new FormData();
  fd.append("file", file);
  const r = await fetch(`${API}/score/${modality}`, { method: "POST", body: fd });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function getResult(id: string): Promise<ScoreResponse> {
  const r = await fetch(`${API}/score/${id}`);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export type Experiment = {
  t: number;
  experiment: number;
  hypothesis?: string;
  spearman?: number;
  mae?: number;
  precision_at_topk?: number;
  n?: number;
  kept: boolean;
  best_so_far?: number;
  error?: string;
};

export async function getHistory(): Promise<Experiment[]> {
  const r = await fetch(`${API}/autoresearch/history`, { cache: "no-store" });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export async function getCurrentScoring(): Promise<{
  score_py: string;
  rubric: string;
}> {
  const r = await fetch(`${API}/autoresearch/current`, { cache: "no-store" });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

export function streamAutoresearch(
  budget: number,
  offline: boolean,
  onExperiment: (e: Experiment) => void,
  onDone: () => void,
  onError: (msg: string) => void,
) {
  const url = `${API}/autoresearch/run?budget=${budget}&offline=${offline}`;
  const es = new EventSource(url);
  es.addEventListener("experiment", (ev: MessageEvent) => {
    try {
      onExperiment(JSON.parse(ev.data) as Experiment);
    } catch (e) {
      onError(String(e));
    }
  });
  es.addEventListener("done", () => {
    onDone();
    es.close();
  });
  es.onerror = () => {
    onError("SSE connection error");
    es.close();
  };
  return () => es.close();
}
