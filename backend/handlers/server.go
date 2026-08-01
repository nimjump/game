package handlers

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fasthttp/router"
	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

var startEpoch = time.Now().Unix()

// ── Per-player replay-verification concurrency cap ──────────────────────────
//
// BUG FIX (security audit — DoS): the replay-verifier worker pool defaults to
// just 2 concurrent Godot processes, each of which can legitimately take up
// to ReplayTimeoutSec (600s, × up to 3 retry attempts). Before this fix,
// nothing stopped a single authenticated account from bursting many
// submissions (the generic rate limiter alone allows a burst of 45 requests)
// and saturating the entire pool by itself, starving every other player's
// submissions behind an unbounded blocking channel send. Capping how many of
// ONE player's submissions can be simulating at once (independent of the
// tick-count/size limits already in place) closes the "one account queues
// everyone else out" version of this — this is a fairness/availability
// guard, not a payout-integrity one (those are separately enforced).
//
// Raised from 2 to 15 by request — still a real cap (a single account still
// can't queue unbounded submissions), just generous enough that no legitimate
// player realistically hits it; the shared worker pool's own limited job
// channel (see game.GetWorkerPool, default 2 concurrent Godot processes) is
// still the actual bottleneck/backpressure for total system throughput —
// this constant only ever protects OTHER players from ONE account hogging
// that shared pool, not the reverse.
const maxReplayInFlightPerPlayer = 15

var (
	replayInFlightMu       sync.Mutex
	replayInFlightByPlayer = map[string]int{}
)

// tryClaimReplaySlot reserves one of this player's limited concurrent replay-
// verification slots. Returns false (claims nothing) if they're already at
// the cap.
func tryClaimReplaySlot(playerID string) bool {
	replayInFlightMu.Lock()
	defer replayInFlightMu.Unlock()
	if replayInFlightByPlayer[playerID] >= maxReplayInFlightPerPlayer {
		return false
	}
	replayInFlightByPlayer[playerID]++
	return true
}

// releaseReplaySlot must be called exactly once for every successful
// tryClaimReplaySlot, regardless of how the verification goroutine exits
// (success, failure, or an early return) — always via `defer` right after
// claiming.
func releaseReplaySlot(playerID string) {
	replayInFlightMu.Lock()
	defer replayInFlightMu.Unlock()
	if replayInFlightByPlayer[playerID] > 0 {
		replayInFlightByPlayer[playerID]--
		if replayInFlightByPlayer[playerID] == 0 {
			delete(replayInFlightByPlayer, playerID)
		}
	}
}

type Server struct {
	Store *game.Store
	rl    *RateLimiter
}

func (s *Server) Register(r *router.Router) {
	s.rl = NewRateLimiter()

	// isAuthed: is Authorization header present? (we don't validate the token here,
	// that's done inside the handler. We only determine the tier — authed tier is generous.)
	isAuthed := func(ctx *fasthttp.RequestCtx) bool {
		return len(ctx.Request.Header.Peek("Authorization")) > 7 // "Bearer " + en az 1 char
	}
	rl := func(h fasthttp.RequestHandler) fasthttp.RequestHandler {
		return s.rl.Middleware(h, isAuthed)
	}

	// Admin login — no auth required to reach these (this IS the auth).
	// SECURITY: uses the dedicated LoginMiddleware, NOT the generic rl()
	// wrapper — rl()'s guest/authed tier is decided purely by whether an
	// Authorization header is present (never validated at that layer), so a
	// brute-forcer could send a throwaway Bearer header to buy the 15/s
	// "authed" tier instead of 5/s guest. LoginMiddleware ignores that split
	// entirely and enforces a much stricter dedicated per-IP bucket
	// (~1 attempt/5s) that can't be bypassed the same way. The credential
	// check itself is already constant-time (see handleAdminLogin).
	r.POST("/backend/admin/login", s.rl.LoginMiddleware(s.handleAdminLogin))
	r.POST("/backend/admin/logout", s.handleAdminLogout)
	r.GET("/backend/admin/me", s.handleAdminMe)

	// Admin endpoints — exposed to the public internet, so every one of
	// these is protected by a session cookie (see admin_session.go; set
	// via POST /backend/admin/login, checked against ADMIN_USERNAME /
	// ADMIN_PASSWORD). They bypass rate limiting (only admins use these).
	r.GET("/backend/developer-mode", s.handleDeveloperModeGet) // public, read-only — no auth needed
	r.POST("/backend/admin/developer-mode", s.requireAdminSession(s.handleDeveloperModeSet))
	r.POST("/backend/admin/prizes", s.requireAdminSession(s.handleAdminSetPrizes))
	// GET mirror of the public /backend/leaderboard/prizes below, same
	// app_sig problem as the replay route: the public path requires the
	// game client's HMAC signature (see appsig.go), which the admin panel
	// can't produce. Admin's PrizesCard used to call the public path
	// directly, got app_signature_invalid, and — because its component body
	// is `if (!cfg) return null`, cfg never got set — the entire "how much
	// to pay out daily/weekly" editor silently rendered as nothing, with no
	// visible error. This exempts it via the admin session gate instead.
	r.GET("/backend/admin/prizes", s.requireAdminSession(s.handleLeaderboardPrizes))
	r.POST("/backend/admin/snapshot", s.requireAdminSession(s.handleAdminSnapshot))
	r.POST("/backend/admin/nimiq-config", s.requireAdminSession(s.handleAdminNimiqConfig))
	r.GET("/backend/admin/nimiq-config", s.requireAdminSession(s.handleAdminNimiqConfigGet))
	r.GET("/backend/admin/nimiq-balance", s.requireAdminSession(s.handleAdminNimiqBalance))
	r.GET("/backend/admin/rewards", s.requireAdminSession(s.handleAdminRewards))
	r.POST("/backend/admin/rewards/retry", s.requireAdminSession(s.handleAdminRetryRewards))
	r.POST("/backend/admin/test-telegram", s.requireAdminSession(s.handleAdminTestTelegram))
	r.GET("/backend/admin/devices", s.requireAdminSession(s.handleAdminDevices))
	r.GET("/backend/admin/devices/{device_id}", s.requireAdminSession(s.handleAdminDevice))
	r.POST("/backend/admin/test-replay", s.requireAdminSession(s.handleAdminTestReplay))
	r.GET("/backend/admin/overview", s.requireAdminSession(s.handleAdminOverview))
	r.GET("/backend/admin/sessions", s.requireAdminSession(s.handleAdminSessions))
	r.GET("/backend/admin/worker-status", s.requireAdminSession(s.handleAdminWorkerStatus))
	r.POST("/backend/admin/replay-retry/{session_id}", s.requireAdminSession(s.handleAdminReplayRetry))
	r.GET("/backend/admin/client-logs", s.requireAdminSession(s.handleAdminClientLogs))
	r.DELETE("/backend/admin/client-logs", s.requireAdminSession(s.handleAdminDeleteClientLogs))
	r.GET("/backend/admin/replay-failed", s.requireAdminSession(s.handleAdminReplayFailed))
	r.GET("/backend/admin/player", s.requireAdminSession(s.handleAdminPlayer))
	r.GET("/backend/admin/players", s.requireAdminSession(s.handleAdminPlayersList))
	r.GET("/backend/admin/streaks", s.requireAdminSession(s.handleAdminStreaks))
	r.POST("/backend/admin/session/{session_id}", s.requireAdminSession(s.handleAdminSessionPatch))
	r.GET("/backend/admin/analytics", s.requireAdminSession(s.handleAdminAnalytics))

	// App config — leaderboard on/off, update lock, replay binary upload
	r.GET("/backend/admin/config", s.requireAdminSession(s.handleAdminGetConfig))
	r.POST("/backend/admin/config", s.requireAdminSession(s.handleAdminSetConfig))
	r.POST("/backend/admin/update-active", s.requireAdminSession(s.handleAdminSetUpdateActive))
	r.GET("/backend/admin/device-breakdown", s.requireAdminSession(s.handleAdminDeviceBreakdown))
	r.GET("/backend/admin/country-breakdown", s.requireAdminSession(s.handleAdminCountryBreakdown))
	r.GET("/backend/admin/quest-pool", s.requireAdminSession(s.handleAdminQuestPool))
	r.POST("/backend/admin/quest-reward", s.requireAdminSession(s.handleAdminSetQuestReward))
	r.POST("/backend/admin/quest-target", s.requireAdminSession(s.handleAdminSetQuestTarget))
	r.POST("/backend/admin/replays/clear-all", s.requireAdminSession(s.handleAdminClearAllReplays))
	r.GET("/backend/admin/leaderboard", s.requireAdminSession(s.handleAdminLeaderboard))
	r.POST("/backend/admin/leaderboard/reset", s.requireAdminSession(s.handleAdminLeaderboardReset))
	r.GET("/backend/admin/replay-binary", s.requireAdminSession(s.handleAdminReplayBinaryStatus))
	r.POST("/backend/admin/replay-binary", s.requireAdminSession(s.handleAdminReplayBinaryUpload))
	r.POST("/backend/admin/replay-binary/delete", s.requireAdminSession(s.handleAdminReplayBinaryDelete))

	// Database tab — key-prefix category overview/clear + failed-replay archive
	r.GET("/backend/admin/database", s.requireAdminSession(s.handleAdminDatabaseOverview))
	r.POST("/backend/admin/database/clear", s.requireAdminSession(s.handleAdminDatabaseClear))
	r.GET("/backend/admin/backup", s.requireAdminSession(s.handleAdminBackupStatus))
	r.GET("/backend/admin/backup/list", s.requireAdminSession(s.handleAdminBackupList))
	r.POST("/backend/admin/backup/run", s.requireAdminSession(s.handleAdminBackupRun))
	r.POST("/backend/admin/backup/restore", s.requireAdminSession(s.handleAdminBackupRestore))
	r.GET("/backend/admin/failed-replay-archive", s.requireAdminSession(s.handleAdminFailedReplayArchiveList))
	r.GET("/backend/admin/failed-replay-archive/{id}/download", s.requireAdminSession(s.handleAdminFailedReplayArchiveDownload))

	// Golden replays — pinned reference replays used to catch determinism
	// regressions (a code/binary change silently altering simulation
	// results) before they show up as real player flags.
	r.GET("/backend/admin/golden-replays", s.requireAdminSession(s.handleAdminGoldenList))
	r.POST("/backend/admin/golden-replays", s.requireAdminSession(s.handleAdminGoldenSave))
	r.POST("/backend/admin/golden-replays/delete", s.requireAdminSession(s.handleAdminGoldenDelete))
	r.POST("/backend/admin/golden-replays/self-test", s.requireAdminSession(s.handleAdminGoldenSelfTest))

	// Static determinism lint — scans game/scripts/*.gd for known
	// determinism-breaking patterns (bare RNG, wall-clock time, hard free(),
	// array mutation during iteration). See backend/game/determinism_lint.go.
	r.GET("/backend/admin/determinism-lint", s.requireAdminSession(s.handleAdminDeterminismLint))

	// Admin replay viewer — same handler as the public /backend/replay/{id}
	// below, registered a second time under /backend/admin/ so it gets the
	// session-cookie gate instead of the app_ts/app_sig HMAC check.
	// corsMiddleware in main.go only enforces app_sig on paths OUTSIDE
	// "/backend/admin" — the public route requires a signature only the
	// compiled game client can produce (see appsig.go), so the admin panel
	// calling the public path directly always got app_signature_invalid
	// ("sig failed") once that signing requirement was added. The admin
	// panel now calls this path instead (see admin/src/lib/api.ts).
	r.GET("/backend/admin/replay/{session_id}", s.requireAdminSession(s.handleReplay))

	// Admin panel UI — reverse-proxied to the Next.js admin app (runs
	// separately, see admin/.env for ADMIN_PORT). Same session-cookie gate,
	// but redirects to /admin/login on failure instead of returning JSON.
	// Path prefix comes from ADMIN_BASE_PATH — must match admin/next.config.js.
	base := adminBasePath()
	r.ANY(base, s.requireAdminSessionPage(s.handleAdminProxy))
	r.ANY(base+"/{filepath:*}", s.requireAdminSessionPage(s.handleAdminProxy))

	// Public endpoint'ler — rate limitli
	r.GET("/backend/auth/challenge", rl(s.handleAuthChallenge))
	r.POST("/backend/auth/verify", rl(s.handleAuthVerify))
	r.GET("/backend/auth/me", rl(s.handleAuthMe))
	r.GET("/backend/ping", rl(s.handlePing))
	// /prefetch and /game_start removed — offline seed system
	r.POST("/backend/submit", rl(s.handleSubmit))
	// CRITICAL BUG FIX (security audit): this was a fully public, unauthenticated
	// endpoint that dumped up to 100 players' full session records — including
	// their real Nimiq wallet address (PlayerID), nickname, score, and full
	// base64 replay log — to literally anyone (only the generic per-IP rate
	// limiter stood in front of it). Nothing in the game client calls this
	// route at all (confirmed by grep — it's dead/vestigial), and an
	// equivalent, properly-gated version already exists at
	// /backend/admin/sessions (see handleAdminSessions below). This also
	// closes a secondary gap: handleReplay's public replay-fetch route relies
	// on session_id being an unguessable capability token, an assumption this
	// endpoint completely broke by handing out every session_id in bulk.
	r.GET("/backend/sessions", s.requireAdminSession(s.handleSessions))
	r.GET("/backend/leaderboard", rl(s.handleLeaderboard))
	r.GET("/backend/leaderboard/prizes", rl(s.handleLeaderboardPrizes))
	r.GET("/backend/leaderboard/winners", rl(s.handleLeaderboardWinners))
	// CRITICAL BUG FIX (security audit): this had NO auth at all — any
	// anonymous request could hit it directly, since it isn't under
	// /backend/admin/ and wasn't wrapped in requireAdminSession like every
	// other payout-triggering route. Combined with a non-atomic check in
	// PayWinnersForPeriod (see its own fix in game/leaderboard.go), this
	// meant: (1) anyone could force-close and pay out a still-in-progress
	// daily/weekly period early, freezing out whoever would have legitimately
	// won the rest of it, and (2) firing many concurrent requests for the
	// same not-yet-paid period could multiply that period's real NIM payout
	// N-fold to whatever addresses currently sit in the top ranks — no
	// login, no payment, nothing required. The automatic background loop
	// (game.StartLeaderboardPayoutLoop, started in Start() below) already
	// pays winners on schedule with no public trigger needed; this endpoint
	// only exists for an admin's manual "pay now" button, so it belongs
	// behind the same admin session gate as every other payout-adjacent
	// admin route.
	r.POST("/backend/leaderboard/pay-winners", s.requireAdminSession(s.handleLeaderboardPayWinners))
	r.POST("/backend/wallet/register", rl(s.handleWalletRegister))
	r.GET("/backend/wallet", rl(s.handleWalletGet))
	r.GET("/backend/replay/{session_id}", rl(s.handleReplay))
	r.GET("/backend/nickname", rl(s.handleNicknameGet))
	r.POST("/backend/nickname", rl(s.handleNicknameSet))
	r.GET("/backend/nickname/check", rl(s.handleNicknameCheck))
	r.GET("/backend/stats", rl(s.handleStats))
	r.GET("/backend/quests", rl(s.handleQuests))
	// NOTE: POST /backend/quests/progress was removed — quest progress is now
	// applied only as a server-side side effect of replay verification (see
	// Store.UpdateQuestProgressFromReplay, called from the /backend/submit
	// handler below), never from a separate client-triggered request.
	r.POST("/backend/quests/claim", rl(s.handleQuestClaim))
	r.POST("/backend/quests/claim_all", rl(s.handleQuestClaimAll))
	r.GET("/backend/streak/status", rl(s.handleStreakStatus))
	r.POST("/backend/streak/claim", rl(s.handleStreakClaim))
	r.GET("/backend/replay-status", rl(s.handleReplayStatus))
	r.GET("/backend/rewards/history", rl(s.handleRewardHistory))
	r.POST("/backend/client-log", rl(s.handleClientLog))

	// Cosmetics — character customization (hat/glasses/outfit/shoes), bought
	// with NIM. Payment verified the same way as VS room entry fees.
	r.GET("/backend/cosmetics/catalog", rl(s.handleCosmeticsCatalog))
	r.POST("/backend/cosmetics/buy", rl(s.handleCosmeticsBuy))
	r.POST("/backend/cosmetics/equip", rl(s.handleCosmeticsEquip))

	// VS Rooms — async 1v1 challenge with optional NIM entry fee.
	r.POST("/backend/vsroom/create", rl(s.handleVSRoomCreate))
	r.GET("/backend/vsroom/mine", rl(s.handleVSRoomMine))
	r.GET("/backend/vsroom/pending-count", rl(s.handleVSRoomPendingCount))
	r.GET("/backend/vsroom/open", rl(s.handleVSRoomOpen))
	r.GET("/backend/vsroom/{id}", rl(s.handleVSRoomGet))
	r.POST("/backend/vsroom/{id}/join", rl(s.handleVSRoomJoin))
	r.POST("/backend/vsroom/{id}/pay", rl(s.handleVSRoomConfirmPayment))
	r.POST("/backend/vsroom/{id}/start", rl(s.handleVSRoomStartPlay))
	r.POST("/backend/vsroom/{id}/cancel", rl(s.handleVSRoomCancel))
	r.POST("/backend/vsroom/{id}/forfeit", rl(s.handleVSRoomForfeit))
	r.GET("/backend/admin/vs-rooms", s.requireAdminSession(s.handleAdminVSRooms))
	r.POST("/backend/admin/vs-rooms/sweep", s.requireAdminSession(s.handleAdminVSRoomsSweep))
	r.POST("/backend/admin/vs-rooms/reconcile-payments", s.requireAdminSession(s.handleAdminVSRoomsReconcile))
	r.POST("/backend/admin/vs-rooms/{id}/cancel", s.requireAdminSession(s.handleAdminVSRoomCancel))
	r.POST("/backend/admin/vs-rooms/{id}/resolve", s.requireAdminSession(s.handleAdminVSRoomResolve))
	r.POST("/backend/admin/vs-rooms/{id}/reopen", s.requireAdminSession(s.handleAdminVSRoomReopen))
}

// StartBackgroundServices — starts retry loop, balance monitor, and the
// Cloudflare IP list refresher. Called from main.go
//
// BUG FIX: game.StartLeaderboardPayoutLoop() (auto-pays daily/weekly winners
// every 15 min) was fully implemented but never actually called from here —
// so leaderboard winners were only ever paid if an admin manually hit
// /bj/leaderboard/pay-winners, silently, forever. Now started alongside the
// other background services.
//
// (There used to also be a StartCleanupLoop() call queued up for stale
// "pending" sessions — removed along with the rest of the dead StatePending
// code; see game/store.go's comment for why that state was never reachable.)
func (s *Server) StartBackgroundServices() {
	s.Store.StartRewardQueue()
	s.Store.StartRetryLoop()
	s.Store.StartBalanceMonitor()
	s.Store.StartVSRoomSweep()
	s.Store.StartVSPaymentReconciler()
	s.Store.StartCosmeticsReconciler()
	s.Store.StartLeaderboardPayoutLoop()
	StartCloudflareIPRefresher()
	log.Printf("[STARTUP] background services started (retry loop + balance monitor + vs room sweep + vs payment reconciler + leaderboard payout loop + cloudflare ip refresher)")
}

// GET /backend/developer-mode — public, read-only status endpoint. Also
// carries the update-lock flag (client polls this to know whether starting
// a new game should be blocked) and the leaderboard on/off flags.
func (s *Server) handleDeveloperModeGet(ctx *fasthttp.RequestCtx) {
	on := s.Store.GetDeveloperMode()
	cfg := s.Store.GetAppConfig()
	writeJSON(ctx, 200, map[string]any{
		"developer_mode":             on,
		"message":                    "We're currently updating the game. Come back soon!",
		"update_active":              cfg.UpdateActive,
		"update_message":             "Game updating. Please check back shortly — thanks for your patience!",
		"daily_leaderboard_enabled":  cfg.DailyLeaderboardEnabled,
		"weekly_leaderboard_enabled": cfg.WeeklyLeaderboardEnabled,
	})
}

// POST /bj/admin/developer-mode — toggle dev mode from admin panel
// Body: {"enabled": true}
func (s *Server) handleDeveloperModeSet(ctx *fasthttp.RequestCtx) {
	var req struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if err := s.Store.SetDeveloperMode(req.Enabled); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] developer_mode=%v", req.Enabled)
	writeJSON(ctx, 200, map[string]any{"ok": true, "developer_mode": req.Enabled})
}

func (s *Server) handlePing(ctx *fasthttp.RequestCtx) {
	log.Printf("[PING] %s", ctx.RemoteIP())
	writeJSON(ctx, 200, map[string]any{
		"status":         "ok",
		"epoch":          startEpoch,
		"developer_mode": s.Store.GetDeveloperMode(),
	})
}

func writeJSON(ctx *fasthttp.RequestCtx, status int, v any) {
	ctx.SetContentType("application/json")
	ctx.SetStatusCode(status)
	_ = json.NewEncoder(ctx).Encode(v)
}

func writeErr(ctx *fasthttp.RequestCtx, status int, msg string) {
	log.Printf("[ERR] %d %s %s -> %s", status, ctx.Method(), ctx.Path(), msg)
	writeJSON(ctx, status, map[string]string{"error": msg})
}

// maxReplaySubmitTicks — hard cap on the RLE-decoded tick count a submitted
// replay is allowed to claim before it's rejected outright (see the BUG FIX
// comment at its use site in handleSubmit). 60 minutes at 60 ticks/sec —
// generous enough that no real play session could plausibly hit it.
const maxReplaySubmitTicks = 60 * 60 * 60

func rleUnpack(raw []byte) (ticks []byte, deltas []float64) {
	ticks = make([]byte, 0, len(raw)*20) // RLE expands ~20x
	i := 0
	for i < len(raw) {
		b := raw[i]
		// 0xFF marker: needs exactly 2 more bytes (lo, hi). Guard: i+2 <= len(raw)-1
		if b == 0xFF {
			if i+2 < len(raw) {
				lo := float64(raw[i+1])
				hi := float64(raw[i+2])
				ms := lo + hi*256.0
				if ms > 0 {
					deltas = append(deltas, ms)
				}
				i += 3
			} else {
				// Truncated marker at end of log — skip remaining bytes safely
				break
			}
			continue
		}
		val := b & 0x03
		count := (b >> 2) & 0x3F
		if count == 0 {
			count = 1
		}
		for k := byte(0); k < count; k++ {
			ticks = append(ticks, val)
		}
		i++
	}
	return
}

// rleTickCount counts the total ticks encoded in a raw RLE log without allocating
// the full unpacked slice. Used to validate client-reported tick count before simulation.
func rleTickCount(raw []byte) int {
	total := 0
	i := 0
	for i < len(raw) {
		b := raw[i]
		if b == 0xFF {
			if i+2 < len(raw) {
				i += 3
			} else {
				break
			}
			continue
		}
		count := int((b >> 2) & 0x3F)
		if count == 0 {
			count = 1
		}
		total += count
		i++
	}
	return total
}

// analyzeDeltaMarkers — analyzes 0xFF delta markers in the RLE log.
// Normal: every 60 ticks = ~1000ms. time_scale=0.1 → ~10000ms → flagged.
// Logic: normal timing passed → not called. Failed → inspect → if ok accept, if not reject.
func analyzeDeltaMarkers(raw []byte) (isPending bool, flagged bool, reason string) {
	const EXPECTED_MS = 1000.0 // 60 tick @ 60fps
	const MIN_RATIO = 0.4      // 400ms
	const MAX_RATIO = 6.0      // 6000ms (time_scale=0.1 → ~10000ms)

	_, deltas := rleUnpack(raw)

	if len(deltas) < 3 {
		return false, false, ""
	}
	isPending = true

	var slowCount, fastCount int
	for _, ms := range deltas {
		ratio := ms / EXPECTED_MS
		if ratio > MAX_RATIO {
			slowCount++
		}
		if ratio < MIN_RATIO {
			fastCount++
		}
	}
	if float64(slowCount)/float64(len(deltas)) > 0.30 {
		return true, true, fmt.Sprintf("timescale_slow:slow=%d/%d", slowCount, len(deltas))
	}
	if float64(fastCount)/float64(len(deltas)) > 0.30 {
		return true, true, fmt.Sprintf("timescale_fast:fast=%d/%d", fastCount, len(deltas))
	}
	return true, false, ""
}

func acCheck(score, ticks int) (flagged bool, reason string) {
	// Fast AC disabled — server-side replay simulation is sufficient
	return false, ""
}

// submitReq — flat JSON sent by client (no encryption; seed included for server-side claim)
type submitReq struct {
	Session       string  `json:"session"` // 32-char hex local UUID
	Seed          string  `json:"seed"`    // game_seed as string (int64 precision)
	Score         int     `json:"score"`
	Ticks         int     `json:"ticks"`
	Char          int     `json:"char"`
	GyroActive    bool    `json:"gyro_active"` // gyro-only movement ramp active this match — see Player.gd's set_gyro_control_active doc comment
	PlayerID      string  `json:"player_id"`
	Nickname      string  `json:"nickname"`
	Nonce         float64 `json:"nonce"`
	ReplayLog     string  `json:"replay_log"`
	PlayerSeed    string  `json:"player_seed"`
	ClientVersion int     `json:"client_version"`       // REMOVED: no longer checked against anything server-side (the replay-version gate was removed) — still accepted on the wire so old/new clients can send it harmlessly, just unused now
	VSRoomID      string  `json:"vs_room_id,omitempty"` // set when this play is one side of a VS room match
	VSRole        string  `json:"vs_role,omitempty"`    // "creator" or "opponent"
	// Ckpt — diagnostic-only checkpoint log (see GameManager.gd _ckpt_log).
	// Never used for scoring/flagging decisions — only compared against the
	// server replay's own checkpoint log (best-effort, logged) when a replay
	// gets flagged, so we can pinpoint the first diverging tick instead of
	// just an aggregate score-diff percentage. Safe to ignore/absent on old clients.
	Ckpt json.RawMessage `json:"ckpt,omitempty"`
}

func (s *Server) handleSubmit(ctx *fasthttp.RequestCtx) {
	ip := realClientIP(ctx)

	// Auth required
	authedPlayer := s.tokenPlayerID(ctx)
	if authedPlayer == "" {
		log.Printf("[SUBMIT] rejected — no valid auth token ip=%s", ip)
		writeErr(ctx, 401, "auth_required")
		return
	}

	// BUG FIX (security audit — DoS): body size was never checked before
	// json.Unmarshal, so any authed player could send a request body up to
	// the server-wide 250MB ceiling (main.go's MaxRequestBodySize — sized for
	// the admin replay-binary upload, not this route) and have it fully
	// buffered AND unmarshaled (allocating a second full copy as Go strings)
	// before the much smaller 700,000-byte replay_log check further down
	// ever got a chance to reject it. Repeated bursts of that is a cheap
	// memory/CPU DoS distinct from the tick-count DoS already fixed below.
	// 2MB is generous headroom over the largest legitimate payload
	// (700,000-byte base64 replay_log + the diagnostic ckpt array + the
	// handful of small scalar fields) while being nowhere near 250MB.
	const maxSubmitBodyBytes = 2 * 1024 * 1024
	if len(ctx.PostBody()) > maxSubmitBodyBytes {
		log.Printf("[SUBMIT] rejected — body too large (%d bytes) ip=%s", len(ctx.PostBody()), ip)
		writeErr(ctx, 413, "payload_too_large")
		return
	}

	var req submitReq
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		log.Printf("[SUBMIT] bad_json ip=%s err=%v", ip, err)
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.Session == "" || req.Seed == "" {
		writeErr(ctx, 400, "missing_fields")
		return
	}

	sid8 := req.Session
	if len(sid8) > 16 {
		sid8 = sid8[:16]
	}

	// Parse seed from client
	gameSeed, seedErr := strconv.ParseInt(req.Seed, 10, 64)
	if seedErr != nil || gameSeed == 0 {
		log.Printf("[SUBMIT] bad_seed session=%s raw=%s", sid8, req.Seed)
		writeErr(ctx, 400, "bad_seed")
		return
	}

	// ── VS room binding sanity check ─────────────────────────────────────────
	// If this submission claims to be one side of a VS room match, verify the
	// room exists, the seed matches the room's seed (so nobody can submit an
	// unrelated normal run as their VS entry), and the authed player is
	// actually the participant claimed by vs_role.
	if req.VSRoomID != "" {
		room, rerr := s.Store.GetVSRoom(req.VSRoomID)
		if rerr != nil || room == nil {
			writeErr(ctx, 404, "vs_room_not_found")
			return
		}
		if room.Seed != req.Seed {
			log.Printf("[SUBMIT] vs_room seed mismatch room=%s room_seed=%s submit_seed=%s", req.VSRoomID, room.Seed, req.Seed)
			writeErr(ctx, 400, "vs_room_seed_mismatch")
			return
		}
		switch req.VSRole {
		case "creator":
			if room.CreatorID != authedPlayer {
				writeErr(ctx, 403, "vs_role_mismatch")
				return
			}
		case "opponent":
			if room.OpponentID != authedPlayer {
				writeErr(ctx, 403, "vs_role_mismatch")
				return
			}
		default:
			writeErr(ctx, 400, "bad_vs_role")
			return
		}
	}

	// ── Seed duplicate check ─────────────────────────────────────────────────
	// First-seen: claim it. Already claimed: reject.
	// VS room matches are the one deliberate exception — both participants
	// play the SAME seed by design, so this is skipped for vs_room_id
	// submissions (already validated above: seed must match the room's own
	// seed, and the authed player must be the exact participant for vs_role,
	// so at most 2 legitimate submissions can ever exist for that seed).
	if req.VSRoomID == "" && s.Store.SeedExists(gameSeed) {
		log.Printf("[SUBMIT] seed_already_used session=%s seed=%d ip=%s", sid8, gameSeed, ip)
		writeErr(ctx, 409, "seed_already_used")
		return
	}
	// ─────────────────────────────────────────────────────────────────────────

	// Nickname: DB'den al (güvenilir kaynak). Client göndermemişse fallback.
	nick := sanitizeNickname(req.Nickname, 16)
	if pn, err := s.Store.GetNickname(authedPlayer); err == nil && pn != nil && pn.Nickname != "" {
		nick = pn.Nickname
	}

	// Basic anticheat
	flagged, reason := acCheck(req.Score, req.Ticks)

	// Replay log
	replayLog := ""
	if req.ReplayLog != "" && len(req.ReplayLog) <= 700000 {
		replayLog = req.ReplayLog
	}
	rawLogBytes, _ := base64.StdEncoding.DecodeString(req.ReplayLog)
	log.Printf("[SUBMIT] ip=%s session=%s seed=%d score=%d ticks=%d player=%s replay_raw=%d",
		ip, sid8, gameSeed, req.Score, req.Ticks, req.PlayerID, len(rawLogBytes))

	if replayLog == "" {
		log.Printf("[SUBMIT] rejected — no replay_log session=%s", sid8)
		writeErr(ctx, 400, "replay_required")
		return
	}

	// Delta marker analysis + RLE tick count validation
	if rawLog, decErr := base64.StdEncoding.DecodeString(replayLog); decErr == nil {
		// RLE-decoded tick count is authoritative — it's exactly what the replay
		// binary will see when it reads this same log. No need to compare against
		// req.Ticks or flag on a mismatch: the client's number was only ever a
		// hint, never the source of truth.
		//
		// BUG FIX (security audit — DoS): moved this cheap, allocation-free
		// count-only pass (rleTickCount) BEFORE analyzeDeltaMarkers, which
		// calls the full rleUnpack (allocates the entire decoded tick array,
		// up to ~44MB for a maximal malicious log — see the tick-count bound
		// below) just to read its `deltas` return value. Rejecting an
		// oversized log here first means a malicious submission never
		// triggers that expensive full decode at all.
		decodedTicks := rleTickCount(rawLog)
		log.Printf("[SUBMIT] session=%s rle_ticks=%d client_ticks=%d", sid8, decodedTicks, req.Ticks)
		// BUG FIX (security audit — DoS): decodedTicks used to be trusted with
		// no upper bound before being handed off to the headless-simulator
		// worker pool. The RLE format's 6-bit run-length field caps each
		// encoded byte at 63 repeated ticks, but the encoded log itself can be
		// up to 700,000 bytes (see the replayLog length check above) — so a
		// maliciously crafted log could claim up to ~44 million decoded ticks
		// from one request, forcing a worker to attempt simulating that for up
		// to the full ReplayTimeoutSec (600s) × 3 retry attempts ≈ 30 minutes
		// of real CPU time tied up by a single HTTP POST, on a pool with as
		// few as 2 concurrent workers by default. Rejecting absurdly long
		// claimed sessions here — before they ever reach the simulator — costs
		// nothing (a real run never gets remotely close to this) and closes
		// the expensive part of the DoS. maxReplaySubmitTicks is generous
		// (60 real-world minutes at 60 ticks/sec) so it never affects a
		// legitimate long session.
		if decodedTicks > maxReplaySubmitTicks {
			log.Printf("[SUBMIT] rejected — decoded tick count %d exceeds max %d session=%s",
				decodedTicks, maxReplaySubmitTicks, sid8)
			writeErr(ctx, 400, "replay_too_long")
			return
		}
		req.Ticks = decodedTicks

		// Only now — after the cheap bound check above already passed — do
		// the full decode+analysis pass that used to always run first.
		isPending, deltaFlagged, deltaReason := analyzeDeltaMarkers(rawLog)
		_ = isPending
		if deltaFlagged && !flagged {
			log.Printf("[AC_DELTA] session=%s reason=%s", sid8, deltaReason)
			flagged = true
			reason = deltaReason
		}
	}

	// Parse player seed.
	// Client sends game_seed ^ 0xDEADBEEF as player_seed (GameManager._init_game_from_seed).
	// If missing (old client), derive it here so the headless binary gets the correct RNG seed.
	var parsedPlayerSeed int64
	if req.PlayerSeed != "" {
		parsedPlayerSeed, _ = strconv.ParseInt(req.PlayerSeed, 10, 64)
	}
	if parsedPlayerSeed == 0 {
		// 0xDEADBEEF = 3735928559 — must match GameManager._init_game_from_seed
		parsedPlayerSeed = gameSeed ^ 3735928559
	}

	// ── Save session to DB (seed claimed here) ───────────────────────────────
	// State must reflect `flagged` right away — when flagged==true the
	// replay-sim goroutine below never runs (see `if !flagged` a few lines
	// down), so State would otherwise be stuck at StateCompleted forever
	// even though Flagged=true. That mismatch is exactly why sessions
	// caught by the fast synchronous anti-cheat check (acCheck / delta
	// markers) never showed up in the admin "Flagged" tab (which filters by
	// State, not Flagged) even though they were correctly flagged=true and
	// rendered red in other tabs.
	initialState := models.StateCompleted
	if flagged {
		initialState = models.StateFlagged
	}
	sess := &models.Session{
		SessionID:   req.Session,
		Seed:        gameSeed,
		ClientScore: req.Score,
		ServerScore: 0,
		Ticks:       req.Ticks,
		Char:        req.Char,
		GyroActive:  req.GyroActive,
		PlayerID:    authedPlayer,
		Nickname:    nick,
		Flagged:     flagged,
		Reason:      reason,
		SubmittedAt: time.Now().Unix(),
		State:       initialState,
		Log:         replayLog,
		PlayerSeed:  parsedPlayerSeed,
	}
	if saveErr := s.Store.Save(sess); saveErr != nil {
		log.Printf("[SUBMIT] DB save error session=%s err=%v", sid8, saveErr)
	}
	log.Printf("[SUBMIT] session=%s score=%d flagged=%v player=%s saved",
		sid8, req.Score, flagged, req.PlayerID)
	// ─────────────────────────────────────────────────────────────────────────

	// Mark this side as PLAYED right now, synchronously — before the async
	// replay sim runs and independent of whether it gets flagged. The actual
	// score is only recorded later (after successful re-simulation), so without
	// this immediate marker the room would keep offering a "Play" button while
	// the replay is still being verified, or forever if the match went to manual
	// review — letting the player play the same match twice.
	if req.VSRoomID != "" {
		s.Store.MarkVSRoomPlayed(req.VSRoomID, req.VSRole, req.Session)
	}

	// A submission flagged up-front (basic anti-cheat, before replay sim even
	// runs) that belongs to a VS match must also send that match to manual
	// review — otherwise the flagged side would just be silently dropped and the
	// other side could auto-forfeit-win at expiry.
	if flagged && req.VSRoomID != "" {
		s.Store.FlagVSRoomForReview(req.VSRoomID, req.VSRole, "anti_cheat: "+reason)
	}

	// Replay simulation (background)
	if !flagged {
		// See tryClaimReplaySlot's doc comment — caps how many of THIS
		// player's replay verifications can be running at once, independent
		// of the generic per-IP rate limiter, so one account can't saturate
		// the whole (small, by default 2-worker) verification pool and starve
		// every other player's submissions behind it.
		if !tryClaimReplaySlot(authedPlayer) {
			log.Printf("[SUBMIT] rejected — too many in-flight replay verifications player=%s", authedPlayer[:min8(authedPlayer)])
			writeErr(ctx, 429, "too_many_pending_replays")
			return
		}
		// BUG-AVOIDANCE: ctx (fasthttp.RequestCtx) gets reused/reset by
		// fasthttp the moment this handler returns — this goroutine keeps
		// running well after that. Reading ctx.RemoteIP()/headers from
		// INSIDE the goroutine would race that reuse and could read a
		// completely different request's IP. Resolve it here, on the
		// handler's own goroutine, and pass the plain string through
		// (same reason every other piece of request data below is passed
		// as an explicit param instead of closing over ctx/req directly).
		clientIP := realClientIP(ctx)
		go func(sessionID, playerID string, clientScore int, log64 string, seed int64, charIdx int, gyroActive bool, playerSeed int64, ticks int, vsRoomID, vsRole string, clientCkpt json.RawMessage, clientIP string) {
			defer releaseReplaySlot(playerID)
			log.Printf("[REPLAY_SIM] queued session=%s seed=%d b64=%d ticks=%d", sessionID[:8], seed, len(log64), ticks)
			result := game.SimulateReplayWithRetry(sessionID, log64, seed, charIdx, gyroActive, playerSeed, ticks)

			stored, gerr := s.Store.Get(sessionID)
			if gerr != nil {
				return
			}

			// Tüm retry'lar başarısız — StateReplayFailed yaz, admin manuel retry yapabilir
			if result == nil {
				log.Printf("[REPLAY_SIM] FAILED all retries session=%s — marking replay_failed", sessionID[:8])
				stored.State = models.StateReplayFailed
				stored.ReplayError = "all retries exhausted"
				_ = s.Store.Save(stored)
				// If this was one side of a VS match, the match must NOT auto-settle
				// (that would forfeit-win the other side off a replay we couldn't
				// even verify) — hold it for manual admin review instead.
				if vsRoomID != "" {
					s.Store.FlagVSRoomForReview(vsRoomID, vsRole, "replay_failed: all retries exhausted")
				}
				return
			}

			log.Printf("[REPLAY_SIM] session=%s %s", sessionID[:8], game.SummaryLine(result, clientScore))

			// Tolerance is admin-configurable (Database... System tab, defaults
			// to 0 = exact match required) — see AppConfig.ScoreMismatchTolerancePercent's
			// doc comment. The score actually stored below is ALWAYS
			// result.ServerScore regardless of this setting; it only decides
			// whether the run gets flagged as suspicious.
			simFlagged, simReason := game.ParseFlagReason(clientScore, result.ServerScore, s.Store.ScoreMismatchTolerance())
			stored.ServerScore = result.ServerScore
			stored.TotalKills = result.QuestKills
			stored.TotalPlatforms = result.QuestPlatforms
			stored.ReplayError = ""
			if simFlagged {
				stored.Flagged = true
				stored.Reason = simReason
				stored.State = models.StateFlagged
				log.Printf("[REPLAY_FLAG] session=%s reason=%s", sessionID[:8], simReason)
				// Best-effort forensic diff: pinpoints the first tick where the
				// client's own recorded checkpoints and the server's re-simulation
				// checkpoints parted ways (position/score/rng-state), instead of
				// just the aggregate score-diff percentage above. Never affects
				// the flagging decision itself — purely diagnostic. Its result is
				// now folded into the archived entry below (see the "extra" map)
				// instead of only being a log.Printf line — a log line rotates out
				// of retention long before anyone notices a ~0.5%-rate issue is
				// worth investigating; an archived, queryable field doesn't.
				ckptDiv := game.LogCheckpointDivergence(sessionID, clientCkpt, result)
				extra := map[string]any{
					"client_score": clientScore,
					"server_score": result.ServerScore,
					"ticks":        ticks,
				}
				if ckptDiv != nil {
					extra["ckpt_first_diverge_tick"] = ckptDiv.FirstDivergeTick
					if ckptDiv.FirstDivergeDetail != "" {
						extra["ckpt_first_diverge_detail"] = ckptDiv.FirstDivergeDetail
					}
					extra["ckpt_matched"] = ckptDiv.MatchedCheckpoints
					extra["ckpt_client_count"] = ckptDiv.ClientCheckpoints
					extra["ckpt_server_count"] = ckptDiv.ServerCheckpoints
					if ckptDiv.Note != "" {
						extra["ckpt_note"] = ckptDiv.Note
					}
				}
				// İsteğe bağlı arşiv: score mismatch'leri de worker timeout'larıyla
				// aynı failed_replays klasörüne kaydet — sebebi anlamak için elindeki
				// log'lar kalıcı olsun, manuel olarak yeniden simüle edebilesin.
				game.ArchiveFailedReplay(
					game.ArchiveFailedReplayDefaultDir(),
					sessionID,
					fmt.Sprintf("%d", seed),
					charIdx,
					fmt.Sprintf("%d", playerSeed),
					log64,
					"score_mismatch",
					simReason,
					extra,
				)
			} else {
				stored.State = models.StateCompleted
			}
			_ = s.Store.Save(stored)
			log.Printf("[REPLAY_SIM] done session=%s server_score=%d flagged=%v",
				sessionID[:8], result.ServerScore, simFlagged)

			// ── VS room score reporting ──────────────────────────────────────
			// Only the server-verified score is ever trusted here — a flagged
			// (client/server mismatch or anti-cheat) submission never counts
			// toward a VS match. Instead of just being dropped (which would let
			// the OTHER side auto-forfeit-win the pot at expiry), a flagged VS
			// side sends the whole match to MANUAL REVIEW so no money moves until
			// an admin has looked at it.
			if vsRoomID != "" {
				// BUG FIX ("vs sistemi ... webde oynasa bile tam ödemeyi
				// alır ... asla düşürülmez"): this used to send the WHOLE
				// match to manual review — no payout to either side — the
				// instant simFlagged was true, even though at this point the
				// replay itself already re-simulated successfully
				// (result != nil, we're past the "replay_failed" branch
				// above) and result.ServerScore is a real, independently
				// server-computed, trusted score. simFlagged here only means
				// the CLIENT's self-reported score didn't exactly match the
				// server's — with the score-mismatch tolerance defaulting to
				// 0% (admin-configurable), a single point of web/native
				// platform rounding noise was enough to trip this and freeze
				// a legitimately-won match's payout pending manual admin
				// action. Same rule as everywhere else in this codebase: the
				// server's own verified score is the ONLY thing that's ever
				// trusted/used — a flag is for admin visibility (still
				// logged below), never a reason to withhold money. Genuine
				// problems (pre-replay anti-cheat catches, or a replay that
				// couldn't be verified AT ALL) still go to manual review —
				// see the "anti_cheat"/"replay_failed" FlagVSRoomForReview
				// calls elsewhere in this handler, untouched by this fix.
				if simFlagged {
					log.Printf("[VSROOM] score_mismatch flagged but settling normally with server-verified score room=%s role=%s reason=%s", vsRoomID, vsRole, simReason)
				}
				if _, verr := s.Store.UpdateVSRoomScore(vsRoomID, vsRole, result.ServerScore, sessionID); verr != nil {
					log.Printf("[VSROOM] score update failed room=%s role=%s session=%s err=%v", vsRoomID, vsRole, sessionID[:8], verr)
				}
			}

			if !simFlagged && result.QuestHasResult && playerID != "" {
				quests, qerr := s.Store.GetOrCreatePlayerQuests(playerID)
				if qerr == nil {
					s.Store.UpdateQuestProgressFromReplay(playerID, result, quests)
					log.Printf("[QUEST_PROGRESS] updated player=%s session=%s", playerID, sessionID[:8])
				} else {
					log.Printf("[QUEST_PROGRESS] failed player=%s: %v", playerID, qerr)
				}

				// ── Coin → NIM ödülü (daily cap uygulanır) ────────────────
				if result.QuestCoins > 0 {
					coinRate := s.Store.CoinNIMRate()
					requestedNIM := float64(result.QuestCoins) * coinRate
					if requestedNIM > 0 {
						// Same shared per-IP anti-multi-accounting guard as
						// streak claims (game/ip_reward_guard.go) — an IP
						// that's already funded MaxRewardAccountsPerIP()
						// distinct accounts today gets every FURTHER
						// account's coin reward blocked too, not just its
						// streak claim. Coins are still recorded/spent in
						// the run itself either way — only the NIM payout
						// is withheld.
						okIP, ierr := s.Store.CheckAndRecordIPRewardEligibility(clientIP, playerID)
						if ierr != nil {
							log.Printf("[COIN_REWARD] ip guard error player=%s session=%s err=%v", playerID, sessionID[:8], ierr)
						} else if !okIP {
							log.Printf("[COIN_REWARD] BLOCKED (ip limit) player=%s ip=%s session=%s requested=%.4f",
								playerID, clientIP, sessionID[:8], requestedNIM)
						} else {
							earned, cerr := s.Store.QueueRewardCapped(playerID, requestedNIM, result.QuestCoins)
							if cerr != nil {
								log.Printf("[COIN_REWARD] error player=%s session=%s err=%v", playerID, sessionID[:8], cerr)
							} else {
								log.Printf("[COIN_REWARD] player=%s session=%s coins=%d rate=%.6f requested=%.4f earned=%.4f NIM",
									playerID, sessionID[:8], result.QuestCoins, coinRate, requestedNIM, earned)
							}
						}
					}
				}
			}
		}(req.Session, authedPlayer, req.Score, replayLog, gameSeed, req.Char, req.GyroActive, parsedPlayerSeed, req.Ticks, req.VSRoomID, req.VSRole, req.Ckpt, clientIP)
	}

	writeJSON(ctx, 200, map[string]any{
		"ok":           true,
		"server_score": 0,
		"client_score": req.Score,
		"flagged":      flagged,
		"reason":       reason,
	})
}

func (s *Server) handleSessions(ctx *fasthttp.RequestCtx) {
	onlyFlagged := string(ctx.QueryArgs().Peek("flagged")) == "1"
	list := s.Store.List(onlyFlagged, 100)
	log.Printf("[SESSIONS] flagged=%v count=%d", onlyFlagged, len(list))
	writeJSON(ctx, 200, map[string]any{"sessions": list})
}

func (s *Server) handleLeaderboardPrizes(ctx *fasthttp.RequestCtx) {
	cfg, err := s.Store.GetLeaderboardConfig()
	if err != nil {
		writeErr(ctx, 500, "config_error")
		return
	}
	writeJSON(ctx, 200, cfg)
}

func (s *Server) handleAdminSetPrizes(ctx *fasthttp.RequestCtx) {
	var cfg models.LeaderboardConfig
	if err := json.Unmarshal(ctx.PostBody(), &cfg); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if err := s.Store.SaveLeaderboardConfig(cfg); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] prizes updated daily=%v/%v/%v weekly=%v/%v/%v",
		cfg.Daily.First, cfg.Daily.Second, cfg.Daily.Third,
		cfg.Weekly.First, cfg.Weekly.Second, cfg.Weekly.Third)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

func (s *Server) handleAdminSnapshot(ctx *fasthttp.RequestCtx) {
	// POST body: {"period_type":"daily","period":"2026-06-17"}
	// If period is empty, snapshot today/this week
	var req struct {
		PeriodType string `json:"period_type"` // "daily" | "weekly"
		Period     string `json:"period"`      // opsiyonel
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.PeriodType == "" {
		req.PeriodType = "daily"
	}
	if req.Period == "" {
		daily, weekly := game.CurrentPeriods()
		if req.PeriodType == "daily" {
			req.Period = daily
		} else {
			req.Period = weekly
		}
	}
	pw, err := s.Store.SnapshotWinners(req.PeriodType, req.Period)
	if err != nil {
		writeErr(ctx, 500, "snapshot_error")
		return
	}
	log.Printf("[ADMIN] snapshot period=%s/%s winners=%d", req.PeriodType, req.Period, len(pw.Winners))
	writeJSON(ctx, 200, pw)
}

// tokenPlayerID extracts and validates the Bearer token from the Authorization header,
// returning the playerID it belongs to, or "" if missing/invalid.
func (s *Server) tokenPlayerID(ctx *fasthttp.RequestCtx) string {
	// Bearer header only — never the query string (a URL token leaks into
	// access/proxy logs and Referer headers). All authenticated client calls
	// send the Authorization header (see ApiConfig/_headers()).
	auth := string(ctx.Request.Header.Peek("Authorization"))
	token := ""
	if strings.HasPrefix(auth, "Bearer ") {
		token = strings.TrimSpace(auth[7:])
	}
	if token == "" {
		return ""
	}
	sess, err := s.Store.GetSession(token)
	if err != nil || sess == nil {
		return ""
	}
	if time.Now().Unix() > sess.ExpiresAt {
		return ""
	}
	return sess.PlayerID
}
