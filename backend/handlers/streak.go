package handlers

// streak.go — claimable daily login-streak NIM reward endpoints.
//
// GET  /backend/streak/status — read-only: current streak day, claimable
//   amount, whether today's already been claimed. Client polls this to
//   render the claim button/amount without guessing.
// POST /backend/streak/claim  — actually claims today's reward (if any).
//   Mirrors handleQuestClaim's shape/locking pattern in quest.go.

import (
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/streak/status
func (s *Server) handleStreakStatus(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	day, claimableNIM, alreadyClaimed, err := s.Store.GetStreakClaimStatus(playerID)
	if err != nil {
		log.Printf("[STREAK_STATUS] player=%s err=%v", playerID[:min8(playerID)], err)
		writeErr(ctx, 500, "streak_status_error")
		return
	}
	// Reward formula params — sent alongside the status so the client can
	// render a proper "here's what tomorrow/day N pays" preview (real-game
	// daily-login-calendar style) instead of only knowing today's number.
	// Client computes reward(day) = min(base + extra*(day-1), max) itself
	// for a window of days around today using these three values.
	writeJSON(ctx, 200, map[string]any{
		"ok":                        true,
		"streak_day":                day,
		"claimable_nim":             claimableNIM,
		"already_claimed":           alreadyClaimed,
		"reward_base_nim":           s.Store.StreakRewardBaseNIM(),
		"reward_extra_per_day_nim":  s.Store.StreakRewardExtraPerDayNIM(),
		"reward_max_nim":            s.Store.StreakRewardMaxNIM(),
	})
}

// POST /backend/streak/claim
func (s *Server) handleStreakClaim(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	// Same double-claim guard as handleQuestClaim — see TryClaimStreakLock.
	release, ok := game.TryClaimStreakLock(playerID)
	if !ok {
		writeErr(ctx, 409, "claim_in_progress")
		return
	}
	defer release()

	ip := realClientIP(ctx)
	result, err := s.Store.ClaimStreakReward(playerID, ip)
	if err != nil {
		log.Printf("[STREAK_CLAIM] player=%s err=%v", playerID[:min8(playerID)], err)
		writeErr(ctx, 500, "streak_claim_error")
		return
	}

	if result.AlreadyClaimed {
		writeJSON(ctx, 409, map[string]any{
			"ok":         false,
			"error":      "already_claimed",
			"streak_day": result.Day,
		})
		return
	}
	if result.NoActiveStreak {
		writeJSON(ctx, 409, map[string]any{
			"ok":         false,
			"error":      "no_active_streak",
			"streak_day": result.Day,
		})
		return
	}
	if result.BlockedIPLimit {
		// Honest, not silent — the client turns this into a specific toast
		// rather than pretending nothing happened (see the request that
		// asked for this behavior explicitly).
		writeJSON(ctx, 429, map[string]any{
			"ok":         false,
			"error":      "ip_account_limit",
			"streak_day": result.Day,
		})
		return
	}

	log.Printf("[STREAK_CLAIM] ok player=%s day=%d amount=%.4f", playerID[:min8(playerID)], result.Day, result.AmountNIM)
	writeJSON(ctx, 200, map[string]any{
		"ok":         true,
		"streak_day": result.Day,
		"reward_nim": result.AmountNIM,
	})
}
