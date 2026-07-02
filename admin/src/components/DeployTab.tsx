"use client";
import { useEffect, useRef, useState } from "react";
import {
  fetchDeployStatus, scheduleDeployJob, fetchDeployJobs, cancelDeployJob,
  uploadReplayBinary, fetchAppConfig,
  type DeployStatus, type DeployJob, type DeployTrigger,
} from "@/lib/api";

function fmtDate(ts?: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB");
}

const TRIGGER_LABELS: Record<DeployTrigger, string> = {
  now: "Right now",
  at: "At a specific time",
  daily_lb_end: "When the daily leaderboard ends",
  weekly_lb_end: "When the weekly leaderboard ends",
};

function statusBadge(status: DeployJob["status"]) {
  switch (status) {
    case "pending":   return <span className="badge badge-yellow">⏳ Pending</span>;
    case "running":   return <span className="badge badge-yellow">⚙ Running</span>;
    case "done":      return <span className="badge badge-green">✓ Done</span>;
    case "failed":    return <span className="badge badge-red">✗ Failed</span>;
    case "cancelled": return <span className="badge">Cancelled</span>;
  }
}

export default function DeployTab() {
  const [status,   setStatus]   = useState<DeployStatus | null>(null);
  const [jobs,      setJobs]     = useState<DeployJob[]>([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState("");
  const [scheduling, setScheduling] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [expanded,  setExpanded]  = useState<string | null>(null);

  // Form state
  const [trigger, setTrigger] = useState<DeployTrigger>("now");
  const [atLocal, setAtLocal] = useState(""); // datetime-local input value
  const [activateBinary, setActivateBinary] = useState(false);
  const [deployCF, setDeployCF] = useState(false);
  const [bumpVersion, setBumpVersion] = useState(false);
  const [newVersion, setNewVersion] = useState("1");
  const fileRef = useRef<HTMLInputElement | null>(null);

  const load = async () => {
    setLoading(true); setError("");
    try {
      const [st, js, cfg] = await Promise.all([fetchDeployStatus(), fetchDeployJobs(), fetchAppConfig()]);
      setStatus(st);
      setJobs(js);
      setNewVersion(String(cfg.replay_version + 1));
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);
  useEffect(() => {
    const id = setInterval(() => { fetchDeployJobs().then(setJobs).catch(() => {}); }, 5000);
    return () => clearInterval(id);
  }, []);

  async function doStageUpload() {
    const f = fileRef.current?.files?.[0];
    if (!f) { alert("Choose a .zip or .exe file first."); return; }
    setUploading(true);
    try {
      await uploadReplayBinary(f, true);
      alert(`Staged ${f.name}. It'll activate when your scheduled job runs.`);
      if (fileRef.current) fileRef.current.value = "";
      load();
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setUploading(false);
    }
  }

  async function doSchedule() {
    if (!activateBinary && !deployCF && !bumpVersion) {
      alert("Enable at least one action (activate binary / deploy Cloudflare / bump version).");
      return;
    }
    if (activateBinary && !status?.has_staged_binary) {
      alert("No staged replay binary — upload one with \"Stage for later\" first.");
      return;
    }
    if (deployCF && !status?.cloudflare_configured) {
      alert("Cloudflare isn't configured — set CLOUDFLARE_API_TOKEN / ACCOUNT_ID / PROJECT in backend/.env first.");
      return;
    }
    let atUnix: number | undefined;
    if (trigger === "at") {
      if (!atLocal) { alert("Pick a date/time."); return; }
      atUnix = Math.floor(new Date(atLocal).getTime() / 1000);
      if (atUnix <= Date.now() / 1000) { alert("That time is in the past."); return; }
    }
    const label = TRIGGER_LABELS[trigger];
    if (!confirm(
      `Schedule this update for: ${label}${trigger === "at" ? " (" + atLocal + ")" : ""}?\n\n` +
      `${activateBinary ? "✓ Activate staged replay binary\n" : ""}` +
      `${deployCF ? "✓ Deploy to Cloudflare Pages\n" : ""}` +
      `${bumpVersion ? `✓ Set replay version to ${newVersion}\n` : ""}` +
      `\nNew games will be blocked for the short time this actually takes to run, then play resumes automatically.`
    )) return;

    setScheduling(true);
    try {
      await scheduleDeployJob({
        trigger, at_unix: atUnix,
        activate_replay_binary: activateBinary,
        deploy_cloudflare: deployCF,
        new_replay_version: bumpVersion ? parseInt(newVersion, 10) : undefined,
      });
      load();
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setScheduling(false);
    }
  }

  async function doCancel(id: string) {
    if (!confirm("Cancel this scheduled job?")) return;
    try {
      await cancelDeployJob(id);
      load();
    } catch (e) {
      alert("Error: " + String(e));
    }
  }

  if (loading) return <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>Loading…</div>;
  if (error)   return <div style={{ padding: 16, color: "var(--red)" }}>{error}</div>;
  if (!status) return null;

  const hasActiveJob = jobs.some(j => j.status === "pending" || j.status === "running");

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

      {/* ── Config status ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 10 }}>Deploy Configuration</div>
        <div style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 12 }}>
          <div>
            Cloudflare Pages: {status.cloudflare_configured
              ? <span className="badge badge-green" style={{ fontSize: 10 }}>✓ configured</span>
              : <span className="badge badge-red" style={{ fontSize: 10 }}>not configured — set env vars</span>}
            {status.cloudflare_configured && (
              <span style={{ color: "var(--text-muted)", marginLeft: 8 }}>
                project: <b>{status.cloudflare_project}</b> · branch: <b>{status.cloudflare_branch}</b> · dir: <span style={{ fontFamily: "monospace" }}>{status.cloudflare_export_dir}</span>
              </span>
            )}
          </div>
          <div>
            Staged replay binary: {status.has_staged_binary
              ? <span className="badge badge-green" style={{ fontSize: 10 }}>✓ {status.staged_binary} ready</span>
              : <span style={{ color: "var(--text-muted)" }}>none — upload one below with &quot;Stage for later&quot;</span>}
          </div>
        </div>
      </div>

      {/* ── Stage a replay binary ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8 }}>1. Stage a Replay Binary (optional)</div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 10 }}>
          Upload now, activate later — it just sits here until a scheduled job with
          &quot;Activate staged replay binary&quot; checked actually runs. For an immediate swap
          instead, use the System tab's upload (no staging).
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          <input ref={fileRef} type="file" accept=".zip,.exe" style={{ fontSize: 12 }} />
          <button className="btn" disabled={uploading} onClick={doStageUpload}>
            {uploading ? "Staging…" : "📥 Stage for later"}
          </button>
        </div>
      </div>

      {/* ── Schedule ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8 }}>2. Schedule the Update</div>

        {hasActiveJob ? (
          <div style={{ fontSize: 12, color: "var(--yellow)", marginBottom: 10 }}>
            ⚠ A job is already pending/running — cancel it below before scheduling a new one.
          </div>
        ) : (
          <>
            <div style={{ display: "flex", flexDirection: "column", gap: 10, marginBottom: 12 }}>
              <div>
                <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 4 }}>When</div>
                <select value={trigger} onChange={e => setTrigger(e.target.value as DeployTrigger)}
                  style={{ padding: "6px 10px", fontSize: 13 }}>
                  {(Object.keys(TRIGGER_LABELS) as DeployTrigger[]).map(t => (
                    <option key={t} value={t}>{TRIGGER_LABELS[t]}</option>
                  ))}
                </select>
                {trigger === "at" && (
                  <input type="datetime-local" value={atLocal} onChange={e => setAtLocal(e.target.value)}
                    style={{ marginLeft: 10, padding: "5px 8px", fontSize: 13 }} />
                )}
              </div>

              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input type="checkbox" checked={activateBinary} onChange={e => setActivateBinary(e.target.checked)}
                  disabled={!status.has_staged_binary} />
                Activate staged replay binary {!status.has_staged_binary && <span style={{ color: "var(--text-muted)", fontSize: 11 }}>(none staged)</span>}
              </label>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input type="checkbox" checked={deployCF} onChange={e => setDeployCF(e.target.checked)}
                  disabled={!status.cloudflare_configured} />
                Deploy to Cloudflare Pages {!status.cloudflare_configured && <span style={{ color: "var(--text-muted)", fontSize: 11 }}>(not configured)</span>}
              </label>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input type="checkbox" checked={bumpVersion} onChange={e => setBumpVersion(e.target.checked)} />
                Set replay version to
                <input type="number" min={1} value={newVersion} onChange={e => setNewVersion(e.target.value)}
                  disabled={!bumpVersion} style={{ width: 70, padding: "3px 6px", fontSize: 12 }} />
              </label>
            </div>

            <button className="btn btn-active" disabled={scheduling} onClick={doSchedule}>
              {scheduling ? "Scheduling…" : "🚀 Schedule Update"}
            </button>
          </>
        )}
      </div>

      {/* ── Job history ── */}
      <div className="card">
        <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", fontWeight: 600, fontSize: 13 }}>
          📋 Deploy Job History
        </div>
        {jobs.length === 0 ? (
          <div style={{ padding: 24, textAlign: "center", color: "var(--text-muted)", fontSize: 13 }}>No jobs yet</div>
        ) : (
          <table>
            <thead>
              <tr><th>Status</th><th>Trigger</th><th>Runs at</th><th>Actions</th><th>Finished</th><th></th></tr>
            </thead>
            <tbody>
              {jobs.map(j => {
                const isOpen = expanded === j.id;
                return (
                  <>
                    <tr key={j.id} style={{ cursor: "pointer" }} onClick={() => setExpanded(isOpen ? null : j.id)}>
                      <td>{statusBadge(j.status)}</td>
                      <td style={{ fontSize: 12 }}>{TRIGGER_LABELS[j.trigger]}</td>
                      <td style={{ fontSize: 11, fontFamily: "monospace" }}>{fmtDate(j.run_at)}</td>
                      <td style={{ fontSize: 11, color: "var(--text-muted)" }}>
                        {[j.activate_replay_binary && "binary", j.deploy_cloudflare && "cloudflare",
                          j.new_replay_version ? `v${j.new_replay_version}` : null]
                          .filter(Boolean).join(" · ") || "—"}
                      </td>
                      <td style={{ fontSize: 11 }}>{fmtDate(j.finished_at)}</td>
                      <td>
                        {j.status === "pending" && (
                          <button className="btn" style={{ fontSize: 11, background: "var(--red)" }}
                            onClick={(e) => { e.stopPropagation(); doCancel(j.id); }}>
                            Cancel
                          </button>
                        )}
                      </td>
                    </tr>
                    {isOpen && (
                      <tr key={j.id + "_log"}>
                        <td colSpan={6} style={{ background: "var(--surface2)", padding: "10px 16px", fontSize: 11, fontFamily: "monospace", whiteSpace: "pre-wrap" }}>
                          {j.error && <div style={{ color: "var(--red)", marginBottom: 6 }}>{j.error}</div>}
                          {(j.log ?? []).join("\n") || "no log"}
                        </td>
                      </tr>
                    )}
                  </>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
