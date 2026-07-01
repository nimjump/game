package handlers

// stats.go — Player stats, leaderboard ve winners HTTP handler'ları
//
// Endpoint'ler:
//   GET  /bj/stats                   → oyuncu özeti (skor, cap, quest, rank)
//   GET  /bj/stats/leaderboard       → sayfalı leaderboard
//   GET  /bj/stats/winners           → geçmiş dönem kazananları
//   GET  /bj/stats/periods           → aktif günlük/haftalık period key'leri

import (
	"log"
	"os"
	"strconv"
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// GET /bj/stats?player_id=xxx[&period_type=daily|weekly|alltime][&period=2026-06-28]
//
// player_id zorunlu değildir; auth token mevcutsa oradan alınır.
func (s *Server) handleStats(ctx *fasthttp.RequestCtx) {
	playerID := string(ctx.QueryArgs().Peek("player_id"))
	if playerID == "" {
		playerID = s.tokenPlayerID(ctx)
	}
	if playerID == "" {
		writeErr(ctx, 400, "player_id required")
		return
	}

	periodType := string(ctx.QueryArgs().Peek("period_type"))
	if periodType == "" {
		periodType = "daily"
	}
	period := string(ctx.QueryArgs().Peek("period"))
	if period == "" {
		daily, weekly := game.CurrentPeriods()
		switch periodType {
		case "weekly":
			period = weekly
		case "alltime":
			period = ""
		default:
			period = daily
		}
	}

	// ── Session istatistikleri ────────────────────────────────────────────────
	sessions := s.Store.List(false, 0)
	var bestScore, totalGames, totalTicks, totalKills, totalPlatforms int
	var lastPlayedAt int64
	var bestSessionID string

	type recentGame struct {
		SessionID   string `json:"session_id"`
		ServerScore int    `json:"server_score"`
		ClientScore int    `json:"client_score"`
		Ticks       int    `json:"ticks"`
		Char        int    `json:"char"`
		Flagged     bool   `json:"flagged"`
		Reason      string `json:"reason,omitempty"`
		SubmittedAt int64  `json:"submitted_at"`
	}
	var recentGames []recentGame

	for _, sess := range sessions {
		if sess.PlayerID != playerID {
			continue
		}
		totalGames++
		totalTicks += sess.Ticks
		totalKills += sess.TotalKills
		totalPlatforms += sess.TotalPlatforms
		displayScore := sess.ServerScore
		if displayScore <= 0 {
			displayScore = sess.ClientScore
		}
		if !sess.Flagged && displayScore > bestScore {
			bestScore = displayScore
			bestSessionID = sess.SessionID
		}
		if sess.SubmittedAt > lastPlayedAt {
			lastPlayedAt = sess.SubmittedAt
		}
		recentGames = append(recentGames, recentGame{
			SessionID:   sess.SessionID,
			ServerScore: sess.ServerScore,
			ClientScore: sess.ClientScore,
			Ticks:       sess.Ticks,
			Char:        sess.Char,
			Flagged:     sess.Flagged,
			Reason:      sess.Reason,
			SubmittedAt: sess.SubmittedAt,
		})
	}
	// En yeni oyun en üstte — submitted_at desc
	for i := 0; i < len(recentGames)-1; i++ {
		for j := i + 1; j < len(recentGames); j++ {
			if recentGames[j].SubmittedAt > recentGames[i].SubmittedAt {
				recentGames[i], recentGames[j] = recentGames[j], recentGames[i]
			}
		}
	}
	// FIX: 10 → 5. "Recent games" artık sadece en yeni 5 oyunu döndürüyor.
	if len(recentGames) > 5 {
		recentGames = recentGames[:5]
	}

	// ── Nickname ──────────────────────────────────────────────────────────────
	nick := ""
	if pn, err := s.Store.GetNickname(playerID); err == nil && pn != nil {
		nick = pn.Nickname
	}

	// ── Leaderboard sıralaması ────────────────────────────────────────────────
	rank := 0
	entries, lbErr := s.Store.GetLeaderboardPaged(periodType, period, 0, 0, playerID)
	if lbErr == nil {
		for _, e := range entries {
			if e.PlayerID == playerID {
				rank = e.Rank
				break
			}
		}
	}

	// ── Daily earn cap ────────────────────────────────────────────────────────
	capStats := s.Store.GetDailyCapStats(playerID)

	// ── Quest özeti (bugün) ───────────────────────────────────────────────────
	day := time.Now().In(game.UTC3).Format("2006-01-02")
	quests, _ := s.Store.GetOrCreatePlayerQuests(playerID)
	progresses := s.Store.AllProgress(playerID, day)

	completedCount, claimedCount := 0, 0
	for _, p := range progresses {
		if p.Completed {
			completedCount++
		}
		if p.ClaimedAt != 0 {
			claimedCount++
		}
	}
	var pendingRewardNIM float64
	for _, p := range progresses {
		if p.Completed && p.ClaimedAt == 0 {
			pendingRewardNIM += p.RewardNIM
		}
	}

	// ── Toplam kazanım (gönderilmiş ödüller) ─────────────────────────────────
	var totalEarnedNIM float64
	if rewards, err := s.Store.ListRewardsByPlayer(playerID, 100); err == nil {
		for _, r := range rewards {
			if r.Status == models.RewardSent {
				totalEarnedNIM += r.AmountNIM
			}
		}
	}

	log.Printf("[STATS] player=%s score=%d games=%d rank=%d cap=%.2f/%.2f",
		playerID[:min8(playerID)], bestScore, totalGames, rank,
		capStats.EarnedToday, capStats.Cap)

	gameURL := os.Getenv("GAME_URL")
	if gameURL == "" {
		gameURL = "https://nimjump.io"
	}

	writeJSON(ctx, 200, map[string]any{
		"player_id":       playerID,
		"nickname":        nick,
		"best_score":      bestScore,
		"best_session_id": bestSessionID,
		"game_url":        gameURL,
		"total_games":     totalGames,
		"total_ticks":     totalTicks,
		"total_kills":     totalKills,
		"total_platforms": totalPlatforms,
		"last_played":     lastPlayedAt,
		"rank":            rank,
		"period":          period,
		"period_type":     periodType,
		"daily_cap":       capStats,
		"recent_games":    recentGames,
		"quests": map[string]any{
			"total":              len(quests),
			"completed":          completedCount,
			"claimed":            claimedCount,
			"pending_reward_nim": pendingRewardNIM,
			"day":                day,
		},
		"total_earned_nim": totalEarnedNIM,
		"server_time":      time.Now().Unix(),
	})
}

// GET /bj/stats/leaderboard
//
//	?period_type=daily|weekly|alltime
//	&period=2026-06-28          (yoksa aktif dönem)
//	&limit=10                   (max 100)
//	&offset=0
//	&player_id=NQ...            (self entry için; token'dan da alınır)
func (s *Server) handleLeaderboard(ctx *fasthttp.RequestCtx) {
	periodType := string(ctx.QueryArgs().Peek("period_type"))
	if periodType == "" {
		periodType = "daily"
	}

	period := string(ctx.QueryArgs().Peek("period"))
	if period == "" && periodType != "alltime" {
		daily, weekly := game.CurrentPeriods()
		if periodType == "weekly" {
			period = weekly
		} else {
			period = daily
		}
	}

	limit := 10
	if raw := ctx.QueryArgs().Peek("limit"); len(raw) > 0 {
		if v, err := strconv.Atoi(string(raw)); err == nil && v > 0 && v <= 100 {
			limit = v
		}
	}
	offset := 0
	if raw := ctx.QueryArgs().Peek("offset"); len(raw) > 0 {
		if v, err := strconv.Atoi(string(raw)); err == nil && v >= 0 {
			offset = v
		}
	}

	selfPlayerID := string(ctx.QueryArgs().Peek("player_id"))
	if selfPlayerID == "" {
		selfPlayerID = s.tokenPlayerID(ctx)
	}

	entries, err := s.Store.GetLeaderboardPaged(periodType, period, limit, offset, selfPlayerID)
	if err != nil {
		writeErr(ctx, 500, "leaderboard_error")
		return
	}
	if entries == nil {
		entries = []game.LBEntry{}
	}

	log.Printf("[LEADERBOARD] period_type=%s period=%s offset=%d limit=%d count=%d",
		periodType, period, offset, limit, len(entries))

	writeJSON(ctx, 200, map[string]any{
		"entries":     entries,
		"period":      period,
		"period_type": periodType,
		"limit":       limit,
		"offset":      offset,
		"count":       len(entries),
	})
}

// GET /bj/stats/winners[?limit=10]
// Geçmiş dönem kazananlarını döner (snapshot edilmiş, admin pay-winners'tan önce).
func (s *Server) handleLeaderboardWinners(ctx *fasthttp.RequestCtx) {
	winners, err := s.Store.ListWinners()
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if winners == nil {
		winners = []models.PeriodWinners{}
	}

	// Opsiyonel limit
	limit := len(winners)
	if raw := ctx.QueryArgs().Peek("limit"); len(raw) > 0 {
		if v, err2 := strconv.Atoi(string(raw)); err2 == nil && v > 0 && v < limit {
			limit = v
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"winners": winners[:limit],
		"count":   len(winners),
	})
}

// GET /bj/stats/periods
// Frontend'in "aktif dönem nedir" sorusunu tek yerden cevaplaması için.
func (s *Server) handleStatsPeriods(ctx *fasthttp.RequestCtx) {
	daily, weekly := game.CurrentPeriods()
	now := time.Now().In(game.UTC3)

	// Bir sonraki gün sonu (UTC+3 gece yarısı)
	nextDay := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, game.UTC3)

	// Haftanın bir sonraki pazartesisi
	daysUntilMonday := (8 - int(now.Weekday())) % 7
	if daysUntilMonday == 0 {
		daysUntilMonday = 7
	}
	nextWeek := time.Date(now.Year(), now.Month(), now.Day()+daysUntilMonday, 0, 0, 0, 0, game.UTC3)

	writeJSON(ctx, 200, map[string]any{
		"daily":            daily,
		"weekly":           weekly,
		"daily_resets_at":  nextDay.Unix(),
		"weekly_resets_at": nextWeek.Unix(),
		"server_time":      now.Unix(),
		"timezone":         "UTC+3",
	})
}