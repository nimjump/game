package game

// ip_reward_guard.go — anti-multi-accounting guard for real-money (NIM)
// reward claims.
//
// Problem: a single person can open several wallet-backed accounts from
// the same IP and claim the same "come back today" reward on all of them,
// turning a small per-account nudge into a multiplied payout with zero
// extra effort. This tracks, per (IP, UTC+3 day), the SET of distinct
// player IDs that have already been paid a reward that day, and caps it at
// an admin-configurable number (default 2) — the 1st and 2nd account from
// an IP claim normally; the 3rd+ is blocked with a clear, honest reason
// (not silently dropped — see streak.go's handler, which surfaces this as
// a distinct error code the client turns into an explicit toast).
//
// Scope / honesty note: this is wired into the streak claim path
// (game/streak_reward.go's ClaimStreakReward) because that's a live,
// request-driven action with a real client IP available. It is NOT
// (yet) wired into every reward path in the codebase — leaderboard payouts
// in particular run on a background timer with no live request/IP to check
// against, so this guard can't apply there without a different design
// (e.g. checking the IP last seen at login time instead of claim time).
// CheckAndRecordIPRewardEligibility below is written as a general, reusable
// building block specifically so it CAN be wired into other real-time claim
// endpoints (quest claim, etc.) later without duplicating this logic.
//
// Not a defense against a determined attacker running the game through
// several proxies/VPNs/mobile networks — no IP-based check can be. It
// raises the bar for the common case (same household/browser, several
// wallets, one Wi-Fi) without adding any real friction for genuine players,
// who only ever touch one account from their own IP.

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const (
	keyIPRewardPfx             = "ipreward:" // prefix + ip + ":" + day
	defaultMaxRewardAccountsPerIP = 2
)

type ipRewardRecord struct {
	IP        string   `json:"ip"`
	Day       string   `json:"day"`
	PlayerIDs []string `json:"player_ids"` // distinct accounts already rewarded from this IP today
	UpdatedAt int64    `json:"updated_at"`
}

func ipRewardKey(ip, day string) []byte {
	return []byte(fmt.Sprintf("%s%s:%s", keyIPRewardPfx, ip, day))
}

// MaxRewardAccountsPerIP — admin panel (AppConfig, incl. an explicit 0 —
// clamped to the enforced minimum of 1, see AppConfig's doc comment) >
// MAX_REWARD_ACCOUNTS_PER_IP env > 2 accounts hardcoded default.
func (s *Store) MaxRewardAccountsPerIP() int {
	if v := s.GetAppConfig().MaxRewardAccountsPerIP; v != nil {
		if *v < 1 {
			return 1
		}
		return *v
	}
	if v := os.Getenv("MAX_REWARD_ACCOUNTS_PER_IP"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 {
			return n
		}
	}
	return defaultMaxRewardAccountsPerIP
}

// CheckAndRecordIPRewardEligibility — call right before queuing a
// real-money reward for a live (request-driven) claim. Returns (true, nil)
// and records playerID against ip's today-set if:
//   - playerID is already in today's set for this ip (repeat claim from an
//     account already counted — always allowed, this isn't a second new
//     account), OR
//   - today's set for this ip has fewer than MaxRewardAccountsPerIP()
//     distinct accounts in it yet (this playerID becomes one of them).
//
// Returns (false, nil) — NOT an error, a normal "blocked" result the
// caller should turn into a user-facing reason — if this would be a NEW
// account beyond the per-IP cap for today. IP is expected to already be the
// resolved real client IP (see handlers/clientip.go's realClientIP) — this
// function does no spoofing-resistance of its own, that happens upstream.
func (s *Store) CheckAndRecordIPRewardEligibility(ip, playerID string) (bool, error) {
	if ip == "" || playerID == "" {
		return true, nil // nothing meaningful to check — fail open rather than block legitimate claims on a missing IP
	}
	day := todayUTC3()
	key := ipRewardKey(ip, day)
	limit := s.MaxRewardAccountsPerIP()

	allowed := false
	err := s.db.Update(func(txn *badger.Txn) error {
		var rec ipRewardRecord
		item, gerr := txn.Get(key)
		if gerr == nil {
			_ = item.Value(func(v []byte) error { return json.Unmarshal(v, &rec) })
		} else if gerr != badger.ErrKeyNotFound {
			return gerr
		} else {
			rec = ipRewardRecord{IP: ip, Day: day}
		}

		for _, pid := range rec.PlayerIDs {
			if pid == playerID {
				allowed = true // already one of this IP's counted accounts today
				return nil
			}
		}

		if len(rec.PlayerIDs) >= limit {
			allowed = false // cap reached, this would be a NEW account beyond it
			return nil
		}

		rec.PlayerIDs = append(rec.PlayerIDs, playerID)
		rec.UpdatedAt = time.Now().Unix()
		allowed = true

		data, merr := json.Marshal(rec)
		if merr != nil {
			return merr
		}
		// TTL 48h — well past the UTC+3 day boundary, auto-cleans itself up.
		return txn.SetEntry(badger.NewEntry(key, data).WithTTL(48 * time.Hour))
	})
	if err != nil {
		return false, err
	}
	return allowed, nil
}
