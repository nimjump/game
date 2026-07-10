"use client";

import { useEffect, useState, useMemo } from "react";
import { fetchPlayersList, searchPlayer, type RegisteredPlayer, type PlayerProfile } from "@/lib/api";
import DeviceBreakdownCard from "./DeviceBreakdownCard";
import NimiqAvatar from "./NimiqAvatar";

function fmtDate(ts: number) {
  if (!ts) return "—";
  // Pinned to UTC+3 — see AnalyticsTab.tsx's fmt() for why.
  return new Date(ts * 1000).toLocaleString(undefined, { timeZone: "Europe/Istanbul" });
}

function fmtRelative(ts: number) {
  if (!ts) return "—";
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function nim(n?: number) { return (n ?? 0).toFixed(2); }

// flagEmoji — computes a country flag emoji from a 2-letter ISO code via the
// Unicode "regional indicator symbol" trick (each letter A-Z maps to
// U+1F1E6..U+1F1FF in the same order) — no bundled flag image assets
// needed. Returns a neutral globe for unknown/private/malformed codes.
function flagEmoji(countryCode: string): string {
  const cc = (countryCode || "").toUpperCase();
  if (cc.length !== 2 || cc === "XX" || !/^[A-Z]{2}$/.test(cc)) return "🌐";
  const base = 0x1f1e6;
  const chars = [...cc].map((c) => base + (c.charCodeAt(0) - 65));
  return String.fromCodePoint(...chars);
}

const PAGE_SIZE = 50;

export default function PlayersListTab() {
  const [players, setPlayers] = useState<RegisteredPlayer[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [sortBy, setSortBy] = useState<"registered" | "last_seen" | "sessions" | "nim">("registered");

  // ── Player detail modal ──────────────────────────────────────────────
  const [detailFor, setDetailFor] = useState<string | null>(null); // player_id
  const [detail, setDetail] = useState<PlayerProfile | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState("");

  function openDetail(playerID: string) {
    setDetailFor(playerID);
    setDetail(null);
    setDetailError("");
    setDetailLoading(true);
    searchPlayer(playerID)
      .then((p) => {
        if (!p) { setDetailError("Player not found."); return; }
        setDetail(p);
      })
      .catch((e) => setDetailError(String(e instanceof Error ? e.message : e)))
      .finally(() => setDetailLoading(false));
  }

  function closeDetail() {
    setDetailFor(null);
    setDetail(null);
    setDetailError("");
  }

  function load(off: number) {
    setLoading(true);
    fetchPlayersList(PAGE_SIZE, off)
      .then((res) => {
        setPlayers(res.players ?? []);
        setTotal(res.total ?? 0);
        setOffset(off);
        setError("");
      })
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }

  useEffect(() => { load(0); }, []);

  const filtered = useMemo(() => {
    let list = [...players];

    if (search.trim()) {
      const q = search.trim().toLowerCase();
      list = list.filter(
        (p) =>
          p.nickname?.toLowerCase().includes(q) ||
          p.player_id?.toLowerCase().includes(q)
      );
    }

    list.sort((a, b) => {
      if (sortBy === "registered") return (b.registered_at ?? 0) - (a.registered_at ?? 0);
      if (sortBy === "last_seen") return (b.last_seen ?? 0) - (a.last_seen ?? 0);
      if (sortBy === "sessions") return (b.session_count ?? 0) - (a.session_count ?? 0);
      if (sortBy === "nim") return (b.total_nim_received ?? 0) - (a.total_nim_received ?? 0);
      return 0;
    });

    return list;
  }, [players, search, sortBy]);

  return (
    <div style={{ padding: 24 }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 16, marginBottom: 24, flexWrap: "wrap" }}>
        <h2 style={{ margin: 0, fontSize: 20, fontWeight: 700 }}>Registered Players</h2>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatPill label="Total" value={total} color="#6366f1" />
        </div>
        <button
          onClick={() => load(offset)}
          style={{ marginLeft: "auto", padding: "6px 14px", borderRadius: 8, border: "1px solid #334155", background: "#1e293b", color: "#e2e8f0", cursor: "pointer", fontSize: 13 }}
        >
          ↻ Refresh
        </button>
      </div>

      <DeviceBreakdownCard />

      {/* Controls */}
      <div style={{ display: "flex", gap: 10, marginBottom: 16, flexWrap: "wrap", alignItems: "center" }}>
        <input
          type="text"
          placeholder="Search nickname or wallet… (current page only)"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ flex: "1 1 220px", padding: "8px 12px", borderRadius: 8, border: "1px solid #334155", background: "#0f172a", color: "#e2e8f0", fontSize: 14, minWidth: 180 }}
        />
        <select
          value={sortBy}
          onChange={(e) => setSortBy(e.target.value as "registered" | "last_seen" | "sessions" | "nim")}
          style={{ padding: "8px 12px", borderRadius: 8, border: "1px solid #334155", background: "#0f172a", color: "#e2e8f0", fontSize: 14 }}
        >
          <option value="registered">Sort: Newest registered</option>
          <option value="last_seen">Sort: Last seen</option>
          <option value="sessions">Sort: Most sessions</option>
          <option value="nim">Sort: Most NIM received</option>
        </select>
        <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "#64748b", marginLeft: "auto" }}>
          <span>{total === 0 ? "0 players" : `${offset + 1}–${Math.min(offset + players.length, total)} of ${total}`}</span>
          <button
            onClick={() => load(Math.max(0, offset - PAGE_SIZE))}
            disabled={loading || offset === 0}
            style={{ padding: "4px 10px", borderRadius: 6, border: "1px solid #334155", background: "#1e293b", color: "#e2e8f0", cursor: "pointer", fontSize: 12 }}
          >
            ← Prev
          </button>
          <button
            onClick={() => load(offset + PAGE_SIZE)}
            disabled={loading || offset + players.length >= total}
            style={{ padding: "4px 10px", borderRadius: 6, border: "1px solid #334155", background: "#1e293b", color: "#e2e8f0", cursor: "pointer", fontSize: 12 }}
          >
            Next →
          </button>
        </div>
      </div>

      {error && (
        <div style={{ background: "#1e1010", border: "1px solid #7f1d1d", borderRadius: 8, padding: "10px 14px", color: "#fca5a5", marginBottom: 16 }}>
          {error}
        </div>
      )}

      {loading ? (
        <div style={{ color: "#64748b", textAlign: "center", padding: 48 }}>Loading players…</div>
      ) : filtered.length === 0 ? (
        <div style={{ color: "#64748b", textAlign: "center", padding: 48 }}>No players found.</div>
      ) : (
        <>
          <div style={{ color: "#64748b", fontSize: 13, marginBottom: 10 }}>
            Showing {filtered.length} of {total} players
          </div>
          <div style={{ overflowX: "auto", borderRadius: 10, border: "1px solid #1e293b" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 14 }}>
              <thead>
                <tr style={{ background: "#0f172a", color: "#94a3b8", textAlign: "left" }}>
                  <th style={th}>Player</th>
                  <th style={th}>Wallet</th>
                  <th style={th}>Sessions</th>
                  <th style={th}>Daily Quests</th>
                  <th style={th}>Rank (D/W)</th>
                  <th style={th}>Streak</th>
                  <th style={th}>Daily Cap</th>
                  <th style={th}>Total NIM</th>
                  <th style={th}>Last Seen</th>
                  <th style={th}>Registered</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((p, i) => (
                  <PlayerRow key={p.player_id} player={p} even={i % 2 === 0} onClick={() => openDetail(p.player_id)} />
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {detailFor && (
        <PlayerDetailModal
          playerID={detailFor}
          profile={detail}
          loading={detailLoading}
          error={detailError}
          onClose={closeDetail}
        />
      )}
    </div>
  );
}

function PlayerRow({ player, even, onClick }: { player: RegisteredPlayer; even: boolean; onClick: () => void }) {
  return (
    <tr
      onClick={onClick}
      style={{ background: even ? "#0f172a" : "#111827", borderBottom: "1px solid #1e293b", cursor: "pointer" }}
      onMouseEnter={(e) => (e.currentTarget.style.background = "#1e293b")}
      onMouseLeave={(e) => (e.currentTarget.style.background = even ? "#0f172a" : "#111827")}
    >
      <td style={td}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <NimiqAvatar address={player.player_id} size={36} />
          <span style={{ fontWeight: 600, color: "#e2e8f0" }}>
            {player.nickname || <span style={{ color: "#64748b" }}>No nickname</span>}
          </span>
        </div>
      </td>
      <td style={{ ...td, fontFamily: "monospace", fontSize: 12, color: "#94a3b8" }}>
        {player.player_id
          ? player.player_id.length > 20
            ? player.player_id.slice(0, 10) + "…" + player.player_id.slice(-6)
            : player.player_id
          : "—"}
      </td>
      <td style={{ ...td, color: "#e2e8f0", fontWeight: 600 }}>{player.session_count ?? 0}</td>
      <td style={td}>
        <QuestBar completed={player.quests_completed ?? 0} total={player.quests_total ?? 5} />
      </td>
      <td style={{ ...td, fontSize: 13 }}>
        <span style={{ color: player.daily_rank ? "#e2e8f0" : "#475569" }}>
          {player.daily_rank ? `#${player.daily_rank}` : "—"}
        </span>
        <span style={{ color: "#475569" }}> / </span>
        <span style={{ color: player.weekly_rank ? "#e2e8f0" : "#475569" }}>
          {player.weekly_rank ? `#${player.weekly_rank}` : "—"}
        </span>
      </td>
      <td style={{ ...td, fontSize: 13 }}>
        {player.streak > 0 ? (
          <span style={{ color: "#e0a030", fontWeight: 600 }}>🔥 {player.streak}</span>
        ) : (
          <span style={{ color: "#475569" }}>—</span>
        )}
      </td>
      <td style={td}>
        <DailyCapBar earned={player.daily_cap?.daily_earned ?? 0} cap={player.daily_cap?.daily_cap ?? 0} />
      </td>
      <td style={{ ...td, color: "#4caf50", fontWeight: 600 }}>{nim(player.total_nim_received)}</td>
      <td style={{ ...td, color: "#94a3b8", fontSize: 13 }}>{fmtRelative(player.last_seen ?? 0)}</td>
      <td style={{ ...td, color: "#94a3b8", fontSize: 12 }}>{fmtDate(player.registered_at)}</td>
    </tr>
  );
}

function QuestBar({ completed, total }: { completed: number; total: number }) {
  const pct = total > 0 ? Math.min(100, Math.round((completed / total) * 100)) : 0;
  const color = pct >= 100 ? "#4caf50" : pct > 0 ? "#e0a030" : "#475569";
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 110 }}>
      <div style={{ width: 60, height: 6, borderRadius: 3, background: "#1e293b", overflow: "hidden" }}>
        <div style={{ width: `${pct}%`, height: "100%", background: color, borderRadius: 3 }} />
      </div>
      <span style={{ fontSize: 12, color: "#94a3b8", whiteSpace: "nowrap" }}>{completed}/{total}</span>
    </div>
  );
}

function DailyCapBar({ earned, cap }: { earned: number; cap: number }) {
  if (cap <= 0) return <span style={{ color: "#475569", fontSize: 12 }}>—</span>;
  const pct = Math.min(100, Math.round((earned / cap) * 100));
  const color = pct >= 100 ? "#e05555" : pct > 70 ? "#e0a030" : "#4caf50";
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 130 }} title={`${nim(earned)} / ${nim(cap)} NIM today`}>
      <div style={{ width: 60, height: 6, borderRadius: 3, background: "#1e293b", overflow: "hidden" }}>
        <div style={{ width: `${pct}%`, height: "100%", background: color, borderRadius: 3 }} />
      </div>
      <span style={{ fontSize: 12, color: "#94a3b8", whiteSpace: "nowrap" }}>{nim(earned)}/{nim(cap)}</span>
    </div>
  );
}

function StatPill({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div style={{ background: color + "18", border: `1px solid ${color}44`, borderRadius: 8, padding: "4px 12px", display: "flex", gap: 6, alignItems: "center" }}>
      <span style={{ color, fontWeight: 700 }}>{value}</span>
      <span style={{ color: "#94a3b8", fontSize: 13 }}>{label}</span>
    </div>
  );
}

// ── Player detail modal ────────────────────────────────────────────────────
function PlayerDetailModal({
  playerID, profile, loading, error, onClose,
}: {
  playerID: string;
  profile: PlayerProfile | null;
  loading: boolean;
  error: string;
  onClose: () => void;
}) {
  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed", inset: 0, background: "rgba(0,0,0,.65)",
        display: "flex", alignItems: "flex-start", justifyContent: "center",
        padding: "40px 16px", zIndex: 999, overflowY: "auto",
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: "#0f172a", border: "1px solid #1e293b", borderRadius: 12,
          padding: 24, maxWidth: 720, width: "100%", boxShadow: "0 8px 32px rgba(0,0,0,.5)",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
          <NimiqAvatar address={playerID} size={44} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontWeight: 700, fontSize: 16, color: "#e2e8f0" }}>
              {profile?.nickname || <span style={{ color: "#64748b" }}>No nickname</span>}
            </div>
            <div style={{ fontFamily: "monospace", fontSize: 11, color: "#64748b", wordBreak: "break-all" }}>
              {playerID}
            </div>
            {profile?.device && (
              <div style={{ fontSize: 11, color: "#64748b", marginTop: 2 }}>
                {profile.device.platform || "?"} · {profile.device.screen || "?"} · DPR {profile.device.dpr || "?"}
              </div>
            )}
          </div>
          <button
            onClick={onClose}
            style={{ padding: "6px 12px", borderRadius: 8, border: "1px solid #334155", background: "#1e293b", color: "#e2e8f0", cursor: "pointer", fontSize: 13 }}
          >
            ✕ Close
          </button>
        </div>

        {loading && <div style={{ color: "#64748b", textAlign: "center", padding: 32 }}>Loading…</div>}
        {error && !loading && (
          <div style={{ background: "#1e1010", border: "1px solid #7f1d1d", borderRadius: 8, padding: "10px 14px", color: "#fca5a5" }}>
            {error}
          </div>
        )}

        {profile && !loading && (
          <>
            {/* Stats */}
            <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 18 }}>
              <StatPill label="Total NIM received" value={Number(nim(profile.total_nim_received))} color="#4caf50" />
              <StatPill label="Streak (days)" value={profile.streak?.count ?? 0} color="#e0a030" />
              <StatPill label="Best score" value={profile.stats.best_score} color="#4caf50" />
              <StatPill label="Games" value={profile.stats.total_games} color="#6366f1" />
              <StatPill label="Kills" value={profile.stats.total_kills} color="#e0a030" />
              <StatPill label="Platforms" value={profile.stats.total_platforms} color="#22d3ee" />
              <StatPill label="Ticks" value={profile.stats.total_ticks} color="#94a3b8" />
              <StatPill label="Cosmetics owned" value={profile.cosmetics?.owned?.length ?? 0} color="#c084fc" />
            </div>

            {/* Equipped cosmetics */}
            {profile.cosmetics && Object.keys(profile.cosmetics.equipped || {}).length > 0 && (
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 18, fontSize: 13 }}>
                <div style={{ color: "#64748b", marginRight: 4 }}>Equipped:</div>
                {Object.entries(profile.cosmetics.equipped).map(([slot, itemId]) => (
                  <span
                    key={slot}
                    style={{ background: "#2a1e40", border: "1px solid #4c1d95", borderRadius: 6, padding: "2px 8px", color: "#d8b4fe" }}
                  >
                    {slot}: {itemId}
                  </span>
                ))}
              </div>
            )}

            {/* Leaderboard + daily cap */}
            <div style={{ display: "flex", gap: 24, flexWrap: "wrap", marginBottom: 18, fontSize: 13 }}>
              <div>
                <div style={{ color: "#64748b", marginBottom: 4 }}>Daily rank</div>
                <div style={{ color: "#e2e8f0", fontWeight: 600 }}>
                  {profile.leaderboard.daily_rank ? `#${profile.leaderboard.daily_rank}` : "—"}
                </div>
              </div>
              <div>
                <div style={{ color: "#64748b", marginBottom: 4 }}>Weekly rank</div>
                <div style={{ color: "#e2e8f0", fontWeight: 600 }}>
                  {profile.leaderboard.weekly_rank ? `#${profile.leaderboard.weekly_rank}` : "—"}
                </div>
              </div>
              <div>
                <div style={{ color: "#64748b", marginBottom: 4 }}>Daily cap</div>
                <DailyCapBar earned={profile.daily_cap?.daily_earned ?? 0} cap={profile.daily_cap?.daily_cap ?? 0} />
              </div>
              <div>
                <div style={{ color: "#64748b", marginBottom: 4 }}>Quest NIM (today / claimed)</div>
                <div style={{ color: "#e2e8f0", fontWeight: 600 }}>
                  {nim(profile.quest_nim_today)} / {nim(profile.quest_nim_claimed)}
                </div>
              </div>
            </div>

            {/* Quests */}
            <div style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "#e2e8f0" }}>Today's quests</div>
              {profile.quests.length === 0 ? (
                <div style={{ color: "#64748b", fontSize: 12 }}>No quests.</div>
              ) : (
                <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                  {profile.quests.map((q) => (
                    <div key={q.id} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12 }}>
                      <span style={{ color: q.completed ? "#4caf50" : "#94a3b8", minWidth: 16 }}>
                        {q.completed ? "✓" : "○"}
                      </span>
                      <span style={{ color: "#e2e8f0", flex: 1 }}>{q.description}</span>
                      <span style={{ color: "#64748b" }}>{q.progress}/{q.target}</span>
                      <span style={{ color: "#e0a030" }}>{nim(q.reward_nim)} NIM</span>
                      {q.claimed && <span className="badge badge-green" style={{ fontSize: 10 }}>claimed</span>}
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Connection IPs */}
            <div style={{ marginBottom: 18 }}>
              <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "#e2e8f0" }}>Connection IPs</div>
              {!profile.ips || profile.ips.length === 0 ? (
                <div style={{ color: "#64748b", fontSize: 12 }}>No IP history recorded yet.</div>
              ) : (
                <div style={{ overflowX: "auto" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
                    <thead>
                      <tr style={{ color: "#64748b", textAlign: "left" }}>
                        <th style={{ padding: "4px 8px" }}>Country</th>
                        <th style={{ padding: "4px 8px" }}>IP</th>
                        <th style={{ padding: "4px 8px" }}>Logins</th>
                        <th style={{ padding: "4px 8px" }}>First seen</th>
                        <th style={{ padding: "4px 8px" }}>Last seen</th>
                      </tr>
                    </thead>
                    <tbody>
                      {[...profile.ips]
                        .sort((a, b) => (b.last_seen ?? 0) - (a.last_seen ?? 0))
                        .map((ipRec) => (
                          <tr key={ipRec.ip} style={{ color: "#e2e8f0" }}>
                            <td style={{ padding: "4px 8px", whiteSpace: "nowrap" }}>
                              <span style={{ marginRight: 6 }}>{flagEmoji(ipRec.country_code)}</span>
                              <span style={{ color: "#94a3b8" }}>{ipRec.country_name || "Unknown"}</span>
                            </td>
                            <td style={{ padding: "4px 8px", fontFamily: "monospace", color: "#e2e8f0" }}>{ipRec.ip}</td>
                            <td style={{ padding: "4px 8px", color: "#94a3b8" }}>{ipRec.count}</td>
                            <td style={{ padding: "4px 8px", color: "#64748b" }}>{fmtDate(ipRec.first_seen)}</td>
                            <td style={{ padding: "4px 8px", color: "#64748b" }}>{fmtRelative(ipRec.last_seen)}</td>
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
                    <thead>
                      <tr style={{ color: "#64748b", textAlign: "left" }}>
                        <th style={{ padding: "4px 8px" }}>State</th>
                        <th style={{ padding: "4px 8px" }}>Client</th>
                        <th style={{ padding: "4px 8px" }}>Server</th>
                        <th style={{ padding: "4px 8px" }}>When</th>
                      </tr>
                    </thead>
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

const th: React.CSSProperties = {
  padding: "10px 14px",
  fontWeight: 600,
  fontSize: 12,
  textTransform: "uppercase",
  letterSpacing: "0.05em",
  borderBottom: "1px solid #1e293b",
};

const td: React.CSSProperties = {
  padding: "10px 14px",
  verticalAlign: "middle",
};

