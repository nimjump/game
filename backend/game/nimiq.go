package game

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const (
	keyPlayerWalletPrefix = "wallet:" // + playerID
	keyPendingRewardPfx   = "reward:" // + rewardID
	keyNimiqConfig        = "nimcfg"
	NimLunaMultiplier     = 100_000 // 1 NIM = 100,000 luna

	MaxRetryAttempts = 10 // informational only — not enforced; rewards retry forever (see attemptSend)

	// RetryInterval — how often the background loop WAKES UP to scan for due
	// rewards (cheap: just a DB list, no RPC calls unless something is
	// actually due). This is intentionally short so a reward that just became
	// eligible again doesn't sit around long.
	RetryInterval = 15 * time.Second

	// RewardRetryCooldown — minimum time between two send ATTEMPTS for the
	// SAME reward. This used to be wired to RetryInterval (15s) by mistake —
	// the comment above the old check said "15 minutes" but the code used
	// RetryInterval.Seconds() = 15 SECONDS, so every reward that failed (e.g.
	// due to RPC "Rate limit exceeded") was retried again on the very next
	// 15s loop tick, forever. With dozens of pending rewards that meant
	// dozens of pushTransaction/getBlockNumber RPC calls every 15 seconds —
	// which is exactly what triggered (and perpetuated) the rate limiting in
	// the first place, and also caused the same still-in-flight transaction
	// to be re-signed/re-pushed before it had time to leave the mempool,
	// producing "Transaction already in mempool" errors on top.
	RewardRetryCooldown = 3 * time.Minute
	// RewardRetryMaxCooldown — cap for the exponential backoff below, so a
	// reward that keeps failing doesn't end up waiting hours between tries.
	RewardRetryMaxCooldown = 15 * time.Minute

	// vsNotifyPingNIM — the smallest indivisible NIM amount (1 luna) sent to
	// a player purely to trigger Nimiq Pay's own built-in "payment received"
	// notification. This mini-app runs inside a WebView with no Web Push
	// support and no way to reach a player who isn't actively in the game,
	// so this piggybacks on the wallet app's own notification instead of
	// building a separate push infrastructure. The actual value is
	// irrelevant — what matters is the memo carrying the message — so it's
	// kept at the true minimum rather than some arbitrary "small" amount.
	// See sendVSJoinPing.
	vsNotifyPingNIM = 0.00001
)

var retryMu sync.Mutex

// sendingRewards tracks reward IDs that currently have an attemptSend() call
// in flight. Without this, the same reward could be dispatched twice at once
// — e.g. QueueReward's immediate "go s.attemptSend(reward)" overlapping with
// the 15s retry loop or an admin's ForceRetryPendingRewards (which explicitly
// skips the normal cooldown check) — and each concurrent call independently
// signs and pushes its own on-chain transaction for the same payout, i.e. a
// real double-spend of house funds. This is a simple mutual-exclusion lock
// per reward ID: attemptSend claims the ID before doing any RPC work and
// releases it when done (success or failure), so a second concurrent call
// for the same reward is dropped instead of firing a second real payment.
var sendingRewards sync.Map // rewardID (string) → struct{}{} while in flight

// ── Config ────────────────────────────────────────────────────────────────────

func (s *Store) GetNimiqConfig() models.NimiqConfig {
	cfg := models.NimiqConfig{
		RPCURL:              getEnv("NIMIQ_RPC_URL", "https://rpc.nimiqwatch.com"),
		WalletAddress:       getEnv("NIMIQ_WALLET_ADDRESS", ""),
		TelegramToken:       getEnv("TELEGRAM_BOT_TOKEN", ""),
		TelegramChatID:      getEnv("TELEGRAM_CHAT_ID", ""),
		LowBalanceThreshold: getEnvFloat("LOW_BALANCE_THRESHOLD", 1000.0),
	}
	var dbCfg models.NimiqConfig
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyNimiqConfig))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &dbCfg)
		})
	})
	if err == nil {
		if dbCfg.RPCURL != "" {
			cfg.RPCURL = dbCfg.RPCURL
		}
		if dbCfg.WalletAddress != "" {
			cfg.WalletAddress = dbCfg.WalletAddress
		}
		if dbCfg.TelegramToken != "" {
			cfg.TelegramToken = dbCfg.TelegramToken
		}
		if dbCfg.TelegramChatID != "" {
			cfg.TelegramChatID = dbCfg.TelegramChatID
		}
		if dbCfg.LowBalanceThreshold > 0 {
			cfg.LowBalanceThreshold = dbCfg.LowBalanceThreshold
		}
	}
	return cfg
}

func (s *Store) SaveNimiqConfig(cfg models.NimiqConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyNimiqConfig), data)
	})
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// getEnvFloat reads a float64 env var, falling back to the given default
// if unset or unparseable.
func getEnvFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return fallback
}

// ── Player wallet ─────────────────────────────────────────────────────────────

// authSource: models.AuthSourceNimiqPay / models.AuthSourceWeb, or "" when the
// caller doesn't know/isn't a real login (e.g. the legacy /bj/wallet/register
// bind-only endpoint) — in that case the player's previously-known AuthSource
// (if any) is preserved instead of being wiped back to empty.
func (s *Store) RegisterPlayerWallet(playerID, nimiqAddress, authSource string) error {
	src := authSource
	if src == "" {
		if existing, _ := s.GetPlayerWallet(playerID); existing != nil {
			src = existing.AuthSource
		}
	}
	pw := models.PlayerWallet{
		PlayerID:     playerID,
		NimiqAddress: nimiqAddress,
		RegisteredAt: time.Now().Unix(),
		AuthSource:   src,
	}
	data, err := json.Marshal(pw)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyPlayerWalletPrefix+playerID), data)
	})
}

func (s *Store) GetPlayerWallet(playerID string) (*models.PlayerWallet, error) {
	var pw models.PlayerWallet
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyPlayerWalletPrefix + playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &pw)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &pw, err
}

// ── Pending Reward CRUD ───────────────────────────────────────────────────────

// ErrZeroRewardAmount — the reward rounds to 0 luna, i.e. there is literally
// nothing to send. Nimiq has no "0 NIM transfer": the node rejects it, and
// before this guard existed such a record was saved with Status=pending,
// attemptSend kept calling nimiqSendTransaction (one getBlockNumber + one
// failed push per retry, forever), the record never left the pending queue,
// and every retry tick logged a failure. That is the "0 NIM payments stuck in
// the RPC" bug: they are not stuck *in* the RPC, they are stuck *in front of*
// it, being retried against it forever.
//
// Rule from now on: a reward with AmountLuna <= 0 is never created, never
// queued, never signed and never pushed. Existing ones are DELETED
// (see PurgeZeroAmountRewards).
var ErrZeroRewardAmount = errors.New("zero_amount: reward would send 0 luna — refusing to create or send it")

// rewardLuna is the single place that converts "what the game promised" into
// "what will actually move on-chain", so every guard below agrees on the
// rounding. Nimiq's smallest unit is 1 luna (0.00001 NIM); anything smaller
// rounds to 0 and is unsendable.
func rewardLuna(amountNIM float64) int64 {
	if amountNIM <= 0 {
		return 0
	}
	return int64(math.Round(amountNIM * NimLunaMultiplier))
}

// deleteReward removes a reward record entirely (hard delete). Used for
// records that can never be sent — see PurgeZeroAmountRewards.
func (s *Store) deleteReward(id string) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Delete([]byte(keyPendingRewardPfx + id))
	})
}

// PurgeZeroAmountRewards hard-deletes every stored reward whose on-chain
// amount is 0 luna, whatever its status (pending / failed / no_wallet).
// Called on startup and at the top of every retry pass, so a database that
// already accumulated such records cleans itself up on the first tick after
// deploying this — no manual SQL/Badger surgery needed.
func (s *Store) PurgeZeroAmountRewards() (int, error) {
	all, err := s.ListRewards("")
	if err != nil {
		return 0, err
	}
	purged := 0
	for i := range all {
		r := &all[i]
		luna := r.AmountLuna
		if luna <= 0 {
			luna = rewardLuna(r.AmountNIM)
		}
		if luna > 0 {
			continue // a real payout — untouched
		}
		// Only terminal states are safe to delete silently: a completed send
		// must stay in the ledger/history. (AmountLuna<=0 can never be
		// "sent" anyway, but be explicit about it.)
		if r.Status == models.RewardSent {
			continue
		}
		if derr := s.deleteReward(r.ID); derr != nil {
			log.Printf("[REWARD] purge failed id=%s err=%v", r.ID, derr)
			continue
		}
		purged++
		log.Printf("[REWARD] PURGED zero-amount id=%s player=%s amount=%.8f NIM (0 luna) status=%s reason=%s attempts=%d",
			r.ID, r.PlayerID, r.AmountNIM, r.Status, r.Reason, r.Attempts)
	}
	if purged > 0 {
		log.Printf("[REWARD] purge complete — removed %d zero-amount reward(s) that could never be sent", purged)
	}
	return purged, nil
}

func newRewardID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return fmt.Sprintf("rw_%d_%s", time.Now().UnixMilli(), hex.EncodeToString(b))
}

func (s *Store) saveReward(r *models.PendingReward) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyPendingRewardPfx+r.ID), data)
	})
}

func (s *Store) GetReward(id string) (*models.PendingReward, error) {
	var r models.PendingReward
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyPendingRewardPfx + id))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &r)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &r, err
}

// ListRewards — returns all rewards (for admin panel)
func (s *Store) ListRewards(status string) ([]models.PendingReward, error) {
	prefix := []byte(keyPendingRewardPfx)
	var out []models.PendingReward
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = prefix
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var r models.PendingReward
				if e := json.Unmarshal(v, &r); e == nil {
					if status == "" || string(r.Status) == status {
						out = append(out, r)
					}
				}
				return nil
			})
		}
		return nil
	})
	return out, err
}

// ListRewardsByPlayer — returns all rewards for a specific player, newest first
func (s *Store) ListRewardsByPlayer(playerID string, limit int) ([]models.PendingReward, error) {
	all, err := s.ListRewards("")
	if err != nil {
		return nil, err
	}
	var out []models.PendingReward
	for _, r := range all {
		if r.PlayerID == playerID {
			out = append(out, r)
		}
	}
	// sort newest first (CreatedAt desc)
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].CreatedAt > out[i].CreatedAt {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ── Main reward function — SAVE FIRST, then send ─────────────────────────────

// WebAuthRewardMultiplier — NIM reward multiplier applied when the player's
// most recent login (models.PlayerWallet.AuthSource) came through the web
// (Nimiq Hub API popup) sign-in channel rather than the real Nimiq Pay app.
// Legacy wallets with an empty AuthSource (registered before this field
// existed) are NOT discounted — every login before the web sign-in path
// shipped could only have come from inside Nimiq Pay.
const WebAuthRewardMultiplier = 0.5

// QueueReward — saves reward to DB first, then attempts to send.
// If sending fails, the record is not deleted — the retry loop continues.
// Applies WebAuthRewardMultiplier for web-sourced players. Use this for every
// real "prize" payout (leaderboard, quest, streak, VS win/split/forfeit,
// in-game coin earn). For payouts that are NOT really a prize — a VS room
// refund (returning the player's own entry fee) or the cosmetic join-ping
// notification — use QueueRewardRaw instead, which skips the multiplier.
func (s *Store) QueueReward(playerID string, amountNIM float64, reason string) (*models.PendingReward, error) {
	return s.queueReward(playerID, amountNIM, reason, true)
}

// QueueRewardRaw — identical to QueueReward but never applies
// WebAuthRewardMultiplier. See QueueReward's doc comment for when to use this
// instead (refunds, cosmetic pings — anything that isn't actually a prize).
func (s *Store) QueueRewardRaw(playerID string, amountNIM float64, reason string) (*models.PendingReward, error) {
	return s.queueReward(playerID, amountNIM, reason, false)
}

// QueueRewardToAddress — like QueueRewardRaw, but for when the destination is
// already a known raw Nimiq address instead of an internal player ID (e.g.
// refunding a duplicate VS-room payment straight back to whoever sent it).
//
// BUG FIX: refundDuplicateVSSide used to call refundVSRoom(r, sender, ...)
// with `sender` being the raw on-chain address of the tx we're refunding —
// but refundVSRoom/QueueRewardRaw treat their playerID argument as an
// internal game player ID and look it up via GetPlayerWallet(playerID). A
// raw "NQ..." address is never a key in that wallet-registration table, so
// the lookup always missed, the reward was saved with Status=RewardNoWallet
// and NimiqAddress left EMPTY, and the retry loop kept re-checking the same
// dead lookup forever — the refund could never actually send. Net effect:
// a player who paid twice for a VS room had their duplicate payment
// permanently stuck (still sitting in the house wallet, but with no
// automated path back to them), while logs falsely said "refunded". This
// function skips the player-ID/wallet-registration lookup entirely and
// writes the known destination address straight onto the reward record, so
// the send queue has everything it needs from the start.
func (s *Store) QueueRewardToAddress(address string, amountNIM float64, reason string) (*models.PendingReward, error) {
	if address == "" {
		return nil, fmt.Errorf("invalid address")
	}
	// amountNIM > 0 is not enough: 0.000004 NIM is "positive" but rounds to
	// 0 luna, which is unsendable. Guard on the actual on-chain amount.
	luna := rewardLuna(amountNIM)
	if luna <= 0 {
		log.Printf("[REWARD] REJECTED (direct-address) to=%s amount=%.8f NIM → 0 luna reason=%s", address, amountNIM, reason)
		return nil, ErrZeroRewardAmount
	}
	reward := &models.PendingReward{
		ID:           newRewardID(),
		PlayerID:     address, // no internal player ID known — address doubles as the trace key
		NimiqAddress: address,
		AmountNIM:    amountNIM,
		AmountLuna:   luna,
		Reason:       reason,
		CreatedAt:    time.Now().Unix(),
		Status:       models.RewardPending,
	}
	if err := s.saveReward(reward); err != nil {
		return nil, fmt.Errorf("save_reward: %w", err)
	}
	log.Printf("[REWARD] saved (direct-address) id=%s to=%s amount=%.4f NIM reason=%s",
		reward.ID, address, amountNIM, reason)
	s.enqueueRewardSend(reward)
	return reward, nil
}

func (s *Store) queueReward(playerID string, amountNIM float64, reason string, applyChannelMultiplier bool) (*models.PendingReward, error) {
	// Look up player's wallet address
	walletInfo, err := s.GetPlayerWallet(playerID)
	if err != nil {
		return nil, fmt.Errorf("wallet_lookup: %w", err)
	}

	if applyChannelMultiplier && walletInfo != nil && walletInfo.AuthSource == models.AuthSourceWeb {
		amountNIM *= WebAuthRewardMultiplier
		reason = reason + ":web_half"
	}

	// ZERO-AMOUNT GUARD (see ErrZeroRewardAmount). Checked AFTER the web
	// multiplier and BEFORE saveReward, so a 0.00002 NIM prize that the
	// multiplier halves into 0 luna never becomes a database row and never
	// reaches attemptSend/nimiqSendTransaction. This is the write-side half of
	// the fix; PurgeZeroAmountRewards is the cleanup half for records that
	// already exist.
	amountLuna := rewardLuna(amountNIM)
	if amountLuna <= 0 {
		log.Printf("[REWARD] REJECTED zero-amount player=%s amount=%.8f NIM → 0 luna (nothing to send) reason=%s",
			playerID[:min8s(playerID)], amountNIM, reason)
		return nil, ErrZeroRewardAmount
	}

	reward := &models.PendingReward{
		ID:         newRewardID(),
		PlayerID:   playerID,
		AmountNIM:  amountNIM,
		AmountLuna: amountLuna,
		Reason:     reason,
		CreatedAt:  time.Now().Unix(),
	}

	if walletInfo == nil || walletInfo.NimiqAddress == "" {
		// Wallet not registered — save but don't send
		reward.Status = models.RewardNoWallet
		reward.ErrorMsg = "wallet_not_registered"
		_ = s.saveReward(reward)
		log.Printf("[REWARD] queued (no_wallet) player=%s reason=%s", playerID[:min8s(playerID)], reason)
		return reward, nil
	}

	reward.NimiqAddress = walletInfo.NimiqAddress
	reward.Status = models.RewardPending

	// SAVE FIRST
	if err := s.saveReward(reward); err != nil {
		return nil, fmt.Errorf("save_reward: %w", err)
	}
	log.Printf("[REWARD] saved id=%s player=%s amount=%.4f NIM reason=%s",
		reward.ID, playerID[:min8s(playerID)], amountNIM, reason)

	// Attempt to send via the rate-limited queue (see enqueueRewardSend below)
	// instead of a free-running goroutine.
	s.enqueueRewardSend(reward)

	return reward, nil
}

// ── Reward send queue (rate-limited) ─────────────────────────────────────────
//
// Nimiq's protocol has no multi-recipient/batch transaction — unlike
// Bitcoin's multi-output txs, a Nimiq tx has exactly one sender and one
// recipient — so N payouts really do mean N separate on-chain transactions;
// that part can't be collapsed into a single call/tx. What CAN be fixed is
// how FAST we fire those N pushTransaction RPC calls at the node:
// QueueReward/retryPendingRewards used to spawn every send in its own
// free-running goroutine with zero coordination between them, so a burst of
// rewards (e.g. a leaderboard payout for 20+ players at once) hit the public
// RPC node's pushTransaction rate limit almost instantly, causing a wave of
// "Rate limit exceeded" failures — which then all retried at the same time
// again too, repeating the problem.
//
// This is a simple single-worker queue: every send request goes through this
// channel instead of getting its own goroutine, and the one worker paces
// itself with a fixed minimum gap between RPC calls. Order within the queue
// doesn't matter (rewards aren't sequential/nonce-based on Nimiq — see
// nimiqBuildAndSignTx's comment, validity_start_height + signature is what
// makes each tx valid, not a per-account sequence number), only the pacing.
const rewardSendGapDefault = 1500 * time.Millisecond

var rewardQueueCh chan *models.PendingReward
var rewardQueueOnce sync.Once

// StartRewardQueue — starts the single background send-worker. Safe to call
// more than once (idempotent via sync.Once); also auto-starts lazily from
// enqueueRewardSend if this was never called explicitly.
func (s *Store) StartRewardQueue() {
	rewardQueueOnce.Do(func() {
		rewardQueueCh = make(chan *models.PendingReward, 2000)
		SafeGo("rewardSendWorker", func() { s.rewardSendWorker() })
	})
}

// enqueueRewardSend adds a reward to the rate-limited send queue.
func (s *Store) enqueueRewardSend(reward *models.PendingReward) {
	s.StartRewardQueue()
	select {
	case rewardQueueCh <- reward:
	default:
		// Queue is absurdly full (2000 pending sends) — fall back to the old
		// direct-goroutine path rather than silently dropping the reward.
		log.Printf("[REWARD_QUEUE] queue full, sending id=%s directly", reward.ID)
		SafeGo("attemptSend", func() { s.attemptSend(reward) })
	}
}

// rewardSendWorker is the single worker that drains rewardQueueCh, sending
// one at a time with a fixed gap between actual RPC calls. Gap is
// configurable via NIMIQ_SEND_GAP_MS env var (milliseconds) for tuning
// against whatever the RPC provider's real limit turns out to be, without a
// code change.
func (s *Store) rewardSendWorker() {
	gap := rewardSendGapDefault
	if v := os.Getenv("NIMIQ_SEND_GAP_MS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n >= 0 {
			gap = time.Duration(n) * time.Millisecond
		}
	}
	log.Printf("[REWARD_QUEUE] worker started, gap=%v", gap)
	for reward := range rewardQueueCh {
		s.attemptSend(reward)
		if gap > 0 {
			time.Sleep(gap)
		}
	}
}

// buildMemo constructs a human-readable tx memo (max 64 bytes) from a reward reason string.
//
// reason formats → memo examples:
//
//	"quest_claim:q_daily_score"                    → "NimJump: Quest reward +5.00 NIM"
//	"leaderboard:weekly:2026-06-24:rank1"          → "NimJump: Weekly leaderboard #1 +18.00 NIM"
//	"leaderboard:daily:2026-06-24:rank3"           → "NimJump: Daily leaderboard #3 +3.00 NIM"
//	"vsroom:<id>:win"                              → "NimJump: VS win +9.50 NIM"
//	"vsroom:<id>:split"                            → "NimJump: VS tie split +4.75 NIM"
//	"vsroom:<id>:forfeit"                          → "NimJump: VS forfeit win +9.50 NIM"
//	"vsroom:<id>:refund"                           → "NimJump: VS refund +5.00 NIM"
//	anything else                                  → "NimJump: Reward +X.XX NIM"
func buildMemo(amountNIM float64, reason string) string {
	nim := fmt.Sprintf("+%.2f NIM", amountNIM)
	parts := strings.SplitN(reason, ":", 4)

	switch {
	case len(parts) >= 2 && parts[0] == "quest_claim":
		return truncate64("NimJump: Quest reward " + nim)

	case len(parts) >= 3 && parts[0] == "vsroom":
		kind := parts[2]
		// notify_join is a near-zero "ping" payment (see sendVSJoinPing) —
		// its whole purpose is to piggyback on Nimiq Pay's own "payment
		// received" notification as a way to reach a player who isn't
		// actively in the game, since a WebView mini-app has no other push
		// channel. The memo text IS the notification, so skip the generic
		// "+0.01 NIM" amount suffix — showing a near-zero amount would just
		// read as a glitch instead of the actual message.
		if kind == "notify_join" {
			return truncate64("NimJump: VS match started — 24h to play!")
		}
		label := map[string]string{
			"win":     "VS win",
			"split":   "VS tie split",
			"forfeit": "VS forfeit win",
			"refund":  "VS refund",
		}[kind]
		if label == "" {
			label = "VS"
		}
		return truncate64(fmt.Sprintf("NimJump: %s %s", label, nim))

	case len(parts) >= 2 && parts[0] == "leaderboard":
		periodType := parts[1] // "daily" or "weekly"
		// parts[2] = date string (e.g. "2026-06-24"), parts[3] = "rank<N>"
		rankStr := ""
		if len(parts) >= 4 {
			rankStr = strings.TrimPrefix(parts[3], "rank")
		} else if len(parts) >= 3 {
			rankStr = strings.TrimPrefix(parts[2], "rank")
		}
		rank := 0
		fmt.Sscanf(rankStr, "%d", &rank)

		periodLabel := map[string]string{
			"daily":  "Daily",
			"weekly": "Weekly",
		}[periodType]
		if periodLabel == "" && len(periodType) > 0 {
			periodLabel = strings.ToUpper(periodType[:1]) + periodType[1:]
		}

		if rank > 0 {
			return truncate64(fmt.Sprintf("NimJump: %s leaderboard #%d %s", periodLabel, rank, nim))
		}
		return truncate64(fmt.Sprintf("NimJump: %s leaderboard %s", periodLabel, nim))

	default:
		return truncate64("NimJump: Reward " + nim)
	}
}

func truncate64(s string) string {
	b := []byte(s)
	if len(b) > 64 {
		b = b[:64]
	}
	return string(b)
}

// attemptSend — single send attempt
func (s *Store) attemptSend(reward *models.PendingReward) {
	// BUG FIX: claim this reward ID before doing any RPC work, and release
	// it when done. If another attemptSend call for the SAME reward is
	// already in flight (e.g. QueueReward's immediate dispatch overlapping
	// the 15s retry loop, or an admin double-clicking "force retry"), this
	// call backs off instead of independently signing and pushing a second
	// real on-chain transaction for the same payout.
	if _, alreadySending := sendingRewards.LoadOrStore(reward.ID, struct{}{}); alreadySending {
		log.Printf("[REWARD] id=%s already has a send in flight — skipping duplicate dispatch", reward.ID)
		return
	}
	defer sendingRewards.Delete(reward.ID)

	reward.Attempts++
	reward.LastAttempt = time.Now().Unix()

	cfg := s.GetNimiqConfig()

	// ZERO-AMOUNT GUARD (legacy records). A reward that somehow got saved
	// with 0 luna before the guard in queueReward existed is un-sendable by
	// definition: delete it instead of retrying it against the RPC forever.
	if reward.AmountLuna <= 0 {
		luna := rewardLuna(reward.AmountNIM)
		if luna <= 0 {
			if derr := s.deleteReward(reward.ID); derr != nil {
				log.Printf("[REWARD] purge failed id=%s err=%v", reward.ID, derr)
			} else {
				log.Printf("[REWARD] PURGED zero-amount id=%s player=%s amount=%.8f NIM (0 luna) reason=%s — deleted, never sent",
					reward.ID, reward.PlayerID, reward.AmountNIM, reward.Reason)
			}
			return
		}
		// Amount was stored wrong but the NIM value is real — repair it.
		reward.AmountLuna = luna
	}

	// Permanent guard: a tx whose recipient equals our own payout wallet
	// (sender == recipient) is rejected by the Nimiq mempool every single time
	// ("Sender same as recipient"), so retrying it forever just spams the log
	// and clogs the queue. Park it in a terminal "skipped" state instead of
	// the retry loop. This mainly happens when a player uses the very wallet
	// the app pays out from — most often the near-zero VS "match started"
	// notification ping to that same address.
	if nimiqAddressesEqual(reward.NimiqAddress, cfg.WalletAddress) {
		reward.Status = models.RewardSkipped
		reward.ErrorMsg = "recipient_equals_sender_wallet"
		log.Printf("[REWARD] SKIPPED id=%s reason=%s — recipient equals app wallet (sender==recipient, un-sendable)", reward.ID, reward.Reason)
		_ = s.saveReward(reward)
		return
	}

	txHash, err := nimiqSendTransaction(cfg, reward.NimiqAddress, reward.AmountLuna, buildMemo(reward.AmountNIM, reward.Reason))

	if err != nil {
		reward.ErrorMsg = err.Error()
		// Retry forever, no cutoff — everything routes through this one
		// reward queue (visible/manageable from the admin panel), so there's
		// no need for a separate "gave up" terminal state. An operator can
		// always see it sitting in the pending queue and force-retry or
		// investigate from there.
		reward.Status = models.RewardPending
		log.Printf("[REWARD] attempt=%d FAILED id=%s err=%v — will retry", reward.Attempts, reward.ID, err)
	} else {
		reward.TxHash = txHash
		reward.Status = models.RewardSent
		reward.SentAt = time.Now().Unix()
		log.Printf("[REWARD] SENT id=%s txhash=%s amount=%.4f NIM → %s",
			reward.ID, txHash, reward.AmountNIM, reward.NimiqAddress)

		// Bakiye kontrol et
		SafeGo("checkBalanceAndNotify", func() { s.checkBalanceAndNotify(cfg) })
	}

	_ = s.saveReward(reward)
}

// RetryPendingRewards — retry all pending rewards (called from cron or on startup)
func (s *Store) RetryPendingRewards() {
	s.retryPendingRewards(false)
}

// ForceRetryPendingRewards — retry all pending rewards immediately, ignoring cooldown (called from admin)
func (s *Store) ForceRetryPendingRewards() {
	s.retryPendingRewards(true)
}

func (s *Store) retryPendingRewards(force bool) {
	retryMu.Lock()
	defer retryMu.Unlock()

	// Clean up zero-amount records BEFORE anything is dispatched: these are
	// the ones that used to sit in the queue forever, one pointless RPC call
	// per retry tick each.
	if n, perr := s.PurgeZeroAmountRewards(); perr != nil {
		log.Printf("[RETRY] zero-amount purge error: %v", perr)
	} else if n > 0 {
		log.Printf("[RETRY] purged %d zero-amount reward(s)", n)
	}

	pending, err1 := s.ListRewards("pending")
	if err1 != nil {
		log.Printf("[RETRY] list error: %v", err1)
		return
	}
	rewards := pending
	failedCount := 0

	// Every reward retries forever (no cutoff — see attemptSend), so any
	// legacy/manually-set "failed" reward should keep getting picked back up
	// here regardless of force, same as before.
	//
	// BUG FIX: this used to reset the "failed" copies back to pending in a
	// separate `failed` slice, then append that same (already-copied) slice
	// into `rewards` — but `append(pending, failed...)` had already copied
	// the ORIGINAL (still-"failed") values into `rewards` at that point, so
	// mutating `failed[i]` afterwards never actually reached the struct that
	// got passed to attemptSend. Reset happens on `failed` BEFORE appending
	// now, so the reset actually lands on what gets retried.
	failed, err2 := s.ListRewards("failed")
	if err2 == nil {
		failedCount = len(failed)
		for i := range failed {
			failed[i].Status = models.RewardPending
		}
		rewards = append(rewards, failed...)
	}

	if len(rewards) == 0 {
		return
	}
	log.Printf("[RETRY] retrying %d rewards (%d pending, %d previously-failed) force=%v", len(rewards), len(pending), failedCount, force)
	for i := range rewards {
		r := &rewards[i]
		// Skip if less than RewardRetryCooldown since last attempt (unless
		// forced), with simple exponential backoff on repeated failures:
		// attempt 1→2 waits the base cooldown, each further failed attempt
		// doubles the wait, capped at RewardRetryMaxCooldown. This is what
		// actually keeps us from hammering the RPC node every 15s — the
		// retry loop itself still ticks every 15s (RetryInterval), it just
		// won't have anything due to send most of the time now.
		cooldown := RewardRetryCooldown
		if r.Attempts > 1 {
			shift := min(r.Attempts-1, 6) // cap the shift so it can't overflow/misbehave
			backoff := RewardRetryCooldown * time.Duration(int64(1)<<uint(shift))
			if backoff > RewardRetryMaxCooldown {
				backoff = RewardRetryMaxCooldown
			}
			cooldown = backoff
		}
		if !force && r.LastAttempt > 0 && time.Now().Unix()-r.LastAttempt < int64(cooldown.Seconds()) {
			continue
		}
		// Defence in depth: never dispatch a reward with nothing to send,
		// whatever state the record was read back in.
		if r.AmountLuna <= 0 && rewardLuna(r.AmountNIM) <= 0 {
			if derr := s.deleteReward(r.ID); derr == nil {
				log.Printf("[RETRY] purged zero-amount id=%s (skipped dispatch)", r.ID)
			}
			continue
		}
		// For no_wallet rewards, re-check wallet
		if r.Status == models.RewardNoWallet || r.NimiqAddress == "" {
			walletInfo, werr := s.GetPlayerWallet(r.PlayerID)
			if werr != nil || walletInfo == nil {
				continue // still not registered
			}
			r.NimiqAddress = walletInfo.NimiqAddress
			r.Status = models.RewardPending
		}
		rr := r
		s.enqueueRewardSend(rr)
	}
}

// StartRetryLoop — called on application startup, retries every 15 seconds
func (s *Store) StartRetryLoop() {
	go func() {
		// Purge legacy zero-amount rewards immediately on boot, so an
		// existing database stops retrying them within seconds of upgrading
		// (the periodic pass below would catch them too — this just makes it
		// happen before the first retry tick).
		if n, err := s.PurgeZeroAmountRewards(); err != nil {
			log.Printf("[REWARD] startup purge error: %v", err)
		} else if n > 0 {
			log.Printf("[REWARD] startup purge removed %d zero-amount reward(s)", n)
		}
		// Wait 5 seconds on startup (let DB fully open)
		time.Sleep(5 * time.Second)
		for {
			s.RetryPendingRewards()
			time.Sleep(RetryInterval)
		}
	}()
}

// ── Nimiq RPC ─────────────────────────────────────────────────────────────────

// nimiqRPCCall is the single entry point every caller in this package uses.
// The transport (connection pooling, address family / NAT64, proxy, retries,
// failover, rate-limit backoff) lives in rpc_client.go; this keeps the
// original signature so call sites don't change.
func nimiqRPCCall(rpcURL, method string, params []any) (any, error) {
	client, err := getRPCClient(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("rpc_config: %w", err)
	}
	return client.call(method, params)
}

// ── Nimiq address helpers ─────────────────────────────────────────────────────

// nimiqUserFriendlyToBytes decodes a Nimiq user-friendly address (e.g. "NQ07 0000...")
// to 20 raw bytes. Strips spaces, removes 2-char checksum prefix "NQ", decodes base32.
func nimiqUserFriendlyToBytes(addr string) ([]byte, error) {
	// Remove spaces and uppercase
	addr = strings.ToUpper(strings.ReplaceAll(addr, " ", ""))
	// Must start with NQ
	if !strings.HasPrefix(addr, "NQ") || len(addr) < 6 {
		return nil, fmt.Errorf("invalid nimiq address: %s", addr)
	}
	// Strip "NQ" + 2 checksum digits → 32 base32 chars remain
	b32 := addr[4:]
	if len(b32) != 32 {
		return nil, fmt.Errorf("nimiq address wrong length: got %d want 32 b32 chars", len(b32))
	}
	const alphabet = "0123456789ABCDEFGHJKLMNPQRSTUVXY"
	out := make([]byte, 20)
	var acc uint64
	bits := 0
	byteIdx := 0
	for _, ch := range b32 {
		idx := strings.IndexRune(alphabet, ch)
		if idx < 0 {
			return nil, fmt.Errorf("invalid base32 char: %c", ch)
		}
		acc = (acc << 5) | uint64(idx)
		bits += 5
		if bits >= 8 {
			bits -= 8
			if byteIdx >= 20 {
				return nil, fmt.Errorf("address decode overflow")
			}
			out[byteIdx] = byte(acc >> uint(bits))
			byteIdx++
		}
	}
	if byteIdx != 20 {
		return nil, fmt.Errorf("address decode underflow: got %d bytes", byteIdx)
	}
	return out, nil
}

// ValidateNimiqAddressFormat is the exported entry point handlers should use
// to validate a client-supplied Nimiq address string before storing it.
//
// SECURITY (security audit): handleWalletRegister used to only check
// `len(addr) >= 4 && addr[:2] == "NQ"` — that lets a caller register any
// string starting with "NQ" as their own wallet's display/payout address,
// including quote/backtick characters. Today that value is only ever read
// back to the SAME player (self-XSS at worst, since it's never rendered to
// other players), but it's a landmine: nothing stops it from being surfaced
// elsewhere later. This reuses the real address decoder (charset + length
// whitelist via nimiqUserFriendlyToBytes) so a stored "address" can only
// ever be exactly what it claims to be — 32 base32 characters (plus the
// "NQ" + 2-digit checksum prefix, spaces optional) — never arbitrary text.
func ValidateNimiqAddressFormat(addr string) error {
	_, err := nimiqUserFriendlyToBytes(addr)
	return err
}

// nimiqGetBlockNumber fetches current block height for validity_start_height
func nimiqGetBlockNumber(rpcURL string) (uint32, error) {
	result, err := nimiqRPCCall(rpcURL, "getBlockNumber", []any{})
	if err != nil {
		return 0, err
	}
	// response: { "data": <blockNumber>, "metadata": null }
	if outer, ok := result.(map[string]any); ok {
		if data, ok := outer["data"].(float64); ok {
			return uint32(data), nil
		}
	}
	// fallback: direct number
	if v, ok := result.(float64); ok {
		return uint32(v), nil
	}
	return 0, fmt.Errorf("unexpected block number type: %T %v", result, result)
}

// nimiqULEB128 encodes n as ULEB128 (postcard/protobuf variable-length uint).
func nimiqULEB128(n int) []byte {
	var out []byte
	for {
		b := byte(n & 0x7F)
		n >>= 7
		if n != 0 {
			b |= 0x80
		}
		out = append(out, b)
		if n == 0 {
			break
		}
	}
	return out
}

// nimiqBuildAndSignTx builds a Nimiq Albatross transaction, signs it with ed25519,
// and returns the hex-encoded serialized transaction ready for pushTransaction RPC.
//
// If memo is empty: Basic tx format (139 bytes)
//
//	variant(1=0x00) | proof_type(1) | pubkey(32) | recipient(20) | value(8be) |
//	fee(8be) | validity_start_height(4be) | network_id(1) | signature(64)
//
// If memo is non-empty: Extended tx format with recipient_data = UTF-8 memo (max 64 bytes)
//
// network_id: 24 = mainnet, 5 = testnet
func nimiqBuildAndSignTx(privateKeyHex string, fromAddrBytes []byte, toAddrBytes []byte, amountLuna uint64, fee uint64, validityStartHeight uint32, networkID byte, memo string) (string, error) {
	pkBytes, err := hex.DecodeString(privateKeyHex)
	if err != nil {
		return "", fmt.Errorf("invalid private key hex: %w", err)
	}
	var privKey ed25519.PrivateKey
	switch len(pkBytes) {
	case 32:
		privKey = ed25519.NewKeyFromSeed(pkBytes)
	case 64:
		privKey = ed25519.PrivateKey(pkBytes)
	default:
		return "", fmt.Errorf("private key must be 32 or 64 bytes, got %d", len(pkBytes))
	}
	pubKey := privKey.Public().(ed25519.PublicKey) // 32 bytes

	// Truncate memo to 64 bytes max
	memoBytes := []byte(memo)
	if len(memoBytes) > 64 {
		memoBytes = memoBytes[:64]
	}

	// SerializeContent (same layout regardless of Basic/Extended):
	// recipient_data_len(2be) | recipient_data | sender(20) | sender_type(1) |
	// recipient(20) | recipient_type(1) | value(8be) | fee(8be) |
	// validity_start_height(4be) | network_id(1) | flags(1) |
	// sender_data ULEB128(0)  ← Albatross-only, postcard Vec<u8>
	var content bytes.Buffer
	binary.Write(&content, binary.BigEndian, uint16(len(memoBytes))) // recipient_data_len 2be
	content.Write(memoBytes)                                         // recipient_data (0 or memo bytes)
	content.Write(fromAddrBytes)                                     // sender 20 bytes
	content.WriteByte(0)                                             // sender_type = Basic
	content.Write(toAddrBytes)                                       // recipient 20 bytes
	content.WriteByte(0)                                             // recipient_type = Basic
	binary.Write(&content, binary.BigEndian, amountLuna)             // value 8 bytes BE
	binary.Write(&content, binary.BigEndian, fee)                    // fee 8 bytes BE
	binary.Write(&content, binary.BigEndian, validityStartHeight)    // validity 4 bytes BE
	content.WriteByte(networkID)                                     // network_id
	content.WriteByte(0)                                             // flags = 0
	content.WriteByte(0x00)                                          // sender_data = ULEB128(0)

	sig := ed25519.Sign(privKey, content.Bytes())

	var tx bytes.Buffer
	if len(memoBytes) == 0 {
		// Basic tx — compact format (139 bytes)
		tx.WriteByte(0x00)                                       // enum variant = Basic
		tx.WriteByte(0x00)                                       // proof_type_and_flags = Ed25519
		tx.Write(pubKey)                                         // pubkey 32 bytes
		tx.Write(toAddrBytes)                                    // recipient 20 bytes
		binary.Write(&tx, binary.BigEndian, amountLuna)          // value 8 bytes
		binary.Write(&tx, binary.BigEndian, fee)                 // fee 8 bytes
		binary.Write(&tx, binary.BigEndian, validityStartHeight) // validity 4 bytes
		tx.WriteByte(networkID)
		tx.Write(sig) // signature 64 bytes
	} else {
		// Extended tx — includes recipient_data as memo
		// proof = proof_type(1=0x00) | pubkey(32) | merkle_path_len ULEB128(0) | sig(64)
		proof := []byte{0x00}
		proof = append(proof, pubKey...)
		proof = append(proof, 0x00) // merkle_path_len ULEB128(0)
		proof = append(proof, sig...)

		tx.WriteByte(0x01)                                       // enum variant = Extended
		tx.Write(fromAddrBytes)                                  // sender 20 bytes
		tx.WriteByte(0x00)                                       // sender_type = Basic
		tx.Write(nimiqULEB128(0))                                // sender_data_len = 0
		tx.Write(toAddrBytes)                                    // recipient 20 bytes
		tx.WriteByte(0x00)                                       // recipient_type = Basic
		tx.Write(nimiqULEB128(len(memoBytes)))                   // recipient_data_len
		tx.Write(memoBytes)                                      // recipient_data = memo
		binary.Write(&tx, binary.BigEndian, amountLuna)          // value 8 bytes
		binary.Write(&tx, binary.BigEndian, fee)                 // fee 8 bytes
		binary.Write(&tx, binary.BigEndian, validityStartHeight) // validity 4 bytes
		tx.WriteByte(networkID)
		tx.WriteByte(0x00)                 // flags = 0
		tx.Write(nimiqULEB128(len(proof))) // proof_len
		tx.Write(proof)
	}

	return hex.EncodeToString(tx.Bytes()), nil
}

// nimiqSendTransaction — builds, signs and broadcasts a Nimiq transaction via pushTransaction RPC.
// Private key (hex) is read from NIMIQ_PRIVATE_KEY env var.
// memo is included as recipient_data (max 64 bytes UTF-8). Empty string = Basic tx (no data).
func nimiqSendTransaction(cfg models.NimiqConfig, toAddress string, amountLuna int64, memo string) (string, error) {
	// First check, before dev-mode short-circuits and before any RPC: a
	// 0-luna transfer does not exist on Nimiq. (In NIMIQ_DEV_MODE this used
	// to return a fake success hash for a 0-amount tx, which hid the bug in
	// development while production retried it forever.)
	if amountLuna <= 0 {
		return "", ErrZeroRewardAmount
	}

	privateKey := os.Getenv("NIMIQ_PRIVATE_KEY")
	if privateKey == "" {
		if os.Getenv("NIMIQ_DEV_MODE") == "1" {
			fakeHash := fmt.Sprintf("devtx_%d", time.Now().UnixNano())
			log.Printf("[NIMIQ_DEV] Fake tx: %d luna → %s hash=%s", amountLuna, toAddress, fakeHash)
			return fakeHash, nil
		}
		return "", fmt.Errorf("NIMIQ_PRIVATE_KEY env var not set")
	}
	if cfg.WalletAddress == "" {
		return "", fmt.Errorf("NIMIQ_WALLET_ADDRESS not configured")
	}
	// Decode addresses
	fromBytes, err := nimiqUserFriendlyToBytes(cfg.WalletAddress)
	if err != nil {
		return "", fmt.Errorf("from address: %w", err)
	}
	toBytes, err := nimiqUserFriendlyToBytes(toAddress)
	if err != nil {
		return "", fmt.Errorf("to address: %w", err)
	}

	// Get current block number for validity window.
	// Add a small buffer (+5) so the tx is valid even if a few blocks are produced
	// between signing and broadcast (Albatross validity window is ~120 blocks).
	blockNum, err := nimiqGetBlockNumber(cfg.RPCURL)
	if err != nil {
		return "", fmt.Errorf("getBlockNumber: %w", err)
	}
	validityStart := blockNum + 5

	// network_id: 24=mainnet, 5=testnet (read from env, default mainnet)
	networkID := byte(24)
	if strings.ToLower(os.Getenv("NIMIQ_NETWORK")) == "testnet" {
		networkID = 5
	}

	rawTx, err := nimiqBuildAndSignTx(
		privateKey, fromBytes, toBytes,
		uint64(amountLuna), 0, // fee = 0
		validityStart, networkID,
		memo,
	)
	if err != nil {
		return "", fmt.Errorf("build tx: %w", err)
	}

	// Push to network
	log.Printf("[NIMIQ] pushing tx blockNum=%d validityStart=%d amount=%d luna → %s", blockNum, validityStart, amountLuna, toAddress)
	result, err := nimiqRPCCall(cfg.RPCURL, "pushTransaction", []any{rawTx})
	if err != nil {
		log.Printf("[NIMIQ] pushTransaction FAILED rawTx_len=%d rawTx=%s err=%v", len(rawTx), rawTx, err)
		return "", fmt.Errorf("pushTransaction: %w", err)
	}
	// pushTransaction response: { "data": "<txHash>", "metadata": null }
	var txHash string
	if outer, ok := result.(map[string]any); ok {
		if data, ok := outer["data"].(string); ok {
			txHash = data
		}
	}
	if txHash == "" {
		txHash = fmt.Sprintf("%v", result) // fallback
	}
	if txHash == "" || txHash == "<nil>" || txHash == "map[]" {
		return "", fmt.Errorf("empty tx hash from pushTransaction: %v", result)
	}
	log.Printf("[NIMIQ] pushed tx hash=%s amount=%d luna → %s", txHash, amountLuna, toAddress)
	return txHash, nil
}

// GetNimiqBalance — returns the application wallet balance in luna
func GetNimiqBalance(cfg models.NimiqConfig) (float64, error) {
	if cfg.WalletAddress == "" {
		return 0, fmt.Errorf("wallet_address_not_set")
	}
	result, err := nimiqRPCCall(cfg.RPCURL, "getAccountByAddress", []any{cfg.WalletAddress})
	if err != nil {
		return 0, err
	}
	// response: { "data": { "balance": <luna>, ... }, "metadata": {...} }
	if outer, ok := result.(map[string]any); ok {
		if data, ok := outer["data"].(map[string]any); ok {
			if bal, ok := data["balance"].(float64); ok {
				return bal / NimLunaMultiplier, nil
			}
		}
	}
	return 0, fmt.Errorf("unexpected_balance_result: %v", result)
}

// ── Balance monitoring ────────────────────────────────────────────────────────

var lastLowBalanceAlert int64 // last alert time (epoch)
const alertCooldown = 3600    // send the same alert at most once per hour

func (s *Store) checkBalanceAndNotify(cfg models.NimiqConfig) {
	balance, err := GetNimiqBalance(cfg)
	if err != nil {
		log.Printf("[BALANCE] check failed: %v", err)
		return
	}
	log.Printf("[BALANCE] %.2f NIM (threshold=%.0f)", balance, cfg.LowBalanceThreshold)

	if balance < cfg.LowBalanceThreshold {
		now := time.Now().Unix()
		if now-lastLowBalanceAlert < alertCooldown {
			return // cooldown
		}
		lastLowBalanceAlert = now

		var msg string
		if balance <= 0 {
			msg = fmt.Sprintf(
				"🚨 BunnyJump Wallet EMPTY!\nAddress: %s\nBalance: %.2f NIM\nRefill immediately!",
				cfg.WalletAddress, balance)
		} else {
			msg = fmt.Sprintf(
				"⚠️ BunnyJump Wallet Low!\nAddress: %s\nBalance: %.2f NIM\nThreshold: %.0f NIM\nRefill needed!",
				cfg.WalletAddress, balance, cfg.LowBalanceThreshold)
		}
		s.sendTelegram(cfg, msg)
	}
}

// StartBalanceMonitor — checks balance every 30 minutes
func (s *Store) StartBalanceMonitor() {
	go func() {
		time.Sleep(2 * time.Minute) // short wait on startup
		for {
			cfg := s.GetNimiqConfig()
			if cfg.WalletAddress != "" && cfg.TelegramToken != "" {
				s.checkBalanceAndNotify(cfg)
			}
			time.Sleep(30 * time.Minute)
		}
	}()
}

// ── Telegram ──────────────────────────────────────────────────────────────────

func (s *Store) sendTelegram(cfg models.NimiqConfig, message string) {
	token := cfg.TelegramToken
	chatID := cfg.TelegramChatID
	if token == "" || chatID == "" {
		// fall back to env vars
		token = os.Getenv("TELEGRAM_BOT_TOKEN")
		chatID = os.Getenv("TELEGRAM_CHAT_ID")
	}
	if token == "" || chatID == "" {
		log.Printf("[TELEGRAM] token or chat_id not configured — message: %s", message)
		return
	}

	apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	params := url.Values{}
	params.Set("chat_id", chatID)
	params.Set("text", message)
	params.Set("parse_mode", "HTML")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.PostForm(apiURL, params)
	if err != nil {
		log.Printf("[TELEGRAM] send error: %v", err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != 200 {
		log.Printf("[TELEGRAM] error %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	} else {
		log.Printf("[TELEGRAM] message sent: %s…", message[:min(50, len(message))])
	}
}

// SendTelegramDirect — for external test/admin use
func (s *Store) SendTelegramDirect(message string) {
	cfg := s.GetNimiqConfig()
	s.sendTelegram(cfg, message)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
