"use client";
import { useState } from "react";
import {
  searchPlayer, adminSessionAction,
  type PlayerProfile, type SessionAction,
} from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

// ── helpers ────────────────────────────────────────────────────────────────────
function fmt(ts: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString();
}
function nimFmt(n: number) {
  return (n ?? 0).toFixed(4);
}

// ── Confirm modal ──────────────────────────────────────────────────────────────
function Confirm({
  msg, onOk, onCancel,
}: { msg: string; onOk: () => void; onCancel: () => void }) {
  return (
    <div style={{
      position: "fixed", inset: 0, background: "rgba(0,0,0,.6)",
      display: "flex", alignItems: "center", justifyContent: "center", zIndex: 999,
    }}>
      <div style={{
        background: "var(--card)", borderRadius: 10, padding: 28,
        maxWidth: 380, width: "90%", boxShadow: "0 8px 32px rgba(0,0,0,.4)",
      }}>
        <p style={{ marginBottom: 20, lineHeight: 1.5 }}>{msg}</p>
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button className="btn" onClick={onCancel}>Cancel</button>
          <button className="btn btn-active" onClick={onOk}>Confirm</button>
        </div>
      </div>
    </div>
  );
}

// ── Session row with action buttons ───────────────────────────────────────────
function SessionRow({
  s, onDone,
}: {
  s: PlayerProfile["recent_sessions"][0];
  onDone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [msg,  setMsg]  = useState("");
  const [conf, setConf] = useState<{ action: SessionAction; label: string } | null>(null);

  const act = async (action: SessionAction, reason?: string) => {
    setBusy(true); setMsg("");
    const res = await adminSessionAction(s.session_id, action, reason);
    setBusy(false);
    if (res.ok) { setMsg(`Done: ${res.state ?? action}`); onDone(); }
    else         { setMsg(`Error: ${res.error}`); }
  };

  const stateColor = (state: string) => {
    if (state === "completed")    return "var(--green)";
    if (state === "flagged")      return "var(--orange)";
    if (state === "replay_failed")return "var(--red)";
    if (state === "active")       return "var(--blue)";
    return "var(--text-muted)";
  };

  return (
    <>
      {conf && (
        <Confirm
          msg={`${conf.label} session ${s.session_id.slice(0, 8)}…?\nClient score: ${s.client_score} / Server score: ${s.server_score}`}
          onOk={() => { setConf(null); act(conf.action); }}
          onCancel={() => setConf(null)}
        />
      )}
      <tr>
        <td style={{ fontFamily: "monospace", fontSize: 11 }}>
          <a href={`/replay/${s.session_id}`} style={{ color: "var(--orange)" }}>
            {s.session_id.slice(0, 8)}
          </a>
        </td>
        <td style={{ color: stateColor(s.state) }}>{s.state}</td>
        <td>{s.client_score}</td>
        <td>{s.server_score}</td>
        <td style={{ fontSize: 11, color: "var(--text-muted)" }}>{s.reason || s.replay_error || "—"}</td>
        <td style={{ fontSize: 11 }}>{fmt(s.submitted_at)}</td>
        <td>
          <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
            {(s.state === "flagged" || s.state === "replay_failed") && (
              <>
                <button className="btn" disabled={busy}
                  style={{ fontSize: 11, padding: "2px 8px", color: "var(--green)" }}
                  onClick={() => setConf({ action: "approve", label: "Approve" })}>
                  Approve
                </button>
                <button className="btn" disabled={busy}
                  style={{ fontSize: 11, padding: "2px 8px" }}
                  onClick={() => setConf({ action: "unflag", label: "Unflag" })}>
                  Unflag
                </button>
              </>
            )}
            {s.state === "flagged" && (
              <button className="btn" disabled={busy}
                style={{ fontSize: 11, padding: "2px 8px", color: "var(--red)" }}
                onClick={() => setConf({ action: "reject", label: "Reject" })}>
                Reject
              </button>
            )}
            {s.has_log && (
              <button className="btn" disabled={busy}
                style={{ fontSize: 11, padding: "2px 8px" }}
                onClick={() => setConf({ action: "retry", label: "Re-simulate" })}>
                Retry
              </button>
            )}
          </div>
          {msg && <div style={{ fontSize: 11, marginTop: 2, color: msg.startsWith("Error") ? "var(--red)" : "var(--green)" }}>{msg}</div>}
        </td>
      </tr>
    </>
  );
}

// ── Main component ─────────────────────────────────────────────────────────────
export default function PlayerSearchTab() {
  const [q,       setQ]       = useState("");
  const [loading, setLoading] = useState(false);
  const [error,   setError]   = useState("");
  const [profile, setProfile] = useState<PlayerProfile | null>(null);

  const search = async () => {
    if (!q.trim()) return;
    setLoading(true); setError(""); setProfile(null);
    try {
      const p = await searchPlayer(q.trim());
      setProfile(p);
    } catch (e: unknown) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  const reload = () => { if (profile) search(); };

  const questDone  = profile?.quests?.filter(q => q.completed).length ?? 0;
  const questTotal = profile?.quests?.length ?? 0;
  const questPct   = questTotal > 0 ? Math.round(questDone / questTotal * 100) : 0;

  const cap = profile?.daily_cap;
  const capPct = cap && cap.daily_cap > 0
    ? Math.min(100, Math.round(cap.daily_earned / cap.daily_cap * 100))
    : 0;

  return (
    <div>
      {/* ── Search bar ── */}
      <div style={{ display: "flex", gap: 8, marginBottom: 20 }}>
        <input
          className="input"
          style={{ flex: 1, maxWidth: 420 }}
          placeholder="Search by wallet address or nickname…"
          value={q}
          onChange={e => setQ(e.target.value)}
          onKeyDown={e => e.key === "Enter" && search()}
        />
        <button className="btn btn-active" onClick={search} disabled={loading}>
          {loading ? "…" : "Search"}
        </button>
      </div>

      {error && <div style={{ color: "var(--red)", marginBottom: 12 }}>{error}</div>}

      {profile && (
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

          {/* ── Identity card ── */}
          <div className="card" style={{ padding: "16px 20px" }}>
            <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "flex-start" }}>
              <div style={{ flex: 1, minWidth: 200, display: "flex", alignItems: "center", gap: 14 }}>
                <NimiqAvatar address={profile.player_id} size={52} />
                <div>
                  <div style={{ fontSize: 18, fontWeight: 700, color: "var(--orange)", marginBottom: 4 }}>
                    {profile.nickname || <span style={{ color: "var(--text-muted)" }}>No nickname</span>}
                  </div>
                  <div style={{ fontFamily: "monospace", fontSize: 12, color: "var(--text-muted)", wordBreak: "break-all" }}>
                    {profile.player_id}
                  </div>
                  {profile.cooldown_end > Date.now() / 1000 && (
                    <div style={{ fontSize: 11, color: "var(--orange)", marginTop: 4 }}>
                      Nickname cooldown until {fmt(profile.cooldown_end)}
                    </div>
                  )}
                </div>
              </div>

              {/* Leaderboard ranks */}
              <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
                {[
                  { label: "Daily", rank: profile.leaderboard.daily_rank },
                  { label: "Weekly", rank: profile.leaderboard.weekly_rank },
                  { label: "All-time", rank: profile.leaderboard.alltime_rank },
                ].map(({ label, rank }) => (
                  <div key={label} style={{
                    background: "var(--bg)", borderRadius: 8, padding: "8px 14px", textAlign: "center",
                  }}>
                    <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{label}</div>
                    <div style={{ fontSize: 20, fontWeight: 700, color: rank ? "var(--orange)" : "var(--text-muted)" }}>
                      {rank ? `#${rank}` : "—"}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          {/* ── Stats row ── */}
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
            {[
              { label: "Best Score",   value: profile.stats.best_score },
              { label: "Games Played", value: profile.stats.total_games },
              { label: "Total Kills",  value: profile.stats.total_kills },
              { label: "Platforms",    value: profile.stats.total_platforms },
            ].map(({ label, value }) => (
              <div key={label} className="card" style={{ flex: 1, minWidth: 110, padding: "12px 16px", textAlign: "center" }}>
                <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 4 }}>{label}</div>
                <div style={{ fontSize: 22, fontWeight: 700, color: "var(--orange)" }}>{value}</div>
              </div>
            ))}
          </div>

          {/* ── Daily cap + Quests ── */}
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>

            {/* Cap */}
            {cap && (
              <div className="card" style={{ flex: 1, minWidth: 220, padding: "14px 18px" }}>
                <div style={{ fontWeight: 600, marginBottom: 8 }}>Daily NIM Earned</div>
                <div style={{ display: "flex", justifyContent: "space-between", fontSize: 13, marginBottom: 6 }}>
                  <span style={{ color: "var(--orange)" }}>{nimFmt(cap.daily_earned)} NIM</span>
                  <span style={{ color: "var(--text-muted)" }}>/ {nimFmt(cap.daily_cap)} cap</span>
                </div>
                <div style={{ background: "var(--bg)", borderRadius: 4, height: 8, overflow: "hidden" }}>
                  <div style={{
                    width: `${capPct}%`, height: "100%",
                    background: cap.daily_cap_full ? "var(--red)" : "var(--orange)",
                    transition: "width .3s",
                  }} />
                </div>
                <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 6 }}>
                  {cap.daily_cap_full
                    ? "Cap reached"
                    : `${nimFmt(cap.daily_cap_remaining)} remaining`}
                  {cap.daily_cap_reset_at > 0 && ` · resets ${fmt(cap.daily_cap_reset_at)}`}
                </div>
                <div style={{ fontSize: 12, marginTop: 8 }}>
                  Quest NIM today: <span style={{ color: "var(--orange)" }}>{nimFmt(profile.quest_nim_claimed)}</span>
                  <span style={{ color: "var(--text-muted)" }}> / {nimFmt(profile.quest_nim_today)} available</span>
                </div>
              </div>
            )}

            {/* Quest summary */}
            <div className="card" style={{ flex: 1, minWidth: 220, padding: "14px 18px" }}>
              <div style={{ fontWeight: 600, marginBottom: 8 }}>
                Daily Quests — {questDone}/{questTotal} &nbsp;
                <span style={{ color: "var(--orange)" }}>({questPct}%)</span>
              </div>
              <div style={{ background: "var(--bg)", borderRadius: 4, height: 8, overflow: "hidden", marginBottom: 10 }}>
                <div style={{ width: `${questPct}%`, height: "100%", background: "var(--orange)", transition: "width .3s" }} />
              </div>
              {profile.quests?.map(qst => {
                const pct = qst.target > 0 ? Math.min(100, Math.round(qst.progress / qst.target * 100)) : 0;
                return (
                  <div key={qst.id} style={{ marginBottom: 8 }}>
                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, marginBottom: 2 }}>
                      <span style={{ color: qst.completed ? "var(--green)" : "inherit" }}>
                        {qst.completed ? "✓ " : ""}{qst.description}
                      </span>
                      <span style={{ color: "var(--text-muted)", whiteSpace: "nowrap", marginLeft: 8 }}>
                        {qst.progress}/{qst.target} · {nimFmt(qst.reward_nim)} NIM
                      </span>
                    </div>
                    <div style={{ background: "var(--bg)", borderRadius: 3, height: 4, overflow: "hidden" }}>
                      <div style={{ width: `${pct}%`, height: "100%", background: qst.completed ? "var(--green)" : "var(--orange)" }} />
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {/* ── Recent sessions ── */}
          <div className="card" style={{ padding: "14px 18px" }}>
            <div style={{ fontWeight: 600, marginBottom: 10 }}>Recent Sessions</div>
            <div style={{ overflowX: "auto" }}>
              <table className="table" style={{ width: "100%", fontSize: 12 }}>
                <thead>
                  <tr>
                    <th>ID</th><th>State</th><th>Client</th><th>Server</th>
                    <th>Note</th><th>Submitted</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {(profile.recent_sessions ?? []).map(s => (
                    <SessionRow key={s.session_id} s={s} onDone={reload} />
                  ))}
                  {!profile.recent_sessions?.length && (
                    <tr><td colSpan={7} style={{ textAlign: "center", color: "var(--text-muted)", padding: 20 }}>No sessions</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>

          {/* ── Reward history ── */}
          {profile.rewards?.length > 0 && (
            <div className="card" style={{ padding: "14px 18px" }}>
              <div style={{ fontWeight: 600, marginBottom: 10 }}>Reward History</div>
              <div style={{ overflowX: "auto" }}>
                <table className="table" style={{ width: "100%", fontSize: 12 }}>
                  <thead>
                    <tr><th>Reason</th><th>Amount</th><th>Status</th><th>Tx</th><th>Created</th></tr>
                  </thead>
                  <tbody>
                    {profile.rewards.map(r => (
                      <tr key={r.id}>
                        <td>{r.reason}</td>
                        <td style={{ color: "var(--orange)" }}>{nimFmt(r.amount_nim)} NIM</td>
                        <td style={{ color: r.status === "sent" ? "var(--green)" : r.status === "failed" ? "var(--red)" : "var(--text-muted)" }}>
                          {r.status}
                        </td>
                        <td style={{ fontFamily: "monospace", fontSize: 10 }}>
                          {r.tx_hash ? r.tx_hash.slice(0, 12) + "…" : "—"}
                        </td>
                        <td>{fmt(r.created_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

        </div>
      )}
    </div>
  );
}
