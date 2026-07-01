package handlers

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/fasthttp/router"
	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

var startEpoch = time.Now().Unix()

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

	// Admin endpoints bypass rate limiting (only you use these)
	r.GET("/backend/developer-mode",            s.handleDeveloperModeGet)
	r.POST("/backend/admin/developer-mode",     s.handleDeveloperModeSet)
	r.POST("/backend/admin/prizes",            s.handleAdminSetPrizes)
	r.POST("/backend/admin/snapshot",          s.handleAdminSnapshot)
	r.POST("/backend/admin/nimiq-config",      s.handleAdminNimiqConfig)
	r.GET("/backend/admin/nimiq-config",       s.handleAdminNimiqConfigGet)
	r.GET("/backend/admin/nimiq-balance",      s.handleAdminNimiqBalance)
	r.GET("/backend/admin/rewards",            s.handleAdminRewards)
	r.POST("/backend/admin/rewards/retry",     s.handleAdminRetryRewards)
	r.POST("/backend/admin/test-telegram",     s.handleAdminTestTelegram)
	r.GET("/backend/admin/devices",             s.handleAdminDevices)
	r.GET("/backend/admin/devices/{device_id}", s.handleAdminDevice)
	r.POST("/backend/admin/test-replay",        s.handleAdminTestReplay)
	r.GET("/backend/admin/overview",            s.handleAdminOverview)
	r.GET("/backend/admin/sessions",            s.handleAdminSessions)
	r.GET("/backend/admin/worker-status",       s.handleAdminWorkerStatus)
	r.POST("/backend/admin/replay-retry/{session_id}", s.handleAdminReplayRetry)
	r.GET("/backend/admin/client-logs",              s.handleAdminClientLogs)
	r.DELETE("/backend/admin/client-logs",           s.handleAdminDeleteClientLogs)
	r.GET("/backend/admin/replay-failed",            s.handleAdminReplayFailed)
	r.GET("/backend/admin/player",                   s.handleAdminPlayer)
	r.GET("/backend/admin/players",                  s.handleAdminPlayersList)
	r.POST("/backend/admin/session/{session_id}",    s.handleAdminSessionPatch)
	r.GET("/backend/admin/analytics",               s.handleAdminAnalytics)

	// Public endpoint'ler — rate limitli
	r.GET("/backend/auth/challenge",            rl(s.handleAuthChallenge))
	r.POST("/backend/auth/verify",              rl(s.handleAuthVerify))
	r.GET("/backend/auth/me",                   rl(s.handleAuthMe))
	r.GET("/backend/ping",                      rl(s.handlePing))
	// /prefetch and /game_start removed — offline seed system
	r.POST("/backend/submit",                   rl(s.handleSubmit))
	r.GET("/backend/sessions",                  rl(s.handleSessions))
	r.GET("/backend/leaderboard",               rl(s.handleLeaderboard))
	r.GET("/backend/leaderboard/prizes",        rl(s.handleLeaderboardPrizes))
	r.GET("/backend/leaderboard/winners",       rl(s.handleLeaderboardWinners))
	r.POST("/backend/leaderboard/pay-winners",  rl(s.handleLeaderboardPayWinners))
	r.POST("/backend/wallet/register",          rl(s.handleWalletRegister))
	r.GET("/backend/wallet",                    rl(s.handleWalletGet))
	r.GET("/backend/replay/{session_id}",       rl(s.handleReplay))
	r.GET("/backend/nickname",                  rl(s.handleNicknameGet))
	r.POST("/backend/nickname",                 rl(s.handleNicknameSet))
	r.GET("/backend/nickname/check",            rl(s.handleNicknameCheck))
	r.GET("/backend/stats",                     rl(s.handleStats))
	r.GET("/backend/quests",                    rl(s.handleQuests))
	r.POST("/backend/quests/progress",          rl(s.handleQuestProgress))
	r.POST("/backend/quests/claim",             rl(s.handleQuestClaim))
	r.POST("/backend/quests/claim_all",         rl(s.handleQuestClaimAll))
	r.GET("/backend/replay-status",             rl(s.handleReplayStatus))
	r.GET("/backend/rewards/history",           rl(s.handleRewardHistory))
	r.POST("/backend/client-log",               rl(s.handleClientLog))

	// VS — real-time 1v1
	r.POST("/backend/vs/join",                  rl(s.handleVSJoin))
	r.GET("/backend/vs/ws/{room_id}",           s.handleVSWebSocket)  // no rate-limit — WS upgrade
}

// StartBackgroundServices — starts retry loop and balance monitor
// called from main.go
func (s *Server) StartBackgroundServices() {
	s.Store.StartRetryLoop()
	s.Store.StartBalanceMonitor()
	log.Printf("[STARTUP] background services started (retry loop + balance monitor)")
}

// GET /bj/developer-mode — returns current dev mode status (public, read-only)
func (s *Server) handleDeveloperModeGet(ctx *fasthttp.RequestCtx) {
	on := s.Store.GetDeveloperMode()
	writeJSON(ctx, 200, map[string]any{
		"developer_mode": on,
		"message":        "We're currently updating the game. Come back soon!",
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
		val   := b & 0x03
		count := (b >> 2) & 0x3F
		if count == 0 { count = 1 }
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
		if count == 0 { count = 1 }
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
	const MIN_RATIO   = 0.4    // 400ms
	const MAX_RATIO   = 6.0    // 6000ms (time_scale=0.1 → ~10000ms)

	_, deltas := rleUnpack(raw)

	if len(deltas) < 3 {
		return false, false, ""
	}
	isPending = true

	var slowCount, fastCount int
	for _, ms := range deltas {
		ratio := ms / EXPECTED_MS
		if ratio > MAX_RATIO { slowCount++ }
		if ratio < MIN_RATIO { fastCount++ }
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
	Session    string  `json:"session"`     // 32-char hex local UUID
	Seed       string  `json:"seed"`        // game_seed as string (int64 precision)
	Score      int     `json:"score"`
	Ticks      int     `json:"ticks"`
	Char       int     `json:"char"`
	PlayerID   string  `json:"player_id"`
	Nickname   string  `json:"nickname"`
	Nonce      float64 `json:"nonce"`
	ReplayLog  string  `json:"replay_log"`
	PlayerSeed string  `json:"player_seed"`
}

func (s *Server) handleSubmit(ctx *fasthttp.RequestCtx) {
	ip := ctx.RemoteIP().String()

	// Auth required
	authedPlayer := s.tokenPlayerID(ctx)
	if authedPlayer == "" {
		log.Printf("[SUBMIT] rejected — no valid auth token ip=%s", ip)
		writeErr(ctx, 401, "auth_required")
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
	if len(sid8) > 16 { sid8 = sid8[:16] }

	// Parse seed from client
	gameSeed, seedErr := strconv.ParseInt(req.Seed, 10, 64)
	if seedErr != nil || gameSeed == 0 {
		log.Printf("[SUBMIT] bad_seed session=%s raw=%s", sid8, req.Seed)
		writeErr(ctx, 400, "bad_seed")
		return
	}

	// ── Seed duplicate check ─────────────────────────────────────────────────
	// First-seen: claim it. Already claimed: reject.
	if s.Store.SeedExists(gameSeed) {
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
		isPending, deltaFlagged, deltaReason := analyzeDeltaMarkers(rawLog)
		_ = isPending
		if deltaFlagged && !flagged {
			log.Printf("[AC_DELTA] session=%s reason=%s", sid8, deltaReason)
			flagged = true
			reason  = deltaReason
		}

		// RLE-decoded tick count is authoritative — it's exactly what the replay
		// binary will see when it reads this same log. No need to compare against
		// req.Ticks or flag on a mismatch: the client's number was only ever a
		// hint, never the source of truth.
		decodedTicks := rleTickCount(rawLog)
		log.Printf("[SUBMIT] session=%s rle_ticks=%d client_ticks=%d", sid8, decodedTicks, req.Ticks)
		req.Ticks = decodedTicks
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
	sess := &models.Session{
		SessionID:    req.Session,
		Seed:         gameSeed,
		ClientScore:  req.Score,
		ServerScore:  0,
		Ticks:        req.Ticks,
		Char:         req.Char,
		PlayerID:     authedPlayer,
		Nickname:     nick,
		Flagged:      flagged,
		Reason:       reason,
		SubmittedAt:  time.Now().Unix(),
		State:        models.StateCompleted,
		Log:          replayLog,
		PlayerSeed:   parsedPlayerSeed,
	}
	if saveErr := s.Store.Save(sess); saveErr != nil {
		log.Printf("[SUBMIT] DB save error session=%s err=%v", sid8, saveErr)
	}
	log.Printf("[SUBMIT] session=%s score=%d flagged=%v player=%s saved",
		sid8, req.Score, flagged, req.PlayerID)
	// ─────────────────────────────────────────────────────────────────────────

	// Replay simulation (background)
	if !flagged {
		go func(sessionID, playerID string, clientScore int, log64 string, seed int64, charIdx int, playerSeed int64, ticks int) {
			log.Printf("[REPLAY_SIM] queued session=%s seed=%d b64=%d ticks=%d", sessionID[:8], seed, len(log64), ticks)
			result := game.SimulateReplayWithRetry(sessionID, log64, seed, charIdx, playerSeed, ticks)

			stored, gerr := s.Store.Get(sessionID)
			if gerr != nil { return }

			// Tüm retry'lar başarısız — StateReplayFailed yaz, admin manuel retry yapabilir
			if result == nil {
				log.Printf("[REPLAY_SIM] FAILED all retries session=%s — marking replay_failed", sessionID[:8])
				stored.State       = models.StateReplayFailed
				stored.ReplayError = "all retries exhausted"
				_ = s.Store.Save(stored)
				return
			}

			log.Printf("[REPLAY_SIM] session=%s %s", sessionID[:8], game.SummaryLine(result, clientScore))

			simFlagged, simReason := game.ParseFlagReason(clientScore, result.ServerScore, 0.05)
			stored.ServerScore    = result.ServerScore
			stored.TotalKills     = result.QuestKills
			stored.TotalPlatforms = result.QuestPlatforms
			stored.ReplayError    = ""
			if simFlagged {
				stored.Flagged = true
				stored.Reason  = simReason
				stored.State   = models.StateFlagged
				log.Printf("[REPLAY_FLAG] session=%s reason=%s", sessionID[:8], simReason)
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
					map[string]any{
						"client_score": clientScore,
						"server_score": result.ServerScore,
						"ticks":        ticks,
					},
				)
			} else {
				stored.State = models.StateCompleted
			}
			_ = s.Store.Save(stored)
			log.Printf("[REPLAY_SIM] done session=%s server_score=%d flagged=%v",
				sessionID[:8], result.ServerScore, simFlagged)

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
					coinRate := game.CoinNIMRate()
					requestedNIM := float64(result.QuestCoins) * coinRate
					if requestedNIM > 0 {
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
		}(req.Session, authedPlayer, req.Score, replayLog, gameSeed, req.Char, parsedPlayerSeed, req.Ticks)
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
	auth := string(ctx.Request.Header.Peek("Authorization"))
	token := ""
	if strings.HasPrefix(auth, "Bearer ") {
		token = strings.TrimSpace(auth[7:])
	}
	if token == "" {
		token = string(ctx.QueryArgs().Peek("token"))
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