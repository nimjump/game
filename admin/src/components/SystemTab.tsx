"use client";
import { useEffect, useRef, useState } from "react";
import {
  fetchAppConfig, saveAppConfig, setUpdateMode, completeUpdate, clearAllReplays,
  fetchReplayBinaryStatus, uploadReplayBinary, deleteReplayBinaryFile,
  fetchGoldenReplays, deleteGoldenReplay, runGoldenSelfTest, fetchDeterminismLint,
  fetchQuestPool, setQuestReward, setQuestTarget,
  type AppConfig, type ReplayBinaryStatus, type GoldenReplay, type GoldenReplayResult,
  type DeterminismFinding, type QuestPoolEntry,
} from "@/lib/api";

function fmtBytes(n: number) {
  if (n > 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB";
  if (n > 1024) return (n / 1024).toFixed(1) + " KB";
  return n + " B";
}

function fmtDate(ts: number) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString("en-GB");
}

export default function SystemTab() {
  const [cfg,      setCfg]      = useState<AppConfig | null>(null);
  const [binary,   setBinary]   = useState<ReplayBinaryStatus | null>(null);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState("");
  const [saving,   setSaving]   = useState(false);
  const [uploading,setUploading]= useState(false);
  const [deletingFile, setDeletingFile] = useState<string | null>(null);
  const [clearing, setClearing] = useState(false);
  const [versionInput, setVersionInput] = useState("1");
  const [capInput, setCapInput] = useState("100");
  const [coinRateInput, setCoinRateInput] = useState("1");
  const fileRef = useRef<HTMLInputElement | null>(null);

  // ── Quest reward overrides ──────────────────────────────────────────
  const [questPool,   setQuestPool]   = useState<QuestPoolEntry[]>([]);
  const [questLoading,setQuestLoading]= useState(true);
  const [questInputs, setQuestInputs] = useState<Record<number, string>>({});
  const [targetInputs, setTargetInputs] = useState<Record<number, string>>({});
  const [questSavingKey, setQuestSavingKey] = useState<string | null>(null); // `${idx}:reward` or `${idx}:target`

  const loadQuestPool = async () => {
    setQuestLoading(true);
    try {
      const quests = await fetchQuestPool();
      setQuestPool(quests);
      const inputs: Record<number, string> = {};
      const targets: Record<number, string> = {};
      for (const q of quests) { inputs[q.idx] = String(q.reward_nim); targets[q.idx] = String(q.target); }
      setQuestInputs(inputs);
      setTargetInputs(targets);
    } catch {
      // non-fatal — quest rewards panel just stays empty
    } finally {
      setQuestLoading(false);
    }
  };

  function syncQuestInputs(quests: QuestPoolEntry[]) {
    setQuestPool(quests);
    setQuestInputs(prev => {
      const next = { ...prev };
      for (const q of quests) next[q.idx] = String(q.reward_nim);
      return next;
    });
    setTargetInputs(prev => {
      const next = { ...prev };
      for (const q of quests) next[q.idx] = String(q.target);
      return next;
    });
  }

  async function doSaveQuestReward(q: QuestPoolEntry) {
    const key = `${q.idx}:reward`;
    const n = parseFloat(questInputs[q.idx]);
    if (!Number.isFinite(n) || n < 0) { alert("Reward must be a number ≥ 0."); return; }
    setQuestSavingKey(key);
    try {
      syncQuestInputs(await setQuestReward(q.idx, n));
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setQuestSavingKey(null);
    }
  }

  async function doResetQuestReward(q: QuestPoolEntry) {
    const key = `${q.idx}:reward`;
    setQuestSavingKey(key);
    try {
      syncQuestInputs(await setQuestReward(q.idx, null));
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setQuestSavingKey(null);
    }
  }

  async function doSaveQuestTarget(q: QuestPoolEntry) {
    const key = `${q.idx}:target`;
    const n = parseInt(targetInputs[q.idx], 10);
    if (!Number.isFinite(n) || n <= 0) { alert("Target must be a whole number > 0."); return; }
    setQuestSavingKey(key);
    try {
      syncQuestInputs(await setQuestTarget(q.idx, n));
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setQuestSavingKey(null);
    }
  }

  async function doResetQuestTarget(q: QuestPoolEntry) {
    const key = `${q.idx}:target`;
    setQuestSavingKey(key);
    try {
      syncQuestInputs(await setQuestTarget(q.idx, null));
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setQuestSavingKey(null);
    }
  }

  // ── Golden replays: determinism self-test ──────────────────────────
  const [goldens,      setGoldens]      = useState<GoldenReplay[]>([]);
  const [goldenLoading,setGoldenLoading]= useState(true);
  const [testing,      setTesting]      = useState(false);
  const [testResults,  setTestResults]  = useState<GoldenReplayResult[] | null>(null);
  const [testRanAt,    setTestRanAt]    = useState<number | null>(null);

  const loadGoldens = async () => {
    setGoldenLoading(true);
    try {
      const res = await fetchGoldenReplays();
      setGoldens(res.goldens ?? []);
    } catch {
      // non-fatal — golden panel just stays empty
    } finally {
      setGoldenLoading(false);
    }
  };

  async function doSelfTest() {
    setTesting(true); setTestResults(null);
    try {
      const res = await runGoldenSelfTest();
      setTestResults(res.results);
      setTestRanAt(Date.now());
    } catch (e) {
      alert("Self-test error: " + String(e));
    } finally {
      setTesting(false);
    }
  }

  async function doDeleteGolden(id: string, label: string) {
    if (!confirm(`Unpin golden replay "${label}"?`)) return;
    try {
      await deleteGoldenReplay(id);
      loadGoldens();
    } catch (e) {
      alert("Error: " + String(e));
    }
  }

  // ── Static determinism lint ─────────────────────────────────────────
  const [lintFindings, setLintFindings] = useState<DeterminismFinding[] | null>(null);
  const [linting,      setLinting]      = useState(false);
  const [lintRanAt,    setLintRanAt]    = useState<number | null>(null);
  const [lintError,    setLintError]    = useState("");

  async function doLint() {
    setLinting(true); setLintError("");
    try {
      const res = await fetchDeterminismLint();
      setLintFindings(res.findings);
      setLintRanAt(Date.now());
    } catch (e) {
      setLintError(String(e instanceof Error ? e.message : e));
    } finally {
      setLinting(false);
    }
  }

  const load = async () => {
    setLoading(true); setError("");
    try {
      const [c, b] = await Promise.all([fetchAppConfig(), fetchReplayBinaryStatus()]);
      setCfg(c);
      setVersionInput(String(c.replay_version));
      setCapInput(String(c.daily_earn_cap_nim && c.daily_earn_cap_nim > 0 ? c.daily_earn_cap_nim : 100));
      setCoinRateInput(String(c.coin_nim_rate && c.coin_nim_rate > 0 ? c.coin_nim_rate : 1));
      setBinary(b);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); loadGoldens(); doLint(); loadQuestPool(); }, []); // eslint-disable-line

  async function saveCap() {
    const n = parseFloat(capInput);
    if (!Number.isFinite(n) || n <= 0) { alert("Daily earn cap must be a positive number."); return; }
    setSaving(true);
    try {
      const updated = await saveAppConfig({ daily_earn_cap_nim: n });
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function saveCoinRate() {
    const n = parseFloat(coinRateInput);
    if (!Number.isFinite(n) || n <= 0) { alert("Coin → NIM rate must be a positive number."); return; }
    setSaving(true);
    try {
      const updated = await saveAppConfig({ coin_nim_rate: n });
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function toggleLeaderboard(key: "daily_leaderboard_enabled" | "weekly_leaderboard_enabled") {
    if (!cfg) return;
    setSaving(true);
    try {
      const updated = await saveAppConfig(
        key === "daily_leaderboard_enabled"
          ? { daily_leaderboard_enabled: !cfg.daily_leaderboard_enabled }
          : { weekly_leaderboard_enabled: !cfg.weekly_leaderboard_enabled }
      );
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function saveVersion() {
    const n = parseInt(versionInput, 10);
    if (!Number.isFinite(n) || n <= 0) { alert("Version must be a positive number."); return; }
    setSaving(true);
    try {
      const updated = await saveAppConfig({ replay_version: n });
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function doSetMode(mode: "off" | "force" | "normal") {
    if (mode === "force" && !confirm(
      "Force update: new games are blocked immediately for everyone. Continue?"
    )) return;
    if (mode === "normal" && !confirm(
      "Normal update: new games stay open until the current weekly leaderboard period ends, then block automatically. Continue?"
    )) return;
    setSaving(true);
    try {
      const updated = await setUpdateMode(mode);
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function doComplete() {
    if (!confirm("Complete update and resume play for everyone?")) return;
    setSaving(true);
    try {
      const updated = await completeUpdate();
      setCfg(updated);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setSaving(false);
    }
  }

  async function doClearReplays() {
    if (!confirm(
      "Remove ALL replay logs? Scores, stats, and rewards already earned stay untouched — only the recorded replay data is deleted."
    )) return;
    setClearing(true);
    try {
      const res = await clearAllReplays();
      alert(`Cleared ${res.sessions_cleared} replay logs + ${res.archive_deleted} archived failed-replay files.`);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setClearing(false);
    }
  }

  async function doUpload() {
    const f = fileRef.current?.files?.[0];
    if (!f) { alert("Choose a .zip or .exe file first."); return; }
    if (!confirm(`Upload ${f.name} as the new replay verifier binary? The worker pool will restart.`)) return;
    setUploading(true);
    try {
      const res = await uploadReplayBinary(f);
      alert(`Uploaded ${res.file} (${fmtBytes(res.size)}). Worker pool restarting.`);
      if (fileRef.current) fileRef.current.value = "";
      const b = await fetchReplayBinaryStatus();
      setBinary(b);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setUploading(false);
    }
  }

  async function doDeleteFile(name: string) {
    if (!confirm(`Delete "${name}" from the servergames folder? If this is the active binary/pck, the worker pool restarts and games will fail to verify until a new one is uploaded.`)) return;
    setDeletingFile(name);
    try {
      await deleteReplayBinaryFile(name);
      const b = await fetchReplayBinaryStatus();
      setBinary(b);
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setDeletingFile(null);
    }
  }

  if (loading) return <div style={{ padding: 32, textAlign: "center", color: "var(--text-muted)" }}>Loading…</div>;
  if (error)   return <div style={{ padding: 16, color: "var(--red)" }}>{error}</div>;
  if (!cfg)    return null;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>

      {/* ── Update mode ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Game Update Mode</span>
          {cfg.update_active ? (
            <span className="badge badge-red">⚠ ACTIVE — new games blocked</span>
          ) : cfg.update_mode === "normal" ? (
            <span className="badge badge-yellow">⏳ Scheduled — blocks when week {cfg.update_scheduled_week} ends</span>
          ) : (
            <span className="badge badge-green">✓ Off — play as normal</span>
          )}
        </div>
        <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 12, lineHeight: 1.6 }}>
          <b>Force</b>: blocks starting new games immediately, for everyone.<br/>
          <b>Normal</b>: keeps the game open until the current weekly leaderboard period ends, then
          blocks automatically — use this for a clean push at week boundary.<br/>
          While blocked, players see a &quot;Game updating&quot; toast instead of starting a new game.
          Click <b>Complete Update</b> once the new client + replay binary are live to resume play.
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button className="btn" disabled={saving} onClick={() => doSetMode("force")}>Force Update</button>
          <button className="btn" disabled={saving} onClick={() => doSetMode("normal")}>Normal Update (end of week)</button>
          <button className="btn" disabled={saving || cfg.update_mode === "off"} onClick={() => doSetMode("off")}>Cancel Scheduled Update</button>
          <button className="btn btn-active" disabled={saving || (!cfg.update_active && cfg.update_mode === "off")} onClick={doComplete}>
            ✓ Complete Update (resume play)
          </button>
        </div>
      </div>

      {/* ── Leaderboards + replay version ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 12 }}>Leaderboards &amp; Versioning</div>
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
            <input type="checkbox" checked={cfg.daily_leaderboard_enabled} disabled={saving}
              onChange={() => toggleLeaderboard("daily_leaderboard_enabled")} />
            Daily leaderboard enabled
          </label>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
            <input type="checkbox" checked={cfg.weekly_leaderboard_enabled} disabled={saving}
              onChange={() => toggleLeaderboard("weekly_leaderboard_enabled")} />
            Weekly leaderboard enabled
          </label>

          <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
            <span style={{ fontSize: 13, color: "var(--text-muted)" }}>Replay version:</span>
            <input type="number" min={1} value={versionInput}
              onChange={e => setVersionInput(e.target.value)}
              style={{ width: 80, padding: "4px 8px", fontSize: 13 }} />
            <button className="btn" disabled={saving || versionInput === String(cfg.replay_version)} onClick={saveVersion}>
              Save
            </button>
            <span style={{ fontSize: 11, color: "var(--text-muted)" }}>
              Bump this whenever you push a new client build + replay binary together —
              submits from an old client (mismatched version) are rejected and never saved.
            </span>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
            <span style={{ fontSize: 13, color: "var(--text-muted)" }}>Daily earn cap (NIM):</span>
            <input type="number" min={0.01} step="any" value={capInput}
              onChange={e => setCapInput(e.target.value)}
              style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
            <button className="btn" disabled={saving || capInput === String(cfg.daily_earn_cap_nim)} onClick={saveCap}>
              Save
            </button>
            <span style={{ fontSize: 11, color: "var(--text-muted)" }}>
              Max NIM a player can earn per day from in-game coins. Quest and leaderboard payouts are not capped by this.
            </span>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
            <span style={{ fontSize: 13, color: "var(--text-muted)" }}>Coin → NIM rate:</span>
            <input type="number" min={0.000001} step="any" value={coinRateInput}
              onChange={e => setCoinRateInput(e.target.value)}
              style={{ width: 100, padding: "4px 8px", fontSize: 13 }} />
            <button className="btn" disabled={saving || coinRateInput === String(cfg.coin_nim_rate)} onClick={saveCoinRate}>
              Save
            </button>
            <span style={{ fontSize: 11, color: "var(--text-muted)" }}>
              How many NIM 1 in-game coin is worth (e.g. 0.001 = 1000 coins per NIM). Applied to coins
              collected in a run, still subject to the daily earn cap above.
            </span>
          </div>
        </div>
      </div>

      {/* ── Quest rewards ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8 }}>Quest Rewards</div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 10, lineHeight: 1.6 }}>
          Override the NIM reward for any daily quest template. Players who already have that quest
          assigned for today keep whatever reward they were originally given — a change here only
          affects quests generated from now on. Use &quot;Reset&quot; to go back to the hardcoded default.
        </div>
        {questLoading ? (
          <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 12 }}>Loading…</div>
        ) : questPool.length === 0 ? (
          <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 12 }}>
            No quest templates found.
          </div>
        ) : (
          <table>
            <thead>
              <tr><th>Type</th><th>Target</th><th>Description</th><th>Default</th><th>Reward (NIM)</th><th></th></tr>
            </thead>
            <tbody>
              {questPool.map(q => {
                const rewardKey = `${q.idx}:reward`;
                const targetKey = `${q.idx}:target`;
                const rewardBusy = questSavingKey === rewardKey;
                const targetBusy = questSavingKey === targetKey;
                return (
                  <tr key={q.idx}>
                    <td style={{ fontFamily: "monospace", fontSize: 11 }}>{q.quest_type}</td>
                    <td>
                      <input type="number" min={1} step={1} value={targetInputs[q.idx] ?? ""}
                        onChange={e => setTargetInputs(prev => ({ ...prev, [q.idx]: e.target.value }))}
                        style={{ width: 70, padding: "3px 6px", fontSize: 12 }} />
                      {q.target_overridden && <span className="badge badge-yellow" style={{ fontSize: 10, marginLeft: 4 }}>ovr</span>}
                      <div style={{ display: "flex", gap: 4, marginTop: 4 }}>
                        <button className="btn" style={{ fontSize: 10, padding: "1px 6px" }}
                          disabled={targetBusy || targetInputs[q.idx] === String(q.target)}
                          onClick={() => doSaveQuestTarget(q)}>
                          {targetBusy ? "…" : "Save"}
                        </button>
                        {q.target_overridden && (
                          <button className="btn" style={{ fontSize: 10, padding: "1px 6px" }}
                            disabled={targetBusy} onClick={() => doResetQuestTarget(q)}>
                            Reset
                          </button>
                        )}
                      </div>
                    </td>
                    <td style={{ fontSize: 12 }}>{q.description}</td>
                    <td style={{ fontSize: 12, color: "var(--text-muted)" }}>
                      target {q.default_target} / {q.default_reward_nim} NIM
                    </td>
                    <td>
                      <input type="number" min={0} step="any" value={questInputs[q.idx] ?? ""}
                        onChange={e => setQuestInputs(prev => ({ ...prev, [q.idx]: e.target.value }))}
                        style={{ width: 80, padding: "3px 6px", fontSize: 12 }} />
                      {q.overridden && <span className="badge badge-yellow" style={{ fontSize: 10, marginLeft: 6 }}>overridden</span>}
                    </td>
                    <td style={{ display: "flex", gap: 6 }}>
                      <button className="btn" style={{ fontSize: 11, padding: "2px 8px" }}
                        disabled={rewardBusy || questInputs[q.idx] === String(q.reward_nim)}
                        onClick={() => doSaveQuestReward(q)}>
                        {rewardBusy ? "…" : "Save"}
                      </button>
                      {q.overridden && (
                        <button className="btn" style={{ fontSize: 11, padding: "2px 8px" }}
                          disabled={rewardBusy} onClick={() => doResetQuestReward(q)}>
                          Reset
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {/* ── Replay verifier binary ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 10 }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Replay Verifier Binary</span>
          {binary && (
            binary.healthy
              ? <span className="badge badge-green">✓ Healthy</span>
              : <span className="badge badge-red">⚠ Not detected</span>
          )}
        </div>
        {binary && (
          <>
            <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 8, fontFamily: "monospace" }}>
              dir: {binary.dir} <br/>
              active binary: {binary.binary || "—"}
            </div>
            {(binary.files ?? []).length > 0 && (
              <table style={{ marginBottom: 12 }}>
                <thead><tr><th>File</th><th>Size</th><th>Modified</th><th></th></tr></thead>
                <tbody>
                  {(binary.files ?? []).map(f => (
                    <tr key={f.name}>
                      <td style={{ fontFamily: "monospace", fontSize: 11 }}>{f.name}</td>
                      <td style={{ fontSize: 11 }}>{fmtBytes(f.size)}</td>
                      <td style={{ fontSize: 11 }}>{fmtDate(f.modified_at)}</td>
                      <td>
                        <button
                          className="btn"
                          style={{ fontSize: 11, padding: "2px 8px", background: "var(--red)" }}
                          disabled={deletingFile === f.name}
                          onClick={() => doDeleteFile(f.name)}
                        >
                          {deletingFile === f.name ? "Deleting…" : "Delete"}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </>
        )}
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 10 }}>
          Upload a new replay.zip (Linux build) or replay.exe (Windows/Godot export) to replace
          the one this server uses to verify replays. The worker pool restarts automatically
          and picks it up within a few seconds.
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          <input ref={fileRef} type="file" accept=".zip,.exe" style={{ fontSize: 12 }} />
          <button className="btn btn-active" disabled={uploading} onClick={doUpload}>
            {uploading ? "Uploading…" : "⬆ Upload & Replace"}
          </button>
        </div>
      </div>

      {/* ── Static determinism lint ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8, flexWrap: "wrap" }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Static Determinism Lint</span>
          {lintFindings && (
            lintFindings.length === 0
              ? <span className="badge badge-green">✓ Clean</span>
              : <span className="badge badge-yellow">⚠ {lintFindings.length} finding{lintFindings.length === 1 ? "" : "s"}</span>
          )}
          <button className="btn" style={{ marginLeft: "auto" }} disabled={linting} onClick={doLint}>
            {linting ? "Scanning…" : "↻ Re-scan"}
          </button>
        </div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 10, lineHeight: 1.6 }}>
          Scans every game/scripts/*.gd file for code patterns known to break client/server replay
          determinism: bare randf()/randi() not going through a seeded RNG, wall-clock time reads
          that would diverge during a fast-forwarded server replay, hard .free() calls (the exact
          cause of the 0xC0000005 headless crash fixed earlier), and array mutation while a loop is
          iterating over it. Re-run this after any Godot script change. A line that's confirmed safe
          (e.g. cosmetic-only, already gated behind <code>_is_headless</code>) can be silenced by
          appending <code># determinism-ok</code> to it.
        </div>
        {lintError && <div style={{ color: "var(--red)", fontSize: 12, marginBottom: 8 }}>{lintError}</div>}
        {lintRanAt && (
          <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 8 }}>
            last scan: {new Date(lintRanAt).toLocaleTimeString("en-GB")}
          </div>
        )}
        {lintFindings && lintFindings.length > 0 && (
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {lintFindings.map((f, i) => (
              <div key={i} style={{
                border: "1px solid var(--border)", borderRadius: 6, padding: "8px 12px",
                background: "var(--surface2)",
              }}>
                <div style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 4, flexWrap: "wrap" }}>
                  <span style={{ fontFamily: "monospace", fontSize: 11, fontWeight: 600 }}>
                    {f.file}:{f.line}
                  </span>
                  <span className="badge badge-yellow" style={{ fontSize: 10 }}>{f.rule}</span>
                </div>
                <div style={{ fontFamily: "monospace", fontSize: 11, color: "var(--text-muted)", marginBottom: 4, whiteSpace: "pre-wrap" }}>
                  {f.snippet}
                </div>
                <div style={{ fontSize: 11, lineHeight: 1.5 }}>{f.message}</div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* ── Golden replays: determinism self-test ── */}
      <div className="card" style={{ padding: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8, flexWrap: "wrap" }}>
          <span style={{ fontWeight: 600, fontSize: 13 }}>Determinism Self-Test (Golden Replays)</span>
          {testResults && (
            testResults.every(r => r.pass)
              ? <span className="badge badge-green">✓ All {testResults.length} passed</span>
              : <span className="badge badge-red">⚠ {testResults.filter(r => !r.pass).length}/{testResults.length} failed — regression!</span>
          )}
        </div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 10, lineHeight: 1.6 }}>
          Golden replays are real, previously-verified sessions pinned with the exact score they
          produced. Run this after uploading a new replay binary or any Godot code change — it
          re-simulates each pinned replay against the CURRENT binary and checks for an exact
          (zero-tolerance) score match. Any mismatch means simulation behavior changed and needs
          investigating before the build goes live. Pin a session as golden from its ▶ row in
          Completed sessions.
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 12 }}>
          <button className="btn btn-active" disabled={testing || goldens.length === 0} onClick={doSelfTest}>
            {testing ? "Running…" : "▶ Run Self-Test"}
          </button>
          {testRanAt && (
            <span style={{ fontSize: 11, color: "var(--text-muted)" }}>
              last run: {new Date(testRanAt).toLocaleTimeString("en-GB")}
            </span>
          )}
        </div>

        {goldenLoading ? (
          <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 12 }}>Loading…</div>
        ) : goldens.length === 0 ? (
          <div style={{ padding: 16, textAlign: "center", color: "var(--text-muted)", fontSize: 12 }}>
            No golden replays pinned yet.
          </div>
        ) : (
          <table>
            <thead>
              <tr><th>Label</th><th>Seed</th><th>Char</th><th>Expected score</th><th>Result</th><th>Pinned</th><th></th></tr>
            </thead>
            <tbody>
              {goldens.map(g => {
                const res = testResults?.find(r => r.id === g.id);
                return (
                  <tr key={g.id}>
                    <td style={{ fontSize: 12 }}>{g.label}</td>
                    <td style={{ fontFamily: "monospace", fontSize: 11, color: "var(--text-muted)" }}>{g.seed}</td>
                    <td style={{ fontSize: 12 }}>{g.char}</td>
                    <td style={{ fontWeight: 600, fontSize: 12 }}>{g.expected_score.toLocaleString()}</td>
                    <td style={{ fontSize: 11 }}>
                      {!res ? (
                        <span style={{ color: "var(--text-muted)" }}>not run yet</span>
                      ) : res.error ? (
                        <span style={{ color: "var(--red)" }}>⚠ sim error: {res.error}</span>
                      ) : res.pass ? (
                        <span style={{ color: "var(--green)" }}>✓ {res.actual_score.toLocaleString()}</span>
                      ) : (
                        <span style={{ color: "var(--red)" }}>
                          ✗ got {res.actual_score.toLocaleString()} (expected {res.expected_score.toLocaleString()})
                        </span>
                      )}
                    </td>
                    <td style={{ fontSize: 11, color: "var(--text-muted)" }}>{fmtDate(g.saved_at)}</td>
                    <td>
                      <button className="btn" style={{ fontSize: 11, padding: "2px 7px" }}
                        onClick={() => doDeleteGolden(g.id, g.label)}>
                        Unpin
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {/* ── Danger zone ── */}
      <div className="card" style={{ padding: 16, borderColor: "var(--red)" }}>
        <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8, color: "var(--red)" }}>Danger Zone</div>
        <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 10 }}>
          Deletes every stored replay log (and the failed-replay archive on disk). Scores,
          quest progress, and rewards already paid out are left untouched — only the raw
          replay recordings are removed. Use this after pushing a new client/replay build so
          old replays (recorded against the old build) don&apos;t linger around.
        </div>
        <button className="btn" style={{ background: "var(--red)" }} disabled={clearing} onClick={doClearReplays}>
          {clearing ? "Clearing…" : "🗑 Remove All Replays"}
        </button>
      </div>
    </div>
  );
}
