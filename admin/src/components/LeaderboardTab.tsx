"use client";
import { useEffect, useState } from "react";
import {
  fetchLeaderboard, type LBEntry,
  fetchLeaderboardPrizes, saveLeaderboardPrizes, type LeaderboardConfig,
} from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

type Period = "daily" | "weekly";

function PrizesCard() {
  const [cfg, setCfg]         = useState<LeaderboardConfig | null>(null);
  const [saving, setSaving]   = useState(false);
  const [error, setError]     = useState("");
  const [savedAt, setSavedAt] = useState(0);

  useEffect(() => {
    fetchLeaderboardPrizes().then(setCfg).catch(e => setError(String(e)));
  }, []);

  const setVal = (period: "daily" | "weekly", rank: "first" | "second" | "third", raw: string) => {
    if (!cfg) return;
    const n = Number(raw);
    setCfg({ ...cfg, [period]: { ...cfg[period], [rank]: Number.isFinite(n) ? n : 0 } });
  };

  const save = async () => {
    if (!cfg) return;
    setSaving(true); setError("");
    try {
      await saveLeaderboardPrizes(cfg);
      setSavedAt(Date.now());
    } catch (e: unknown) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setSaving(false);
    }
  };

  if (!cfg) return null;

  const row = (label: string, period: "daily" | "weekly") => (
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
      <span style={{ fontSize: 13, color: "var(--text-muted)", width: 60 }}>{label}</span>
      {(["first", "second", "third"] as const).map(rank => (
        <label key={rank} style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 12 }}>
          {rank === "first" ? "🥇" : rank === "second" ? "🥈" : "🥉"}
          <input type="number" min={0} step="1" value={cfg[period][rank]}
            onChange={e => setVal(period, rank, e.target.value)}
            style={{ width: 70, padding: "4px 6px", fontSize: 13 }} />
          <span style={{ color: "var(--text-muted)" }}>NIM</span>
        </label>
      ))}
    </div>
  );

  return (
    <div className="card" style={{ padding: 16, marginBottom: 16 }}>
      <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 12 }}>Leaderboard Prizes</div>
      {row("Daily", "daily")}
      {row("Weekly", "weekly")}
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 8 }}>
        <button className="btn btn-active" disabled={saving} onClick={save}>
          {saving ? "Saving…" : "Save prizes"}
        </button>
        {savedAt > 0 && Date.now() - savedAt < 3000 && (
          <span style={{ fontSize: 12, color: "var(--green)" }}>Saved</span>
        )}
        {error && <span style={{ fontSize: 12, color: "var(--red)" }}>{error}</span>}
      </div>
      <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 8 }}>
        Applies to the next snapshot (end of period, or manual pay-winners) — doesn&apos;t change prizes already snapshotted/paid.
      </div>
    </div>
  );
}

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
      <PrizesCard />

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
