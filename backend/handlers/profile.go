package handlers

// profile.go — the auth-gated "profile card" endpoint powering the
// clickable leaderboard / VS-leaderboard rows.
//
// Endpoint:
//   GET /backend/profile?player_id= → another player's public profile card (auth required — no anonymous viewing)

import (
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// GET /backend/profile?player_id=NQ...
//
// Auth required — wallet-signing gate, no card without a valid session
// token, regardless of whose profile is being requested.
func (s *Server) handleProfile(ctx *fasthttp.RequestCtx) {
	viewer := s.tokenPlayerID(ctx)
	if viewer == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	targetID := string(ctx.QueryArgs().Peek("player_id"))
	if targetID == "" {
		writeErr(ctx, 400, "player_id required")
		return
	}

	// ── Aggregate from sessions — same single pass handleStats does ────────
	sessions := s.Store.List(false, 0)
	var gamesPlayed, totalKills, playTimeTicks, bestScore int
	var lastSeen int64
	var recent []models.ProfileMatch
	for _, sess := range sessions {
		if sess.PlayerID != targetID {
			continue
		}
		gamesPlayed++
		totalKills += sess.TotalKills
		playTimeTicks += sess.Ticks
		displayScore := sess.ServerScore
		if displayScore <= 0 {
			displayScore = sess.ClientScore
		}
		if !sess.Flagged && displayScore > bestScore {
			bestScore = displayScore
		}
		if sess.SubmittedAt > lastSeen {
			lastSeen = sess.SubmittedAt
		}
		recent = append(recent, models.ProfileMatch{
			SessionID:   sess.SessionID,
			Score:       displayScore,
			Kills:       sess.TotalKills,
			Char:        sess.Char,
			Flagged:     sess.Flagged,
			HasReplay:   sess.Log != "", // same rule game.LBEntry.HasReplay uses
			SubmittedAt: sess.SubmittedAt,
		})
	}
	// Newest first, cap at 5 — same convention as handleStats's recent_games.
	for i := 0; i < len(recent)-1; i++ {
		for j := i + 1; j < len(recent); j++ {
			if recent[j].SubmittedAt > recent[i].SubmittedAt {
				recent[i], recent[j] = recent[j], recent[i]
			}
		}
	}
	if len(recent) > 5 {
		recent = recent[:5]
	}

	nick := ""
	if pn, err := s.Store.GetNickname(targetID); err == nil && pn != nil {
		nick = pn.Nickname
	}

	streak := s.Store.GetStreak(targetID)

	// ── Daily + weekly rank ──────────────────────────────────────────────
	// RankMapForPeriod does one scan+sort for the WHOLE leaderboard and
	// returns every player's rank — cheaper than GetLeaderboardPaged (built
	// for "give me a page around player X") when all we need is one
	// player's number out of it. Same filtering rules as the real
	// leaderboard (see its doc comment in game/leaderboard.go), so this
	// number always agrees with what LeaderboardPanel shows.
	daily, weekly := game.CurrentPeriods()
	dailyRanks := s.Store.RankMapForPeriod("daily", daily)
	weeklyRanks := s.Store.RankMapForPeriod("weekly", weekly)

	card := models.ProfileCard{
		PlayerID:      targetID,
		Nickname:      nick,
		GamesPlayed:   gamesPlayed,
		TotalKills:    totalKills,
		PlayTimeTicks: playTimeTicks,
		LoginStreak:   streak.Count,
		LastSeen:      lastSeen,
		BestScore:     bestScore,
		DailyRank:     dailyRanks[targetID],
		WeeklyRank:    weeklyRanks[targetID],
		RecentMatches: recent,
	}
	if card.RecentMatches == nil {
		card.RecentMatches = []models.ProfileMatch{}
	}

	log.Printf("[PROFILE] viewer=%s target=%s games=%d", viewer[:min8(viewer)], targetID[:min8(targetID)], gamesPlayed)
	writeJSON(ctx, 200, card)
}
