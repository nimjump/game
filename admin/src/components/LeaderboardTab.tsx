"use client";
import { useEffect, useState } from "react";
import { fetchLeaderboard, type LBEntry } from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

type Period = "daily" | "weekly";

export default function LeaderboardTab() {
  const [period,  setPeriod]  = useState<Period>("daily");
  const [entries, setEntries] = useState<LBEntry[]>([]);
  const [label,   setLabel]   = useState("");
  const [enabled, setEnabled] = useState(true);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState("");

  const load = async (p: Period) => {
    setLoading(true); setError("");
    try {
      const res = await fetchLeaderboard(p, 100);
      setEntries(res.entries ?? []);
      setLabel(res.period || p);
      setEnabled(res.enabled ?? true);
    } catch (e: unknown) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(period); }, [period]);

  return (
    <div>
      {/* Period selector */}
      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        {(["daily", "weekly"] as Period[]).map(p => (
          <button key={p}
            className={period === p ? "btn btn-active" : "btn"}
            onClick={() => setPeriod(p)}
          >
            {p.charAt(0).toUpperCase() + p.slice(1)}
          </button>
        ))}
        <button className="btn" onClick={() => load(period)} disabled={loading}>
          Refresh
        </button>
        {label && (
          <span style={{ alignSelf: "center", fontSize: 12, color: "var(--text-muted)" }}>
            Period: {label}
          </span>
        )}
        {!enabled && (
          <span className="badge badge-yellow">⚠ {period} leaderboard is disabled (System tab)</span>
        )}
      </div>

      {error   && <div style={{ color: "var(--red)", marginBottom: 12 }}>{error}</div>}
      {loading && <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>Loading…</div>}

      {!loading && (
        <div className="card">
          {entries.length === 0 ? (
            <div style={{ padding: 40, textAlign: "center", color: "var(--text-muted)" }}>
              No entries yet
            </div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th style={{ width: 60 }}>Rank</th>
                  <th>Player</th>
                  <th>Score</th>
                </tr>
              </thead>
              <tbody>
                {entries.map(e => (
                  <tr key={e.player_id}
                    style={e.rank <= 3 ? { background: "var(--surface2)" } : {}}
                  >
                    <td>
                      <span style={{
                        fontSize: 16, fontWeight: 700,
                        color: e.rank === 1 ? "#FFD700"
                             : e.rank === 2 ? "#C0C0C0"
                             : e.rank === 3 ? "#CD7F32"
                             : "var(--text-muted)",
                      }}>
                        #{e.rank}
                      </span>
                    </td>
                    <td>
                      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                        <NimiqAvatar address={e.player_id} size={34} />
                        <div>
                          <div style={{ fontWeight: 600, color: "var(--orange)" }}>
                            {e.nickname || "—"}
                          </div>
                          <div style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>
                            {e.player_id ? e.player_id.slice(0, 22) + "…" : "—"}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td style={{ fontWeight: 700, fontSize: 16, color: "var(--orange)" }}>
                      {(e.server_score ?? e.score ?? 0).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  );
}
