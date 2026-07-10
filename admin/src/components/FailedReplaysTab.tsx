"use client";
import Link from "next/link";
import { useState } from "react";
import { retryReplay, adminSessionAction, type FailedReplay } from "@/lib/api";

function fmt(ts: number) {
  if (!ts) return "—";
  // Pinned to UTC+3 — see AnalyticsTab.tsx's fmt() for why.
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}
function shortId(id: string) { return id ? id.slice(0, 10) + "…" : "—"; }

interface Props {
  items: FailedReplay[];
  onRetryDone: () => void;
}

type RowState = "idle" | "loading" | "ok" | "err";

// ── Confirm modal ──────────────────────────────────────────────────────────────
function Confirm({ msg, onOk, onCancel }: { msg: string; onOk: () => void; onCancel: () => void }) {
  return (
    <div style={{
      position: "fixed", inset: 0, background: "rgba(0,0,0,.6)",
      display: "flex", alignItems: "center", justifyContent: "center", zIndex: 999,
    }}>
      <div style={{
        background: "var(--card)", borderRadius: 10, padding: 28,
        maxWidth: 400, width: "90%", boxShadow: "0 8px 32px rgba(0,0,0,.4)",
      }}>
        <p style={{ marginBottom: 20, lineHeight: 1.5, whiteSpace: "pre-line" }}>{msg}</p>
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button className="btn" onClick={onCancel}>Cancel</button>
          <button className="btn btn-active" onClick={onOk}>Confirm</button>
        </div>
      </div>
    </div>
  );
}

export default function FailedReplaysTab({ items, onRetryDone }: Props) {
  const [rowState, setRowState] = useState<Record<string, RowState>>({});
  const [rowMsg,   setRowMsg]   = useState<Record<string, string>>({});
  const [conf,     setConf]     = useState<{ id: string; action: "retry" | "approve" | "reject"; label: string; detail: string } | null>(null);

  const set = (id: string, st: RowState, msg = "") => {
    setRowState(p => ({ ...p, [id]: st }));
    setRowMsg(p => ({ ...p, [id]: msg }));
  };

  const doRetry = async (sessionId: string) => {
    set(sessionId, "loading");
    const res = await retryReplay(sessionId);
    if (res.ok) {
      set(sessionId, "ok", `Score: ${res.server_score} ${res.flagged ? "🚩 " + res.reason : "✓ OK"}`);
      onRetryDone();
    } else {
      set(sessionId, "err", res.reason ?? "error");
    }
  };

  const doAction = async (sessionId: string, action: "approve" | "reject") => {
    set(sessionId, "loading");
    const res = await adminSessionAction(sessionId, action);
    if (res.ok) {
      set(sessionId, "ok", `Done: ${res.state ?? action}`);
      onRetryDone();
    } else {
      set(sessionId, "err", res.error ?? "error");
    }
  };

  const confirmAndRun = () => {
    if (!conf) return;
    const { id, action } = conf;
    setConf(null);
    if (action === "retry")   doRetry(id);
    else                      doAction(id, action);
  };

  return (
    <>
      {conf && (
        <Confirm
          msg={conf.detail}
          onOk={confirmAndRun}
          onCancel={() => setConf(null)}
        />
      )}

      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", display: "flex", alignItems: "center", gap: 12 }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Failed Replays ({items.length})</span>
          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>
            Simulation failed — retry, approve, or reject each session
          </span>
        </div>

        {items.length === 0 ? (
          <div style={{ padding: 40, textAlign: "center", color: "var(--text-muted)" }}>
            No failed replays
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Session</th>
                <th>Player</th>
                <th>Client Score</th>
                <th>Error</th>
                <th>Date</th>
                <th>View</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {items.map(s => {
                const st  = rowState[s.session_id] ?? "idle";
                const msg = rowMsg[s.session_id] ?? "";
                const busy = st === "loading";
                return (
                  <tr key={s.session_id}>
                    <td style={{ fontFamily: "monospace", fontSize: 11 }}>{shortId(s.session_id)}</td>
                    <td>
                      <div style={{ fontSize: 13, fontWeight: 600 }}>{s.nickname || "—"}</div>
                      <div style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>
                        {s.player_id ? s.player_id.slice(0, 22) + "…" : "—"}
                      </div>
                    </td>
                    <td style={{ fontWeight: 600 }}>{s.client_score.toLocaleString()}</td>
                    <td style={{ fontSize: 11, color: "var(--red)", maxWidth: 180, wordBreak: "break-all" }}>
                      {s.replay_error || "—"}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap" }}>
                      {fmt(s.submitted_at)}
                    </td>
                    <td>
                      {s.has_log && (
                        <Link href={`/replay/${s.session_id}`}>
                          <button className="btn" style={{ fontSize: 11, padding: "2px 7px" }}>▶</button>
                        </Link>
                      )}
                    </td>
                    <td>
                      {msg ? (
                        <span style={{ fontSize: 11, color: st === "ok" ? "var(--green)" : "var(--red)" }}>{msg}</span>
                      ) : (
                        <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                          {s.has_log && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 8px", background: "var(--yellow)", color: "#000" }}
                              onClick={() => setConf({
                                id: s.session_id, action: "retry", label: "Re-simulate",
                                detail: `Re-run replay simulation for session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score}`,
                              })}>
                              {busy ? "…" : "⟳ Retry"}
                            </button>
                          )}
                          <button className="btn" disabled={busy}
                            style={{ fontSize: 11, padding: "2px 8px", color: "var(--green)" }}
                            onClick={() => setConf({
                              id: s.session_id, action: "approve", label: "Approve",
                              detail: `Approve session ${s.session_id.slice(0, 8)}…?\nClient score ${s.client_score} will be accepted.\nSession will be marked completed.`,
                            })}>
                            Approve
                          </button>
                          <button className="btn" disabled={busy}
                            style={{ fontSize: 11, padding: "2px 8px", color: "var(--red)" }}
                            onClick={() => setConf({
                              id: s.session_id, action: "reject", label: "Reject",
                              detail: `Reject session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score}\nSession will be marked flagged.`,
                            })}>
                            Reject
                          </button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
