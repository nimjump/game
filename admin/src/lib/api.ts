export const BASE     = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8080";
export const GAME_URL = process.env.NEXT_PUBLIC_GAME_URL   ?? "https://nimjump.io";

// Every call below goes through this instead of the global fetch, so the
// admin session cookie (see backend/handlers/admin_session.go) always gets
// sent — including in dev, where this app runs standalone on ADMIN_PORT and
// BASE points at a different origin (the backend's PORT). In production the
// proxy makes both same-origin, where this is a no-op (cookies already go
// out by default), but it doesn't hurt there either.
const rawFetch: typeof globalThis.fetch =
  typeof window !== "undefined" ? window.fetch.bind(window) : globalThis.fetch;
function fetch(input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> {
  return rawFetch(input, { credentials: "include", ...init });
}

export interface Session {
  session_id: string;
  seed: string;
  state: "pending" | "active" | "completed" | "flagged" | "replay_failed";
  player_id?: string;
  nickname?: string;
  client_score: number;
  server_score: number;
  ticks: number;
  char: number;
  // Was gyro tilt control active during this match (drives the gyro-only
  // movement ramp — see game/scripts/Player.gd's set_gyro_control_active
  // doc comment). false/missing = tap control (instant movement, no ramp).
  gyro_active?: boolean;
  // BUG FIX: this used to be named `log`, but handleReplay in
  // backend/handlers/replay_handlers.go has always sent the RLE-encoded
  // input log back under the key "replay_log" (matching the game client's
  // own field name for it) — never "log". Session.log was therefore
  // always undefined here, silently, which is exactly why the replay
  // detail page's Frame Timing / Input Heatmap charts always rendered
  // "No log data" even for sessions that genuinely had a log recorded.
  replay_log?: string;
  flagged: boolean;
  reason?: string;
  replay_error?: string;
  has_log?: boolean;
  created_at: number;
  submitted_at?: number;
  elapsed_sec?: number;
}

export interface ClientLogEntry {
  id: string;
  level: "error" | "warn" | "info";
  message: string;
  count: number;
  players: string[];
  ips: string[];
  devices: string[];
  created_at: number;
  updated_at: number;
  // convenience alias used by page.tsx (maps to players[0])
  player_id?: string;
}

export interface FailedReplay {
  session_id: string;
  player_id?: string;
  nickname?: string;
  client_score: number;
  replay_error: string;
  submitted_at: number;
  has_log: boolean;
}

export interface Overview {
  counts: {
    total: number;
    pending: number;
    active: number;
    completed: number;
    flagged: number;
    replay_failed?: number;
  };
  replay: {
    binary_ok: boolean;
    binary_path: string;
    queue_len: number;
    max_workers: number;
  };
  rewards?: {
    total_nim_sent: number;
    total_nim_pending: number;
    sent_count: number;
    pending_count: number;
  };
  system: {
    goroutines: number;
    heap_mb: number;
    uptime_sec: number;
    cpu_count: number;
  };
  resources?: {
    ram_total_bytes: number;
    ram_used_bytes: number;
    disk_total_bytes: number;
    disk_used_bytes: number;
  };
  active_sessions: Session[];
  recent_sessions: Session[];
  server_time: number;
}

function parseSessions(text: string): Session[] {
  const fixed = text.replace(/"seed"\s*:\s*(\d+)/g, '"seed": "$1"');
  const data = JSON.parse(fixed);
  return Array.isArray(data) ? data : (data.entries ?? data.sessions ?? []);
}

export async function fetchOverview(): Promise<Overview> {
  const r = await fetch(`${BASE}/backend/admin/overview`, { cache: "no-store" });
  if (!r.ok) throw new Error("overview fetch failed");
  const text = await r.text();
  const fixed = text.replace(/"seed"\s*:\s*(\d+)/g, '"seed": "$1"');
  return JSON.parse(fixed) as Overview;
}

export async function fetchSessions(flagged?: boolean): Promise<Session[]> {
  const url = flagged ? `${BASE}/backend/sessions?flagged=1` : `${BASE}/backend/sessions`;
  const r = await fetch(url, { cache: "no-store" });
  if (!r.ok) throw new Error("sessions fetch failed");
  return parseSessions(await r.text());
}

export async function fetchAdminSessions(state?: string, player?: string): Promise<Session[]> {
  const params = new URLSearchParams({ limit: "500" });
  if (state) params.set("state", state);
  if (player) params.set("player", player);
  const r = await fetch(`${BASE}/backend/admin/sessions?${params}`, { cache: "no-store" });
  if (!r.ok) throw new Error("admin sessions fetch failed");
  const text = await r.text();
  const data = JSON.parse(text);
  return data.sessions ?? [];
}

export async function fetchSession(id: string): Promise<Session | null> {
  // /backend/replay/{id} is the PUBLIC route — it requires the app_ts/app_sig
  // HMAC signature that only the compiled game client can produce (see
  // backend/handlers/appsig.go). The admin panel has no way to produce that
  // signature and isn't supposed to — it authenticates via the admin session
  // cookie instead, so this hits the admin-only mirror route
  // (/backend/admin/replay/{id}, same handler, gated by requireAdminSession)
  // which corsMiddleware exempts from the app_sig check entirely.
  const r = await fetch(`${BASE}/backend/admin/replay/${id}`, { cache: "no-store" });
  if (!r.ok) return null;
  const text = await r.text();
  const fixed = text.replace(/"seed"\s*:\s*(\d+)/g, '"seed": "$1"');
  const data = JSON.parse(fixed);
  return data as Session;
}

export async function fetchClientLogs(level?: string): Promise<{ logs: ClientLogEntry[]; total: number }> {
  const params = level ? `?level=${encodeURIComponent(level)}` : "";
  const r = await fetch(`${BASE}/backend/admin/client-logs${params}`, { cache: "no-store" });
  if (!r.ok) throw new Error("client-logs fetch failed");
  const data = await r.json();
  return { logs: data.logs ?? [], total: data.total ?? (data.logs?.length ?? 0) };
}

export async function deleteClientLogs(): Promise<{ ok: boolean; deleted: number }> {
  const r = await fetch(`${BASE}/backend/admin/client-logs`, { method: "DELETE" });
  if (!r.ok) throw new Error("delete client logs failed");
  return r.json();
}

export async function fetchFailedReplays(): Promise<FailedReplay[]> {
  const r = await fetch(`${BASE}/backend/admin/replay-failed`, { cache: "no-store" });
  if (!r.ok) throw new Error("failed replays fetch failed");
  const data = await r.json();
  return data.sessions ?? [];
}

export interface ReplayRetryResult {
  ok: boolean;
  session_id?: string;
  server_score?: number;
  client_score?: number;
  flagged?: boolean;
  reason?: string;
  error?: string;
}

// Deliberately does NOT throw on a non-2xx response (e.g. sim_error,
// no_replay_log) — callers branch on `res.ok`/`res.reason`/`res.error`
// themselves, same pattern as adminSessionAction below.
export async function retryReplay(sessionId: string): Promise<ReplayRetryResult> {
  const r = await fetch(`${BASE}/backend/admin/replay-retry/${sessionId}`, { method: "POST" });
  const data = await r.json().catch(() => ({}));
  return data as ReplayRetryResult;
}

export type SessionAction = "approve" | "unflag" | "reject" | "retry";

export interface SessionActionResult {
  ok: boolean;
  action?: string;
  session_id?: string;
  state?: string;
  reason?: string;
  flagged?: boolean;
  server_score?: number;
  message?: string;
  error?: string;
}

export async function adminSessionAction(
  sessionId: string,
  action: SessionAction,
  reason?: string
): Promise<SessionActionResult> {
  const r = await fetch(`${BASE}/backend/admin/session/${sessionId}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, reason }),
  });
  const data = await r.json();
  return data as SessionActionResult;
}

// Matches questOut in backend/handlers/admin_player.go — id/type, not
// quest_id/name; "description" is the only display label the backend sends.
export interface PlayerQuest {
  id: string;
  type: string;
  description: string;
  target: number;
  progress: number;
  completed: boolean;
  claimed: boolean;
  reward_nim: number;
}

// Matches game.DailyCapStats's JSON tags (backend/game/daily_earn_cap.go).
export interface DailyCapStats {
  daily_earned: number;
  daily_cap: number;
  daily_cap_remaining: number;
  daily_cap_reset_at: number;
  daily_cap_full: boolean;
}

export interface PendingReward {
  id: string;
  player_id: string;
  amount_nim: number;
  reason: string;
  status: string;
  created_at: number;
  sent_at?: number;
  tx_hash?: string;
}

// Matches the map[string]any built by handleAdminPlayer in
// backend/handlers/admin_player.go — session fields here are a subset of
// Session (this endpoint builds its own trimmed sessionOut shape, not the
// full Session type used elsewhere).
export interface PlayerProfileSession {
  session_id: string;
  state: string;
  client_score: number;
  server_score: number;
  ticks: number;
  char: number;
  flagged: boolean;
  reason?: string;
  replay_error?: string;
  submitted_at: number;
  has_log: boolean;
}

export interface PlayerStreak {
  count: number;        // consecutive days including today (0 if streak is dead)
  last_day: string;      // "2026-07-08" (UTC+3) — last day actually counted
  longest_run: number;   // best streak ever reached
}

export interface PlayerCosmetics {
  owned: string[];               // item IDs the player has purchased
  equipped: Record<string, string>; // slot -> item_id ("hat"/"glasses"/"outfit"/"shoes")
}

// Matches ipOut in backend/handlers/admin_player.go (backed by
// game.PlayerIPRecord + game.IPGeo — see backend/game/player_ip.go).
// country_code is "" if not yet/never resolvable, "XX" for
// private/loopback/LAN addresses (dev/testing traffic).
export interface PlayerIPEntry {
  ip: string;
  country_code: string;
  country_name: string;
  first_seen: number;
  last_seen: number;
  count: number;
}

export interface PlayerProfile {
  player_id: string;
  nickname: string;
  cooldown_end: number;
  streak: PlayerStreak;
  cosmetics: PlayerCosmetics;
  ips: PlayerIPEntry[];
  stats: {
    best_score: number;
    total_games: number;
    total_ticks: number;
    total_kills: number;
    total_platforms: number;
  };
  daily_cap: DailyCapStats;
  quests: PlayerQuest[];
  quest_nim_today: number;
  quest_nim_claimed: number;
  total_nim_received: number; // lifetime, all "sent" rewards (not capped to recent_sessions/rewards list length)
  device?: PlayerDevice | null;
  leaderboard: {
    daily_rank?: number;
    weekly_rank?: number;
    daily_period?: string;
    weekly_period?: string;
  };
  recent_sessions: PlayerProfileSession[];
  rewards: PendingReward[];
}

export interface PlayerDevice {
  player_id: string;
  user_agent: string;
  platform: string;
  screen: string;
  dpr: string;
  updated_at: number;
}

export interface DeviceBreakdownEntry {
  platform: string;
  count: number;
}

export async function fetchDeviceBreakdown(): Promise<DeviceBreakdownEntry[]> {
  const r = await fetch(`${BASE}/backend/admin/device-breakdown`, { cache: "no-store" });
  if (!r.ok) throw new Error("device breakdown fetch failed");
  const d = await r.json();
  return d.platforms ?? [];
}

export async function searchPlayer(q: string): Promise<PlayerProfile | null> {
  const r = await fetch(`${BASE}/backend/admin/player?q=${encodeURIComponent(q)}`, { cache: "no-store" });
  if (!r.ok) return null;
  const text = await r.text();
  const fixed = text.replace(/"seed"\s*:\s*(\d+)/g, '"seed": "$1"');
  return JSON.parse(fixed) as PlayerProfile;
}

export interface LBEntry {
  rank: number;
  player_id: string;
  nickname?: string;
  server_score: number;
  score?: number;
}

export interface LeaderboardResponse {
  period_type: string;
  period: string;
  entries: LBEntry[];
  enabled?: boolean;
}

// Backend expects "period_type", not "type" (see handleLeaderboard in
// backend/handlers/stats.go) — using the wrong param name meant this
// silently always fell back to the daily leaderboard, regardless of
// which tab was selected.
export async function fetchLeaderboard(periodType: string, limit = 100): Promise<LeaderboardResponse> {
  const r = await fetch(`${BASE}/backend/admin/leaderboard?period_type=${periodType}&limit=${limit}`, { cache: "no-store" });
  if (!r.ok) throw new Error("leaderboard fetch failed");
  return r.json();
}

// Resets the daily or weekly leaderboard with one click. Doesn't delete any
// sessions/scores/replays — just marks "now" as the cutoff for the
// currently-open day/week, so older scores drop off that board (alltime is
// untouched). See handleAdminLeaderboardReset in backend/handlers/admin_system.go.
export async function resetLeaderboard(periodType: "daily" | "weekly"): Promise<{ ok: boolean; period_type: string; period: string }> {
  const r = await fetch(`${BASE}/backend/admin/leaderboard/reset`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ period_type: periodType }),
  });
  if (!r.ok) throw new Error("leaderboard reset failed");
  return r.json();
}

export interface AnalyticsReward {
  id: string;
  player_id: string;
  nickname?: string;
  amount_nim: number;
  reason: string;
  status: string;
  tx_hash?: string;
  sent_at?: number;
  created_at: number;
}

export interface Analytics {
  generated_at: number;
  today: string;
  week_start: string;
  players: {
    total: number;
    today: number;
    this_week: number;
    new_today: number;
    new_week: number;
  };
  sessions: {
    total: number;
    today: number;
    this_week: number;
    completed: number;
    flagged: number;
  };
  playtime_sec: {
    total: number;
    today: number;
    this_week: number;
  };
  nim: {
    total_distributed: number;
    distributed_today: number;
    distributed_this_week: number;
    quest_total: number;
    quest_today: number;
    quest_this_week: number;
    leaderboard_total: number;
    leaderboard_today: number;
    leaderboard_this_week: number;
  };
  reward_queue: {
    pending: number;
    failed: number;
    sent: number;
  };
  recent_payments: AnalyticsReward[];
  queued_payments: AnalyticsReward[];
  nimiq_balance: {
    balance_nim: number;
    wallet_address: string;
    low_threshold: number;
    is_low: boolean;
    error?: string;
  };
}

export async function fetchAnalytics(): Promise<Analytics> {
  const r = await fetch(`${BASE}/backend/admin/analytics`, { cache: "no-store" });
  if (!r.ok) throw new Error("analytics fetch failed");
  return r.json();
}

export interface RegisteredPlayer {
  player_id: string;
  nickname: string;
  registered_at: number;
  is_active: boolean;
  token_expires_at?: number;
  session_count: number;
  last_seen?: number;
  quests_completed: number;
  quests_total: number;
  daily_rank: number;  // 0 = not ranked this period
  weekly_rank: number; // 0 = not ranked this period
  daily_cap: DailyCapStats;
  total_nim_received: number; // lifetime, all "sent" rewards
  streak: number; // consecutive days including today (0 if streak is dead)
}

export interface PlayersListResponse {
  total: number;
  players: RegisteredPlayer[];
}

export async function fetchPlayersList(limit = 50, offset = 0): Promise<PlayersListResponse> {
  const r = await fetch(`${BASE}/backend/admin/players?limit=${limit}&offset=${offset}`, { cache: "no-store" });
  if (!r.ok) throw new Error("players list fetch failed");
  return r.json();
}

// ── Streak tab: aggregate + per-player breakdown ────────────────────────────

export interface StreakPlayerRow {
  player_id: string;
  nickname: string;
  streak_day: number;   // 0 = streak has lapsed
  longest_run: number;
  total_claimed_nim: number;
  claims_count: number;
  last_claim_at?: number;
}

export interface StreaksResponse {
  total_nim_distributed: number;
  total_claims: number;
  unique_claimers: number;
  active_streaks: number;
  total: number;
  offset: number;
  limit: number;
  players: StreakPlayerRow[];
}

export async function fetchStreaks(limit = 50, offset = 0): Promise<StreaksResponse> {
  const r = await fetch(`${BASE}/backend/admin/streaks?limit=${limit}&offset=${offset}`, { cache: "no-store" });
  if (!r.ok) throw new Error("streaks fetch failed");
  return r.json();
}

// ── App config: leaderboard toggles, update lock ────────────────────────────

export interface AppConfig {
  daily_leaderboard_enabled: boolean;
  weekly_leaderboard_enabled: boolean;
  // update_active — true = new games are currently locked/blocked. Set via
  // setUpdateActive() below, not through saveAppConfig (same reason as
  // before: keeps the one on/off switch as a single dedicated route).
  update_active: boolean;
  daily_earn_cap_nim?: number;
  coin_nim_rate?: number;
  // Streak claim reward knobs — reward(day) = min(base + extra*(day-1), max).
  // See backend/game/streak_reward.go. undefined = not configured yet
  // (server falls back to its own hardcoded defaults).
  streak_reward_base_nim?: number;
  streak_reward_extra_per_day_nim?: number;
  streak_reward_max_nim?: number;
  // IP anti-multi-accounting guard — max distinct accounts per IP per day
  // that can claim ANY reward (streak, quest, in-game coin). See
  // backend/game/ip_reward_guard.go.
  max_reward_accounts_per_ip?: number;
}

export async function fetchAppConfig(): Promise<AppConfig> {
  const r = await fetch(`${BASE}/backend/admin/config`, { cache: "no-store" });
  if (!r.ok) throw new Error("config fetch failed");
  return r.json();
}

export async function saveAppConfig(patch: Partial<{
  daily_leaderboard_enabled: boolean;
  weekly_leaderboard_enabled: boolean;
  daily_earn_cap_nim: number;
  coin_nim_rate: number;
  streak_reward_base_nim: number;
  streak_reward_extra_per_day_nim: number;
  streak_reward_max_nim: number;
  max_reward_accounts_per_ip: number;
}>): Promise<AppConfig> {
  const r = await fetch(`${BASE}/backend/admin/config`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patch),
  });
  if (!r.ok) throw new Error("config save failed");
  return r.json();
}

// ── Quest reward pool (admin-editable NIM rewards per quest template) ──────────

export interface QuestPoolEntry {
  idx: number; // stable key for setQuestReward/setQuestTarget calls
  quest_type: string;
  target: number;         // effective — override if set, else default
  default_target: number;
  description: string;
  default_reward_nim: number;
  reward_nim: number; // effective — override if set, else default
  overridden: boolean;         // reward overridden
  target_overridden: boolean;
}

export async function fetchQuestPool(): Promise<QuestPoolEntry[]> {
  const r = await fetch(`${BASE}/backend/admin/quest-pool`, { cache: "no-store" });
  if (!r.ok) throw new Error("quest pool fetch failed");
  const d = await r.json();
  return d.quests ?? [];
}

// Pass rewardNIM = null to reset that template back to its hardcoded default.
export async function setQuestReward(idx: number, rewardNIM: number | null): Promise<QuestPoolEntry[]> {
  const r = await fetch(`${BASE}/backend/admin/quest-reward`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ idx, reward_nim: rewardNIM }),
  });
  if (!r.ok) throw new Error("quest reward save failed");
  const d = await r.json();
  return d.quests ?? [];
}

// Pass target = null to reset that template's goal number back to default.
export async function setQuestTarget(idx: number, target: number | null): Promise<QuestPoolEntry[]> {
  const r = await fetch(`${BASE}/backend/admin/quest-target`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ idx, target }),
  });
  if (!r.ok) throw new Error("quest target save failed");
  const d = await r.json();
  return d.quests ?? [];
}

export interface LeaderboardPrizes {
  first: number;
  second: number;
  third: number;
}

export interface LeaderboardConfig {
  daily: LeaderboardPrizes;
  weekly: LeaderboardPrizes;
}

export async function fetchLeaderboardPrizes(): Promise<LeaderboardConfig> {
  // /backend/leaderboard/prizes is the PUBLIC route, gated by the game
  // client's app_ts/app_sig signature (appsig.go) — the admin panel can't
  // produce that, so this hits the admin-session-gated mirror instead (see
  // server.go). Was silently failing before: PrizesCard bails out with
  // `if (!cfg) return null`, so the whole daily/weekly payout editor just
  // never appeared, with no visible error.
  const r = await fetch(`${BASE}/backend/admin/prizes`, { cache: "no-store" });
  if (!r.ok) throw new Error("prizes fetch failed");
  return r.json();
}

export async function saveLeaderboardPrizes(cfg: LeaderboardConfig): Promise<void> {
  const r = await fetch(`${BASE}/backend/admin/prizes`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(cfg),
  });
  if (!r.ok) throw new Error("prizes save failed");
}

// setUpdateActive — the game-update lock's only two states now: pass true
// to "Activate" (block new games from starting) or false to "Deactivate"
// (resume normal play). Replaces the old 3-state setUpdateMode/completeUpdate
// pair — see backend/game/appconfig.go's package doc comment for why.
export async function setUpdateActive(active: boolean): Promise<AppConfig> {
  const r = await fetch(`${BASE}/backend/admin/update-active`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ active }),
  });
  if (!r.ok) throw new Error("update-active failed");
  return r.json();
}

export async function clearAllReplays(): Promise<{ ok: boolean; sessions_cleared: number; archive_deleted: number }> {
  const r = await fetch(`${BASE}/backend/admin/replays/clear-all`, { method: "POST" });
  if (!r.ok) throw new Error("clear-all-replays failed");
  return r.json();
}

// ── Replay verifier binary (upload / status) ────────────────────────────────────

export interface ReplayBinaryFile {
  name: string;
  size: number;
  modified_at: number;
}

export interface ReplayBinaryStatus {
  dir: string;
  healthy: boolean;
  binary: string;
  files: ReplayBinaryFile[];
}

export async function fetchReplayBinaryStatus(): Promise<ReplayBinaryStatus> {
  const r = await fetch(`${BASE}/backend/admin/replay-binary`, { cache: "no-store" });
  if (!r.ok) throw new Error("replay-binary status fetch failed");
  const data = await r.json();
  // Defensive normalization: never trust the backend to always send an
  // array here (e.g. an older backend build, or any future response-shape
  // bug). Consumers of this type (SystemTab.tsx) call .length/.map() on
  // `files` without a null check — a bare `null`/`undefined` from the API
  // would throw a render exception with no error boundary, blanking the
  // entire admin page. Normalizing here is the single choke point that
  // guarantees `files` is always a real array no matter what the server did.
  return { ...data, files: Array.isArray(data?.files) ? data.files : [] };
}

export async function deleteReplayBinaryFile(file: string): Promise<void> {
  const r = await fetch(`${BASE}/backend/admin/replay-binary/delete`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ file }),
  });
  if (!r.ok) {
    const body = await r.json().catch(() => ({}));
    throw new Error(body?.error || "delete failed");
  }
}

// ── Database tab ─────────────────────────────────────────────────────────────

export interface DBCategory {
  key: string;
  prefix: string;
  label: string;
  description: string;
  dangerous: boolean;
  count: number;
}

export async function fetchDatabaseOverview(): Promise<DBCategory[]> {
  const r = await fetch(`${BASE}/backend/admin/database`, { cache: "no-store" });
  if (!r.ok) throw new Error("database overview fetch failed");
  const data = await r.json();
  return data.categories ?? [];
}

export async function clearDatabaseCategory(category: string): Promise<{ ok: boolean; deleted: number }> {
  const r = await fetch(`${BASE}/backend/admin/database/clear`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ category }),
  });
  if (!r.ok) throw new Error("clear category failed");
  return r.json();
}

export interface FailedReplayEntry {
  id: string;
  session_id?: string;
  seed?: string;
  char: number;
  category: string;
  reason?: string;
  extra?: Record<string, unknown>;
  archived_at: number;
  has_log: boolean;
}

export async function fetchFailedReplayArchive(): Promise<FailedReplayEntry[]> {
  const r = await fetch(`${BASE}/backend/admin/failed-replay-archive`, { cache: "no-store" });
  if (!r.ok) throw new Error("failed-replay archive fetch failed");
  const data = await r.json();
  return data.entries ?? [];
}

export function failedReplayDownloadUrl(id: string): string {
  return `${BASE}/backend/admin/failed-replay-archive/${encodeURIComponent(id)}/download`;
}

// uploadReplayBinary — always activates immediately now (the old "stage,
// activate later via a scheduled Deploy job" path was removed along with
// the Deploy tab — see backend/game/appconfig.go's package doc comment).
export async function uploadReplayBinary(file: File): Promise<{ ok: boolean; file: string; size: number; dir: string }> {
  const form = new FormData();
  form.append("file", file);
  const r = await fetch(`${BASE}/backend/admin/replay-binary`, { method: "POST", body: form });
  if (!r.ok) {
    let msg = "upload failed";
    try { const d = await r.json(); msg = d.error || msg; } catch {}
    throw new Error(msg);
  }
  return r.json();
}

// ── Golden replays: determinism regression tests (backend/game/golden_replay.go) ──

export interface GoldenReplay {
  id: string;
  label: string;
  source_session?: string;
  seed: number;
  char: number;
  expected_score: number;
  expected_ticks: number;
  saved_at: number;
}

export interface GoldenReplayResult {
  id: string;
  label: string;
  pass: boolean;
  expected_score: number;
  actual_score: number;
  expected_ticks: number;
  actual_ticks: number;
  error?: string;
}

export interface GoldenSelfTestResponse {
  results: GoldenReplayResult[];
  total: number;
  failed: number;
  pass: boolean;
}

export async function fetchGoldenReplays(): Promise<{ goldens: GoldenReplay[]; count: number }> {
  const r = await fetch(`${BASE}/backend/admin/golden-replays`, { cache: "no-store" });
  if (!r.ok) throw new Error("golden replays fetch failed");
  return r.json();
}

export async function saveGoldenReplay(sessionId: string, label: string): Promise<{ ok: boolean }> {
  const r = await fetch(`${BASE}/backend/admin/golden-replays`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session_id: sessionId, label }),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || "save failed");
  return data;
}

export async function deleteGoldenReplay(id: string): Promise<{ ok: boolean }> {
  const r = await fetch(`${BASE}/backend/admin/golden-replays/delete`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id }),
  });
  if (!r.ok) throw new Error("delete failed");
  return r.json();
}

export async function runGoldenSelfTest(): Promise<GoldenSelfTestResponse> {
  const r = await fetch(`${BASE}/backend/admin/golden-replays/self-test`, { method: "POST" });
  if (!r.ok) throw new Error("self-test failed");
  return r.json();
}

// ── Static determinism lint (backend/game/determinism_lint.go) ─────────────

export interface DeterminismFinding {
  file: string;
  line: number;
  rule: string;
  severity: "warn" | "info";
  message: string;
  snippet: string;
}

export interface DeterminismLintResponse {
  findings: DeterminismFinding[];
  total: number;
  warnings: number;
  clean: boolean;
}

export async function fetchDeterminismLint(): Promise<DeterminismLintResponse> {
  const r = await fetch(`${BASE}/backend/admin/determinism-lint`, { cache: "no-store" });
  if (!r.ok) throw new Error("determinism lint failed");
  return r.json();
}

// ── VS Rooms: async 1v1 challenge (backend/game/vsroom.go) ─────────────────

export interface VSRoom {
  id: string;
  seed: string;
  entry_nim: number;
  is_private: boolean;
  creator_id: string;
  creator_nickname: string;
  creator_paid: boolean;
  creator_pay_tx?: string;
  creator_score?: number;
  creator_session?: string;
  creator_played_at?: number;
  opponent_id?: string;
  opponent_nickname?: string;
  opponent_paid: boolean;
  opponent_pay_tx?: string;
  opponent_score?: number;
  opponent_session?: string;
  opponent_played_at?: number;
  status: string;
  winner_id?: string;
  payout_nim?: number;
  fee_nim?: number;
  payout_tx_hash?: string;
  payout_tx_hash_2?: string;
  settled_at?: number;
  created_at: number;
  expires_at: number;
  creator_forfeit_requested?: boolean;
  opponent_forfeit_requested?: boolean;
  // Live — true while a participant is actively streaming their run via the
  // live relay (backend/handlers/vs_live.go). Transient — computed fresh on
  // every response, never persisted.
  live?: boolean;
}

// fetchVSRooms — paginated: a single player can open unlimited paid rooms,
// so the admin list can no longer just fetch "everything" in one call.
// Returns the requested page plus the total matching-room count so the UI
// can offer a "load more" control.
export async function fetchVSRooms(limit = 100, offset = 0): Promise<{ rooms: VSRoom[]; total: number }> {
  const r = await fetch(`${BASE}/backend/admin/vs-rooms?limit=${limit}&offset=${offset}`, { cache: "no-store" });
  if (!r.ok) throw new Error("vs rooms fetch failed");
  const data = await r.json();
  return { rooms: data.rooms || [], total: data.total ?? (data.rooms || []).length };
}

export async function sweepVSRooms(): Promise<{ ok: boolean }> {
  const r = await fetch(`${BASE}/backend/admin/vs-rooms/sweep`, { method: "POST" });
  if (!r.ok) throw new Error("sweep failed");
  return r.json();
}

export async function reconcileVSPayments(): Promise<{ ok: boolean }> {
  const r = await fetch(`${BASE}/backend/admin/vs-rooms/reconcile-payments`, { method: "POST" });
  if (!r.ok) throw new Error("reconcile failed");
  return r.json();
}

export async function cancelVSRoomAdmin(id: string): Promise<{ ok: boolean; room: VSRoom }> {
  const r = await fetch(`${BASE}/backend/admin/vs-rooms/${encodeURIComponent(id)}/cancel`, { method: "POST" });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || "cancel failed");
  return data;
}

// ── Auth (session-cookie login, see backend/handlers/admin_session.go) ─────

export async function adminLogin(username: string, password: string): Promise<void> {
  const r = await fetch(`${BASE}/backend/admin/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || "login_failed");
}

export async function adminLogout(): Promise<void> {
  await fetch(`${BASE}/backend/admin/logout`, { method: "POST" });
}

export async function adminMe(): Promise<boolean> {
  try {
    const r = await fetch(`${BASE}/backend/admin/me`, { cache: "no-store" });
    if (!r.ok) return false;
    const data = await r.json();
    return !!data.authenticated;
  } catch {
    return false;
  }
}