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
function fmtGB(bytes: number) {
  return (bytes / 1024 / 1024 / 1024).toFixed(1) + " GB";
}

function UsageBar({ label, used, total }: { label: string; used: number; total: number }) {
  const pct = total > 0 ? Math.min(100, (used / total) * 100) : 0;
  const color = pct > 90 ? "var(--red)" : pct > 75 ? "var(--yellow)" : "var(--green)";
  return (
    <div style={{ flex: 1, minWidth: 200 }}>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11, marginBottom: 4 }}>
        <span style={{ color: "var(--text-muted)" }}>{label}</span>
        <span style={{ fontWeight: 600 }}>
          {total > 0 ? `${fmtGB(used)} / ${fmtGB(total)} (${pct.toFixed(0)}%)` : "n/a"}
        </span>
      </div>
      <div style={{ background: "var(--surface2)", borderRadius: 4, height: 8 }}>
        <div style={{ background: color, borderRadius: 4, height: 8, width: `${pct}%` }} />
      </div>
    </div>
  );
}

interface Props { ov: Overview; }

export default function OverviewTab({ ov }: Props) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 16 }}>

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
                    <NimiqAvatar address={s.player_id ?? ""} size={24} />
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
          {ov.system.heap_mb}MB heap &nbsp;·&nbsp;
          {ov.system.cpu_count}cpu
        </span>
      </div>

      {/* Reward payouts (lifetime, site-wide) */}
      {ov.rewards && (
        <div className="card" style={{ gridColumn: "1 / -1", padding: "12px 20px", display: "flex", gap: 32, flexWrap: "wrap", alignItems: "center" }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>💰 NIM Payouts</span>
          <span style={{ fontSize: 12 }}>
            Sent: <b style={{ color: "var(--green)" }}>{ov.rewards.total_nim_sent.toFixed(2)} NIM</b>
            <span style={{ color: "var(--text-muted)" }}> ({ov.rewards.sent_count} rewards)</span>
          </span>
          <span style={{ fontSize: 12 }}>
            Pending: <b style={{ color: ov.rewards.pending_count > 0 ? "var(--yellow)" : "var(--text-muted)" }}>
              {ov.rewards.total_nim_pending.toFixed(2)} NIM
            </b>
            <span style={{ color: "var(--text-muted)" }}> ({ov.rewards.pending_count} rewards)</span>
          </span>
        </div>
      )}

      {/* Server resources — RAM + disk */}
      {ov.resources && (ov.resources.ram_total_bytes > 0 || ov.resources.disk_total_bytes > 0) && (
        <div className="card" style={{ gridColumn: "1 / -1", padding: "12px 20px" }}>
          <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 10 }}>🖥 Server Resources</div>
          <div style={{ display: "flex", gap: 24, flexWrap: "wrap" }}>
            <UsageBar label="RAM" used={ov.resources.ram_used_bytes} total={ov.resources.ram_total_bytes} />
            <UsageBar label={`Disk (DB_PATH volume)`} used={ov.resources.disk_used_bytes} total={ov.resources.disk_total_bytes} />
          </div>
        </div>
      )}

    </div>
  );
}
