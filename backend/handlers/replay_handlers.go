package handlers

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

func (s *Server) handleReplay(ctx *fasthttp.RequestCtx) {
	sessionID := ctx.UserValue("session_id").(string)
	sess, err := s.Store.Get(sessionID)
	if err != nil {
		writeErr(ctx, 404, "session_not_found")
		return
	}
	if sess.Log == "" {
		writeErr(ctx, 404, "no_replay_log")
		return
	}

	// ── VS room replay lock ──────────────────────────────────────────────────
	// While a VS match is still pending (one side hasn't played their round
	// yet), nobody but an admin gets the replay log for either side — the
	// opponent could otherwise watch the exact same-seed run and scout the
	// platform/enemy layout before playing themselves. Unlocks automatically
	// once both sides have a recorded score (see FindVSRoomBySessionID).
	if room, rerr := s.Store.FindVSRoomBySessionID(sessionID); rerr == nil && room != nil {
		bothPlayed := room.CreatorScore != nil && room.OpponentScore != nil
		if !bothPlayed {
			log.Printf("[REPLAY] blocked — session=%s belongs to pending VS room=%s", sessionID, room.ID)
			writeErr(ctx, 403, "vs_replay_locked")
			return
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"session_id":   sess.SessionID,
		"seed":         strconv.FormatInt(sess.Seed, 10),
		"char":         sess.Char,
		"server_score": sess.ServerScore,
		"client_score": sess.ClientScore,
		"ticks":        sess.Ticks,
		"flagged":      sess.Flagged,
		"reason":       sess.Reason,
		"replay_log":   sess.Log,
		"nickname":     sess.Nickname,
		"player_id":    sess.PlayerID,
		"player_seed":  strconv.FormatInt(sess.PlayerSeed, 10),
	})
}

func (s *Server) handleReplayStatus(ctx *fasthttp.RequestCtx) {
	status := game.ReplayBinaryStatus()
	status["queue_len"] = game.ReplayQueueLen()
	status["max_workers"] = cap(game.ReplaySemCap())
	writeJSON(ctx, 200, status)
}

func (s *Server) handleAdminDevices(ctx *fasthttp.RequestCtx) {
	sessions := s.Store.List(false, 200)
	type playerEntry struct {
		PlayerID    string `json:"player_id"`
		Nickname    string `json:"nickname"`
		ClientScore int    `json:"best_score"`
		SubmittedAt int64  `json:"last_seen"`
	}
	seen := map[string]*playerEntry{}
	for _, sess := range sessions {
		if sess.PlayerID == "" {
			continue
		}
		if e, ok := seen[sess.PlayerID]; !ok {
			seen[sess.PlayerID] = &playerEntry{
				PlayerID:    sess.PlayerID,
				Nickname:    sess.Nickname,
				ClientScore: sess.ClientScore,
				SubmittedAt: sess.SubmittedAt,
			}
		} else {
			if sess.ClientScore > e.ClientScore {
				e.ClientScore = sess.ClientScore
			}
			if sess.SubmittedAt > e.SubmittedAt {
				e.SubmittedAt = sess.SubmittedAt
			}
			if e.Nickname == "" && sess.Nickname != "" {
				e.Nickname = sess.Nickname
			}
		}
	}
	var out []playerEntry
	for _, e := range seen {
		out = append(out, *e)
	}
	writeJSON(ctx, 200, map[string]any{"players": out, "count": len(out)})
}

func (s *Server) handleAdminDevice(ctx *fasthttp.RequestCtx) {
	playerID := ctx.UserValue("device_id").(string)
	all := s.Store.List(false, 0)
	var out []map[string]any
	for _, sess := range all {
		if sess.PlayerID != playerID {
			continue
		}
		out = append(out, map[string]any{
			"session_id":   sess.SessionID,
			"player_id":    sess.PlayerID,
			"server_score": sess.ServerScore,
			"client_score": sess.ClientScore,
			"flagged":      sess.Flagged,
			"flag_reason":  sess.Reason,
			"submitted_at": sess.SubmittedAt,
		})
	}
	writeJSON(ctx, 200, map[string]any{"player_id": playerID, "sessions": out})
}

func (s *Server) handleAdminOverview(ctx *fasthttp.RequestCtx) {
	all := s.Store.List(false, 0)

	var pendingCount, activeCount, completedCount, flaggedCount int

	type summary struct {
		SessionID   string `json:"session_id"`
		PlayerID    string `json:"player_id"`
		Nickname    string `json:"nickname"`
		State       string `json:"state"`
		ClientScore int    `json:"client_score"`
		ServerScore int    `json:"server_score"`
		Ticks       int    `json:"ticks"`
		Char        int    `json:"char"`
		Flagged     bool   `json:"flagged"`
		Reason      string `json:"reason,omitempty"`
		CreatedAt   int64  `json:"created_at"`
		SubmittedAt int64  `json:"submitted_at"`
		ElapsedSec  int64  `json:"elapsed_sec,omitempty"`
	}

	activeSessions := make([]summary, 0)
	submitted := make([]summary, 0)
	nowMs := time.Now().UnixMilli()

	for _, sess := range all {
		state := string(sess.State)
		elapsed := int64(0)

		switch sess.State {
		case models.StatePending:
			if sess.GameStartedAt > 0 {
				activeCount++
				state = "active"
				elapsed = (nowMs - sess.GameStartedAt) / 1000
				activeSessions = append(activeSessions, summary{
					SessionID:  sess.SessionID,
					PlayerID:   sess.PlayerID,
					Nickname:   sess.Nickname,
					State:      "active",
					CreatedAt:  sess.CreatedAt,
					ElapsedSec: elapsed,
				})
			} else {
				pendingCount++
			}
		case models.StateCompleted:
			completedCount++
		case models.StateFlagged:
			flaggedCount++
		}

		if sess.SubmittedAt > 0 {
			submitted = append(submitted, summary{
				SessionID:   sess.SessionID,
				PlayerID:    sess.PlayerID,
				Nickname:    sess.Nickname,
				State:       state,
				ClientScore: sess.ClientScore,
				ServerScore: sess.ServerScore,
				Ticks:       sess.Ticks,
				Char:        sess.Char,
				Flagged:     sess.Flagged,
				Reason:      sess.Reason,
				CreatedAt:   sess.CreatedAt,
				SubmittedAt: sess.SubmittedAt,
				ElapsedSec:  elapsed,
			})
		}
	}

	for i := 0; i < len(submitted); i++ {
		for j := i + 1; j < len(submitted); j++ {
			if submitted[j].SubmittedAt > submitted[i].SubmittedAt {
				submitted[i], submitted[j] = submitted[j], submitted[i]
			}
		}
	}
	recent := submitted
	if len(recent) > 20 {
		recent = recent[:20]
	}

	// replay_failed count
	var replayFailedCount int
	for _, sess := range all {
		if sess.State == models.StateReplayFailed {
			replayFailedCount++
		}
	}

	rs := game.ReplayBinaryStatus()
	ws := game.WorkerPoolStatus()

	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)

	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "."
	}
	sysRes := game.GetSystemResources(dbPath)

	writeJSON(ctx, 200, map[string]any{
		"counts": map[string]any{
			"total":          len(all),
			"pending":        pendingCount,
			"active":         activeCount,
			"completed":      completedCount,
			"flagged":        flaggedCount,
			"replay_failed":  replayFailedCount,
		},
		"replay": map[string]any{
			"binary_ok":   rs["healthy"],
			"binary_path": rs["binary"],
			"queue_len":   game.ReplayQueueLen(),
			"max_workers": cap(game.ReplaySemCap()),
		},
		"worker_pool": ws,
		"resources": map[string]any{
			"ram_total_bytes":  sysRes.RAMTotalBytes,
			"ram_used_bytes":   sysRes.RAMUsedBytes,
			"disk_total_bytes": sysRes.DiskTotalBytes,
			"disk_used_bytes":  sysRes.DiskUsedBytes,
		},
		"system": map[string]any{
			"goroutines": runtime.NumGoroutine(),
			"heap_mb":    mem.HeapAlloc / 1024 / 1024,
			"uptime_sec": time.Now().Unix() - startEpoch,
			"cpu_count":  runtime.NumCPU(),
		},
		"active_sessions": activeSessions,
		"recent_sessions": recent,
		"server_time":     time.Now().Unix(),
	})
}

func (s *Server) handleAdminSessions(ctx *fasthttp.RequestCtx) {
	stateFilter := string(ctx.QueryArgs().Peek("state"))
	playerFilter := string(ctx.QueryArgs().Peek("player"))
	limit := 200
	if raw := ctx.QueryArgs().Peek("limit"); len(raw) > 0 {
		if v, err := strconv.Atoi(string(raw)); err == nil && v > 0 && v <= 2000 {
			limit = v
		}
	}

	all := s.Store.List(false, 0)
	nowMs := time.Now().UnixMilli()

	type sessionOut struct {
		SessionID   string `json:"session_id"`
		PlayerID    string `json:"player_id"`
		Nickname    string `json:"nickname"`
		State       string `json:"state"`
		ClientScore int    `json:"client_score"`
		ServerScore int    `json:"server_score"`
		Ticks       int    `json:"ticks"`
		Char        int    `json:"char"`
		Flagged     bool   `json:"flagged"`
		Reason      string `json:"reason,omitempty"`
		HasLog      bool   `json:"has_log"`
		CreatedAt   int64  `json:"created_at"`
		SubmittedAt int64  `json:"submitted_at"`
		ElapsedSec  int64  `json:"elapsed_sec,omitempty"`
	}

	var out []sessionOut
	for _, sess := range all {
		state := string(sess.State)
		elapsed := int64(0)
		if sess.State == models.StatePending && sess.GameStartedAt > 0 {
			state = "active"
			elapsed = (nowMs - sess.GameStartedAt) / 1000
		}

		if stateFilter != "" && state != stateFilter {
			continue
		}
		if playerFilter != "" && !strings.Contains(
			strings.ToLower(sess.PlayerID+sess.Nickname),
			strings.ToLower(playerFilter),
		) {
			continue
		}

		out = append(out, sessionOut{
			SessionID:   sess.SessionID,
			PlayerID:    sess.PlayerID,
			Nickname:    sess.Nickname,
			State:       state,
			ClientScore: sess.ClientScore,
			ServerScore: sess.ServerScore,
			Ticks:       sess.Ticks,
			Char:        sess.Char,
			Flagged:     sess.Flagged,
			Reason:      sess.Reason,
			HasLog:      sess.Log != "",
			CreatedAt:   sess.CreatedAt,
			SubmittedAt: sess.SubmittedAt,
			ElapsedSec:  elapsed,
		})
		if len(out) >= limit {
			break
		}
	}
	writeJSON(ctx, 200, map[string]any{"sessions": out, "count": len(out)})
}

func (s *Server) handleAdminTestReplay(ctx *fasthttp.RequestCtx) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	sess, err := s.Store.Get(req.SessionID)
	if err != nil || sess.Log == "" {
		writeErr(ctx, 404, "session_not_found_or_no_log")
		return
	}
	raw, decErr := base64.StdEncoding.DecodeString(sess.Log)
	if decErr != nil {
		writeErr(ctx, 400, "bad_replay_log")
		return
	}
	log.Printf("[ADMIN_REPLAY] session=%s raw_bytes=%d", sess.SessionID[:8], len(raw))
	result, simErr := game.SimulateReplay(sess.Log, sess.Seed, sess.Char, 120, sess.PlayerSeed)
	if simErr != nil {
		writeErr(ctx, 500, "sim_error: "+simErr.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{
		"session_id":   sess.SessionID,
		"client_score": sess.ClientScore,
		"server_score": result.ServerScore,
		"ticks":        result.Ticks,
		"kills":        result.QuestKills,
		"platforms":    result.QuestPlatforms,
	})
}

// GET /backend/admin/worker-status — persistent worker pool durumu
func (s *Server) handleAdminWorkerStatus(ctx *fasthttp.RequestCtx) {
	ws := game.WorkerPoolStatus()

	// replay_failed session'larını da listele
	all := s.Store.List(false, 0)
	type failedSummary struct {
		SessionID   string `json:"session_id"`
		PlayerID    string `json:"player_id"`
		Nickname    string `json:"nickname"`
		ClientScore int    `json:"client_score"`
		ReplayError string `json:"replay_error"`
		SubmittedAt int64  `json:"submitted_at"`
	}
	failed := make([]failedSummary, 0)
	for _, sess := range all {
		if sess.State == models.StateReplayFailed {
			failed = append(failed, failedSummary{
				SessionID:   sess.SessionID,
				PlayerID:    sess.PlayerID,
				Nickname:    sess.Nickname,
				ClientScore: sess.ClientScore,
				ReplayError: sess.ReplayError,
				SubmittedAt: sess.SubmittedAt,
			})
		}
	}
	// En yeni önce
	for i := 0; i < len(failed); i++ {
		for j := i + 1; j < len(failed); j++ {
			if failed[j].SubmittedAt > failed[i].SubmittedAt {
				failed[i], failed[j] = failed[j], failed[i]
			}
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"worker_pool":     ws,
		"failed_sessions": failed,
		"failed_count":    len(failed),
	})
}

// POST /backend/admin/replay-retry/{session_id} — başarısız replay'i manuel tekrar simüle et
func (s *Server) handleAdminReplayRetry(ctx *fasthttp.RequestCtx) {
	sessionID := ctx.UserValue("session_id").(string)
	sess, err := s.Store.Get(sessionID)
	if err != nil {
		writeErr(ctx, 404, "session_not_found")
		return
	}
	if sess.Log == "" {
		writeErr(ctx, 400, "no_replay_log")
		return
	}

	log.Printf("[REPLAY_RETRY] admin manual retry session=%s", sessionID[:8])

	result, simErr := game.SimulateReplayFast(sess.Log, sess.Seed, sess.Char, game.ReplayTimeoutSec(sess.Ticks), sess.PlayerSeed)
	if simErr != nil {
		log.Printf("[REPLAY_RETRY] failed session=%s err=%v", sessionID[:8], simErr)
		sess.ReplayError = simErr.Error()
		_ = s.Store.Save(sess)
		writeErr(ctx, 500, "sim_error: "+simErr.Error())
		return
	}

	simFlagged, simReason := game.ParseFlagReason(sess.ClientScore, result.ServerScore, 0.05)
	sess.ServerScore    = result.ServerScore
	sess.TotalKills     = result.QuestKills
	sess.TotalPlatforms = result.QuestPlatforms
	sess.ReplayError    = ""
	if simFlagged {
		sess.Flagged = true
		sess.Reason  = simReason
		sess.State   = models.StateFlagged
		game.ArchiveFailedReplay(
			game.ArchiveFailedReplayDefaultDir(),
			sessionID,
			strconv.FormatInt(sess.Seed, 10),
			sess.Char,
			strconv.FormatInt(sess.PlayerSeed, 10),
			sess.Log,
			"score_mismatch",
			simReason,
			map[string]any{
				"client_score": sess.ClientScore,
				"server_score": result.ServerScore,
				"ticks":        sess.Ticks,
				"trigger":      "admin_manual_retry",
			},
		)
	} else {
		sess.State = models.StateCompleted
	}
	_ = s.Store.Save(sess)

	log.Printf("[REPLAY_RETRY] done session=%s server_score=%d flagged=%v", sessionID[:8], result.ServerScore, simFlagged)
	writeJSON(ctx, 200, map[string]any{
		"ok":           true,
		"session_id":   sessionID,
		"server_score": result.ServerScore,
		"client_score": sess.ClientScore,
		"flagged":      simFlagged,
		"reason":       simReason,
	})
}