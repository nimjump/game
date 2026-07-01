"use client";
import Link from "next/link";
import type { Overview, Session } from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

function fmtDur(sec: number) {
  if (!sec) return "—";
  const m = Math.floor(sec / 60), s = sec % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}
function fmt(ts: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB");
}

interface Props { ov: Overview; }

export default function OverviewTab({ ov }: Props) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>

      {/* Currently playing */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13 }}>
          🎮 Currently playing ({(ov.active_sessions ?? []).length})
        </div>
        {(ov.active_sessions ?? []).length === 0 ? (
          <div style={{ padding: 24, textAlign: "center", color: "var(--text-muted)", fontSize: 13 }}>No active sessions</div>
        ) : (
          <table>
            <thead><tr><th>Player</th><th>Duration</th></tr></thead>
            <tbody>
              {(ov.active_sessions ?? []).map((s: Session) => (
                <tr key={s.session_id}>
                  <td>
                    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                      <NimiqAvatar address={s.player_id} size={26} />
                      <span style={{ fontSize: 12 }}>{s.nickname || (s.player_id ? s.player_id.slice(0, 12) + "…" : "—")}</span>
                    </div>
                  </td>
                  <td style={{ color: "var(--green)", fontWeight: 600 }}>{fmtDur(s.elapsed_sec ?? 0)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Recent sessions */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13 }}>
          ⏱ Recent sessions
        </div>
        <table>
          <thead><tr><th>Player</th><th>Client</th><th>Server</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {(ov.recent_sessions ?? []).map((s: Session) => (
              <tr key={s.session_id} style={s.flagged ? { background: "#1a0d0d" } : {}}>
                <td>
                  <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
                    <NimiqAvatar address={s.player_id} size={24} />
                    <span style={{ fontSize: 12 }}>{s.nickname || "—"}</span>
                  </div>
                </td>
                <td style={{ fontWeight: 600 }}>{s.client_score.toLocaleString()}</td>
                <td style={{ fontWeight: 700, color: s.flagged ? "var(--red)" : "var(--green)" }}>
                  {s.server_score.toLocaleString()}
                </td>
                <td>
                  {s.state === "flagged" || s.flagged
                    ? <span className="badge badge-red" style={{ fontSize: 10 }}>🚩</span>
                    : s.state === "replay_failed"
                    ? <span className="badge badge-yellow" style={{ fontSize: 10 }}>⚠</span>
                    : s.state === "completed"
                    ? <span className="badge badge-green" style={{ fontSize: 10 }}>✓</span>
                    : <span className="badge badge-yellow" style={{ fontSize: 10 }}>⏳</span>}
                </td>
                <td>
                  <Link href={`/replay/${s.session_id}`}>
                    <button className="btn btn-blue" style={{ fontSize: 11, padding: "2px 7px" }}>▶</button>
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* System + replay status */}
      <div className="card" style={{ gridColumn: "1 / -1", padding: "12px 20px", display: "flex", gap: 32, flexWrap: "wrap", alignItems: "center" }}>
        <span style={{ fontWeight: 600, fontSize: 13 }}>🔄 Replay Sim</span>
        <span style={{ fontSize: 12 }}>
          Binary: {ov.replay.binary_ok
            ? <span style={{ color: "var(--green)" }}>✓ OK</span>
            : <span style={{ color: "var(--red)" }}>✗ Missing</span>}
        </span>
        <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
          Queue: <b style={{ color: ov.replay.queue_len > 0 ? "var(--yellow)" : "var(--green)" }}>
            {ov.replay.queue_len}/{ov.replay.max_workers}
          </b>
        </span>
        <span style={{ fontSize: 11, color: "var(--text-muted)", fontFamily: "monospace" }}>
          {ov.replay.binary_path ?? "—"}
        </span>
        <span style={{ marginLeft: "auto", fontSize: 11, color: "var(--text-muted)" }}>
          ⬆ {fmtDur(ov.system.uptime_sec)} &nbsp;·&nbsp;
          {ov.system.goroutines}g &nbsp;·&nbsp;
          {ov.system.heap_mb}MB &nbsp;·&nbsp;
          {ov.system.cpu_count}cpu
        </span>
      </div>

    </div>
  );
}
