package handlers

import (
	"encoding/json"
	"fmt"
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// POST /bj/wallet/register
// Body: {"nimiq_address":"NQ..."}  — player_id taken from auth token
func (s *Server) handleWalletRegister(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	var req struct {
		PlayerID     string `json:"player_id"`     // ignored — enforced by token
		NimiqAddress string `json:"nimiq_address"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.NimiqAddress == "" {
		writeErr(ctx, 400, "nimiq_address is required")
		return
	}
	if len(req.NimiqAddress) < 4 || req.NimiqAddress[:2] != "NQ" {
		writeErr(ctx, 400, "invalid_nimiq_address")
		return
	}
	if err := s.Store.RegisterPlayerWallet(playerID, req.NimiqAddress); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}

	// Retry pending rewards that were in no_wallet status
	go s.Store.RetryPendingRewards()

	log.Printf("[WALLET] registered player=%s nimiq=%s", playerID[:min8(playerID)], req.NimiqAddress)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// GET /bj/wallet — returns authenticated player's wallet
func (s *Server) handleWalletGet(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	pw, err := s.Store.GetPlayerWallet(playerID)
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if pw == nil {
		writeJSON(ctx, 200, map[string]any{"registered": false, "nimiq_address": ""})
		return
	}
	writeJSON(ctx, 200, map[string]any{
		"registered":    true,
		"nimiq_address": pw.NimiqAddress,
		"registered_at": pw.RegisteredAt,
	})
}

// POST /bj/admin/nimiq-config
// Body: {"rpc_url":"...", "wallet_address":"NQ...", "telegram_token":"...", "telegram_chat_id":"...", "low_balance_threshold": 1000}
func (s *Server) handleAdminNimiqConfig(ctx *fasthttp.RequestCtx) {
	var cfg models.NimiqConfig
	if err := json.Unmarshal(ctx.PostBody(), &cfg); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if err := s.Store.SaveNimiqConfig(cfg); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] nimiq config updated rpc=%s wallet=%s", cfg.RPCURL, cfg.WalletAddress)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// GET /bj/admin/nimiq-config
func (s *Server) handleAdminNimiqConfigGet(ctx *fasthttp.RequestCtx) {
	cfg := s.Store.GetNimiqConfig()
	writeJSON(ctx, 200, map[string]any{
		"rpc_url":               cfg.RPCURL,
		"wallet_address":        cfg.WalletAddress,
		"low_balance_threshold": cfg.LowBalanceThreshold,
		// token and chat_id are partially masked for security
		"telegram_configured": cfg.TelegramToken != "",
	})
}

// GET /bj/admin/nimiq-balance
func (s *Server) handleAdminNimiqBalance(ctx *fasthttp.RequestCtx) {
	cfg := s.Store.GetNimiqConfig()
	balance, err := game.GetNimiqBalance(cfg)
	if err != nil {
		log.Printf("[ADMIN] nimiq_balance error: %v", err)
		writeErr(ctx, 500, "balance_fetch_error")
		return
	}
	writeJSON(ctx, 200, map[string]any{
		"balance_nim":    balance,
		"wallet_address": cfg.WalletAddress,
		"low_threshold":  cfg.LowBalanceThreshold,
		"is_low":         balance < cfg.LowBalanceThreshold,
	})
}

// GET /bj/admin/rewards?status=pending|sent|failed|no_wallet
func (s *Server) handleAdminRewards(ctx *fasthttp.RequestCtx) {
	status := string(ctx.QueryArgs().Peek("status"))
	rewards, err := s.Store.ListRewards(status)
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if rewards == nil {
		rewards = []models.PendingReward{}
	}
	writeJSON(ctx, 200, map[string]any{
		"rewards": rewards,
		"count":   len(rewards),
	})
}

// GET /backend/rewards/history
//
// Oyuncunun kendi NIM kazanım geçmişi ("last transactions").
// FIX: önceden Store'dan limit=20 ile çekilip sıralama yapılmadan
// direkt döndürülüyordu — eğer Store.ListRewardsByPlayer Badger
// iterator sırasıyla (key sırası, zaman sırası DEĞİL) dönüyorsa
// "en yeni 20" garantisi yoktu. Şimdi: store'dan daha geniş bir
// havuz çekiliyor, biz SentAt (yoksa CreatedAt) değerine göre
// kendimiz desc sort edip en yeni 5'i kırpıyoruz.
func (s *Server) handleRewardHistory(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	const displayLimit = 5
	const fetchLimit = 100 // store'dan bolca çek, zaman sırasını biz garanti edeceğiz

	rewards, err := s.Store.ListRewardsByPlayer(playerID, fetchLimit)
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if rewards == nil {
		rewards = []models.PendingReward{}
	}

	// En yeni en üstte. Gönderilmiş (sent) ödüllerde SentAt daha güvenilir
	// zaman damgası; henüz gönderilmemiş (pending/failed) kayıtlarda
	// SentAt sıfır olacağı için CreatedAt'e düşüyoruz.
	rewardSortKey := func(r models.PendingReward) int64 {
		if r.SentAt > 0 {
			return r.SentAt
		}
		return r.CreatedAt
	}
	for i := 0; i < len(rewards)-1; i++ {
		for j := i + 1; j < len(rewards); j++ {
			if rewardSortKey(rewards[j]) > rewardSortKey(rewards[i]) {
				rewards[i], rewards[j] = rewards[j], rewards[i]
			}
		}
	}

	if len(rewards) > displayLimit {
		rewards = rewards[:displayLimit]
	}

	log.Printf("[REWARD_HISTORY] player=%s returned=%d (fetched=%d)",
		playerID[:min8(playerID)], len(rewards), fetchLimit)

	writeJSON(ctx, 200, map[string]any{
		"rewards": rewards,
		"count":   len(rewards),
	})
}

// POST /backend/admin/rewards/retry — force retry all pending rewards immediately
func (s *Server) handleAdminRetryRewards(ctx *fasthttp.RequestCtx) {
	go s.Store.ForceRetryPendingRewards()
	writeJSON(ctx, 200, map[string]any{"ok": true, "message": "retry started"})
}

// POST /bj/admin/test-telegram
// Body: {"message":"test message"}
func (s *Server) handleAdminTestTelegram(ctx *fasthttp.RequestCtx) {
	var req struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || req.Message == "" {
		req.Message = "🔔 NimJump backend test message"
	}
	s.Store.SendTelegramDirect(req.Message)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /bj/leaderboard/pay-winners
// Body: {"period_type":"daily","period":"2026-06-17"}
func (s *Server) handleLeaderboardPayWinners(ctx *fasthttp.RequestCtx) {
	var req struct {
		PeriodType string `json:"period_type"`
		Period     string `json:"period"`
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

	// Get winners (create snapshot if none exists)
	pw, err := s.Store.GetWinners(req.Period)
	if err != nil || pw == nil {
		pw, err = s.Store.SnapshotWinners(req.PeriodType, req.Period)
		if err != nil {
			writeErr(ctx, 500, "snapshot_error")
			return
		}
	}

	type queueResult struct {
		PlayerID string  `json:"player_id"`
		Nickname string  `json:"nickname"`
		Rank     int     `json:"rank"`
		PrizeNIM float64 `json:"prize_nim"`
		RewardID string  `json:"reward_id,omitempty"`
		Error    string  `json:"error,omitempty"`
	}

	results := make([]queueResult, 0, len(pw.Winners))
	for _, w := range pw.Winners {
		if w.PrizeNIM <= 0 {
			continue
		}
		res := queueResult{
			PlayerID: w.PlayerID,
			Nickname: w.Nickname,
			Rank:     w.Rank,
			PrizeNIM: w.PrizeNIM,
		}
		reason := fmt.Sprintf("leaderboard:%s:%s:rank%d", req.PeriodType, req.Period, w.Rank)
		reward, rerr := s.Store.QueueReward(w.PlayerID, w.PrizeNIM, reason)
		if rerr != nil {
			res.Error = rerr.Error()
		} else {
			res.RewardID = reward.ID
		}
		results = append(results, res)
	}

	writeJSON(ctx, 200, map[string]any{
		"period":      req.Period,
		"period_type": req.PeriodType,
		"queued":      len(results),
		"results":     results,
	})
}