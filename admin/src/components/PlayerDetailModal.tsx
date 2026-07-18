"use client";

// Self-contained player-detail modal: give it a playerID and it fetches the
// full profile (searchPlayer) and renders avatar, identity, stats, recent
// sessions, IPs and reward history. Reused from any tab (Players list, VS
// Rooms, …) so clicking a player anywhere opens the same detail view.

import { useEffect, useState } from "react";
import { searchPlayer, type PlayerProfile } from "@/lib/api";
import NimiqAvatar from "./NimiqAvatar";

function nim(n?: number) { return (n ?? 0).toFixed(2); }
function fmtDate(ts?: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}
function flagEmoji(cc?: string): string {
  if (!cc || cc.length !== 2) return "🏳️";
  const A = 0x1f1e6;
  return String.fromCodePoint(A + (cc.toUpperCase().charCodeAt(0) - 65)) +
         String.fromCodePoint(A + (cc.toUpperCase().charCodeAt(1) - 65));
}

function StatPill({ label, value, color }: { label: string; value: number | string; color: string }) {
  return (
    <div style={{ background: "#111827", border: "1px solid #1e293b", borderRadius: 8, padding: "8px 12px", minWidth: 92 }}>
      <div style={{ fontSize: 10, color: "#64748b", textTransform: "uppercase", letterSpacing: "0.04em" }}>{label}</div>
      <div style={{ fontSize: 16, fontWeight: 700, color }}>{value}</div>
    </div>
  );
}

export default function PlayerDetailModal({ playerID, onClose }: { playerID: string; onClose: () => void }) {
  const [profile, setProfile] = useState<PlayerProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let dead = false;
    setLoading(true); setError(""); setProfile(null);
    searchPlayer(playerID)
      .then((p) => { if (dead) return; if (!p) { setError("Player not found."); return; } setProfile(p); })
      .catch((e) => { if (!dead) setError(String(e instanceof Error ? e.message : e)); })
      .finally(() => { if (!dead) setLoading(false); });
    return () => { dead = true; };
  }, [playerID]);

  return (
    <div
      onClick={onClose}
      style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,.65)", display: "flex", alignItems: "flex-start", justifyContent: "center", padding: "40px 16px", zIndex: 999, overflowY: "auto" }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 12, padding: 24, maxWidth: 720, width: "100%", boxShadow: "0 8px 32px rgba(0,0,0,.5)" }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
          <NimiqAvatar address={playerID} size={44} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontWeight: 700, fontSize: 16, color: "#e2e8f0" }}>
              {profile?.nickname || <span style={{ color: "#64748b" }}>No nickname</span>}
            </div>
            <div style={{ fontFamily: "monospace", fontSize: 11, color: "#64748b", wordBreak: "break-all" }}>{playerID}</div>
            {profile?.device && (
              <div style={{ fontSize: 11, color: "#64748b", marginTop: 2 }}>
                {profile.device.platform || "?"} · {profile.device.screen || "?"} · DPR {profile.device.dpr || "?"}
              </div>
            )}
          </div>
          <button onClick={onClose} style={{ padding: "6px 12px", borderRadius: 8, border: "1px solid #334155", background: "#1e293b", color: "#e2e8f0", cursor: "pointer", fontSize: 13 }}>✕ Close</button>
        </div>

        {loading && <div style={{ color: "#64748b", textAlign: "center", padding: 32 }}>Loading…</div>}
        {error && !loading && (
          <div style={{ background: "#1e1010", border: "1px solid #7f1d1d", borderRadius: 8, padding: "10px 14px", color: "#fca5a5" }}>{error}</div>
        )}

        {profile && !loading && (
          <>
            <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 18 }}>
              <StatPill label="Total NIM received" value={nim(profile.total_nim_received)} color="#4caf50" />
              <StatPill label="Streak (days)" value={profile.streak?.count ?? 0} color="#e0a030" />
              <StatPill label="Best score" value={profile.stats.best_score} color="#4caf50" />
              <StatPill label="Games" value={profile.stats.total_games} color="#6366f1" />
              <StatPill label="Kills" value={profile.stats.total_kills} color="#e0a030" />
              <StatPill label="Platforms" value={profile.stats.total_platforms} color="#22d3ee" />
            </div>

            {/* Connection IPs */}
            <div style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "#e2e8f0" }}>Connection IPs</div>
              {!profile.ips || profile.ips.length === 0 ? (
                <div style={{ color: "#64748b", fontSize: 12 }}>No IP history yet.</div>
              ) : (
                <div style={{ overflowX: "auto" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
                    <thead><tr style={{ color: "#64748b", textAlign: "left" }}>
                      <th style={{ padding: "4px 8px" }}>Country</th><th style={{ padding: "4px 8px" }}>IP</th><th style={{ padding: "4px 8px" }}>Logins</th><th style={{ padding: "4px 8px" }}>Last seen</th>
                    </tr></thead>
                    <tbody>
                      {[...profile.ips].sort((a, b) => (b.last_seen ?? 0) - (a.last_seen ?? 0)).map((ip) => (
                        <tr key={ip.ip} style={{ color: "#e2e8f0" }}>
                          <td style={{ padding: "4px 8px", whiteSpace: "nowrap" }}><span style={{ marginRight: 6 }}>{flagEmoji(ip.country_code)}</span><span style={{ color: "#94a3b8" }}>{ip.country_name || "Unknown"}</span></td>
                          <td style={{ padding: "4px 8px", fontFamily: "monospace" }}>{ip.ip}</td>
                          <td style={{ padding: "4px 8px", color: "#94a3b8" }}>{ip.count}</td>
                          <td style={{ padding: "4px 8px", color: "#64748b" }}>{fmtDate(ip.last_seen)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>

            {/* Recent sessions */}
            <div style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "#e2e8f0" }}>Recent sessions</div>
              {profile.recent_sessions.length === 0 ? (
                <div style={{ color: "#64748b", fontSize: 12 }}>No sessions yet.</div>
              ) : (
                <div style={{ overflowX: "auto" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
                    <thead><tr style={{ color: "#64748b", textAlign: "left" }}>
                      <th style={{ padding: "4px 8px" }}>State</th><th style={{ padding: "4px 8px" }}>Client</th><th style={{ padding: "4px 8px" }}>Server</th><th style={{ padding: "4px 8px" }}>When</th>
                    </tr></thead>
                    <tbody>
                      {profile.recent_sessions.slice(0, 10).map((s) => (
                        <tr key={s.session_id} style={{ color: s.flagged ? "#f87171" : "#e2e8f0" }}>
                          <td style={{ padding: "4px 8px" }}>{s.state}</td>
                          <td style={{ padding: "4px 8px" }}>{s.client_score}</td>
                          <td style={{ padding: "4px 8px" }}>{s.server_score}</td>
                          <td style={{ padding: "4px 8px", color: "#64748b" }}>{fmtDate(s.submitted_at)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>

            {/* Reward history */}
            <div>
              <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "#e2e8f0" }}>Reward history</div>
              {profile.rewards.length === 0 ? (
                <div style={{ color: "#64748b", fontSize: 12 }}>No rewards yet.</div>
              ) : (
                <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                  {profile.rewards.slice(0, 10).map((r) => (
                    <div key={r.id} style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
                      <span style={{ color: "#94a3b8" }}>{r.reason}</span>
                      <span style={{ color: "#e2e8f0" }}>{nim(r.amount_nim)} NIM</span>
                      <span style={{ color: r.status === "sent" ? "#4caf50" : "#e0a030" }}>{r.status}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
