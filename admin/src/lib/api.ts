export const BASE     = process.env.NEXT_PUBLIC_BACKEND_URL ?? "http://localhost:8080";
export const GAME_URL = process.env.NEXT_PUBLIC_GAME_URL   ?? "https://nimjump.io";

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
  log?: string;
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
  system: {
    goroutines: number;
    heap_mb: number;
    uptime_sec: number;
    cpu_count: number;
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
  const r = await fetch(`${BASE}/backend/replay/${id}`, { cache: "no-store" });
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

export async function deleteClientLogs(): Promise<void> {
  await fetch(`${BASE}/backend/admin/client-logs`, { method: "DELETE" });
}

export async function fetchFailedReplays(): Promise<FailedReplay[]> {
  const r = await fetch(`${BASE}/backend/admin/replay-failed`, { cache: "no-store" });
  if (!r.ok) throw new Error("failed replays fetch failed");
  const data = await r.json();
  return data.sessions ?? [];
}

export async function retryReplay(sessionId: string): Promise<void> {
  await fetch(`${BASE}/backend/admin/replay-retry/${sessionId}`, { method: "POST" });
}

export type SessionAction = "approve" | "unflag" | "reject" | "retry";

export interface SessionActionResult {
  ok: boolean;
  message?: string;
  server_score?: number;
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

export interface PlayerQuest {
  quest_id: string;
  name: string;
  description: string;
  target: number;
  progress: number;
  completed: boolean;
  claimed: boolean;
  reward_nim: number;
}

export interface DailyCapStats {
  earned_today: number;
  daily_cap: number;
  remaining: number;
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

export interface PlayerProfile {
  player_id: string;
  nickname: string;
  total_sessions: number;
  total_score: number;
  daily_cap: DailyCapStats;
  quests: PlayerQuest[];
  leaderboard: {
    daily?: { rank: number; score: number };
    weekly?: { rank: number; score: number };
    alltime?: { rank: number; score: number };
  };
  recent_sessions: Session[];
  reward_history: PendingReward[];
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
}

export async function fetchLeaderboard(periodType: string, limit = 100): Promise<LeaderboardResponse> {
  const r = await fetch(`${BASE}/backend/leaderboard?type=${periodType}&limit=${limit}`, { cache: "no-store" });
  if (!r.ok) throw new Error("leaderboard fetch failed");
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
}

export interface PlayersListResponse {
  total: number;
  players: RegisteredPlayer[];
}

export async function fetchPlayersList(): Promise<PlayersListResponse> {
  const r = await fetch(`${BASE}/backend/admin/players`, { cache: "no-store" });
  if (!r.ok) throw new Error("players list fetch failed");
  return r.json();
}