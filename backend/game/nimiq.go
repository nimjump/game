package game

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
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
	keyPlayerWalletPrefix = "wallet:"   // + playerID
	keyPendingRewardPfx   = "reward:"   // + rewardID
	keyNimiqConfig        = "nimcfg"
	NimLunaMultiplier     = 100_000     // 1 NIM = 100,000 luna

	MaxRetryAttempts = 10               // after this, marked as "failed"
	RetryInterval    = 15 * time.Second // retry every 15 seconds
)

var retryMu sync.Mutex

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

func (s *Store) RegisterPlayerWallet(playerID, nimiqAddress string) error {
	pw := models.PlayerWallet{
		PlayerID:     playerID,
		NimiqAddress: nimiqAddress,
		RegisteredAt: time.Now().Unix(),
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

// QueueReward — saves reward to DB first, then attempts to send.
// If sending fails, the record is not deleted — the retry loop continues.
func (s *Store) QueueReward(playerID string, amountNIM float64, reason string) (*models.PendingReward, error) {
	// Look up player's wallet address
	walletInfo, err := s.GetPlayerWallet(playerID)
	if err != nil {
		return nil, fmt.Errorf("wallet_lookup: %w", err)
	}

	reward := &models.PendingReward{
		ID:         newRewardID(),
		PlayerID:   playerID,
		AmountNIM:  amountNIM,
		AmountLuna: int64(math.Round(amountNIM * NimLunaMultiplier)),
		Reason:     reason,
		CreatedAt:  time.Now().Unix(),
	}

	if walletInfo == nil || walletInfo.NimiqAddress == "" {
		// Wallet not registered — save but don't send
		reward.Status   = models.RewardNoWallet
		reward.ErrorMsg = "wallet_not_registered"
		_ = s.saveReward(reward)
		log.Printf("[REWARD] queued (no_wallet) player=%s reason=%s", playerID[:min8s(playerID)], reason)
		return reward, nil
	}

	reward.NimiqAddress = walletInfo.NimiqAddress
	reward.Status       = models.RewardPending

	// SAVE FIRST
	if err := s.saveReward(reward); err != nil {
		return nil, fmt.Errorf("save_reward: %w", err)
	}
	log.Printf("[REWARD] saved id=%s player=%s amount=%.4f NIM reason=%s",
		reward.ID, playerID[:min8s(playerID)], amountNIM, reason)

	// Attempt to send in background
	go s.attemptSend(reward)

	return reward, nil
}

// buildMemo constructs a human-readable tx memo (max 64 bytes) from a reward reason string.
//
// reason formats → memo examples:
//   "quest_claim:q_daily_score"                    → "NimJump: Quest reward +5.00 NIM"
//   "leaderboard:weekly:2026-06-24:rank1"          → "NimJump: Weekly leaderboard #1 +18.00 NIM"
//   "leaderboard:daily:2026-06-24:rank3"           → "NimJump: Daily leaderboard #3 +3.00 NIM"
//   "vsroom:<id>:win"                              → "NimJump: VS win +9.50 NIM"
//   "vsroom:<id>:split"                            → "NimJump: VS tie split +4.75 NIM"
//   "vsroom:<id>:forfeit"                          → "NimJump: VS forfeit win +9.50 NIM"
//   "vsroom:<id>:refund"                           → "NimJump: VS refund +5.00 NIM"
//   anything else                                  → "NimJump: Reward +X.XX NIM"
func buildMemo(amountNIM float64, reason string) string {
	nim := fmt.Sprintf("+%.2f NIM", amountNIM)
	parts := strings.SplitN(reason, ":", 4)

	switch {
	case len(parts) >= 2 && parts[0] == "quest_claim":
		return truncate64("NimJump: Quest reward " + nim)

	case len(parts) >= 3 && parts[0] == "vsroom":
		kind := parts[2]
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
	reward.Attempts++
	reward.LastAttempt = time.Now().Unix()

	cfg := s.GetNimiqConfig()
	txHash, err := nimiqSendTransaction(cfg, reward.NimiqAddress, reward.AmountLuna, buildMemo(reward.AmountNIM, reward.Reason))

	if err != nil {
		reward.ErrorMsg = err.Error()
		reward.Status = models.RewardPending // always keep pending — retry forever
		log.Printf("[REWARD] attempt=%d FAILED id=%s err=%v — will retry", reward.Attempts, reward.ID, err)
	} else {
		reward.TxHash = txHash
		reward.Status = models.RewardSent
		reward.SentAt = time.Now().Unix()
		log.Printf("[REWARD] SENT id=%s txhash=%s amount=%.4f NIM → %s",
			reward.ID, txHash, reward.AmountNIM, reward.NimiqAddress)

		// Bakiye kontrol et
		go s.checkBalanceAndNotify(cfg)
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

	pending, err1 := s.ListRewards("pending")
	failed, err2  := s.ListRewards("failed")
	if err1 != nil {
		log.Printf("[RETRY] list error: %v", err1)
		return
	}
	rewards := append(pending, failed...)
	if err2 == nil {
		// reset any old "failed" back to pending so they keep retrying
		for i := range failed {
			failed[i].Status = models.RewardPending
		}
	}
	if len(rewards) == 0 {
		return
	}
	log.Printf("[RETRY] retrying %d rewards (%d pending, %d previously-failed) force=%v", len(rewards), len(pending), len(failed), force)
	for i := range rewards {
		r := &rewards[i]
		// Skip if less than 15 minutes since last attempt (unless forced)
		if !force && r.LastAttempt > 0 && time.Now().Unix()-r.LastAttempt < int64(RetryInterval.Seconds()) {
			continue
		}
		// For no_wallet rewards, re-check wallet
		if r.Status == models.RewardNoWallet || r.NimiqAddress == "" {
			walletInfo, werr := s.GetPlayerWallet(r.PlayerID)
			if werr != nil || walletInfo == nil {
				continue // still not registered
			}
			r.NimiqAddress = walletInfo.NimiqAddress
			r.Status       = models.RewardPending
		}
		go s.attemptSend(r)
	}
}

// StartRetryLoop — called on application startup, retries every 15 seconds
func (s *Store) StartRetryLoop() {
	go func() {
		// Wait 5 seconds on startup (let DB fully open)
		time.Sleep(5 * time.Second)
		for {
			s.RetryPendingRewards()
			time.Sleep(RetryInterval)
		}
	}()
}

// ── Nimiq RPC ─────────────────────────────────────────────────────────────────

type nimRPCReq struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
	ID      int    `json:"id"`
}

type nimRPCResp struct {
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"` // can be null, string, or object
}

func nimiqRPCCall(rpcURL, method string, params []any) (any, error) {
	body, _ := json.Marshal(nimRPCReq{JSONRPC: "2.0", Method: method, Params: params, ID: 1})
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Post(rpcURL, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("rpc_connect: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("rpc_read: %w", err)
	}
	var r nimRPCResp
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("rpc_parse: %w", err)
	}
	// error field: check if it's non-null and non-empty
	if len(r.Error) > 0 && string(r.Error) != "null" {
		var rpcErr struct {
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if json.Unmarshal(r.Error, &rpcErr) == nil && rpcErr.Message != "" {
			return nil, fmt.Errorf("rpc_err %d: %s | data=%s", rpcErr.Code, rpcErr.Message, string(rpcErr.Data))
		}
		return nil, fmt.Errorf("rpc_err: %s", string(r.Error))
	}
	// parse result as generic any
	var result any
	if err := json.Unmarshal(r.Result, &result); err != nil {
		return nil, fmt.Errorf("rpc_result_parse: %w", err)
	}
	return result, nil
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
//   variant(1=0x00) | proof_type(1) | pubkey(32) | recipient(20) | value(8be) |
//   fee(8be) | validity_start_height(4be) | network_id(1) | signature(64)
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
	content.Write(memoBytes)                                          // recipient_data (0 or memo bytes)
	content.Write(fromAddrBytes)                                      // sender 20 bytes
	content.WriteByte(0)                                              // sender_type = Basic
	content.Write(toAddrBytes)                                        // recipient 20 bytes
	content.WriteByte(0)                                              // recipient_type = Basic
	binary.Write(&content, binary.BigEndian, amountLuna)             // value 8 bytes BE
	binary.Write(&content, binary.BigEndian, fee)                    // fee 8 bytes BE
	binary.Write(&content, binary.BigEndian, validityStartHeight)    // validity 4 bytes BE
	content.WriteByte(networkID)                                      // network_id
	content.WriteByte(0)                                              // flags = 0
	content.WriteByte(0x00)                                           // sender_data = ULEB128(0)

	sig := ed25519.Sign(privKey, content.Bytes())

	var tx bytes.Buffer
	if len(memoBytes) == 0 {
		// Basic tx — compact format (139 bytes)
		tx.WriteByte(0x00)                                        // enum variant = Basic
		tx.WriteByte(0x00)                                        // proof_type_and_flags = Ed25519
		tx.Write(pubKey)                                          // pubkey 32 bytes
		tx.Write(toAddrBytes)                                     // recipient 20 bytes
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

		tx.WriteByte(0x01)                                        // enum variant = Extended
		tx.Write(fromAddrBytes)                                   // sender 20 bytes
		tx.WriteByte(0x00)                                        // sender_type = Basic
		tx.Write(nimiqULEB128(0))                                 // sender_data_len = 0
		tx.Write(toAddrBytes)                                     // recipient 20 bytes
		tx.WriteByte(0x00)                                        // recipient_type = Basic
		tx.Write(nimiqULEB128(len(memoBytes)))                    // recipient_data_len
		tx.Write(memoBytes)                                       // recipient_data = memo
		binary.Write(&tx, binary.BigEndian, amountLuna)          // value 8 bytes
		binary.Write(&tx, binary.BigEndian, fee)                 // fee 8 bytes
		binary.Write(&tx, binary.BigEndian, validityStartHeight) // validity 4 bytes
		tx.WriteByte(networkID)
		tx.WriteByte(0x00)               // flags = 0
		tx.Write(nimiqULEB128(len(proof))) // proof_len
		tx.Write(proof)
	}

	return hex.EncodeToString(tx.Bytes()), nil
}

// nimiqSendTransaction — builds, signs and broadcasts a Nimiq transaction via pushTransaction RPC.
// Private key (hex) is read from NIMIQ_PRIVATE_KEY env var.
// memo is included as recipient_data (max 64 bytes UTF-8). Empty string = Basic tx (no data).
func nimiqSendTransaction(cfg models.NimiqConfig, toAddress string, amountLuna int64, memo string) (string, error) {
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
	if amountLuna <= 0 {
		return "", fmt.Errorf("amount must be positive")
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
const alertCooldown = 3600   // send the same alert at most once per hour

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
	token  := cfg.TelegramToken
	chatID := cfg.TelegramChatID
	if token == "" || chatID == "" {
		// fall back to env vars
		token  = os.Getenv("TELEGRAM_BOT_TOKEN")
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