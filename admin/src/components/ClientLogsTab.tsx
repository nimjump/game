"use client";
import { useState } from "react";
import { deleteClientLogs, type ClientLogEntry } from "@/lib/api";

function fmt(ts: number) {
  if (!ts) return "—";
  // Pinned to UTC+3 — see AnalyticsTab.tsx's fmt() for why.
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}

interface Props {
  logs: ClientLogEntry[];
  total: number;
  levelFilter: string;
  onLevelChange: (level: string) => void;
  onCleared: () => void;
}

export default function ClientLogsTab({ logs: _logs, total, levelFilter, onLevelChange, onCleared }: Props) {
  const logs = _logs ?? [];
  const [clearing, setClearing] = useState(false);
  const [expanded, setExpanded] = useState<string | null>(null);

  async function doClear() {
    if (!confirm("Delete all client logs?")) return;
    setClearing(true);
    try {
      const res = await deleteClientLogs();
      alert(`${res.deleted} logs deleted.`);
      onCleared();
    } catch(e) {
      alert("Error: " + String(e));
    } finally {
      setClearing(false);
    }
  }

  return (
    <div className="card">
      {/* Toolbar */}
      <div style={{
        padding: "12px 16px",
        borderBottom: "1px solid var(--border)",
        display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap",
      }}>
        <span style={{ fontWeight: 600, fontSize: 13 }}>🐛 Client Logs</span>
        <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
          {logs.length} shown / {total} unique messages (max 500, 14-day TTL)
        </span>

        {/* Level filter */}
        <div style={{ display: "flex", gap: 4 }}>
          {(["", "error", "warn", "info"] as const).map(lvl => (
            <button key={lvl}
              className={`btn ${levelFilter === lvl ? "btn-active" : ""}`}
              style={{ fontSize: 11, padding: "3px 9px" }}
              onClick={() => onLevelChange(lvl)}
            >
              {lvl === "" ? "All" : lvl}
            </button>
          ))}
        </div>

        <button className="btn"
          style={{ marginLeft: "auto", background: "var(--red)", fontSize: 12 }}
          disabled={clearing || logs.length === 0}
          onClick={doClear}
        >
          {clearing ? "Deleting…" : "🗑 Clear All"}
        </button>
      </div>

      {logs.length === 0 ? (
        <div style={{ padding: 40, textAlign: "center", color: "var(--text-muted)" }}>No logs</div>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Level</th>
              <th>Message</th>
              <th style={{ textAlign: "center" }}>Count</th>
              <th>Players</th>
              <th>Devices</th>
              <th>First seen</th>
              <th>Last seen</th>
            </tr>
          </thead>
          <tbody>
            {logs.map(e => {
              const isOpen = expanded === e.id;
              return (
                <>
                  <tr key={e.id}
                    style={{ cursor: "pointer" }}
                    onClick={() => setExpanded(isOpen ? null : e.id)}
                  >
                    <td>
                      <span className={`badge ${
                        e.level === "error" ? "badge-red" :
                        e.level === "warn"  ? "badge-yellow" : "badge-green"
                      }`} style={{ fontSize: 10 }}>
                        {e.level}
                      </span>
                    </td>
                    <td style={{
                      fontFamily: "monospace", fontSize: 11,
                      maxWidth: 420, overflow: "hidden",
                      textOverflow: "ellipsis", whiteSpace: isOpen ? "normal" : "nowrap",
                      wordBreak: isOpen ? "break-all" : "normal",
                    }}>
                      {e.message}
                    </td>
                    <td style={{ textAlign: "center", fontWeight: 700,
                      color: e.count > 10 ? "var(--red)" : e.count > 2 ? "var(--yellow)" : "var(--text)" }}>
                      {e.count}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)" }}>
                      {e.players?.length ?? 0} player{(e.players?.length ?? 0) !== 1 ? "s" : ""}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)" }}>
                      {e.devices?.length ?? 0} device{(e.devices?.length ?? 0) !== 1 ? "s" : ""}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap" }}>
                      {fmt(e.created_at)}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap" }}>
                      {fmt(e.updated_at)}
                    </td>
                  </tr>

                  {/* Expanded detail row */}
                  {isOpen && (
                    <tr key={e.id + "_exp"}>
                      <td colSpan={7} style={{
                        background: "var(--surface2)",
                        padding: "10px 16px",
                        fontSize: 11,
                        fontFamily: "monospace",
                      }}>
                        {e.players && e.players.length > 0 && (
                          <div style={{ marginBottom: 6 }}>
                            <b>Players:</b> {e.players.join(" · ")}
                          </div>
                        )}
                        {e.ips && e.ips.length > 0 && (
                          <div style={{ marginBottom: 6 }}>
                            <b>IPs:</b> {e.ips.join(" · ")}
                          </div>
                        )}
                        {e.devices && e.devices.length > 0 && (
                          <div>
                            <b>Devices:</b>
                            {e.devices.map((d, i) => (
                              <div key={i} style={{ color: "var(--text-muted)", marginLeft: 8, marginTop: 2 }}>
                                {d}
                              </div>
                            ))}
                          </div>
                        )}
                      </td>
                    </tr>
                  )}
                </>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
