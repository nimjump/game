"use client";

import { useEffect, useState, useMemo } from "react";
import { fetchPlayersList, type RegisteredPlayer } from "@/lib/api";
import NimiqAvatar from "./NimiqAvatar";

function fmtDate(ts: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString();
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

const PAGE_SIZE = 50;

export default function PlayersListTab() {
  const [players, setPlayers] = useState<RegisteredPlayer[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [sortBy, setSortBy] = useState<"registered" | "last_seen" | "sessions">("registered");

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
          onChange={(e) => setSortBy(e.target.value as "registered" | "last_seen" | "sessions")}
          style={{ padding: "8px 12px", borderRadius: 8, border: "1px solid #334155", background: "#0f172a", color: "#e2e8f0", fontSize: 14 }}
        >
          <option value="registered">Sort: Newest registered</option>
          <option value="last_seen">Sort: Last seen</option>
          <option value="sessions">Sort: Most sessions</option>
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
                  <th style={th}>Daily Cap</th>
                  <th style={th}>Last Seen</th>
                  <th style={th}>Registered</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((p, i) => (
                  <PlayerRow key={p.player_id} player={p} even={i % 2 === 0} />
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

function PlayerRow({ player, even }: { player: RegisteredPlayer; even: boolean }) {
  return (
    <tr style={{ background: even ? "#0f172a" : "#111827", borderBottom: "1px solid #1e293b" }}>
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
      <td style={td}>
        <DailyCapBar earned={player.daily_cap?.daily_earned ?? 0} cap={player.daily_cap?.daily_cap ?? 0} />
      </td>
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
