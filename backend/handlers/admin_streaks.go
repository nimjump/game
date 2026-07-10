package handlers

// admin_streaks.go — GET /backend/admin/streaks
//
// Powers the admin panel's dedicated "Streaks" tab: aggregate totals (how
// much NIM has the daily-login-streak system paid out, in total, all-time)
// plus a per-player breakdown (current streak day, longest run ever, total
// NIM claimed via streak, how many times they've claimed). Reward-config
// knobs (base/extra/max/max-accounts-per-IP) live on the existing
// /backend/admin/config GET+POST (see admin_system.go) — this endpoint is
// read-only stats, not config.

import (
	"sort"
	"strings"

	"github.com/valyala/fasthttp"

	"nimjump-backend/models"
)

func (s *Server) handleAdminStreaks(ctx *fasthttp.RequestCtx) {
	// Every SENT reward whose Reason is "streak:day=N" (see
	// backend/game/streak_reward.go's ReasonStreak) is a real, successfully
	// paid streak claim. One full scan gives us both the all-time aggregate
	// AND the per-player breakdown in a single pass.
	sentRewards, err := s.Store.ListRewards(string(models.RewardSent))
	if err != nil {
		writeErr(ctx, 500, "streaks_error")
		return
	}
	type claimAgg struct {
		totalNIM float64
		claims   int
		lastAt   int64
	}
	aggByPlayer := map[string]*claimAgg{}
	var totalNIM float64
	var totalClaims int
	for _, r := range sentRewards {
		if !strings.HasPrefix(r.Reason, "streak:") {
			continue
		}
		totalNIM += r.AmountNIM
		totalClaims++
		a := aggByPlayer[r.PlayerID]
		if a == nil {
			a = &claimAgg{}
			aggByPlayer[r.PlayerID] = a
		}
		a.totalNIM += r.AmountNIM
		a.claims++
		ts := r.SentAt
		if ts == 0 {
			ts = r.CreatedAt
		}
		if ts > a.lastAt {
			a.lastAt = ts
		}
	}

	// Every player who has EVER had a streak record (live or lapsed) — see
	// ListAllStreaks's doc comment for why this doesn't zero out dead
	// streaks itself (GetStreak, called per-row below, does that correctly).
	allStreaks := s.Store.ListAllStreaks()

	nicknames, _ := s.Store.ListAllNicknames()
	nickByID := make(map[string]string, len(nicknames))
	for _, pn := range nicknames {
		nickByID[pn.PlayerID] = pn.Nickname
	}

	// Union: anyone with a streak record OR anyone who's ever claimed a
	// streak reward (should be a subset of the former in practice, but a
	// union costs nothing and is defensively correct either way).
	allIDs := make(map[string]bool, len(allStreaks)+len(aggByPlayer))
	for pid := range allStreaks {
		allIDs[pid] = true
	}
	for pid := range aggByPlayer {
		allIDs[pid] = true
	}

	type streakRow struct {
		PlayerID        string  `json:"player_id"`
		Nickname        string  `json:"nickname"`
		StreakDay       int     `json:"streak_day"` // 0 if the streak has lapsed (see GetStreak)
		LongestRun      int     `json:"longest_run"`
		TotalClaimedNIM float64 `json:"total_claimed_nim"`
		ClaimsCount     int     `json:"claims_count"`
		LastClaimAt     int64   `json:"last_claim_at,omitempty"`
	}
	rows := make([]streakRow, 0, len(allIDs))
	activeStreaks := 0
	for pid := range allIDs {
		live := s.Store.GetStreak(pid) // authoritative live count — zeroes out dead streaks
		if live.Count > 0 {
			activeStreaks++
		}
		var claimed float64
		var claims int
		var lastAt int64
		if a := aggByPlayer[pid]; a != nil {
			claimed = a.totalNIM
			claims = a.claims
			lastAt = a.lastAt
		}
		rows = append(rows, streakRow{
			PlayerID:        pid,
			Nickname:        nickByID[pid],
			StreakDay:       live.Count,
			LongestRun:      live.LongestRun,
			TotalClaimedNIM: claimed,
			ClaimsCount:     claims,
			LastClaimAt:     lastAt,
		})
	}

	// Longest-active-streak-first, then biggest all-time earner as a
	// tiebreaker — puts the most "interesting" players at the top of the
	// default view instead of an arbitrary map-iteration order.
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].StreakDay != rows[j].StreakDay {
			return rows[i].StreakDay > rows[j].StreakDay
		}
		return rows[i].TotalClaimedNIM > rows[j].TotalClaimedNIM
	})

	total := len(rows)
	limit, offset := queryPage(ctx, 50)
	if offset < 0 {
		offset = 0
	}
	end := total
	if offset > total {
		offset = total
	}
	if limit > 0 && offset+limit < total {
		end = offset + limit
	}
	page := rows[offset:end]

	writeJSON(ctx, 200, map[string]any{
		"ok":                    true,
		"total_nim_distributed": totalNIM,
		"total_claims":          totalClaims,
		"unique_claimers":       len(aggByPlayer),
		"active_streaks":        activeStreaks,
		"total":                 total,
		"offset":                offset,
		"limit":                 limit,
		"players":               page,
	})
}
