"use client";
import { useEffect, useState } from "react";
import {
  fetchDatabaseOverview, clearDatabaseCategory,
  fetchFailedReplayArchive, failedReplayDownloadUrl,
  type DBCategory, type FailedReplayEntry,
} from "@/lib/api";

function fmtDate(ts: number) {
  if (!ts) return "—";
  // Pinned to UTC+3 — see AnalyticsTab.tsx's fmt() for why (matches the
  // backend's fixed leaderboard/period timezone, avoids day-boundary
  // entries showing the wrong calendar date in a non-UTC+3 browser).
  return new Date(ts * 1000).toLocaleString("en-GB", { timeZone: "Europe/Istanbul" });
}

export default function DatabaseTab() {
  const [categories, setCategories] = useState<DBCategory[]>([]);
  const [archive,    setArchive]    = useState<FailedReplayEntry[]>([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState("");
  const [clearing,   setClearing]   = useState<string | null>(null);

  const load = async () => {
    setLoading(true); setError("");
    try {
      const [cats, arch] = await Promise.all([fetchDatabaseOverview(), fetchFailedReplayArchive()]);
      setCategories(cats);
      setArchive(arch);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);

  async function doClear(cat: DBCategory) {
    const msg = cat.dangerous
      ? `⚠ DANGEROUS: permanently delete all ${cat.count} "${cat.label}" entries?\n\n${cat.description}\n\nThis cannot be undone.`
      : `Delete all ${cat.count} "${cat.label}" entries?\n\n${cat.description}`;
    if (!confirm(msg)) return;
    if (cat.dangerous && !confirm(`Really sure? Type OK to confirm deleting ${cat.label}.`)) return;
    setClearing(cat.key);
    try {
      const res = await clearDatabaseCategory(cat.key);
      alert(`Deleted ${res.deleted} entries from ${cat.label}.`);
      load();
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setClearing(null);
    }
  }

  if (loading) return <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>Loading…</div>;
  if (error)   return <div style={{ padding: 16, color: "var(--red)" }}>{error}</div>;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

      {/* ── Categories ── */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13 }}>
          🗄 Database Contents
        </div>
        <table>
          <thead>
            <tr><th>Category</th><th>Description</th><th style={{ textAlign: "center" }}>Count</th><th></th></tr>
          </thead>
          <tbody>
            {categories.map(c => (
              <tr key={c.key}>
                <td style={{ fontWeight: 600 }}>
                  {c.label}
                  {c.dangerous && <span className="badge badge-red" style={{ marginLeft: 6, fontSize: 9 }}>sensitive</span>}
                  <div style={{ fontFamily: "monospace", fontSize: 10, color: "var(--text-muted)" }}>{c.prefix}</div>
                </td>
                <td style={{ fontSize: 11, color: "var(--text-muted)", maxWidth: 420 }}>{c.description}</td>
                <td style={{ textAlign: "center", fontWeight: 700, fontSize: 14 }}>{c.count.toLocaleString()}</td>
                <td>
                  <button className="btn" style={c.dangerous ? { background: "var(--red)" } : {}}
                    disabled={clearing === c.key || c.count === 0}
                    onClick={() => doClear(c)}>
                    {clearing === c.key ? "Deleting…" : "🗑 Clear"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* ── Failed replay archive ── */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13 }}>
          📦 Failed Replay Archive ({archive.length})
        </div>
        {archive.length === 0 ? (
          <div style={{ padding: 24, textAlign: "center", color: "var(--text-muted)", fontSize: 13 }}>
            No failed replays archived
          </div>
        ) : (
          <table>
            <thead>
              <tr><th>Session</th><th>Category</th><th>Reason</th><th>Archived</th><th></th></tr>
            </thead>
            <tbody>
              {archive.map(e => (
                <tr key={e.id}>
                  <td style={{ fontFamily: "monospace", fontSize: 11 }}>
                    {e.session_id ? e.session_id.slice(0, 16) + "…" : "—"}
                  </td>
                  <td><span className="badge badge-yellow" style={{ fontSize: 10 }}>{e.category}</span></td>
                  <td style={{ fontSize: 11, color: "var(--text-muted)", maxWidth: 300, overflow: "hidden", textOverflow: "ellipsis" }}>
                    {e.reason || "—"}
                  </td>
                  <td style={{ fontSize: 11, whiteSpace: "nowrap" }}>{fmtDate(e.archived_at)}</td>
                  <td>
                    {e.has_log && (
                      <a href={failedReplayDownloadUrl(e.id)} target="_blank" rel="noopener noreferrer">
                        <button className="btn" style={{ fontSize: 11 }}>⬇ Download</button>
                      </a>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
