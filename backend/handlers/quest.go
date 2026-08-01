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
	now := time.Now().In(game.UTC3)
	day := now.Format("2006-01-02")
	// resetAt — unix timestamp of the next UTC+3 midnight, i.e. exactly when
	// `day` above rolls over server-side. Sent to the client so its "Reset:
	// HH:MM:SS" countdown label can count down to the REAL reset instant
	// (an absolute unix timestamp, timezone-agnostic) instead of guessing
	// from the player's own device clock/timezone — a player whose phone is
	// not on UTC+3 would otherwise see a countdown that hits zero at the
	// wrong time relative to when quests actually reset.
	resetAt := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, game.UTC3).Unix()
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
	writeJSON(ctx, 200, map[string]any{"quests": result, "day": day, "reset_at": resetAt})
}

// NOTE: There used to be a POST /bj/quests/progress endpoint here, callable
// directly by the client after a run, which re-derived quest progress from a
// session's server-validated score/ticks. It's been removed — quest progress
// is now applied EXCLUSIVELY as a side effect of replay verification, inside
// the /backend/submit handler (see server.go's call to
// Store.UpdateQuestProgressFromReplay, which covers every quest type,
// including the score/altitude/speedrun/streak ones this endpoint used to
// handle itself). The client never triggers quest progress directly anymore;
// it only ever submits a replay, and the server updates quests as part of
// verifying it. This removes an entire client-facing attack surface (no more
// need for the ClaimQuestProgressForSession idempotency guard either, since
// UpdateQuestProgressFromReplay only ever runs once per submitted session,
// from server code, not from a repeatable client-triggered request).

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

	// BUG FIX: serialize claims for the same (player, quest) — without this,
	// two concurrent requests (double-click, retry, two tabs) could both
	// read ClaimedAt==0 before either wrote it, and both would queue a real
	// NIM payout. See TryClaimQuestLock in game/quest.go.
	release, ok := game.TryClaimQuestLock(playerID, questID)
	if !ok {
		writeErr(ctx, 409, "claim_in_progress")
		return
	}
	defer release()

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

	// Same shared per-IP anti-multi-accounting guard as streak claims (see
	// game/ip_reward_guard.go) — checked BEFORE marking the quest claimed,
	// so a blocked claim stays unclaimed/retryable rather than burning the
	// player's quest for nothing. Deliberately still counts as "using up"
	// one of the IP's daily account slots even for a 0-reward quest (rare
	// in practice, and simpler than special-casing it).
	ip := realClientIP(ctx)
	if okIP, ierr := s.Store.CheckAndRecordIPRewardEligibility(ip, playerID); ierr != nil {
		log.Printf("[QUEST_CLAIM] ip guard error player=%s quest=%s err=%v", playerID[:min8(playerID)], questID, ierr)
	} else if !okIP {
		log.Printf("[QUEST_CLAIM] BLOCKED (ip limit) player=%s ip=%s quest=%s", playerID[:min8(playerID)], ip, questID)
		writeJSON(ctx, 429, map[string]any{"ok": false, "error": "ip_account_limit", "quest_id": questID})
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
	// BUG FIX (security audit): quest_ids was unbounded — a large client-
	// supplied array forced one DB GetProgress lookup + lock attempt per
	// entry, letting a single request drive unbounded DB/CPU load (there are
	// only a handful of real daily quests, so any legitimate call is tiny).
	const maxClaimAllQuestIDs = 64
	if len(req.QuestIDs) > maxClaimAllQuestIDs {
		writeErr(ctx, 400, "too_many_quest_ids")
		return
	}
	req.PlayerID = authedPlayer

	type claimResult struct {
		QuestID   string  `json:"quest_id"`
		OK        bool    `json:"ok"`
		RewardNIM float64 `json:"reward_nim,omitempty"`
		Error     string  `json:"error,omitempty"`
	}

	ip := realClientIP(ctx)
	results := make([]claimResult, 0, len(req.QuestIDs))
	for _, questID := range req.QuestIDs {
		// Same double-claim guard as handleQuestClaim — see TryClaimQuestLock.
		release, lockOK := game.TryClaimQuestLock(req.PlayerID, questID)
		if !lockOK {
			results = append(results, claimResult{QuestID: questID, Error: "claim_in_progress"})
			continue
		}

		prog, err := s.Store.GetProgress(req.PlayerID, questID)
		if err != nil || prog == nil {
			results = append(results, claimResult{QuestID: questID, Error: "not_found"})
			release()
			continue
		}
		if !prog.Completed {
			results = append(results, claimResult{QuestID: questID, Error: "not_completed"})
			release()
			continue
		}
		if prog.ClaimedAt != 0 {
			results = append(results, claimResult{QuestID: questID, Error: "already_claimed"})
			release()
			continue
		}
		// Same guard as handleQuestClaim — see the comment there.
		if okIP, ierr := s.Store.CheckAndRecordIPRewardEligibility(ip, req.PlayerID); ierr != nil {
			log.Printf("[QUEST_CLAIM_ALL] ip guard error player=%s quest=%s err=%v", req.PlayerID[:min8(req.PlayerID)], questID, ierr)
		} else if !okIP {
			results = append(results, claimResult{QuestID: questID, Error: "ip_account_limit"})
			release()
			continue
		}
		prog.ClaimedAt = time.Now().Unix()
		if err := s.Store.SaveProgress(prog); err != nil {
			results = append(results, claimResult{QuestID: questID, Error: "save_error"})
			release()
			continue
		}
		release()
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
