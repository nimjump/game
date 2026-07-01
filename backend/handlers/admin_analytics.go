package handlers

// admin_analytics.go — GET /backend/admin/analytics
//
// Returns comprehensive platform analytics:
//   - Daily / weekly / total player counts (unique)
//   - New registrations today / this week
//   - Session counts & play-time totals
//   - NIM distributed (today / this week / all-time), broken down by category
//   - Reward queue snapshot (pending / failed / sent)
//   - Recent payments (last 20 sent rewards)
//   - Queued payments (pending + failed)
//   - Nimiq account balance

import (
	"log"
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

func (s *Server) handleAdminAnalytics(ctx *fasthttp.RequestCtx) {
	now       := time.Now().In(game.UTC3)
	todayStr  := now.Format("2006-01-02")
	weekStart := now.AddDate(0, 0, -int(now.Weekday()))
	weekStr   := weekStart.Format("2006-01-02")
	dayStart  := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, game.UTC3).Unix()
	weekStartU := time.Date(weekStart.Year(), weekStart.Month(), weekStart.Day(), 0, 0, 0, 0, game.UTC3).Unix()

	// ── Sessions scan ──────────────────────────────────────────────────────────
	allSessions := s.Store.List(false, 0)

	type playerEntry struct {
		firstSeen int64
		lastSeen  int64
	}
	playerMap := map[string]*playerEntry{}

	var (
		totalSessions, todaySessions, weekSessions     int
		totalTicks, todayTicks, weekTicks               int64
		completedSessions, flaggedSessions              int
	)

	for _, sess := range allSessions {
		if sess.PlayerID == "" { continue }

		// Track unique players
		ts := sess.SubmittedAt
		if ts == 0 { ts = sess.CreatedAt }
		if e, ok := playerMap[sess.PlayerID]; ok {
			if ts < e.firstSeen { e.firstSeen = ts }
			if ts > e.lastSeen  { e.lastSeen  = ts }
		} else {
			playerMap[sess.PlayerID] = &playerEntry{firstSeen: ts, lastSeen: ts}
		}

		// Session counts
		totalSessions++
		if sess.State == models.StateCompleted { completedSessions++ }
		if sess.State == models.StateFlagged   { flaggedSessions++ }

		t := int64(sess.Ticks)
		totalTicks += t

		if ts >= dayStart {
			todaySessions++
			todayTicks += t
		}
		if ts >= weekStartU {
			weekSessions++
			weekTicks += t
		}
	}

	totalPlayers := len(playerMap)
	todayPlayers, weekPlayers := 0, 0
	newToday, newThisWeek := 0, 0

	for _, e := range playerMap {
		if e.lastSeen >= dayStart  { todayPlayers++ }
		if e.lastSeen >= weekStartU { weekPlayers++ }
		if e.firstSeen >= dayStart  { newToday++ }
		if e.firstSeen >= weekStartU { newThisWeek++ }
	}

	// ── Rewards scan ──────────────────────────────────────────────────────────
	allRewards, err := s.Store.ListRewards("")
	if err != nil {
		log.Printf("[ANALYTICS] reward scan error: %v", err)
		allRewards = nil
	}

	var (
		nimTotalAll, nimTodayAll, nimWeekAll   float64
		rewardPending, rewardFailed, rewardSent int
	)

	// Recent payments (sent, newest first, max 20)
	type rewardOut struct {
		ID          string  `json:"id"`
		PlayerID    string  `json:"player_id"`
		Nickname    string  `json:"nickname,omitempty"`
		Amount      float64 `json:"amount_nim"`
		Reason      string  `json:"reason"`
		Status      string  `json:"status"`
		TxHash      string  `json:"tx_hash,omitempty"`
		SentAt      int64   `json:"sent_at,omitempty"`
		CreatedAt   int64   `json:"created_at"`
	}
	var recentPayments []rewardOut
	var queuedPayments []rewardOut

	// Build nickname map from sessions scan (already in memory — no extra DB hits)
	nickMap := map[string]string{}
	for _, sess := range allSessions {
		if sess.PlayerID != "" && sess.Nickname != "" {
			nickMap[sess.PlayerID] = sess.Nickname
		}
	}

	for _, r := range allRewards {
		nick := nickMap[r.PlayerID]
		switch r.Status {
		case models.RewardSent:
			rewardSent++
			nimTotalAll += r.AmountNIM
			if r.SentAt >= dayStart   { nimTodayAll += r.AmountNIM }
			if r.SentAt >= weekStartU { nimWeekAll  += r.AmountNIM }
			if len(recentPayments) < 20 {
				recentPayments = append(recentPayments, rewardOut{
					ID: r.ID, PlayerID: r.PlayerID, Nickname: nick,
					Amount: r.AmountNIM, Reason: r.Reason,
					Status: string(r.Status), TxHash: r.TxHash,
					SentAt: r.SentAt, CreatedAt: r.CreatedAt,
				})
			}
		case models.RewardPending:
			rewardPending++
			queuedPayments = append(queuedPayments, rewardOut{
				ID: r.ID, PlayerID: r.PlayerID, Nickname: nick,
				Amount: r.AmountNIM, Reason: r.Reason,
				Status: string(r.Status), CreatedAt: r.CreatedAt,
			})
		case models.RewardFailed:
			rewardFailed++
			queuedPayments = append(queuedPayments, rewardOut{
				ID: r.ID, PlayerID: r.PlayerID, Nickname: nick,
				Amount: r.AmountNIM, Reason: r.Reason,
				Status: string(r.Status), CreatedAt: r.CreatedAt,
			})
		}
	}

	// Sort recent payments newest-first
	for i := 0; i < len(recentPayments)-1; i++ {
		for j := i+1; j < len(recentPayments); j++ {
			if recentPayments[j].SentAt > recentPayments[i].SentAt {
				recentPayments[i], recentPayments[j] = recentPayments[j], recentPayments[i]
			}
		}
	}

	// ── Quest NIM stats (today) ───────────────────────────────────────────────
	// Approximate: scan rewards with reason "quest_*"
	var nimQuestAll, nimQuestToday, nimQuestWeek float64
	var nimLeaderboardAll, nimLeaderboardToday, nimLeaderboardWeek float64
	for _, r := range allRewards {
		if r.Status != models.RewardSent { continue }
		ts := r.SentAt
		isQuest := len(r.Reason) > 6 && r.Reason[:6] == "quest_"
		isLeader := len(r.Reason) >= 11 && r.Reason[:11] == "leaderboard"
		if isQuest {
			nimQuestAll += r.AmountNIM
			if ts >= dayStart   { nimQuestToday += r.AmountNIM }
			if ts >= weekStartU { nimQuestWeek  += r.AmountNIM }
		}
		if isLeader {
			nimLeaderboardAll += r.AmountNIM
			if ts >= dayStart   { nimLeaderboardToday += r.AmountNIM }
			if ts >= weekStartU { nimLeaderboardWeek  += r.AmountNIM }
		}
	}

	// ── Nimiq balance (with 4s timeout so analytics never hangs) ────────────────
	type nimBalanceOut struct {
		BalanceNIM    float64 `json:"balance_nim"`
		WalletAddress string  `json:"wallet_address"`
		LowThreshold  float64 `json:"low_threshold"`
		IsLow         bool    `json:"is_low"`
		Error         string  `json:"error,omitempty"`
	}
	cfg := s.Store.GetNimiqConfig()
	nimBalance := nimBalanceOut{
		WalletAddress: cfg.WalletAddress,
		LowThreshold:  cfg.LowBalanceThreshold,
	}
	type balResult struct {
		bal float64
		err error
	}
	balCh := make(chan balResult, 1)
	go func() {
		b, e := game.GetNimiqBalance(cfg)
		balCh <- balResult{b, e}
	}()
	select {
	case res := <-balCh:
		if res.err != nil {
			nimBalance.Error = res.err.Error()
		} else {
			nimBalance.BalanceNIM = res.bal
			nimBalance.IsLow      = res.bal < cfg.LowBalanceThreshold
		}
	case <-time.After(4 * time.Second):
		nimBalance.Error = "timeout"
	}

	// ── Play-time formatting helpers ──────────────────────────────────────────
	ticksToSec := func(ticks int64) int64 { return ticks / 60 } // 60 ticks/sec

	writeJSON(ctx, 200, map[string]any{
		"generated_at": time.Now().Unix(),
		"today":        todayStr,
		"week_start":   weekStr,

		"players": map[string]any{
			"total":       totalPlayers,
			"today":       todayPlayers,
			"this_week":   weekPlayers,
			"new_today":   newToday,
			"new_week":    newThisWeek,
		},

		"sessions": map[string]any{
			"total":     totalSessions,
			"today":     todaySessions,
			"this_week": weekSessions,
			"completed": completedSessions,
			"flagged":   flaggedSessions,
		},

		"playtime_sec": map[string]any{
			"total":     ticksToSec(totalTicks),
			"today":     ticksToSec(todayTicks),
			"this_week": ticksToSec(weekTicks),
		},

		"nim": map[string]any{
			"total_distributed":      nimTotalAll,
			"distributed_today":      nimTodayAll,
			"distributed_this_week":  nimWeekAll,
			"quest_total":            nimQuestAll,
			"quest_today":            nimQuestToday,
			"quest_this_week":        nimQuestWeek,
			"leaderboard_total":      nimLeaderboardAll,
			"leaderboard_today":      nimLeaderboardToday,
			"leaderboard_this_week":  nimLeaderboardWeek,
		},

		"reward_queue": map[string]any{
			"pending": rewardPending,
			"failed":  rewardFailed,
			"sent":    rewardSent,
		},

		"recent_payments": recentPayments,
		"queued_payments": queuedPayments,
		"nimiq_balance":   nimBalance,
	})
}
