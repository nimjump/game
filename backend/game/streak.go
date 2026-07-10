package game

// streak.go — daily login-streak tracking.
//
// The persisted Count/LastDay here reflect days the player has actually
// CLAIMED their streak reward, not merely logged in — see
// streak_reward.go's doc comment. RecordDailyActivity is called from
// ClaimStreakReward at the moment of a successful claim, in the same fixed
// UTC+3 day used everywhere else in this codebase (see leaderboard.go's
// UTC3), so a streak's "day" always lines up with the same daily reset
// players already see on the leaderboard.
//
// BUG FIX (previously): this used to be called from EVERY successful auth
// check (fresh sign-in verify AND session restore in handlers/auth.go) —
// "purely did this wallet show up today, no score/play/claim required".
// That meant the streak count (and the lobby's "N day streak! Keep it
// going" toast) advanced the instant a returning player opened the app,
// before they'd done anything at all — including on their very first
// visit of a brand new day, confusingly celebrating a streak they hadn't
// actually claimed yet. Moved the advance to claim-time so the number only
// ever reflects real, deliberate claims. auth.go now only *reads* the
// current (already-claimed) count via GetStreak for display — see
// PeekStreakDay for the read-only "what day would a claim right now land
// on" preview used by the claim UI before the player has actually tapped
// claim.

import (
	"encoding/json"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const keyStreakPfx = "streak:" // prefix + playerID

type PlayerStreak struct {
	Count      int    `json:"count"`       // consecutive days including today (0 if streak is dead)
	LastDay    string `json:"last_day"`    // "2026-07-08" (UTC+3) — last day actually counted
	LongestRun int    `json:"longest_run"` // best streak ever reached — for admin/bragging-rights display
	// Advanced — true only on the ONE call per UTC+3 day that actually moved
	// the counter (the first auth/restore of the day). False on every
	// repeat call that same day. Not persisted (json:"-") — this is a
	// per-request signal for the caller (streak_reward.go), not stored
	// state; storing it would go stale the moment a second call comes in.
	Advanced bool `json:"-"`
}

func streakKey(playerID string) []byte { return []byte(keyStreakPfx + playerID) }

// RecordDailyActivity — advances playerID's streak if today is a new
// UTC+3 day for them: +1 if their last counted day was yesterday, reset
// to 1 if there's a gap (or this is their first-ever visit), no-op if
// they've already been counted today.
func (s *Store) RecordDailyActivity(playerID string) (PlayerStreak, error) {
	if playerID == "" {
		return PlayerStreak{}, nil
	}
	now := time.Now().In(utc3)
	today := dailyPeriodKey(now)
	yesterday := dailyPeriodKey(now.AddDate(0, 0, -1))

	var out PlayerStreak
	err := s.db.Update(func(txn *badger.Txn) error {
		var cur PlayerStreak
		item, gerr := txn.Get(streakKey(playerID))
		if gerr == nil {
			_ = item.Value(func(v []byte) error { return json.Unmarshal(v, &cur) })
		} else if gerr != badger.ErrKeyNotFound {
			return gerr
		}

		if cur.LastDay == today {
			out = cur // already counted today — no-op
			out.Advanced = false
			return nil
		}

		if cur.LastDay == yesterday {
			cur.Count++
		} else {
			cur.Count = 1 // gap of 1+ days, or first-ever visit — restart at 1
		}
		cur.LastDay = today
		if cur.Count > cur.LongestRun {
			cur.LongestRun = cur.Count
		}
		cur.Advanced = true
		out = cur

		data, merr := json.Marshal(cur)
		if merr != nil {
			return merr
		}
		return txn.Set(streakKey(playerID), data)
	})
	return out, err
}

// ListAllStreaks — every player who has EVER had a streak record, keyed by
// playerID. Unlike GetStreak, this does NOT zero out dead streaks (last_day
// neither today nor yesterday) — the admin Streaks tab wants to show
// "longest run ever" and history for lapsed players too, not just live
// streaks. Callers that need "is this streak currently alive" should check
// LastDay against today/yesterday themselves (see GetStreak for the exact
// logic) or just call GetStreak per player if they need the live-zeroed count.
func (s *Store) ListAllStreaks() map[string]PlayerStreak {
	out := map[string]PlayerStreak{}
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(keyStreakPfx)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.ValidForPrefix(opts.Prefix); it.Next() {
			item := it.Item()
			playerID := string(item.Key()[len(keyStreakPfx):])
			var cur PlayerStreak
			_ = item.Value(func(v []byte) error { return json.Unmarshal(v, &cur) })
			out[playerID] = cur
		}
		return nil
	})
	return out
}

// GetStreak — read-only lookup, used by the admin player profile view and
// by the client's /backend/auth/me response. Never mutates anything — if
// the player's last counted day is neither today nor yesterday, their
// streak is already dead even though the stored record hasn't caught up
// yet (that only happens lazily, next time they actually show up), so
// this reports 0 instead of a stale count.
func (s *Store) GetStreak(playerID string) PlayerStreak {
	var cur PlayerStreak
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(streakKey(playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &cur) })
	})
	now := time.Now().In(utc3)
	today := dailyPeriodKey(now)
	yesterday := dailyPeriodKey(now.AddDate(0, 0, -1))
	if cur.LastDay != today && cur.LastDay != yesterday {
		cur.Count = 0
	}
	return cur
}

// PeekStreakDay — read-only: what day number a claim RIGHT NOW would land
// on, WITHOUT advancing/mutating anything. Mirrors RecordDailyActivity's
// exact day-advance rule (+1 if last claimed day was yesterday, restart at
// 1 on a gap or first-ever claim, same number again if already claimed
// today) so the claim UI (GetStreakClaimStatus) can show the player "Day
// N" and the correct reward preview BEFORE they've actually tapped claim.
// Always returns >= 1 — there's no "no active streak" case here, since a
// brand new player (or one whose streak lapsed) can always start a fresh
// streak at day 1 the moment they claim.
func (s *Store) PeekStreakDay(playerID string) int {
	if playerID == "" {
		return 0
	}
	var cur PlayerStreak
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(streakKey(playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &cur) })
	})
	now := time.Now().In(utc3)
	today := dailyPeriodKey(now)
	yesterday := dailyPeriodKey(now.AddDate(0, 0, -1))
	if cur.LastDay == today {
		return cur.Count // already claimed today — same day number
	}
	if cur.LastDay == yesterday {
		return cur.Count + 1
	}
	return 1 // gap of 1+ days, or first-ever claim
}
