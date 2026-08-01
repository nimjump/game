"use client";
import { useEffect, useState } from "react";
import {
  fetchDatabaseOverview, clearDatabaseCategory,
  fetchFailedReplayArchive, failedReplayDownloadUrl,
  fetchBackupStatus, fetchBackupList, runBackupNow, restoreBackup,
  type DBCategory, type FailedReplayEntry, type BackupStatus, type BackupSnapshot,
} from "@/lib/api";

function fmtBytes(n?: number) {
  if (!n) return "—";
  const units = ["B", "KiB", "MiB", "GiB"];
  let i = 0, v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${units[i]}`;
}

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
  const [backupStatus, setBackupStatus] = useState<BackupStatus | null>(null);
  const [backups,      setBackups]      = useState<BackupSnapshot[]>([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState("");
  const [clearing,   setClearing]   = useState<string | null>(null);
  const [backingUp,  setBackingUp]  = useState(false);
  const [restoring,  setRestoring]  = useState<string | null>(null);

  const load = async () => {
    setLoading(true); setError("");
    try {
      const [cats, arch, bstatus] = await Promise.all([
        fetchDatabaseOverview(), fetchFailedReplayArchive(), fetchBackupStatus(),
      ]);
      setCategories(cats);
      setArchive(arch);
      setBackupStatus(bstatus);
      if (bstatus.configured) {
        setBackups(await fetchBackupList().catch(() => []));
      }
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);

  async function doBackupNow() {
    setBackingUp(true);
    try {
      const status = await runBackupNow();
      setBackupStatus(status);
      setBackups(await fetchBackupList().catch(() => []));
    } catch (e) {
      alert("Backup failed: " + String(e instanceof Error ? e.message : e));
    } finally {
      setBackingUp(false);
    }
  }

  async function doRestore(key: string) {
    const warn =
      `⚠ DANGEROUS: this REPLACES THE ENTIRE LIVE DATABASE (every player's balance, ` +
      `quest progress, VS match history, everything) with the snapshot:\n\n${key}\n\n` +
      `Anything written since that snapshot was taken will be lost. A safety snapshot ` +
      `of the CURRENT state is taken automatically right before this runs, so this ` +
      `specific mistake is recoverable — but this is still a live-traffic-disrupting, ` +
      `full-database swap. Only do this to actually recover from real data loss.\n\n` +
      `To confirm, type the snapshot name exactly:\n${key}`;
    const typed = prompt(warn);
    if (typed !== key) {
      if (typed !== null) alert("Snapshot name didn't match — restore cancelled.");
      return;
    }
    setRestoring(key);
    try {
      await restoreBackup(key);
      alert(`Restore complete from ${key}. Reloading admin data.`);
      load();
    } catch (e) {
      alert("Restore failed: " + String(e instanceof Error ? e.message : e));
    } finally {
      setRestoring(null);
    }
  }

  async function doClear(cat: DBCategory) {
    const msg = cat.dangerous
      ? `⚠ DANGEROUS: permanently delete all ${cat.count} "${cat.label}" entries?\n\n${cat.description}\n\nThis cannot be undone.`
      : `Delete all ${cat.count} "${cat.label}" entries?\n\n${cat.description}`;
    if (!confirm(msg)) return;
    if (cat.dangerous && !confirm(`Really sure? Type OK to confirm deleting ${cat.label}.`)) return;
    setClearing(cat.key);
    try {
      const res = await clearDatabaseCategory(cat.key, cat.dangerous ? cat.key : undefined);
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

      {/* ── Off-site backups ── */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13, display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <span>☁️ Off-site Backups (Cloudflare R2)</span>
          {backupStatus?.configured && (
            <button className="btn" disabled={backingUp} onClick={doBackupNow}>
              {backingUp ? "Backing up…" : "Backup now"}
            </button>
          )}
        </div>
        {!backupStatus?.configured ? (
          <div style={{ padding: 16, fontSize: 12, color: "var(--text-muted)" }}>
            Not configured — set <code>R2_ACCOUNT_ID</code>, <code>R2_ACCESS_KEY_ID</code>,{" "}
            <code>R2_SECRET_ACCESS_KEY</code> and <code>R2_BUCKET</code> in backend/.env
            (see the comments there for setup steps). Until then there is no off-site copy
            of the database — everything lives only on this disk.
          </div>
        ) : (
          <>
            <div style={{ padding: "10px 16px", fontSize: 12, display: "flex", gap: 24, flexWrap: "wrap" }}>
              <span>Every <b>{backupStatus.interval_hours}h</b>, keeping last <b>{backupStatus.retention_count}</b></span>
              <span>Last success: <b>{fmtDate(backupStatus.last_success_at || 0)}</b></span>
              {backupStatus.last_error && (
                <span style={{ color: "var(--red)" }}>Last error: {backupStatus.last_error}</span>
              )}
            </div>
            {backups.length === 0 ? (
              <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 13 }}>
                No snapshots uploaded yet
              </div>
            ) : (
              <table>
                <thead><tr><th>Snapshot</th><th>Size</th><th>Last modified</th><th></th></tr></thead>
                <tbody>
                  {backups.slice(0, 10).map(b => (
                    <tr key={b.key}>
                      <td style={{ fontFamily: "monospace", fontSize: 11 }}>{b.key}</td>
                      <td>{fmtBytes(b.size)}</td>
                      <td style={{ fontSize: 11, whiteSpace: "nowrap" }}>{b.last_modified}</td>
                      <td>
                        <button className="btn" style={{ background: "var(--red)", fontSize: 11 }}
                          disabled={restoring !== null}
                          onClick={() => doRestore(b.key)}>
                          {restoring === b.key ? "Restoring…" : "♻ Restore"}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </>
        )}
      </div>

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
