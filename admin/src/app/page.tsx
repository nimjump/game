"use client";
import { useEffect, useState, useCallback } from "react";
import {
  fetchOverview, fetchAdminSessions, fetchClientLogs, fetchFailedReplays,
  type Session, type Overview, type ClientLogEntry, type FailedReplay,
} from "@/lib/api";
import StatCards        from "@/components/StatCards";
import OverviewTab      from "@/components/OverviewTab";
import SessionsTab      from "@/components/SessionsTab";
import FailedReplaysTab from "@/components/FailedReplaysTab";
import ClientLogsTab    from "@/components/ClientLogsTab";
import PlayerSearchTab  from "@/components/PlayerSearchTab";
import PlayersListTab   from "@/components/PlayersListTab";
import LeaderboardTab   from "@/components/LeaderboardTab";
import AnalyticsTab     from "@/components/AnalyticsTab";

// ── Types ──────────────────────────────────────────────────────────────────────
export type Tab =
  | "overview" | "active" | "completed" | "flagged" | "all"
  | "failed_replays" | "logs" | "players" | "players_search" | "leaderboard" | "analytics";

const TAB_LABELS: [Tab, string][] = [
  ["overview",        "Overview"],
  ["analytics",       "Analytics"],
  ["active",          "Active"],
  ["completed",       "Completed"],
  ["flagged",         "Flagged"],
  ["failed_replays",  "Failed"],
  ["all",             "All Sessions"],
  ["leaderboard",     "Leaderboard"],
  ["players",         "Players"],
  ["players_search",  "Player Search"],
  ["logs",            "Logs"],
];

function fmtDur(sec: number) {
  const m = Math.floor(sec / 60), s = sec % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

// ── Page ───────────────────────────────────────────────────────────────────────
export default function AdminPage() {
  const [tab,         setTab]         = useState<Tab>("overview");
  const [overview,    setOverview]    = useState<Overview | null>(null);
  const [sessions,    setSessions]    = useState<Session[]>([]);
  const [clientLogs,  setClientLogs]  = useState<ClientLogEntry[]>([]);
  const [logTotal,    setLogTotal]    = useState(0);
  const [logLevel,    setLogLevel]    = useState("");
  const [failedReps,  setFailedReps]  = useState<FailedReplay[]>([]);
  const [search,      setSearch]      = useState("");
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState("");
  const [autoRefresh, setAutoRefresh] = useState(true);

  // ── Loaders ──────────────────────────────────────────────────────────────────
  const loadOverview = useCallback(() => {
    setLoading(true); setError("");
    fetchOverview()
      .then(setOverview)
      .catch(e => setError(String(e)))
      .finally(() => setLoading(false));
  }, []);

  const loadSessions = useCallback((t: Tab, q?: string) => {
    const stateMap: Record<string, string | undefined> = {
      active: "active", completed: "completed", flagged: "flagged", all: undefined,
    };
    setLoading(true); setError("");
    fetchAdminSessions(stateMap[t], q || undefined)
      .then(setSessions)
      .catch(e => setError(String(e)))
      .finally(() => setLoading(false));
  }, []);

  const loadLogs = useCallback((level?: string) => {
    setLoading(true); setError("");
    fetchClientLogs(level || undefined)
      .then(res => { setClientLogs(res.logs); setLogTotal(res.total); })
      .catch(e => setError(String(e)))
      .finally(() => setLoading(false));
  }, []);

  const loadFailed = useCallback(() => {
    setLoading(true); setError("");
    fetchFailedReplays()
      .then(setFailedReps)
      .catch(e => setError(String(e)))
      .finally(() => setLoading(false));
  }, []);

  // ── Tab switch ───────────────────────────────────────────────────────────────
  const refresh = useCallback(() => {
    if (tab === "overview")       return loadOverview();
    if (tab === "logs")           return loadLogs(logLevel);
    if (tab === "failed_replays") return loadFailed();
    if (tab === "players")        return; // self-contained
    if (tab === "players_search") return; // self-contained
    if (tab === "leaderboard")    return; // self-contained
    if (tab === "analytics")      return; // self-contained
    loadSessions(tab, search);
  }, [tab, logLevel, search, loadOverview, loadLogs, loadFailed, loadSessions]);

  useEffect(() => { refresh(); }, [tab]); // eslint-disable-line

  // ── Auto-refresh overview every 5s ───────────────────────────────────────────
  useEffect(() => {
    if (!autoRefresh || tab !== "overview") return;
    const id = setInterval(loadOverview, 5000);
    return () => clearInterval(id);
  }, [autoRefresh, tab, loadOverview]);

  const isSessions = ["active", "completed", "flagged", "all"].includes(tab);

  return (
    <main style={{ maxWidth: 1200, margin: "0 auto", padding: "24px 16px" }}>

      {/* ── Header ── */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 20 }}>
        <div>
          <h1 style={{ fontSize: 20, fontWeight: 700, marginBottom: 2 }}>NimJump Admin Panel</h1>
          {overview && (
            <span style={{ color: "var(--text-muted)", fontSize: 12 }}>
              {fmtDur(overview.system.uptime_sec)} uptime &nbsp;·&nbsp;
              {overview.system.goroutines}g &nbsp;·&nbsp;
              {overview.system.heap_mb}MB &nbsp;·&nbsp;
              {overview.system.cpu_count} CPU
            </span>
          )}
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <label style={{ fontSize: 12, color: "var(--text-muted)", display: "flex", gap: 5, alignItems: "center", cursor: "pointer" }}>
            <input type="checkbox" checked={autoRefresh} onChange={e => setAutoRefresh(e.target.checked)} />
            Auto-refresh
          </label>
          <button className="btn" onClick={refresh}>Refresh</button>
        </div>
      </div>

      {/* ── Stat cards (only when overview data exists) ── */}
      {overview && (
        <StatCards ov={overview} activeTab={tab} onTabChange={t => setTab(t)} />
      )}

      {/* ── Tab bar ── */}
      <div style={{ display: "flex", gap: 6, marginBottom: 14, flexWrap: "wrap" }}>
        {TAB_LABELS.map(([t, label]) => (
          <button key={t}
            className={tab === t ? "btn btn-active" : "btn"}
            onClick={() => setTab(t)}
          >
            {label}
          </button>
        ))}
      </div>

      {/* ── Status ── */}
      {loading && tab !== "players" && tab !== "players_search" && tab !== "leaderboard" && tab !== "analytics" && (
        <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>Loading…</div>
      )}
      {error && <div style={{ padding: 16, color: "var(--red)", fontSize: 13 }}>{error}</div>}

      {/* ── Tab content ── */}
      {(tab === "players" || tab === "players_search" || tab === "leaderboard" || tab === "analytics" || !loading) && (
        <>
          {tab === "overview" && overview && (
            <OverviewTab ov={overview} />
          )}

          {tab === "failed_replays" && (
            <FailedReplaysTab items={failedReps} onRetryDone={loadFailed} />
          )}

          {tab === "logs" && (
            <ClientLogsTab
              logs={clientLogs}
              total={logTotal}
              levelFilter={logLevel}
              onLevelChange={lvl => { setLogLevel(lvl); loadLogs(lvl || undefined); }}
              onCleared={() => loadLogs(logLevel || undefined)}
            />
          )}

          {tab === "players" && (
            <PlayersListTab />
          )}

          {tab === "players_search" && (
            <PlayerSearchTab />
          )}

          {tab === "leaderboard" && (
            <LeaderboardTab />
          )}

          {tab === "analytics" && (
            <AnalyticsTab />
          )}

          {isSessions && (
            <SessionsTab
              sessions={sessions}
              showDuration={tab === "active"}
              searchValue={search}
              onSearch={q => setSearch(q)}
              onSearchSubmit={q => loadSessions(tab, q)}
              onActionDone={() => loadSessions(tab, search)}
            />
          )}
        </>
      )}

    </main>
  );
}
