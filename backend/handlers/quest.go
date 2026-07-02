package handlers

import (
	"encoding/json"
	"log"
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// GET /bj/quests?player_id=xxx
func (s *Server) handleQuests(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	quests, err := s.Store.GetOrCreatePlayerQuests(playerID)
	if err != nil {
		writeErr(ctx, 500, "failed to load quests")
		return
	}
	day := time.Now().In(game.UTC3).Format("2006-01-02")
	progresses := s.Store.AllProgress(playerID, day)

	progMap := map[string]models.PlayerQuestProgress{}
	for _, p := range progresses {
		progMap[p.QuestID] = p
	}

	type QuestWithProgress struct {
		models.Quest
		Progress  int   `json:"progress"`
		Completed bool  `json:"completed"`
		ClaimedAt int64 `json:"claimed_at,omitempty"`
	}

	result := make([]QuestWithProgress, 0, len(quests))
	for _, q := range quests {
		p, ok := progMap[q.ID]
		qp := QuestWithProgress{Quest: q}
		if ok {
			qp.Progress  = p.Progress
			qp.Completed = p.Completed
			qp.ClaimedAt = p.ClaimedAt
		}
		result = append(result, qp)
	}

	log.Printf("[QUESTS] player=%s day=%s quests=%d", playerID[:min8(playerID)], day, len(result))
	writeJSON(ctx, 200, map[string]any{"quests": result, "day": day})
}

// POST /bj/quests/progress
// Validates the request using the server score stored in DB for the given session_id
type questProgressReq struct {
	PlayerID  string `json:"player_id"`
	SessionID string `json:"session_id"` // required — for server-side validation
}

func (s *Server) handleQuestProgress(ctx *fasthttp.RequestCtx) {
	authedPlayer := s.tokenPlayerID(ctx)
	if authedPlayer == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	var req questProgressReq
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.SessionID == "" {
		writeErr(ctx, 400, "session_id is required")
		return
	}
	// Always use the token's player, ignore client-sent player_id
	req.PlayerID = authedPlayer

	// Fetch session from DB — real values are here
	sess, err := s.Store.Get(req.SessionID)
	if err != nil {
		writeErr(ctx, 404, "session_not_found")
		return
	}

	// Session must belong to the authenticated player
	if sess.PlayerID != "" && sess.PlayerID != authedPlayer {
		log.Printf("[QUEST_PROGRESS] player_mismatch session=%s authed=%s sess=%s",
			req.SessionID[:min8(req.SessionID)], authedPlayer[:min8(authedPlayer)], sess.PlayerID[:min8(sess.PlayerID)])
		writeErr(ctx, 403, "forbidden")
		return
	}

	// Don't grant quest progress from flagged or invalid sessions
	if sess.Flagged || sess.ServerScore <= 0 {
		log.Printf("[QUEST_PROGRESS] skipped — flagged=%v server_score=%d session=%s",
			sess.Flagged, sess.ServerScore, req.SessionID[:min8(req.SessionID)])
		writeJSON(ctx, 200, map[string]any{"ok": true, "completed": []string{}, "skipped": "flagged_or_zero"})
		return
	}

	// Server-validated values
	serverScore := sess.ServerScore
	ticks := sess.Ticks // total ticks = game duration proxy

	quests, qerr := s.Store.GetOrCreatePlayerQuests(req.PlayerID)
	if qerr != nil {
		writeErr(ctx, 500, "failed to load quests")
		return
	}
	day := time.Now().In(game.UTC3).Format("2006-01-02")
	updated := []string{}

	for _, q := range quests {
		prog, _ := s.Store.GetProgress(req.PlayerID, q.ID)
		if prog == nil {
			prog = &models.PlayerQuestProgress{
				PlayerID:  req.PlayerID,
				QuestID:   q.ID,
				Day:       day,
				Target:    q.Target,
				RewardNIM: q.RewardNIM,
			}
		}
		if prog.Completed {
			continue
		}

		switch q.Type {
		// ── Score-based (single match peak) ──────────────────────────────
		case models.QuestScore:
			if serverScore > prog.Progress {
				prog.Progress = serverScore
			}

		// ── Cumulative score across matches ───────────────────────────────
		case models.QuestTotalScore:
			prog.Progress += serverScore

		// ── Match count — only counts matches that scored at least 300 ─────
		case models.QuestGames, models.QuestGames5, models.QuestGames10:
			if serverScore >= 300 {
				prog.Progress += 1
			}

		// ── Altitude (New logic: Reach score X in a single match) ─────────
		case models.QuestAltitude:
			if serverScore > prog.Progress {
				prog.Progress = serverScore
			}

		// ── Speedrun ──────────────────────────────────────────────────────
		case models.QuestSpeedrun:
			if serverScore >= 1000 && ticks <= 90*60 {
				prog.Progress = 1
			}

		// ── Streak (New logic: Pass 500 points in 3 separate matches today)
		case models.QuestStreak:
			if serverScore >= 500 {
				prog.Progress += 1
			}

		// ── Kill/coin/item based — handled exclusively by server-side replay (UpdateQuestProgressFromReplay)
		// This proxy endpoint only has basic score+ticks, no detailed game-simulation context.
		case models.QuestKills, models.QuestKillsTotal, models.QuestMosquito,
			models.QuestFlying, models.QuestNoDmgKill, models.QuestMultiKill,
			models.QuestCoinTotal, models.QuestCoinMatch, models.QuestGoldenCarot,
			models.QuestItemHunter, models.QuestPowerup, models.QuestNoCoins,
			models.QuestPacifist, models.QuestNoDmgMatch, models.QuestHighJumpOnly,
			models.QuestMirrorRun, models.QuestNoHit:
			// noop — rich context simulation handles these safely
		}

		if prog.Progress >= q.Target {
			prog.Progress = q.Target
			prog.Completed = true
			updated = append(updated, q.ID)
			log.Printf("[QUEST_DONE] player=%s quest=%s reward=%.3f NIM",
				req.PlayerID[:min8(req.PlayerID)], q.ID, q.RewardNIM)
		}

		_ = s.Store.SaveProgress(prog)
	}

	log.Printf("[QUEST_PROGRESS] player=%s session=%s server_score=%d ticks=%d completed=%v",
		req.PlayerID[:min8(req.PlayerID)], req.SessionID[:min8(req.SessionID)],
		serverScore, ticks, updated)

	writeJSON(ctx, 200, map[string]any{
		"ok":        true,
		"completed": updated,
	})
}

// POST /bj/quests/claim
func (s *Server) handleQuestClaim(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	questID := string(ctx.QueryArgs().Peek("quest_id"))
	if questID == "" {
		writeErr(ctx, 400, "quest_id is required")
		return
	}

	prog, err := s.Store.GetProgress(playerID, questID)
	if err != nil || prog == nil {
		writeErr(ctx, 404, "quest_progress_not_found")
		return
	}
	if !prog.Completed {
		writeErr(ctx, 409, "quest_not_completed")
		return
	}
	if prog.ClaimedAt != 0 {
		writeErr(ctx, 409, "already_claimed")
		return
	}

	prog.ClaimedAt = time.Now().Unix()
	if err := s.Store.SaveProgress(prog); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}

	log.Printf("[QUEST_CLAIM] player=%s quest=%s reward=%.3f NIM claimed_at=%d",
		playerID[:min8(playerID)], questID, prog.RewardNIM, prog.ClaimedAt)

	// Queue the NIM reward (save first, then send)
	rewardID := ""
	rewardErr := ""
	if prog.RewardNIM > 0 {
		reward, rerr := s.Store.QueueReward(playerID, prog.RewardNIM, "quest_claim:"+questID)
		if rerr != nil {
			rewardErr = rerr.Error()
			log.Printf("[QUEST_CLAIM] QueueReward failed player=%s quest=%s err=%v", playerID[:min8(playerID)], questID, rerr)
		} else {
			rewardID = reward.ID
		}
	}

	resp := map[string]any{
		"ok":         true,
		"quest_id":   questID,
		"reward_nim": prog.RewardNIM,
		"claimed_at": prog.ClaimedAt,
		"reward_id":  rewardID,
	}
	if rewardErr != "" {
		resp["reward_error"] = rewardErr
	}
	writeJSON(ctx, 200, resp)
}

// POST /backend/quests/claim_all
// Body: { "quest_ids": ["id1", "id2", ...] }
// Claims all provided quest IDs in one request.
func (s *Server) handleQuestClaimAll(ctx *fasthttp.RequestCtx) {
	authedPlayer := s.tokenPlayerID(ctx)
	if authedPlayer == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	var req struct {
		PlayerID string   `json:"player_id"` // ignored — use token
		QuestIDs []string `json:"quest_ids"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || len(req.QuestIDs) == 0 {
		writeErr(ctx, 400, "quest_ids are required")
		return
	}
	req.PlayerID = authedPlayer

	type claimResult struct {
		QuestID   string  `json:"quest_id"`
		OK        bool    `json:"ok"`
		RewardNIM float64 `json:"reward_nim,omitempty"`
		Error     string  `json:"error,omitempty"`
	}

	results := make([]claimResult, 0, len(req.QuestIDs))
	for _, questID := range req.QuestIDs {
		prog, err := s.Store.GetProgress(req.PlayerID, questID)
		if err != nil || prog == nil {
			results = append(results, claimResult{QuestID: questID, Error: "not_found"})
			continue
		}
		if !prog.Completed {
			results = append(results, claimResult{QuestID: questID, Error: "not_completed"})
			continue
		}
		if prog.ClaimedAt != 0 {
			results = append(results, claimResult{QuestID: questID, Error: "already_claimed"})
			continue
		}
		prog.ClaimedAt = time.Now().Unix()
		if err := s.Store.SaveProgress(prog); err != nil {
			results = append(results, claimResult{QuestID: questID, Error: "save_error"})
			continue
		}
		if prog.RewardNIM > 0 {
			_, rerr := s.Store.QueueReward(req.PlayerID, prog.RewardNIM, "quest_claim:"+questID)
			if rerr != nil {
				log.Printf("[QUEST_CLAIM_ALL] QueueReward failed player=%s quest=%s err=%v", req.PlayerID[:min8(req.PlayerID)], questID, rerr)
			}
		}
		log.Printf("[QUEST_CLAIM_ALL] player=%s quest=%s reward=%.3f", req.PlayerID[:min8(req.PlayerID)], questID, prog.RewardNIM)
		results = append(results, claimResult{QuestID: questID, OK: true, RewardNIM: prog.RewardNIM})
	}

	writeJSON(ctx, 200, map[string]any{"ok": true, "results": results})
}

func min8(s string) int {
	if len(s) < 8 {
		return len(s)
	}
	return 8
}