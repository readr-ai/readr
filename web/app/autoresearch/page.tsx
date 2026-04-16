"use client";
import { useEffect, useState } from "react";
import {
  Experiment,
  getCurrentScoring,
  getHistory,
  streamAutoresearch,
} from "@/lib/api";
import SpearmanChart from "@/components/SpearmanChart";
import CsvImport from "@/components/CsvImport";

export default function Autoresearch() {
  const [history, setHistory] = useState<Experiment[]>([]);
  const [scorePy, setScorePy] = useState("");
  const [rubric, setRubric] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [budget, setBudget] = useState(5);
  const [offline, setOffline] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  async function refresh() {
    const [h, c] = await Promise.all([getHistory(), getCurrentScoring()]);
    setHistory(h);
    setScorePy(c.score_py);
    setRubric(c.rubric);
  }

  useEffect(() => {
    refresh().catch((e) => setErr(String(e)));
  }, []);

  function start() {
    setErr(null);
    setStreaming(true);
    const close = streamAutoresearch(
      budget,
      offline,
      (e) => {
        setHistory((h) => {
          // If this is a live phase update for an experiment we already
          // have, replace the last row rather than append a new one.
          if (e.phase && e.phase !== "done" && e.phase !== "error") {
            const last = h[h.length - 1];
            if (last && last.experiment === e.experiment && last.phase !== "done") {
              return [...h.slice(0, -1), e];
            }
            return [...h, e];
          }
          // Terminal event: replace any placeholder for this experiment.
          const last = h[h.length - 1];
          if (last && last.experiment === e.experiment && last.phase !== "done") {
            return [...h.slice(0, -1), e];
          }
          return [...h, e];
        });
      },
      () => {
        setStreaming(false);
        refresh();
      },
      (m) => {
        setErr(m);
        setStreaming(false);
      },
    );
    return close;
  }

  const best = history
    .filter((e) => e.kept && typeof e.spearman === "number")
    .reduce((m, e) => Math.max(m, e.spearman!), -1);

  const current = streaming ? history[history.length - 1] : null;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Autoresearch</h1>
          <p className="text-muted text-sm mt-1 max-w-2xl">
            Claude edits <span className="kbd">api/scoring/score.py</span>,
            evaluates against held-out labels, and the runner keeps or reverts
            each change. Mirrors Karpathy&apos;s loop — <span className="kbd">train.py</span>{" "}
            becomes <span className="kbd">score.py</span>, metric is Spearman
            correlation with actual views.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <input
            type="number"
            min={1}
            max={200}
            value={budget}
            onChange={(e) => setBudget(Math.max(1, +e.target.value))}
            className="w-16 bg-panel2 border border-border rounded px-2 py-1 text-sm"
          />
          <label className="text-xs text-muted flex items-center gap-1">
            <input
              type="checkbox"
              checked={offline}
              onChange={(e) => setOffline(e.target.checked)}
            />
            offline
          </label>
          <button className="btn-primary" disabled={streaming} onClick={start}>
            {streaming ? "Running…" : "Start run"}
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <Stat label="Experiments" value={history.filter((h) => h.phase === "done" || h.phase === "error" || h.phase === undefined).length.toString()} />
        <Stat
          label="Best Spearman"
          value={best < 0 ? "—" : best.toFixed(3)}
        />
        <Stat
          label="Last hypothesis"
          value={[...history].reverse().find((h) => h.hypothesis)?.hypothesis ?? "—"}
          small
        />
      </div>

      {current && (
        <LiveCard exp={current} />
      )}

      <CsvImport onDone={refresh} />

      <div className="card">
        <div className="label mb-2">Spearman over experiments</div>
        <SpearmanChart data={history} />
      </div>

      <div className="card overflow-x-auto">
        <div className="label mb-2">Experiment log</div>
        <table className="w-full text-sm">
          <thead className="text-muted text-xs">
            <tr>
              <th className="text-left py-2">#</th>
              <th className="text-left">Hypothesis</th>
              <th className="text-right">Spearman</th>
              <th className="text-right">MAE</th>
              <th className="text-right">P@top10%</th>
              <th className="text-right">Kept</th>
            </tr>
          </thead>
          <tbody>
            {history
              .slice()
              .reverse()
              .map((e, i) => (
                <tr key={i} className="border-t border-border">
                  <td className="py-2 font-mono text-xs">{e.experiment}</td>
                  <td className="pr-4">
                    {e.error ? (
                      <span className="text-bad">error: {e.error}</span>
                    ) : (
                      e.hypothesis
                    )}
                  </td>
                  <td className="text-right font-mono">
                    {e.spearman?.toFixed(3) ?? "—"}
                  </td>
                  <td className="text-right font-mono">
                    {e.mae?.toFixed(2) ?? "—"}
                  </td>
                  <td className="text-right font-mono">
                    {e.precision_at_topk?.toFixed(2) ?? "—"}
                  </td>
                  <td className="text-right">
                    {e.kept ? (
                      <span className="text-ok">kept</span>
                    ) : (
                      <span className="text-muted">revert</span>
                    )}
                  </td>
                </tr>
              ))}
          </tbody>
        </table>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="card">
          <div className="label mb-2">Current score.py</div>
          <pre className="text-[11px] leading-relaxed overflow-auto max-h-96 bg-panel2 p-3 rounded">
            {scorePy}
          </pre>
        </div>
        <div className="card">
          <div className="label mb-2">Rubric</div>
          <pre className="text-[11px] leading-relaxed overflow-auto max-h-96 bg-panel2 p-3 rounded whitespace-pre-wrap">
            {rubric}
          </pre>
        </div>
      </div>

      {err && (
        <div className="card text-bad text-sm font-mono whitespace-pre-wrap">
          {err}
        </div>
      )}
    </div>
  );
}

function Stat({
  label,
  value,
  small,
}: {
  label: string;
  value: string;
  small?: boolean;
}) {
  return (
    <div className="card">
      <div className="label">{label}</div>
      <div className={small ? "mt-1 text-sm" : "mt-1 text-2xl font-semibold"}>
        {value}
      </div>
    </div>
  );
}

function LiveCard({ exp }: { exp: Experiment }) {
  const phase = exp.phase ?? "done";
  const dotColor =
    phase === "thinking"
      ? "bg-warn"
      : phase === "proposed"
      ? "bg-accent2"
      : phase === "error"
      ? "bg-bad"
      : "bg-ok";
  return (
    <div className="card flex items-center gap-4">
      <div className="relative flex items-center justify-center">
        <div className={`w-3 h-3 rounded-full ${dotColor}`} />
        <div className={`absolute w-3 h-3 rounded-full ${dotColor} opacity-40 animate-ping`} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-xs text-muted">
          Experiment {exp.experiment} · {phase}
        </div>
        <div className="text-sm truncate">
          {phase === "thinking" && "Agent is drafting the next edit…"}
          {phase === "proposed" && (exp.hypothesis ?? "Proposed an edit, running eval…")}
          {phase === "done" && (exp.hypothesis ?? "Eval complete")}
          {phase === "error" && (exp.error ?? "Error")}
        </div>
      </div>
      {phase === "done" && typeof exp.spearman === "number" && (
        <div className="text-xs text-muted font-mono">
          ρ={exp.spearman.toFixed(3)} · {exp.kept ? "kept" : "revert"}
        </div>
      )}
    </div>
  );
}
