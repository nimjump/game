package handlers

// admin_player.go — Admin player search & session management
//
// GET    /backend/admin/player?q=<wallet|nickname>  — search player, return full profile
// PATCH  /backend/admin/session/{session_id}        — change session state

import (
	"encoding/json"
	"log"
	"strings"
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// ── GET /backend/admin/player?q=... ──────────────────────────────────────────
//
// q can be:
//   - Full or partial wallet address (NQ... or lowercase hex)
//   - Nickname (exact match first, then prefix scan)
//
// Returns full player profile: sessions, daily cap, quests, leaderboard rank,
// recent reward history.
func (s *Server) handleAdminPlayer(ctx *fasthttp.RequestCtx) {
	q := strings.TrimSpace(string(ctx.QueryArgs().Peek("q")))
	if len(q) < 2 {
		writeErr(ctx, 400, "q must be at least 2 characters")
		return
	}

	// ── Resolve playerID ─────────────────────────────────────────────────────
	playerID := ""

	// 1. Exact nickname match
	if pid, err := s.Store.GetPlayerByNickname(strings.ToLower(q)); err == nil && pid != "" {
		playerID = pid
	}

	// 2. Wallet address / player_id prefix scan
	if playerID == "" {
		all := s.Store.List(false, 0)
		qlo := strings.ToLower(q)
		for _, sess := range all {
			if strings.ToLower(sess.PlayerID) == qlo ||
				strings.HasPrefix(strings.ToLower(sess.PlayerID), qlo) {
				playerID = sess.PlayerID
				break
			}
		}
	}

	// 3. Nickname prefix scan (e.g. "rab" matches "rabbit")
	if playerID == "" {
		qlo := strings.ToLower(q)
		all := s.Store.List(false, 0)
		seen := map[string]bool{}
		for _, sess := range all {
			if seen[sess.PlayerID] { continue }
			seen[sess.PlayerID] = true
			if pn, err := s.Store.GetNickname(sess.PlayerID); err == nil && pn != nil {
				if strings.HasPrefix(strings.ToLower(pn.Nickname), qlo) {
					playerID = sess.PlayerID
					break
				}
			}
		}
	}

	if playerID == "" {
		writeErr(ctx, 404, "player_not_found")
		return
	}

	// ── Nickname ──────────────────────────────────────────────────────────────
	nickname := ""
	cooldownEnd := int64(0)
	if pn, err := s.Store.GetNickname(playerID); err == nil && pn != nil {
		nickname = pn.Nickname
		cooldownEnd = pn.CooldownEnd
	}

	// ── Sessions ──────────────────────────────────────────────────────────────
	allSessions := s.Store.List(false, 0)
	type sessionOut struct {
		SessionID   string `json:"session_id"`
		State       string `json:"state"`
		ClientScore int    `json:"client_score"`
		ServerScore int    `json:"server_score"`
		Ticks       int    `json:"ticks"`
		Char        int    `json:"char"`
		Flagged     bool   `json:"flagged"`
		Reason      string `json:"reason,omitempty"`
		ReplayError string `json:"replay_error,omitempty"`
		SubmittedAt int64  `json:"submitted_at"`
		HasLog      bool   `json:"has_log"`
	}
	var sessions []sessionOut
	var bestScore, totalGames, totalTicks, totalKills, totalPlatforms int
	for _, sess := range allSessions {
		if sess.PlayerID != playerID { continue }
		totalGames++
		totalTicks += sess.Ticks
		totalKills += sess.TotalKills
		totalPlatforms += sess.TotalPlatforms
		if sess.ServerScore > bestScore { bestScore = sess.ServerScore }
		sessions = append(sessions, sessionOut{
			SessionID:   sess.SessionID,
			State:       string(sess.State),
			ClientScore: sess.ClientScore,
			ServerScore: sess.ServerScore,
			Ticks:       sess.Ticks,
			Char:        sess.Char,
			Flagged:     sess.Flagged,
			Reason:      sess.Reason,
			ReplayError: sess.ReplayError,
			SubmittedAt: sess.SubmittedAt,
			HasLog:      sess.Log != "",
		})
	}
	// Sort newest first
	for i := 0; i < len(sessions)-1; i++ {
		for j := i + 1; j < len(sessions); j++ {
			if sessions[j].SubmittedAt > sessions[i].SubmittedAt {
				sessions[i], sessions[j] = sessions[j], sessions[i]
			}
		}
	}
	recent := sessions
	if len(recent) > 20 { recent = recent[:20] }

	// ── Daily cap ─────────────────────────────────────────────────────────────
	capStats := s.Store.GetDailyCapStats(playerID)

	// ── Quests ───────────────────────────────────────────────────────────────
	day := time.Now().In(game.UTC3).Format("2006-01-02")
	quests, _ := s.Store.GetOrCreatePlayerQuests(playerID)
	progresses := s.Store.AllProgress(playerID, day)
	progMap := map[string]models.PlayerQuestProgress{}
	for _, p := range progresses { progMap[p.QuestID] = p }

	type questOut struct {
		ID          string  `json:"id"`
		Type        string  `json:"type"`
		Description string  `json:"description"`
		Target      int     `json:"target"`
		Progress    int     `json:"progress"`
		Completed   bool    `json:"completed"`
		Claimed     bool    `json:"claimed"`
		RewardNIM   float64 `json:"reward_nim"`
	}
	var questsOut []questOut
	totalQuestNIM := 0.0
	claimedQuestNIM := 0.0
	for _, q := range quests {
		p := progMap[q.ID]
		claimed := p.ClaimedAt > 0
		if claimed { claimedQuestNIM += q.RewardNIM }
		if p.Completed || claimed { totalQuestNIM += q.RewardNIM }
		pct := 0
		if q.Target > 0 { pct = p.Progress * 100 / q.Target }
		if pct > 100 { pct = 100 }
		questsOut = append(questsOut, questOut{
			ID:          q.ID,
			Type:        string(q.Type),
			Description: q.Description,
			Target:      q.Target,
			Progress:    p.Progress,
			Completed:   p.Completed || claimed,
			Claimed:     claimed,
			RewardNIM:   q.RewardNIM,
		})
		_ = pct
	}

	// ── Leaderboard rank ─────────────────────────────────────────────────────
	dailyRank, weeklyRank, alltimeRank := 0, 0, 0
	dailyPeriod, weeklyPeriod := game.CurrentPeriods()
	if entries, err := s.Store.GetLeaderboardPaged("daily", dailyPeriod, 0, 0, playerID); err == nil {
		for _, e := range entries { if e.PlayerID == playerID { dailyRank = e.Rank; break } }
	}
	if entries, err := s.Store.GetLeaderboardPaged("weekly", weeklyPeriod, 0, 0, playerID); err == nil {
		for _, e := range entries { if e.PlayerID == playerID { weeklyRank = e.Rank; break } }
	}
	if entries, err := s.Store.GetLeaderboardPaged("alltime", "", 0, 0, playerID); err == nil {
		for _, e := range entries { if e.PlayerID == playerID { alltimeRank = e.Rank; break } }
	}

	// ── Reward history ────────────────────────────────────────────────────────
	rewards, _ := s.Store.ListRewardsByPlayer(playerID, 30)
	if rewards == nil { rewards = []models.PendingReward{} }

	writeJSON(ctx, 200, map[string]any{
		"player_id":    playerID,
		"nickname":     nickname,
		"cooldown_end": cooldownEnd,
		"stats": map[string]any{
			"best_score":      bestScore,
			"total_games":     totalGames,
			"total_ticks":     totalTicks,
			"total_kills":     totalKills,
			"total_platforms": totalPlatforms,
		},
		"daily_cap":       capStats,
		"quests":          questsOut,
		"quest_nim_today": totalQuestNIM,
		"quest_nim_claimed": claimedQuestNIM,
		"leaderboard": map[string]any{
			"daily_rank":   dailyRank,
			"weekly_rank":  weeklyRank,
			"alltime_rank": alltimeRank,
			"daily_period": dailyPeriod,
			"weekly_period": weeklyPeriod,
		},
		"recent_sessions": recent,
		"rewards":         rewards,
	})
}

// ── PATCH /backend/admin/session/{session_id} ─────────────────────────────────
//
// Body: { "action": "approve" | "unflag" | "reject" | "retry" , "reason": "..." }
//
//   approve  — force state=completed, flagged=false, server_score=client_score (or replay result)
//   unflag   — clear flag, set state=completed, keep existing server_score
//   reject   — set state=flagged, flagged=true, reason=body.reason
//   retry    — re-run replay simulation (same as handleAdminReplayRetry but via PATCH)
func (s *Server) handleAdminSessionPatch(ctx *fasthttp.RequestCtx) {
	sessionID := ctx.UserValue("session_id").(string)
	sess, err := s.Store.Get(sessionID)
	if err != nil {
		writeErr(ctx, 404, "session_not_found")
		return
	}

	var req struct {
		Action string `json:"action"` // "approve" | "unflag" | "reject" | "retry"
		Reason string `json:"reason"` // for reject; optional for others
	}
	if e := json.Unmarshal(ctx.PostBody(), &req); e != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}

	switch req.Action {

	case "unflag":
		// Clear flag, leave server_score as-is
		sess.Flagged = false
		sess.Reason  = ""
		sess.State   = models.StateCompleted
		if err := s.Store.Save(sess); err != nil {
			writeErr(ctx, 500, "save_error"); return
		}
		log.Printf("[ADMIN_SESSION] unflag session=%s", sessionID[:8])
		writeJSON(ctx, 200, map[string]any{
			"ok": true, "action": "unflag",
			"session_id": sessionID, "state": string(sess.State),
		})

	case "approve":
		// Trust client score: set server_score = client_score, mark clean
		// If replay log exists, run sim first
		if sess.Log != "" {
			result, simErr := game.SimulateReplayFast(sess.Log, sess.Seed, sess.Char, 90, sess.PlayerSeed)
			if simErr == nil && result != nil {
				sess.ServerScore    = result.ServerScore
				sess.TotalKills     = result.QuestKills
				sess.TotalPlatforms = result.QuestPlatforms
				sess.ReplayError    = ""
			} else {
				// Sim failed: trust client score with admin override
				sess.ServerScore = sess.ClientScore
				log.Printf("[ADMIN_SESSION] approve sim failed, using client_score=%d session=%s", sess.ClientScore, sessionID[:8])
			}
		} else {
			sess.ServerScore = sess.ClientScore
		}
		sess.Flagged = false
		sess.Reason  = "admin_approved"
		sess.State   = models.StateCompleted
		if err := s.Store.Save(sess); err != nil {
			writeErr(ctx, 500, "save_error"); return
		}
		log.Printf("[ADMIN_SESSION] approve session=%s server_score=%d", sessionID[:8], sess.ServerScore)
		writeJSON(ctx, 200, map[string]any{
			"ok": true, "action": "approve",
			"session_id": sessionID, "server_score": sess.ServerScore,
			"state": string(sess.State),
		})

	case "reject":
		reason := req.Reason
		if reason == "" { reason = "admin_rejected" }
		sess.Flagged = true
		sess.Reason  = reason
		sess.State   = models.StateFlagged
		if err := s.Store.Save(sess); err != nil {
			writeErr(ctx, 500, "save_error"); return
		}
		log.Printf("[ADMIN_SESSION] reject session=%s reason=%s", sessionID[:8], reason)
		writeJSON(ctx, 200, map[string]any{
			"ok": true, "action": "reject",
			"session_id": sessionID, "reason": reason,
			"state": string(sess.State),
		})

	case "retry":
		if sess.Log == "" {
			writeErr(ctx, 400, "no_replay_log"); return
		}
		result, simErr := game.SimulateReplayFast(sess.Log, sess.Seed, sess.Char, 90, sess.PlayerSeed)
		if simErr != nil {
			sess.ReplayError = simErr.Error()
			sess.State       = models.StateReplayFailed
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
		} else {
			sess.Flagged = false
			sess.Reason  = ""
			sess.State   = models.StateCompleted
		}
		_ = s.Store.Save(sess)
		log.Printf("[ADMIN_SESSION] retry session=%s server_score=%d flagged=%v", sessionID[:8], result.ServerScore, simFlagged)
		writeJSON(ctx, 200, map[string]any{
			"ok": true, "action": "retry",
			"session_id":   sessionID,
			"server_score": result.ServerScore,
			"flagged":      simFlagged,
			"reason":       simReason,
			"state":        string(sess.State),
		})

	default:
		writeErr(ctx, 400, "unknown action: use approve|unflag|reject|retry")
	}
}
