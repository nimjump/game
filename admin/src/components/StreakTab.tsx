"use client";
import { useEffect, useState, useCallback } from "react";
import {
  fetchStreaks, fetchAppConfig, saveAppConfig,
  type StreakPlayerRow, type AppConfig,
} from "@/lib/api";

function nim(n?: number) { return (n ?? 0).toFixed(4); }
function fmt(ts?: number) {
  if (!ts) return "—";
  // Pinned to UTC+3 — see AnalyticsTab.tsx's fmt() for why.
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}

// Backend defaults (backend/game/streak_reward.go's defaultStreakReward*NIM /
// ip_reward_guard.go's defaultMaxRewardAccountsPerIP) — used to prefill the
// inputs when the admin config doesn't have an explicit value set yet, so
// the form shows what's ACTUALLY in effect right now, not blank fields.
const DEFAULT_BASE = 0.2;
const DEFAULT_EXTRA = 0.5;
const DEFAULT_MAX = 10.0;
const DEFAULT_MAX_ACCOUNTS = 2;

const PAGE_SIZE = 50;

export default function StreakTab() {
  // ── Player table + aggregate stats ──
  const [players, setPlayers] = useState<StreakPlayerRow[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [aggTotalNIM, setAggTotalNIM] = useState(0);
  const [aggClaims, setAggClaims] = useState(0);
  const [aggUnique, setAggUnique] = useState(0);
  const [aggActive, setAggActive] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async (off: number) => {
    setLoading(true); setError("");
    try {
      const res = await fetchStreaks(PAGE_SIZE, off);
      setPlayers(res.players);
      setTotal(res.total);
      setOffset(off);
      setAggTotalNIM(res.total_nim_distributed);
      setAggClaims(res.total_claims);
      setAggUnique(res.unique_claimers);
      setAggActive(res.active_streaks);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(0); }, [load]);

  // ── Reward config (base/extra/max/max-accounts-per-IP) ──
  const [cfg, setCfg] = useState<AppConfig | null>(null);
  const [baseInput, setBaseInput] = useState("");
  const [extraInput, setExtraInput] = useState("");
  const [maxInput, setMaxInput] = useState("");
  const [maxAccountsInput, setMaxAccountsInput] = useState("");
  const [cfgLoading, setCfgLoading] = useState(true);
  const [cfgError, setCfgError] = useState("");
  const [savingKey, setSavingKey] = useState<string | null>(null);

  function syncCfgInputs(c: AppConfig) {
    setCfg(c);
    setBaseInput(String(c.streak_reward_base_nim ?? DEFAULT_BASE));
    setExtraInput(String(c.streak_reward_extra_per_day_nim ?? DEFAULT_EXTRA));
    setMaxInput(String(c.streak_reward_max_nim ?? DEFAULT_MAX));
    setMaxAccountsInput(String(c.max_reward_accounts_per_ip ?? DEFAULT_MAX_ACCOUNTS));
  }

  const loadCfg = useCallback(async () => {
    setCfgLoading(true); setCfgError("");
    try {
      syncCfgInputs(await fetchAppConfig());
    } catch (e) {
      setCfgError(String(e instanceof Error ? e.message : e));
    } finally {
      setCfgLoading(false);
    }
  }, []);

  useEffect(() => { loadCfg(); }, [loadCfg]);

  async function saveBase() {
    const n = parseFloat(baseInput);
    if (!Number.isFinite(n) || n < 0) { alert("Base reward must be a number ≥ 0."); return; }
    setSavingKey("base");
    try { syncCfgInputs(await saveAppConfig({ streak_reward_base_nim: n })); }
    catch (e) { alert("Error: " + String(e)); }
    finally { setSavingKey(null); }
  }
  async function saveExtra() {
    const n = parseFloat(extraInput);
    if (!Number.isFinite(n) || n < 0) { alert("Extra-per-day must be a number ≥ 0."); return; }
    setSavingKey("extra");
    try { syncCfgInputs(await saveAppConfig({ streak_reward_extra_per_day_nim: n })); }
    catch (e) { alert("Error: " + String(e)); }
    finally { setSavingKey(null); }
  }
  async function saveMax() {
    const n = parseFloat(maxInput);
    if (!Number.isFinite(n) || n < 0) { alert("Max reward must be a number ≥ 0."); return; }
    setSavingKey("max");
    try { syncCfgInputs(await saveAppConfig({ streak_reward_max_nim: n })); }
    catch (e) { alert("Error: " + String(e)); }
    finally { setSavingKey(null); }
  }
  async function saveMaxAccounts() {
    const n = parseInt(maxAccountsInput, 10);
    if (!Number.isFinite(n) || n < 1) { alert("Max accounts per IP must be a whole number ≥ 1."); return; }
    setSavingKey("max_accounts");
    try { syncCfgInputs(await saveAppConfig({ max_reward_accounts_per_ip: n })); }
    catch (e) { alert("Error: " + String(e)); }
    finally { setSavingKey(null); }
  }

  // Live preview of the formula with whatever's currently typed in — lets
  // the admin see "day 7 pays X" before hitting Save on anything.
  const previewBase = parseFloat(baseInput);
  const previewExtra = parseFloat(extraInput);
  const previewMax = parseFloat(maxInput);
  const previewOk = [previewBase, previewExtra, previewMax].every(Number.isFinite);
  function previewDay(day: number) {
    if (!previewOk) return null;
    return Math.min(previewBase + previewExtra * (day - 1), previewMax);
  }

  const pageStart = total === 0 ? 0 : offset + 1;
  const pageEnd = Math.min(offset + players.length, total);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

      {/* ── Aggregate stats ── */}
      <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 160px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>NIM distributed (all-time)</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "var(--orange)" }}>{nim(aggTotalNIM)}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Total claims</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{aggClaims}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Unique claimers</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{aggUnique}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Active streaks right now</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{aggActive}</div>
        </div>
      </div>

      {/* ── Reward config ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8 }}>Reward Formula</div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 12, lineHeight: 1.6 }}>
          reward(day) = min(Base + Extra × (day − 1), Max) — claimed once per day from the lobby
          streak badge, not auto-paid. Changes apply to the next claim immediately, nothing needs
          a restart.
        </div>
        {cfgError && <div style={{ color: "var(--red)", fontSize: 12, marginBottom: 8 }}>{cfgError}</div>}
        {cfgLoading || !cfg ? (
          <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 12 }}>Loading…</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{ fontSize: 13, color: "var(--text-muted)", width: 150 }}>Base (day 1, NIM):</span>
              <input type="number" min={0} step="any" value={baseInput}
                onChange={e => setBaseInput(e.target.value)}
                style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
              <button className="btn" disabled={savingKey === "base" || baseInput === String(cfg.streak_reward_base_nim ?? DEFAULT_BASE)} onClick={saveBase}>
                {savingKey === "base" ? "…" : "Save"}
              </button>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{ fontSize: 13, color: "var(--text-muted)", width: 150 }}>Extra per day (NIM):</span>
              <input type="number" min={0} step="any" value={extraInput}
                onChange={e => setExtraInput(e.target.value)}
                style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
              <button className="btn" disabled={savingKey === "extra" || extraInput === String(cfg.streak_reward_extra_per_day_nim ?? DEFAULT_EXTRA)} onClick={saveExtra}>
                {savingKey === "extra" ? "…" : "Save"}
              </button>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{ fontSize: 13, color: "var(--text-muted)", width: 150 }}>Max (NIM):</span>
              <input type="number" min={0} step="any" value={maxInput}
                onChange={e => setMaxInput(e.target.value)}
                style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
              <button className="btn" disabled={savingKey === "max" || maxInput === String(cfg.streak_reward_max_nim ?? DEFAULT_MAX)} onClick={saveMax}>
                {savingKey === "max" ? "…" : "Save"}
              </button>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <span style={{ fontSize: 13, color: "var(--text-muted)", width: 150 }}>Max accounts / IP / day:</span>
              <input type="number" min={1} step={1} value={maxAccountsInput}
                onChange={e => setMaxAccountsInput(e.target.value)}
                style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
              <button className="btn" disabled={savingKey === "max_accounts" || maxAccountsInput === String(cfg.max_reward_accounts_per_ip ?? DEFAULT_MAX_ACCOUNTS)} onClick={saveMaxAccounts}>
                {savingKey === "max_accounts" ? "…" : "Save"}
              </button>
              <span style={{ fontSize: 11, color: "var(--text-muted)" }}>
                Anti-multi-accounting — also applies to quest claims and in-game coin rewards (not leaderboard payouts).
              </span>
            </div>

            {previewOk && (
              <div style={{ marginTop: 4, display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
                <span style={{ fontSize: 11, color: "var(--text-muted)" }}>Preview:</span>
                {[1, 2, 3, 5, 7, 10, 14, 30].map(d => (
                  <span key={d} className="badge" style={{ fontSize: 11 }}>
                    day {d}: {nim(previewDay(d) ?? 0)}
                  </span>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      {/* ── Per-player breakdown ── */}
      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <button onClick={() => load(offset)} className="btn" style={{ fontSize: 12, padding: "6px 12px" }} disabled={loading}>
          {loading ? "Loading…" : "Refresh"}
        </button>
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "var(--text-muted)" }}>
          <span>{total === 0 ? "0 players" : `${pageStart}–${pageEnd} of ${total}`}</span>
          <button
            onClick={() => load(Math.max(0, offset - PAGE_SIZE))}
            className="btn" style={{ fontSize: 12, padding: "4px 10px" }}
            disabled={loading || offset === 0}
          >
            ← Prev
          </button>
          <button
            onClick={() => load(offset + PAGE_SIZE)}
            className="btn" style={{ fontSize: 12, padding: "4px 10px" }}
            disabled={loading || offset + players.length >= total}
          >
            Next →
          </button>
        </div>
      </div>

      {error && <div style={{ padding: 16, color: "var(--red)", fontSize: 13 }}>{error}</div>}

      <div className="card" style={{ padding: 0, overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ textAlign: "left", fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>
              <th style={{ padding: "10px 14px" }}>Player</th>
              <th style={{ padding: "10px 14px" }}>Current streak</th>
              <th style={{ padding: "10px 14px" }}>Longest run</th>
              <th style={{ padding: "10px 14px" }}>Total claimed</th>
              <th style={{ padding: "10px 14px" }}>Claims</th>
              <th style={{ padding: "10px 14px" }}>Last claim</th>
            </tr>
          </thead>
          <tbody>
            {players.map(p => (
              <tr key={p.player_id} style={{ borderTop: "1px solid var(--border)" }}>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>
                  {p.nickname || <span style={{ fontFamily: "monospace", color: "var(--text-muted)" }}>{p.player_id.slice(0, 12)}…</span>}
                </td>
                <td style={{ padding: "10px 14px" }}>
                  {p.streak_day > 0 ? (
                    <span className="badge badge-green">{p.streak_day} day{p.streak_day === 1 ? "" : "s"}</span>
                  ) : (
                    <span style={{ color: "var(--text-muted)", fontSize: 12 }}>lapsed</span>
                  )}
                </td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>{p.longest_run}</td>
                <td style={{ padding: "10px 14px", fontSize: 12, color: "var(--orange)", fontWeight: 600 }}>{nim(p.total_claimed_nim)} NIM</td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>{p.claims_count}</td>
                <td style={{ padding: "10px 14px", fontSize: 12, color: "var(--text-muted)" }}>{fmt(p.last_claim_at)}</td>
              </tr>
            ))}
            {players.length === 0 && !loading && (
              <tr><td colSpan={6} style={{ padding: 20, textAlign: "center", color: "var(--text-muted)" }}>No streak activity yet.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
