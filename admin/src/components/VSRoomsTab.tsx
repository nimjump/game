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

export default function VSRoomsTab() {
  const [rooms, setRooms] = useState<VSRoom[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<"all" | "active" | "completed">("active");
  const [sweeping, setSweeping] = useState(false);
  const [reconciling, setReconciling] = useState(false);
  const [cancelling, setCancelling] = useState<string | null>(null);

  async function doCancel(r: VSRoom) {
    const amountTxt = r.creator_paid ? ` and refund ${nim(r.entry_nim)} NIM to ${r.creator_nickname}` : "";
    if (!confirm(`Close room ${r.id}${amountTxt}? Only possible while nobody has joined yet.`)) return;
    setCancelling(r.id);
    try {
      await cancelVSRoomAdmin(r.id);
      await load();
    } catch (e) {
      alert(e instanceof Error ? e.message : "Cancel failed");
    } finally {
      setCancelling(null);
    }
  }

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const { rooms } = await fetchVSRooms();
      setRooms(rooms.sort((a, b) => b.created_at - a.created_at));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const active = rooms.filter(r => !["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status));
  const completed = rooms.filter(r => ["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status));
  const paidVolume = rooms.reduce((sum, r) => sum + (r.creator_paid ? r.entry_nim : 0) + (r.opponent_paid ? r.entry_nim : 0), 0);
  const feeCollected = rooms.reduce((sum, r) => sum + (r.fee_nim ?? 0), 0);

  const shown = filter === "all" ? rooms : filter === "active" ? active : completed;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Active rooms</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{active.length}</div>
        </div>
        <div className="card" style={{ padding: "14px 18px", flex: "1 1 140px" }}>
          <div style={{ fontSize: 11, color: "var(--text-muted)", textTransform: "uppercase" }}>Total rooms</div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{rooms.length}</div>
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

      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
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
        <button onClick={load} className="btn" style={{ fontSize: 12, padding: "6px 12px" }} disabled={loading}>
          {loading ? "Loading…" : "Refresh"}
        </button>
        <button
          onClick={async () => { setSweeping(true); try { await sweepVSRooms(); await load(); } finally { setSweeping(false); } }}
          className="btn"
          style={{ fontSize: 12, padding: "6px 12px" }}
          disabled={sweeping}
          title="Force-run the 24h expiry/settlement sweep now instead of waiting for the next automatic pass"
        >
          {sweeping ? "Sweeping…" : "Force sweep"}
        </button>
        <button
          onClick={async () => { setReconciling(true); try { await reconcileVSPayments(); await load(); } finally { setReconciling(false); } }}
          className="btn"
          style={{ fontSize: 12, padding: "6px 12px" }}
          disabled={reconciling}
          title="Force-scan the app wallet's incoming transactions now and match any unconfirmed VS payments — the automatic pass already runs every 90s regardless, this is just for immediate feedback"
        >
          {reconciling ? "Scanning chain…" : "Force payment scan"}
        </button>
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
                <td style={{ padding: "10px 14px" }}><StatusBadge status={r.status} /></td>
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
                  {!r.opponent_id && !["completed", "expired_payout", "expired_refunded", "cancelled"].includes(r.status) && (
                    <button
                      onClick={() => doCancel(r)}
                      className="btn"
                      style={{ fontSize: 11, padding: "3px 8px", background: "var(--red)" }}
                      disabled={cancelling === r.id}
                      title="Nobody has joined this room — close it and refund the creator if they paid"
                    >
                      {cancelling === r.id ? "Closing…" : "Close & Refund"}
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
