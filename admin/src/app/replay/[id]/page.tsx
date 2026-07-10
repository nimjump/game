"use client";
import { useEffect, useState, use, useMemo } from "react";
import Link from "next/link";
import { fetchSession, GAME_URL, type Session } from "@/lib/api";

// ── RLE decoder ──────────────────────────────────────────────────────────────
function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

interface ReplayData {
  ticks: number[];
  deltas: number[];
  totalTicks: number;
  neutralCount: number; rightCount: number; leftCount: number;
  changeCount: number;  rapidChanges: number;
  avgDeltaMs: number;   minDeltaMs: number; maxDeltaMs: number;
  slowChunks: number;   fastChunks: number;
}

function decodeRLE(raw: Uint8Array): ReplayData {
  const ticks: number[] = [], deltas: number[] = [];
  let i = 0;
  while (i < raw.length) {
    const b = raw[i];
    if (b === 0xFF && i + 2 < raw.length) {
      const ms = raw[i + 1] + raw[i + 2] * 256;
      if (ms > 0) deltas.push(ms);
      i += 3; continue;
    }
    const val = b & 0x03, count = Math.max(1, (b >> 2) & 0x3F);
    for (let k = 0; k < count; k++) ticks.push(val);
    i++;
  }
  let neutral = 0, right = 0, left = 0, changes = 0, rapid = 0, lastChange = -99;
  for (let j = 0; j < ticks.length; j++) {
    const v = ticks[j];
    if (v === 0) neutral++; else if (v === 1) right++; else left++;
    if (j > 0 && ticks[j] !== ticks[j - 1]) {
      changes++;
      if (j - lastChange <= 2) rapid++;
      lastChange = j;
    }
  }
  const sum = deltas.reduce((a, b) => a + b, 0);
  return {
    ticks, deltas, totalTicks: ticks.length,
    neutralCount: neutral, rightCount: right, leftCount: left,
    changeCount: changes, rapidChanges: rapid,
    avgDeltaMs: deltas.length ? sum / deltas.length : 0,
    minDeltaMs: deltas.length ? Math.min(...deltas) : 0,
    maxDeltaMs: deltas.length ? Math.max(...deltas) : 0,
    slowChunks: deltas.filter(d => d > 6000).length,
    fastChunks: deltas.filter(d => d < 400).length,
  };
}

// ── Charts ───────────────────────────────────────────────────────────────────
function DeltaChart({ deltas }: { deltas: number[] }) {
  if (!deltas.length) return <div style={{ color: "var(--text-muted)", fontSize: 12 }}>No delta markers</div>;
  const W = 540, H = 72, pad = 4, max = Math.max(...deltas, 2000);
  const bw = Math.max(2, (W - pad * 2) / deltas.length - 1);
  return (
    <svg width="100%" viewBox={`0 0 ${W} ${H}`} style={{ display: "block" }}>
      <line x1={pad} x2={W - pad}
        y1={H - pad - (1000 / max) * (H - pad * 2)}
        y2={H - pad - (1000 / max) * (H - pad * 2)}
        stroke="#58a6ff33" strokeWidth="1" strokeDasharray="4,3" />
      {deltas.map((d, i) => {
        const h = Math.max(2, (d / max) * (H - pad * 2));
        return <rect key={i} x={pad + i * (bw + 1)} y={H - pad - h}
          width={bw} height={h} rx="1"
          fill={d > 6000 ? "#f85149" : d < 400 ? "#f0c04a" : "#3fb950"} />;
      })}
    </svg>
  );
}

function InputHeatmap({ ticks }: { ticks: number[] }) {
  if (!ticks.length) return null;
  const sz = 60, W = 540, H = 16 * 3 + 1 * 4 + 20;
  const chunks = [];
  for (let i = 0; i < ticks.length; i += sz) {
    const sl = ticks.slice(i, i + sz);
    let r = 0, l = 0, n = 0;
    for (const v of sl) { if (v === 1) r++; else if (v === 2) l++; else n++; }
    chunks.push({ r, l, n });
  }
  const cw = Math.max(4, (W - 1) / chunks.length - 1);
  return (
    <svg width="100%" viewBox={`0 0 ${W} ${H}`} style={{ display: "block" }}>
      <text x="0" y="12" fontSize="9" fill="#8b949e">→ Right (blue) · Neutral (gray) · Left (orange) ←</text>
      {chunks.map((c, i) => {
        const x = 1 + i * (cw + 1), t = c.r + c.l + c.n || 1;
        return (
          <g key={i}>
            <rect x={x} y={20}    width={cw} height={16} fill={`rgba(88,166,255,${c.r / t})`} />
            <rect x={x} y={37}    width={cw} height={16} fill={`rgba(139,148,158,${c.n / t})`} />
            <rect x={x} y={54}    width={cw} height={16} fill={`rgba(210,153,34,${c.l / t})`} />
          </g>
        );
      })}
    </svg>
  );
}

function Row({ label, value, sub }: { label: string; value: React.ReactNode; sub?: string }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center",
      padding: "5px 0", borderBottom: "1px solid var(--border)" }}>
      <span style={{ color: "var(--text-muted)", fontSize: 12 }}>{label}</span>
      <span style={{ fontSize: 13, fontWeight: 600 }}>
        {value}
        {sub && <span style={{ color: "var(--text-muted)", fontWeight: 400, marginLeft: 4, fontSize: 11 }}>{sub}</span>}
      </span>
    </div>
  );
}

// ── Page ─────────────────────────────────────────────────────────────────────
export default function ReplayPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [session,  setSession]  = useState<Session | null>(null);
  const [error,    setError]    = useState("");
  const [loading,  setLoading]  = useState(true);
  const [showGame, setShowGame] = useState(false);  // iframe toggle

  useEffect(() => {
    setLoading(true);
    fetchSession(id)
      .then(s => { if (!s) setError("Session not found"); else setSession(s); })
      .catch(e => setError(String(e)))
      .finally(() => setLoading(false));
  }, [id]);

  const replay = useMemo<ReplayData | null>(() => {
    if (!session?.replay_log) return null;
    try { return decodeRLE(b64ToBytes(session.replay_log)); } catch { return null; }
  }, [session]);

  if (loading) return <main style={{ padding: 64, textAlign: "center", color: "var(--text-muted)" }}>Loading…</main>;
  if (error)   return <main style={{ padding: 64, textAlign: "center", color: "var(--red)" }}>{error}</main>;
  if (!session) return null;

  const gameReplayUrl = `${GAME_URL}/?replay=${encodeURIComponent(id)}`;
  const scoreDiff = session.client_score > 0
    ? ((session.server_score - session.client_score) / session.client_score * 100).toFixed(1)
    : "—";
  const scoreOk    = Math.abs(parseFloat(scoreDiff)) <= 5;
  const durationSec = (session.ticks / 60).toFixed(1);
  const rapidRatio  = replay && replay.changeCount > 0
    ? (replay.rapidChanges / replay.changeCount * 100).toFixed(1) : "—";
  const timingOk = replay
    ? replay.slowChunks / Math.max(replay.deltas.length, 1) <= 0.30 &&
      replay.fastChunks / Math.max(replay.deltas.length, 1) <= 0.30
    : true;

  return (
    <main style={{ maxWidth: 1200, margin: "0 auto", padding: "24px 16px" }}>

      {/* ── Header ── */}
      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 20, flexWrap: "wrap" }}>
        <Link href="/" style={{ color: "var(--text-muted)", fontSize: 13 }}>← Back</Link>
        <h1 style={{ fontSize: 18, fontWeight: 700 }}>Replay</h1>
        <span style={{ fontFamily: "monospace", fontSize: 11, color: "var(--text-muted)" }}>
          {session.session_id.slice(0, 16)}…
        </span>
        {session.flagged
          ? <span className="badge badge-red">⚠ {session.reason ?? "flagged"}</span>
          : <span className="badge badge-green">✓ Clean</span>}

        <div style={{ marginLeft: "auto", display: "flex", gap: 8 }}>
          {/* Open in new tab as fallback */}
          <a href={gameReplayUrl} target="_blank" rel="noopener noreferrer"
            className="btn" style={{ textDecoration: "none", fontSize: 12 }}>
            ↗ Open in new tab
          </a>
          {/* In-page game toggle */}
          <button
            className={showGame ? "btn btn-active" : "btn"}
            style={{ fontSize: 13, fontWeight: 600 }}
            onClick={() => setShowGame(v => !v)}
          >
            {showGame ? "⏹ Hide Game" : "▶ Watch Live"}
          </button>
        </div>
      </div>

      {/* ── LIVE GAME IFRAME ── */}
      {showGame && (
        <div style={{
          marginBottom: 20,
          borderRadius: 12,
          overflow: "hidden",
          border: "2px solid var(--blue)",
          boxShadow: "0 0 32px rgba(88,166,255,0.15)",
          position: "relative",
          background: "#000",
        }}>
          {/* Portrait game — max 400px wide, centered */}
          <div style={{ display: "flex", justifyContent: "center", background: "#000", padding: "0" }}>
            <iframe
              src={gameReplayUrl}
              title="NimJump Replay"
              allow="autoplay"
              style={{
                width: "min(400px, 100%)",
                height: "min(711px, 178vw)", /* 9:16 aspect */
                border: "none",
                display: "block",
              }}
            />
          </div>
          <div style={{
            padding: "8px 14px",
            background: "var(--surface)",
            borderTop: "1px solid var(--border)",
            fontSize: 11,
            color: "var(--text-muted)",
            display: "flex",
            gap: 16,
            alignItems: "center",
          }}>
            <span>🎮 Live replay — game running in iframe</span>
            <span>Seed: <b style={{ fontFamily: "monospace" }}>{session.seed}</b></span>
            <span>Char: <b>#{(session.char ?? 0) + 1}</b></span>
            <span>Control: <b>{session.gyro_active ? "🎯 Gyro" : "👆 Tap"}</b></span>
            <a href={gameReplayUrl} target="_blank" rel="noopener noreferrer"
              style={{ marginLeft: "auto", color: "var(--blue)", fontSize: 11 }}>
              Full screen ↗
            </a>
          </div>
        </div>
      )}

      {/* ── ANALYSIS GRID ── */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 300px", gap: 16, alignItems: "start" }}>

        {/* ── Left: charts ── */}
        <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>

          {/* Score comparison */}
          <div className="card" style={{ padding: 16 }}>
            <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
              letterSpacing: "0.06em", marginBottom: 14 }}>Score Comparison</div>
            {[
              { label: "Client score", val: session.client_score, color: "var(--blue)" },
              { label: "Server score", val: session.server_score, color: session.flagged ? "var(--red)" : "var(--green)" },
            ].map(({ label, val, color }) => {
              const max = Math.max(session.client_score, session.server_score, 1);
              return (
                <div key={label} style={{ marginBottom: 10 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, marginBottom: 4 }}>
                    <span style={{ color: "var(--text-muted)" }}>{label}</span>
                    <span style={{ fontWeight: 700, color }}>{val.toLocaleString()}</span>
                  </div>
                  <div style={{ background: "var(--surface2)", borderRadius: 4, height: 8 }}>
                    <div style={{ background: color, borderRadius: 4, height: 8, width: `${(val / max) * 100}%` }} />
                  </div>
                </div>
              );
            })}
            <div style={{ marginTop: 8, display: "flex", gap: 8, alignItems: "center" }}>
              <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Difference:</span>
              <span style={{ fontSize: 12, fontWeight: 700, color: scoreOk ? "var(--green)" : "var(--red)" }}>{scoreDiff}%</span>
              {!scoreOk && <span className="badge badge-red" style={{ fontSize: 10 }}>⚠ Mismatch</span>}
            </div>
          </div>

          {/* Frame timing */}
          <div className="card" style={{ padding: 16 }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
              <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase", letterSpacing: "0.06em" }}>
                Frame Timing (delta markers)
              </div>
              <div style={{ display: "flex", gap: 10, fontSize: 11 }}>
                <span style={{ color: "#3fb950" }}>● Normal</span>
                <span style={{ color: "#f85149" }}>● &gt;6s</span>
                <span style={{ color: "#f0c04a" }}>● &lt;400ms</span>
              </div>
            </div>
            {replay ? (
              <>
                <DeltaChart deltas={replay.deltas} />
                <div style={{ marginTop: 8, display: "flex", gap: 16, fontSize: 11, color: "var(--text-muted)", flexWrap: "wrap" }}>
                  <span>Markers: <b style={{ color: "var(--text)" }}>{replay.deltas.length}</b></span>
                  <span>Avg: <b style={{ color: "var(--text)" }}>{replay.avgDeltaMs.toFixed(0)}ms</b></span>
                  <span>Min: <b>{replay.minDeltaMs}ms</b></span>
                  <span>Max: <b>{replay.maxDeltaMs}ms</b></span>
                  {timingOk
                    ? <span className="badge badge-green" style={{ fontSize: 10 }}>✓ Timing OK</span>
                    : <span className="badge badge-red"   style={{ fontSize: 10 }}>⚠ Timing anomaly</span>}
                </div>
              </>
            ) : <div style={{ color: "var(--text-muted)", fontSize: 12, padding: "12px 0" }}>No log data</div>}
          </div>

          {/* Input heatmap */}
          <div className="card" style={{ padding: 16 }}>
            <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
              letterSpacing: "0.06em", marginBottom: 10 }}>Input Heatmap (per 60-tick chunk)</div>
            {replay ? (
              <>
                <InputHeatmap ticks={replay.ticks} />
                <div style={{ marginTop: 10, display: "flex", gap: 16, fontSize: 11, color: "var(--text-muted)", flexWrap: "wrap" }}>
                  <span>→ Right: <b style={{ color: "#58a6ff" }}>{replay.rightCount.toLocaleString()}</b> ({replay.totalTicks > 0 ? (replay.rightCount / replay.totalTicks * 100).toFixed(1) : 0}%)</span>
                  <span>◉ Neutral: <b>{replay.neutralCount.toLocaleString()}</b> ({replay.totalTicks > 0 ? (replay.neutralCount / replay.totalTicks * 100).toFixed(1) : 0}%)</span>
                  <span>← Left: <b style={{ color: "#d29922" }}>{replay.leftCount.toLocaleString()}</b> ({replay.totalTicks > 0 ? (replay.leftCount / replay.totalTicks * 100).toFixed(1) : 0}%)</span>
                </div>
              </>
            ) : <div style={{ color: "var(--text-muted)", fontSize: 12 }}>No log data</div>}
          </div>

          {/* Input change pattern */}
          {replay && (
            <div className="card" style={{ padding: 16 }}>
              <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
                letterSpacing: "0.06em", marginBottom: 12 }}>Input Change Pattern</div>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
                <Row label="Total direction changes" value={replay.changeCount.toLocaleString()} />
                <Row label="Rapid changes (≤2 ticks)" value={replay.rapidChanges.toLocaleString()} sub={`${rapidRatio}%`} />
                <Row label="Changes per second" value={(replay.changeCount / (replay.totalTicks / 60)).toFixed(2)} />
                <Row label="Bot suspicion (>85% rapid)"
                  value={parseFloat(rapidRatio as string) > 85 ? "⚠ YES" : "✓ No"} />
              </div>
            </div>
          )}
        </div>

        {/* ── Right: session info ── */}
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>

          <div className="card" style={{ padding: 16 }}>
            <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
              letterSpacing: "0.06em", marginBottom: 12 }}>Session</div>
            <Row label="Player"    value={session.player_id ? session.player_id.slice(0, 16) + "…" : "—"} />
            <Row label="Nickname"  value={session.nickname || "—"} />
            <Row label="Seed"      value={<span style={{ fontFamily: "monospace", fontSize: 11 }}>{session.seed}</span>} />
            <Row label="Character" value={`#${(session.char ?? 0) + 1}`} />
            <Row label="Control"   value={session.gyro_active ? "🎯 Gyro" : "👆 Tap"} />
            <Row label="Ticks"     value={session.ticks.toLocaleString()} />
            <Row label="Duration"  value={`${durationSec}s`} sub={`(${(session.ticks / 60 / 60).toFixed(2)}min)`} />
            {replay && <Row label="Log bytes" value={Math.ceil(atob(session.replay_log!).length)} sub="bytes" />}
          </div>

          {replay && (
            <div className="card" style={{ padding: 16 }}>
              <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
                letterSpacing: "0.06em", marginBottom: 12 }}>Timing</div>
              <Row label="Delta markers"    value={replay.deltas.length} sub="(every 60 ticks)" />
              <Row label="Expected"         value="~1000ms" />
              <Row label="Average"          value={`${replay.avgDeltaMs.toFixed(0)}ms`}
                sub={Math.abs(replay.avgDeltaMs - 1000) < 200 ? "✓ normal" : "⚠ off"} />
              <Row label="Slowest"          value={`${replay.maxDeltaMs}ms`}
                sub={replay.maxDeltaMs > 6000 ? "⚠ time_scale?" : ""} />
              <Row label="Fastest"          value={`${replay.minDeltaMs}ms`}
                sub={replay.minDeltaMs < 400 ? "⚠ speedup?" : ""} />
              <Row label="Slow >6s"         value={replay.slowChunks}
                sub={`${(replay.slowChunks / Math.max(replay.deltas.length, 1) * 100).toFixed(1)}%`} />
              <Row label="Fast <400ms"      value={replay.fastChunks}
                sub={`${(replay.fastChunks / Math.max(replay.deltas.length, 1) * 100).toFixed(1)}%`} />
              <div style={{ marginTop: 10 }}>
                {timingOk
                  ? <div className="badge badge-green" style={{ width: "100%", justifyContent: "center", padding: "6px 0" }}>✓ Normal</div>
                  : <div className="badge badge-red"   style={{ width: "100%", justifyContent: "center", padding: "6px 0" }}>⚠ Anomaly</div>}
              </div>
            </div>
          )}

          {session.flagged && (
            <div className="card" style={{ padding: 16, borderColor: "var(--red)" }}>
              <div style={{ color: "var(--red)", fontSize: 11, textTransform: "uppercase",
                letterSpacing: "0.06em", marginBottom: 8 }}>Flag Reason</div>
              <div style={{ fontFamily: "monospace", fontSize: 11, color: "var(--red)",
                wordBreak: "break-all", lineHeight: 1.6 }}>{session.reason}</div>
            </div>
          )}

          <div className="card" style={{ padding: 16 }}>
            <div style={{ color: "var(--text-muted)", fontSize: 11, textTransform: "uppercase",
              letterSpacing: "0.06em", marginBottom: 10 }}>Verdict</div>
            {[
              { label: "Score match", ok: scoreOk },
              { label: "Timing",      ok: timingOk },
              { label: "Not flagged", ok: !session.flagged },
            ].map(({ label, ok }) => (
              <div key={label} style={{ display: "flex", justifyContent: "space-between",
                alignItems: "center", padding: "4px 0" }}>
                <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{label}</span>
                <span style={{ fontSize: 12, fontWeight: 700, color: ok ? "var(--green)" : "var(--red)" }}>
                  {ok ? "✓ Pass" : "✗ Fail"}
                </span>
              </div>
            ))}
          </div>

        </div>
      </div>
    </main>
  );
}
