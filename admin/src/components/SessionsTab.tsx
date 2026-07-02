"use client";
import Link from "next/link";
import { useState } from "react";
import { retryReplay, adminSessionAction, saveGoldenReplay, type Session, type SessionAction } from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

function fmt(ts: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB");
}
function scoreDiff(s: Session) {
  if (!s.submitted_at || s.client_score === 0) return "—";
  const d = Math.abs(s.server_score - s.client_score);
  return ((d / s.client_score) * 100).toFixed(1) + "%";
}

interface Props {
  sessions: Session[];
  onSearch: (q: string) => void;
  onSearchSubmit: (q: string) => void;
  searchValue: string;
  onActionDone?: () => void; // refresh parent after action
}

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

export default function SessionsTab({
  sessions, onSearch, onSearchSubmit, searchValue, onActionDone,
}: Props) {
  const [rowState, setRowState] = useState<Record<string, "loading" | "ok" | "err">>({});
  const [rowMsg,   setRowMsg]   = useState<Record<string, string>>({});
  const [conf, setConf] = useState<{
    id: string; action: SessionAction; detail: string;
  } | null>(null);

  const set = (id: string, st: "loading" | "ok" | "err", msg = "") => {
    setRowState(p => ({ ...p, [id]: st }));
    setRowMsg(p => ({ ...p, [id]: msg }));
  };

  const doAction = async (sessionId: string, action: SessionAction) => {
    set(sessionId, "loading");
    let res;
    if (action === "retry") {
      const r = await retryReplay(sessionId);
      res = { ok: r.ok, state: r.flagged ? "flagged" : "completed", error: r.reason };
      if (r.ok) set(sessionId, "ok", `${r.server_score} ${r.flagged ? "🚩" : "✓"}`);
      else       set(sessionId, "err", r.reason ?? "error");
    } else {
      res = await adminSessionAction(sessionId, action);
      if (res.ok) set(sessionId, "ok", `Done: ${res.state ?? action}`);
      else        set(sessionId, "err", res.error ?? "error");
    }
    if (res.ok && onActionDone) onActionDone();
  };

  const confirmAndRun = () => {
    if (!conf) return;
    const { id, action } = conf;
    setConf(null);
    doAction(id, action);
  };

  const pinGolden = async (sessionId: string) => {
    const label = window.prompt("Label for this golden replay (e.g. \"bunny3, mystery box heavy\"):", "");
    if (label === null) return; // cancelled
    set(sessionId, "loading");
    try {
      await saveGoldenReplay(sessionId, label.trim());
      set(sessionId, "ok", "📌 pinned as golden");
    } catch (e) {
      set(sessionId, "err", String(e instanceof Error ? e.message : e));
    }
  };

  return (
    <>
      {conf && (
        <Confirm msg={conf.detail} onOk={confirmAndRun} onCancel={() => setConf(null)} />
      )}

      {/* Search bar */}
      <div style={{ marginBottom: 12 }}>
        <input
          type="text"
          value={searchValue}
          onChange={e => onSearch(e.target.value)}
          onKeyDown={e => e.key === "Enter" && onSearchSubmit(searchValue)}
          placeholder="Search player ID / nickname… (Enter)"
          style={{
            background: "var(--surface2)", border: "1px solid var(--border)",
            borderRadius: 6, padding: "6px 12px", color: "var(--text)",
            fontSize: 12, width: 280,
          }}
        />
      </div>

      <div className="card">
        {sessions.length === 0 ? (
          <div style={{ padding: 40, textAlign: "center", color: "var(--text-muted)" }}>No records</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Player</th>
                <th>Status</th>
                <th>Client</th>
                <th>Server</th>
                <th>Diff</th>
                <th>Ticks</th>
                <th>Date</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {sessions.map((s, i) => {
                const st   = rowState[s.session_id];
                const msg  = rowMsg[s.session_id] ?? "";
                const busy = st === "loading";
                const isFlagged      = s.flagged || s.state === "flagged";
                const isReplayFailed = s.state === "replay_failed";
                return (
                  <tr key={s.session_id}
                    style={
                      isFlagged       ? { background: "#1a0d0d" } :
                      isReplayFailed  ? { background: "#1a1500" } :
                      {}
                    }
                  >
                    <td style={{ color: "var(--text-muted)", fontSize: 11 }}>{i + 1}</td>
                    <td>
                      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                        <NimiqAvatar address={s.player_id ?? ""} size={30} />
                        <div>
                          <div style={{ fontSize: 13, fontWeight: 600 }}>{s.nickname || "—"}</div>
                          <div style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>
                            {s.player_id ? s.player_id.slice(0, 18) + "…" : "—"}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td>
                      {isFlagged && !isReplayFailed &&
                        <span className="badge badge-red" style={{ fontSize: 10 }}>⚠ {s.reason?.split(":")[0] ?? "flagged"}</span>}
                      {s.state === "completed" && !s.flagged &&
                        <span className="badge badge-green" style={{ fontSize: 10 }}>✓ OK</span>}
                      {s.state === "pending" &&
                        <span className="badge badge-yellow" style={{ fontSize: 10 }}>⏳</span>}
                      {isReplayFailed &&
                        <span className="badge badge-yellow" style={{ fontSize: 10 }}>⚠ Replay Failed</span>}
                    </td>
                    <td style={{ fontWeight: 600 }}>{s.client_score.toLocaleString()}</td>
                    <td style={{ fontWeight: 700, color: isFlagged ? "var(--red)" : "var(--green)" }}>
                      {s.server_score.toLocaleString()}
                    </td>
                    <td style={{ color: isFlagged ? "var(--red)" : "var(--text-muted)", fontSize: 12 }}>{scoreDiff(s)}</td>
                    <td style={{ color: "var(--text-muted)", fontSize: 12 }}>{s.ticks.toLocaleString()}</td>
                    <td style={{ color: "var(--text-muted)", fontSize: 11 }}>
                      {s.submitted_at ? fmt(s.submitted_at) : fmt(s.created_at)}
                    </td>
                    <td>
                      {msg ? (
                        <span style={{ fontSize: 11, color: st === "ok" ? "var(--green)" : "var(--red)" }}>{msg}</span>
                      ) : (
                        <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                          {/* View replay */}
                          {s.has_log !== false && (
                            <Link href={`/replay/${s.session_id}`}>
                              <button className="btn" style={{ fontSize: 11, padding: "2px 7px" }}>▶</button>
                            </Link>
                          )}
                          {/* Pin as golden replay — only makes sense for a clean completed run */}
                          {s.state === "completed" && !s.flagged && s.has_log !== false && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 7px" }}
                              title="Pin as golden replay (determinism self-test)"
                              onClick={() => pinGolden(s.session_id)}>
                              📌
                            </button>
                          )}
                          {/* Flagged/failed actions */}
                          {(isFlagged || isReplayFailed) && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 7px", color: "var(--green)" }}
                              onClick={() => setConf({
                                id: s.session_id, action: "approve",
                                detail: `Approve session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score}\nSession will be marked completed.`,
                              })}>
                              Approve
                            </button>
                          )}
                          {isFlagged && !isReplayFailed && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 7px" }}
                              onClick={() => setConf({
                                id: s.session_id, action: "unflag",
                                detail: `Unflag session ${s.session_id.slice(0, 8)}…?\nKeeps server score: ${s.server_score}`,
                              })}>
                              Unflag
                            </button>
                          )}
                          {isFlagged && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 7px", color: "var(--red)" }}
                              onClick={() => setConf({
                                id: s.session_id, action: "reject",
                                detail: `Reject session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score}\nSession stays flagged / rejected.`,
                              })}>
                              Reject
                            </button>
                          )}
                          {isReplayFailed && s.has_log !== false && (
                            <button className="btn" disabled={busy}
                              style={{ fontSize: 11, padding: "2px 7px", background: "var(--yellow)", color: "#000" }}
                              onClick={() => setConf({
                                id: s.session_id, action: "retry",
                                detail: `Re-simulate session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score}`,
                              })}>
                              {busy ? "…" : "⟳ Retry"}
                            </button>
                          )}
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
