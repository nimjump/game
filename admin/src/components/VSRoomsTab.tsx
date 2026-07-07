"use client";
import { useEffect, useState, useCallback } from "react";
import { fetchVSRooms, sweepVSRooms, reconcileVSPayments, cancelVSRoomAdmin, type VSRoom } from "@/lib/api";

function nim(n?: number) { return (n ?? 0).toFixed(4); }
function fmt(ts?: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB");
}
function timeLeft(expiresAt: number, status: string) {
  if (["completed", "expired_payout", "expired_refunded", "cancelled"].includes(status)) return "—";
  const rem = expiresAt - Math.floor(Date.now() / 1000);
  if (rem <= 0) return "expired (pending sweep)";
  const h = Math.floor(rem / 3600), m = Math.floor((rem % 3600) / 60);
  return `${h}h ${m}m`;
}

const STATUS_COLORS: Record<string, string> = {
  awaiting_creator_pay:   "var(--text-muted)",
  awaiting_creator_play:  "var(--orange)",
  waiting_opponent:       "var(--text-muted)",
  awaiting_opponent_pay:  "var(--text-muted)",
  awaiting_opponent_play: "var(--orange)",
  completed:              "#4caf50",
  expired_payout:         "#4caf50",
  expired_refunded:       "#e0a030",
  cancelled:              "var(--text-muted)",
};

function StatusBadge({ status }: { status: string }) {
  return (
    <span style={{
      color: STATUS_COLORS[status] || "var(--text)",
      fontSize: 11,
      fontWeight: 700,
      textTransform: "uppercase",
      letterSpacing: "0.03em",
    }}>
      {status.replace(/_/g, " ")}
    </span>
  );
}

const PAGE_SIZE = 100;
// A single, generously-high limit used only for the summary KPI cards
// (active count / total / NIM volume / fee collected), which need to
// reflect ALL rooms, not just whatever page of the table is currently
// loaded. The backend already scans every room into memory to answer this
// regardless of the limit passed, so this costs nothing extra server-side.
const STATS_LIMIT = 1_000_000;

export default function VSRoomsTab() {
  const [rooms, setRooms] = useState<VSRoom[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [statsRooms, setStatsRooms] = useState<VSRoom[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<"all" | "active" | "completed">("active");
  const [sweeping, setSweeping] = useState(false);
  const [reconciling, setReconciling] = useState(false);
  const [cancelling, setCancelling] = useState<string | null>(null);

  async function doCancel(r: VSRoom) {
    const matched = !!r.opponent_id;
    const refunds: string[] = [];
    if (r.creator_paid) refunds.push(`${nim(r.entry_nim)} NIM to ${r.creator_nickname}`);
    if (matched && r.opponent_paid) refunds.push(`${nim(r.entry_nim)} NIM to ${r.opponent_nickname}`);
    const amountTxt = refunds.length ? ` and refund ${refunds.join(" + ")}` : "";
    const warn = matched ? " This room is already matched — this is a forced dispute resolution, use with care." : "";
    if (!confirm(`Close room ${r.id}${amountTxt}?${warn}`)) return;
    setCancelling(r.id);
    try {
      await cancelVSRoomAdmin(r.id);
      await Promise.all([load(offset), loadStats()]);
    } catch (e) {
      alert(e instanceof Error ? e.message : "Cancel failed");
    } finally {
      setCancelling(null);
    }
  }

  const load = useCallback(async (off: number) => {
    setLoading(true);
    try {
      const { rooms, total } = await fetchVSRooms(PAGE_SIZE, off);
      setRooms(rooms.sort((a, b) => b.created_at - a.created_at));
      setTotal(total);
      setOffset(off);
    } finally {
      setLoading(false);
    }
  }, []);

  const loadStats = useCallback(async () => {
    const { rooms } = await fetchVSRooms(STATS_LIMIT, 0);
    setStatsRooms(rooms);
  }, []);

  useEffect(() => { load(0); loadStats(); }, [load, loadStats]);

  // KPI cards are computed from statsRooms (an all-rooms fetch) so they stay
  // accurate all-time figures regardless of which page of the table below is
  // currently loaded.
  const activeAll = statsRooms.filter(r => !["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status));
  const paidVolume = statsRooms.reduce((sum, r) => sum + (r.creator_paid ? r.entry_nim : 0) + (r.opponent_paid ? r.entry_nim : 0), 0);
  const feeCollected = statsRooms.reduce((sum, r) => sum + (r.fee_nim ?? 0), 0);

  // Table filter (active/completed/all) applies only to the currently
  // loaded page — use Prev/Next below to page through the rest.
  const active = rooms.filter(r => !["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status));
  const completed = rooms.filter(r => ["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status));
  const shown = filter === "all" ? rooms : filter === "active" ? active : completed;

  const pageStart = total === 0 ? 0 : offset + 1;
  const pageEnd = Math.min(offset + rooms.length, total);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Active rooms</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{activeAll.length}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Total rooms</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{statsRooms.length}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 160px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>NIM paid in (all-time)</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "var(--orange)" }}>{nim(paidVolume)}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 160px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>System fee collected (5%)</div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "var(--orange)" }}>{nim(feeCollected)}</div>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        {(["active", "completed", "all"] as const).map(f => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={f === filter ? "btn btn-active" : "btn"}
            style={{ fontSize: 12, padding: "6px 12px" }}
          >
            {f === "active" ? "Active" : f === "completed" ? "Completed" : "All"}
          </button>
        ))}
        <button onClick={() => { load(offset); loadStats(); }} className="btn" style={{ fontSize: 12, padding: "6px 12px" }} disabled={loading}>
          {loading ? "Loading…" : "Refresh"}
        </button>
        <button
          onClick={async () => { setSweeping(true); try { await sweepVSRooms(); await Promise.all([load(offset), loadStats()]); } finally { setSweeping(false); } }}
          className="btn"
          style={{ fontSize: 12, padding: "6px 12px" }}
          disabled={sweeping}
          title="Force-run the 24h expiry/settlement sweep now instead of waiting for the next automatic pass"
        >
          {sweeping ? "Sweeping…" : "Force sweep"}
        </button>
        <button
          onClick={async () => { setReconciling(true); try { await reconcileVSPayments(); await Promise.all([load(offset), loadStats()]); } finally { setReconciling(false); } }}
          className="btn"
          style={{ fontSize: 12, padding: "6px 12px" }}
          disabled={reconciling}
          title="Force-scan the app wallet's incoming transactions now and match any unconfirmed VS payments — the automatic pass already runs every 90s regardless, this is just for immediate feedback"
        >
          {reconciling ? "Scanning chain…" : "Force payment scan"}
        </button>
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "var(--text-muted)" }}>
          <span>{total === 0 ? "0 rooms" : `${pageStart}–${pageEnd} of ${total}`}</span>
          <button
            onClick={() => load(Math.max(0, offset - PAGE_SIZE))}
            className="btn"
            style={{ fontSize: 12, padding: "4px 10px" }}
            disabled={loading || offset === 0}
          >
            ← Prev
          </button>
          <button
            onClick={() => load(offset + PAGE_SIZE)}
            className="btn"
            style={{ fontSize: 12, padding: "4px 10px" }}
            disabled={loading || offset + rooms.length >= total}
          >
            Next →
          </button>
        </div>
      </div>

      <div className="card" style={{ padding: 0, overflowX: "auto" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ textAlign: "left", fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>
              <th style={{ padding: "10px 14px" }}>Room</th>
              <th style={{ padding: "10px 14px" }}>Entry</th>
              <th style={{ padding: "10px 14px" }}>Creator</th>
              <th style={{ padding: "10px 14px" }}>Opponent</th>
              <th style={{ padding: "10px 14px" }}>Status</th>
              <th style={{ padding: "10px 14px" }}>Time left</th>
              <th style={{ padding: "10px 14px" }}>Winner / payout</th>
              <th style={{ padding: "10px 14px" }}>Created</th>
              <th style={{ padding: "10px 14px" }}></th>
            </tr>
          </thead>
          <tbody>
            {shown.map(r => (
              <tr key={r.id} style={{ borderTop: "1px solid var(--border)" }}>
                <td style={{ padding: "10px 14px", fontFamily: "monospace", fontSize: 12 }}>
                  {r.id}
                  {r.is_private && <span style={{ marginLeft: 6, fontSize: 10, color: "var(--text-muted)", textTransform: "uppercase" }}>private</span>}
                  {r.live && (
                    <span style={{
                      marginLeft: 6, fontSize: 10, fontWeight: 700, color: "#fff",
                      background: "var(--red, #d32f2f)", borderRadius: 4, padding: "1px 6px",
                      textTransform: "uppercase", letterSpacing: "0.03em",
                    }} title="Someone is actively playing this round right now — streaming live">
                      ● live
                    </span>
                  )}
                </td>
                <td style={{ padding: "10px 14px" }}>{r.entry_nim > 0 ? `${nim(r.entry_nim)} NIM` : "Free"}</td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>
                  {r.creator_nickname}
                  {r.entry_nim > 0 && <span style={{ color: r.creator_paid ? "#4caf50" : "var(--text-muted)", marginLeft: 6 }}>{r.creator_paid ? "paid" : "unpaid"}</span>}
                  {r.creator_score != null && <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>score {r.creator_score}</span>}
                </td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>
                  {r.opponent_nickname || <span style={{ color: "var(--text-muted)" }}>—</span>}
                  {r.opponent_id && r.entry_nim > 0 && <span style={{ color: r.opponent_paid ? "#4caf50" : "var(--text-muted)", marginLeft: 6 }}>{r.opponent_paid ? "paid" : "unpaid"}</span>}
                  {r.opponent_score != null && <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>score {r.opponent_score}</span>}
                </td>
                <td style={{ padding: "10px 14px" }}>
                  <StatusBadge status={r.status} />
                  {(r.creator_forfeit_requested || r.opponent_forfeit_requested) && (
                    <div style={{ fontSize: 10, color: "var(--red)", marginTop: 2, textTransform: "uppercase" }} title="A player has asked to bail out of this match — it only cancels once BOTH sides request it">
                      forfeit: {[r.creator_forfeit_requested && "creator", r.opponent_forfeit_requested && "opponent"].filter(Boolean).join(" + ")}
                    </div>
                  )}
                </td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>{timeLeft(r.expires_at, r.status)}</td>
                <td style={{ padding: "10px 14px", fontSize: 12 }}>
                  {r.winner_id ? (
                    <span>{r.winner_id === r.creator_id ? r.creator_nickname : r.opponent_nickname} · {nim(r.payout_nim)} NIM</span>
                  ) : r.status === "completed" ? (
                    <span>split · {nim(r.payout_nim)} NIM each</span>
                  ) : r.status === "expired_refunded" ? (
                    <span>refunded</span>
                  ) : "—"}
                </td>
                <td style={{ padding: "10px 14px", fontSize: 12, color: "var(--text-muted)" }}>{fmt(r.created_at)}</td>
                <td style={{ padding: "10px 14px" }}>
                  {!["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status) && (
                    <button
                      onClick={() => doCancel(r)}
                      className="btn"
                      style={{ fontSize: 11, padding: "3px 8px", background: "var(--red)" }}
                      disabled={cancelling === r.id}
                      title={r.opponent_id
                        ? "Already matched — force-close and refund whoever paid in (dispute resolution)"
                        : "Nobody has joined this room — close it and refund the creator if they paid"}
                    >
                      {cancelling === r.id ? "Closing…" : r.opponent_id ? "Force Close & Refund" : "Close & Refund"}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {shown.length === 0 && !loading && (
              <tr><td colSpan={9} style={{ padding: 20, textAlign: "center", color: "var(--text-muted)" }}>No rooms.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
