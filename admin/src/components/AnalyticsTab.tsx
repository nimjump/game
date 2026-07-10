"use client";
import { useEffect, useState } from "react";
import { fetchAnalytics, type Analytics, type AnalyticsReward } from "@/lib/api";
import NimiqAvatar from "@/components/NimiqAvatar";

// ── helpers ────────────────────────────────────────────────────────────────────
function nim(n: number) { return (n ?? 0).toFixed(4); }
function fmtTime(sec: number) {
  if (!sec) return "0s";
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}
function fmt(ts: number) {
  if (!ts) return "—";
  // BUG FIX: was rendering in the admin browser's own local timezone, but
  // every period boundary on the backend (daily/weekly leaderboard, resets,
  // payouts — see backend/game/leaderboard.go's UTC3) is fixed UTC+3. A
  // session at 00:30 UTC+3 (backend buckets it as "today") rendered as
  // ~21:30 the PREVIOUS day in a browser set to e.g. UTC — exactly why the
  // same "daily" list could show two different calendar dates. Pin display
  // to the same UTC+3 the backend uses.
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}

// ── Stat card ──────────────────────────────────────────────────────────────────
function StatCard({
  label, value, sub, accent, wide,
}: {
  label: string;
  value: string | number;
  sub?: string;
  accent?: boolean;
  wide?: boolean;
}) {
  return (
    <div className="card" style={{
      padding: "14px 18px",
      flex: wide ? "1 1 200px" : "1 1 130px",
      minWidth: wide ? 180 : 120,
    }}>
      <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.04em" }}>
        {label}
      </div>
      <div style={{ fontSize: 22, fontWeight: 700, color: accent ? "var(--orange)" : "var(--text)" }}>
        {value}
      </div>
      {sub && <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

// ── Section header ─────────────────────────────────────────────────────────────
function SectionHeader({ title }: { title: string }) {
  return (
    <div style={{
      fontWeight: 700, fontSize: 13,
      borderBottom: "1px solid var(--border)",
      paddingBottom: 8, marginBottom: 12, marginTop: 8,
      color: "var(--orange)",
      letterSpacing: "0.03em",
    }}>
      {title}
    </div>
  );
}

// ── Payment row ────────────────────────────────────────────────────────────────
function PaymentRow({ r, showStatus }: { r: AnalyticsReward; showStatus?: boolean }) {
  return (
    <tr>
      <td>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <NimiqAvatar address={r.player_id} size={26} />
          <div>
            <div style={{ fontSize: 12, fontWeight: 600 }}>{r.nickname || "—"}</div>
            <div style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>
              {r.player_id ? r.player_id.slice(0, 16) + "…" : "—"}
            </div>
          </div>
        </div>
      </td>
      <td style={{ color: "var(--orange)", fontWeight: 700 }}>{nim(r.amount_nim)} NIM</td>
      <td style={{ fontSize: 11, color: "var(--text-muted)" }}>{r.reason}</td>
      {showStatus && (
        <td>
          <span style={{
            fontSize: 10, padding: "2px 6px", borderRadius: 4,
            background: r.status === "sent" ? "#1a3a1a" : r.status === "failed" ? "#3a1a1a" : "#2a2a1a",
            color: r.status === "sent" ? "var(--green)" : r.status === "failed" ? "var(--red)" : "var(--yellow)",
          }}>
            {r.status}
          </span>
        </td>
      )}
      <td style={{ fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap" }}>
        {r.status === "sent" ? fmt(r.sent_at ?? 0) : fmt(r.created_at)}
      </td>
      {r.tx_hash && (
        <td style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>
          {r.tx_hash.slice(0, 10)}…
        </td>
      )}
    </tr>
  );
}

// ── Main ───────────────────────────────────────────────────────────────────────
export default function AnalyticsTab() {
  const [data,    setData]    = useState<Analytics | null>(null);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState("");

  const load = async () => {
    setLoading(true); setError("");
    try { setData(await fetchAnalytics()); }
    catch (e: unknown) { setError(String(e instanceof Error ? e.message : e)); }
    finally { setLoading(false); }
  };

  useEffect(() => { load(); }, []);

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: "var(--text-muted)" }}>Loading analytics…</div>;
  if (error)   return <div style={{ padding: 16, color: "var(--red)" }}>{error}</div>;
  if (!data)   return null;

  const { players, sessions, playtime_sec, nim: nimData, reward_queue, recent_payments, queued_payments, nimiq_balance } = data;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>

      {/* Header row */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div style={{ fontSize: 12, color: "var(--text-muted)" }}>
          Today: <b>{data.today}</b> &nbsp;·&nbsp; Week from: <b>{data.week_start}</b>
        </div>
        <button className="btn" onClick={load}>Refresh</button>
      </div>

      {/* ── Nimiq balance ── */}
      <div>
        <SectionHeader title="Nimiq Account Balance" />
        <div className="card" style={{ padding: "16px 20px", display: "flex", alignItems: "center", gap: 20, flexWrap: "wrap" }}>
          {/* Avatar for the server wallet address */}
          {nimiq_balance.wallet_address && (
            <NimiqAvatar address={nimiq_balance.wallet_address} size={56} />
          )}
          <div>
            <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 4 }}>SERVER WALLET BALANCE</div>
            <div style={{
              fontSize: 32, fontWeight: 700,
              color: nimiq_balance.is_low ? "var(--red)" : "var(--orange)",
            }}>
              {nim(nimiq_balance.balance_nim)} <span style={{ fontSize: 16 }}>NIM</span>
            </div>
            {nimiq_balance.wallet_address && (
              <div style={{ fontSize: 11, fontFamily: "monospace", color: "var(--text-muted)", marginTop: 4 }}>
                {nimiq_balance.wallet_address}
              </div>
            )}
            {nimiq_balance.is_low && (
              <div style={{ fontSize: 12, color: "var(--red)", marginTop: 4 }}>
                ⚠ Low balance! Threshold: {nim(nimiq_balance.low_threshold)} NIM
              </div>
            )}
            {nimiq_balance.error && (
              <div style={{ fontSize: 12, color: "var(--red)", marginTop: 4 }}>
                Error: {nimiq_balance.error}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ── Players ── */}
      <div>
        <SectionHeader title="Players" />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatCard label="Total Registered" value={players.total} accent />
          <StatCard label="Active Today"     value={players.today} />
          <StatCard label="Active This Week" value={players.this_week} />
          <StatCard label="New Today"        value={players.new_today} accent />
          <StatCard label="New This Week"    value={players.new_week} />
        </div>
      </div>

      {/* ── Sessions ── */}
      <div>
        <SectionHeader title="Sessions" />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatCard label="Total"           value={sessions.total} />
          <StatCard label="Today"           value={sessions.today} accent />
          <StatCard label="This Week"       value={sessions.this_week} />
          <StatCard label="Completed"       value={sessions.completed} />
          <StatCard label="Flagged"         value={sessions.flagged} />
        </div>
      </div>

      {/* ── Play time ── */}
      <div>
        <SectionHeader title="Total Play Time" />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatCard label="All Time"    value={fmtTime(playtime_sec.total)} wide />
          <StatCard label="Today"       value={fmtTime(playtime_sec.today)} wide accent />
          <StatCard label="This Week"   value={fmtTime(playtime_sec.this_week)} wide />
        </div>
      </div>

      {/* ── NIM distributed ── */}
      <div>
        <SectionHeader title="NIM Distributed" />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatCard label="Total All Time"    value={nim(nimData.total_distributed) + " NIM"} accent wide />
          <StatCard label="Today"             value={nim(nimData.distributed_today) + " NIM"} wide />
          <StatCard label="This Week"         value={nim(nimData.distributed_this_week) + " NIM"} wide />
        </div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 10 }}>
          <StatCard label="Quests Total"      value={nim(nimData.quest_total) + " NIM"} wide />
          <StatCard label="Quests Today"      value={nim(nimData.quest_today) + " NIM"} wide accent />
          <StatCard label="Quests This Week"  value={nim(nimData.quest_this_week) + " NIM"} wide />
          <StatCard label="Leaderboard Total" value={nim(nimData.leaderboard_total) + " NIM"} wide />
          <StatCard label="Leaderboard Today" value={nim(nimData.leaderboard_today) + " NIM"} wide />
          <StatCard label="Leaderboard Week"  value={nim(nimData.leaderboard_this_week) + " NIM"} wide />
        </div>
      </div>

      {/* ── Reward queue ── */}
      <div>
        <SectionHeader title="Payment Queue" />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <StatCard label="Pending" value={reward_queue.pending} accent />
          <StatCard label="Failed"  value={reward_queue.failed}  />
          <StatCard label="Sent"    value={reward_queue.sent}    />
        </div>
      </div>

      {/* ── Queued payments ── */}
      {queued_payments?.length > 0 && (
        <div>
          <SectionHeader title={`Queued Payments (${queued_payments.length})`} />
          <div className="card">
            <table>
              <thead>
                <tr><th>Player</th><th>Amount</th><th>Reason</th><th>Status</th><th>Date</th></tr>
              </thead>
              <tbody>
                {queued_payments.map(r => <PaymentRow key={r.id} r={r} showStatus />)}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* ── Recent payments ── */}
      <div>
        <SectionHeader title="Recent Payments (Sent)" />
        <div className="card">
          {(!recent_payments || recent_payments.length === 0) ? (
            <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>No payments sent yet</div>
          ) : (
            <table>
              <thead>
                <tr><th>Player</th><th>Amount</th><th>Reason</th><th>Sent At</th><th>Tx</th></tr>
              </thead>
              <tbody>
                {recent_payments.slice(0, 5).map(r => <PaymentRow key={r.id} r={r} />)}
              </tbody>
            </table>
          )}
        </div>
      </div>

    </div>
  );
}
