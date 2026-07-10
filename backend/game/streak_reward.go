package game

// streak_reward.go — CLAIMABLE NIM reward for maintaining a daily login
// streak. Mirrors the daily-quest claim pattern on purpose: the reward is
// never auto-paid on login/session-restore, the player must actively hit a
// "claim" action from the client, same as handleQuestClaim (see
// handlers/quest.go and handlers/streak.go).
//
// Reward formula (day = streak.Count, i.e. 1 on a brand new streak):
//
//	reward(day) = min(Base + ExtraPerDay * (day - 1), Max)
//
// All three knobs are admin-editable (AppConfig.StreakRewardBaseNIM /
// StreakRewardExtraPerDayNIM / StreakRewardMaxNIM, see appconfig.go) with
// small hardcoded defaults (0.2 / 0.5 / 10.0) — grows with the streak, but
// the Max ceiling means a single day's claim can NEVER pay out more than a
// known, bounded amount no matter how long the streak runs.
//
// Anti-abuse: every claim goes through
// CheckAndRecordIPRewardEligibility (ip_reward_guard.go) FIRST — the same
// IP can only fund MaxRewardAccountsPerIP() distinct accounts' claims per
// UTC+3 day (default 2). A blocked claim is reported to the caller as a
// normal (not error) "blocked_ip_limit" result, which handlers/streak.go
// turns into an honest toast rather than a silent no-op.
//
// One claim per player per UTC+3 day, tracked independently of
// PlayerStreak itself (streakclaim:<playerID>:<day> key) — this record is
// purely "did they collect today's reward yet". The PlayerStreak count
// itself (streak.go) IS advanced here, at the moment of a successful
// claim — see ClaimStreakReward, and streak.go's doc comment for why this
// moved here from auth.go's login/restore handlers.

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

// claimingStreaks — same class of guard as claimingQuests in quest.go:
// without this, two concurrent claim requests for the same player (double
// click, retry, two tabs) could both read alreadyClaimed==false before
// either writes the claim record, and both would go on to QueueReward — a
// real double-payout.
var claimingStreaks sync.Map

// TryClaimStreakLock claims the in-process lock for playerID's streak
// claim. Returns ok=false if another claim for this player is already in
// flight. On success, callers MUST call release() when done (defer).
func TryClaimStreakLock(playerID string) (release func(), ok bool) {
	if _, already := claimingStreaks.LoadOrStore(playerID, struct{}{}); already {
		return func() {}, false
	}
	return func() { claimingStreaks.Delete(playerID) }, true
}

// floatEnvOr — parses a float env var, falling back to def if unset/blank/
// invalid/negative. Small shared helper for the several NIM-amount env
// vars in this file.
func floatEnvOr(key string, def float64) float64 {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || f < 0 {
		return def
	}
	return f
}

const (
	defaultStreakRewardBaseNIM        = 0.2
	defaultStreakRewardExtraPerDayNIM = 0.5
	defaultStreakRewardMaxNIM         = 10.0

	keyStreakClaimPfx = "streakclaim:" // prefix + playerID + ":" + day

	// ReasonStreak — prefix used for streak-claim QueueReward calls, so
	// admin transaction history / IsReasonCapped can tell them apart from
	// in_game_coins / quest / leaderboard rewards at a glance.
	ReasonStreak = "streak"
)

type streakClaimRecord struct {
	PlayerID  string  `json:"player_id"`
	Day       string  `json:"day"`
	AmountNIM float64 `json:"amount_nim"`
	ClaimedAt int64   `json:"claimed_at"`
}

func streakClaimKey(playerID, day string) []byte {
	return []byte(fmt.Sprintf("%s%s:%s", keyStreakClaimPfx, playerID, day))
}

// StreakRewardBaseNIM — admin panel > STREAK_REWARD_BASE_NIM env > 0.2 NIM.
func (s *Store) StreakRewardBaseNIM() float64 {
	if v := s.GetAppConfig().StreakRewardBaseNIM; v != nil {
		return *v
	}
	return floatEnvOr("STREAK_REWARD_BASE_NIM", defaultStreakRewardBaseNIM)
}

// StreakRewardExtraPerDayNIM — admin panel > STREAK_REWARD_EXTRA_PER_DAY_NIM
// env > 0.5 NIM.
func (s *Store) StreakRewardExtraPerDayNIM() float64 {
	if v := s.GetAppConfig().StreakRewardExtraPerDayNIM; v != nil {
		return *v
	}
	return floatEnvOr("STREAK_REWARD_EXTRA_PER_DAY_NIM", defaultStreakRewardExtraPerDayNIM)
}

// StreakRewardMaxNIM — admin panel > STREAK_REWARD_MAX_NIM env > 10.0 NIM.
func (s *Store) StreakRewardMaxNIM() float64 {
	if v := s.GetAppConfig().StreakRewardMaxNIM; v != nil {
		return *v
	}
	return floatEnvOr("STREAK_REWARD_MAX_NIM", defaultStreakRewardMaxNIM)
}

// ComputeStreakReward — the formula described in this file's doc comment.
// day <= 0 (no active streak) always returns 0.
func (s *Store) ComputeStreakReward(day int) float64 {
	if day <= 0 {
		return 0
	}
	base := s.StreakRewardBaseNIM()
	extra := s.StreakRewardExtraPerDayNIM()
	max := s.StreakRewardMaxNIM()
	reward := base + extra*float64(day-1)
	if reward < 0 {
		reward = 0
	}
	if max > 0 && reward > max {
		reward = max
	}
	return reward
}

// GetStreakClaimStatus — read-only. Returns the day a claim would land on
// (or already landed on today), how much NIM is claimable right now, and
// whether today's claim already happened. Used by the client's "claim" UI
// to render the right amount/state without guessing.
//
// Before today's claim: day/amount are a PREVIEW (PeekStreakDay) — nothing
// has advanced yet, this is just "here's what you'd get if you tapped
// claim right now". After today's claim: day reflects the actual advanced
// PlayerStreak.Count (claiming already moved it), amount is 0 (nothing
// left to claim today).
func (s *Store) GetStreakClaimStatus(playerID string) (day int, claimableNIM float64, alreadyClaimed bool, err error) {
	claimed, cerr := s.getStreakClaimRecord(playerID, todayUTC3())
	if cerr != nil {
		return 0, 0, false, cerr
	}
	if claimed != nil {
		return s.GetStreak(playerID).Count, 0, true, nil
	}
	day = s.PeekStreakDay(playerID)
	claimableNIM = s.ComputeStreakReward(day)
	return day, claimableNIM, false, nil
}

func (s *Store) getStreakClaimRecord(playerID, day string) (*streakClaimRecord, error) {
	var rec streakClaimRecord
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(streakClaimKey(playerID, day))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &rec) })
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &rec, nil
}

// StreakClaimResult — outcome of a claim attempt. Exactly one of
// AmountNIM>0 / AlreadyClaimed / BlockedIPLimit / NoActiveStreak is the
// "reason" — handlers/streak.go maps this straight to a response/toast.
type StreakClaimResult struct {
	Day             int
	AmountNIM       float64
	AlreadyClaimed  bool
	BlockedIPLimit  bool
	NoActiveStreak  bool
}

// ClaimStreakReward — the actual claim. ip should be the resolved real
// client IP (handlers/clientip.go's realClientIP), used for the
// multi-accounting guard. Concurrency: callers MUST serialize claims for
// the same playerID themselves (see TryClaimStreakLock below, mirroring
// TryClaimQuestLock in quest.go) — this function does a plain read-then-
// write with no transactional check-and-set of its own, same tradeoff
// quest claiming already makes.
func (s *Store) ClaimStreakReward(playerID, ip string) (StreakClaimResult, error) {
	day, amount, alreadyClaimed, err := s.GetStreakClaimStatus(playerID)
	if err != nil {
		return StreakClaimResult{}, err
	}
	if alreadyClaimed {
		return StreakClaimResult{Day: day, AlreadyClaimed: true}, nil
	}
	if day <= 0 || amount <= 0 {
		return StreakClaimResult{Day: day, NoActiveStreak: true}, nil
	}

	okIP, ierr := s.CheckAndRecordIPRewardEligibility(ip, playerID)
	if ierr != nil {
		return StreakClaimResult{}, ierr
	}
	if !okIP {
		log.Printf("[STREAK_CLAIM] BLOCKED (ip limit) player=%s ip=%s day=%d amount=%.4f",
			playerID[:min8s(playerID)], ip, day, amount)
		return StreakClaimResult{Day: day, BlockedIPLimit: true}, nil
	}

	// THE actual streak advance — see streak.go's doc comment for why this
	// lives here (claim time) instead of auth.go (login time). Done only
	// now, after the already-claimed/no-active-streak/IP-limit checks above
	// all passed, so a blocked or short-circuited claim attempt never
	// silently bumps the count without the player actually getting paid.
	// RecordDailyActivity is idempotent per UTC+3 day, so this always
	// agrees with the `day` GetStreakClaimStatus just peeked above (barring
	// an astronomically unlikely day-boundary race between the two calls,
	// same class of negligible race every other peek-then-act flow in this
	// codebase already accepts).
	advanced, aerr := s.RecordDailyActivity(playerID)
	if aerr != nil {
		return StreakClaimResult{}, aerr
	}
	day = advanced.Count
	amount = s.ComputeStreakReward(day)

	today := todayUTC3()
	rec := streakClaimRecord{
		PlayerID:  playerID,
		Day:       today,
		AmountNIM: amount,
		ClaimedAt: time.Now().Unix(),
	}
	data, merr := json.Marshal(rec)
	if merr != nil {
		return StreakClaimResult{}, merr
	}
	if err := s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(badger.NewEntry(streakClaimKey(playerID, today), data).WithTTL(48 * time.Hour))
	}); err != nil {
		return StreakClaimResult{}, err
	}

	reason := fmt.Sprintf("%s:day=%d", ReasonStreak, day)
	if _, err := s.QueueReward(playerID, amount, reason); err != nil {
		// Reward record saved but the queue failed — roll the claim record
		// back so the player isn't locked out of a reward they never
		// actually received.
		_ = s.db.Update(func(txn *badger.Txn) error { return txn.Delete(streakClaimKey(playerID, today)) })
		return StreakClaimResult{}, err
	}

	log.Printf("[STREAK_CLAIM] player=%s ip=%s day=%d amount=%.4f", playerID[:min8s(playerID)], ip, day, amount)
	return StreakClaimResult{Day: day, AmountNIM: amount}, nil
}
