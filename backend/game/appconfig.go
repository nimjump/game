package game

// appconfig.go — runtime-toggleable app settings, admin-controlled and
// persisted in BadgerDB. Defaults come from env vars (backend/.env) on
// first read; after that, admin panel changes (saved to DB) always win.
//
// Covers:
//   - daily / weekly leaderboard on-off switches
//   - game update lock — a simple on/off switch that blocks new games from
//     starting (used while pushing a new client build); see SetUpdateActive
//
// REMOVED (on request): the old 3-state "update mode" (off/force/normal,
// with "normal" deferring the block until the current weekly leaderboard
// period ended) collapsed down to a plain on/off switch — the game client
// only ever read the derived `update_active` boolean anyway (see Main.gd's
// _check_server_status), never `update_mode`/`update_scheduled_week`, so
// this simplification needed zero client-side changes. Also removed: the
// "replay version" gate (AppConfig.ReplayVersion / client_version submit
// check in handlers/server.go) and the whole Deploy-jobs feature
// (deploy_job.go, cloudflare_deploy.go, admin_deploy.go, replay_staging.go)
// that used to bundle "activate replay binary + deploy to Cloudflare Pages
// + bump replay version + force update mode" into one scheduled job.

import (
	"encoding/json"
	"log"
	"os"
	"strconv"

	badger "github.com/dgraph-io/badger/v4"
)

const keyAppConfig = "cfg:app"

type AppConfig struct {
	DailyLeaderboardEnabled  bool `json:"daily_leaderboard_enabled"`
	WeeklyLeaderboardEnabled bool `json:"weekly_leaderboard_enabled"`

	// UpdateActive — true = new games are currently blocked ("locked").
	// Toggled straight on/off from the admin panel (SystemTab) via
	// SetUpdateActive below — see the package doc comment above for why
	// this used to be a 3-state mode and no longer is.
	UpdateActive bool `json:"update_active"`

	// DailyEarnCapNIM — admin-editable daily in-game-coin earn cap (NIM).
	// 0 means "not set yet" → falls back to DAILY_EARN_CAP_NIM env var or the
	// 100 NIM default (see DailyCapNIM() in daily_earn_cap.go). Only
	// "in_game_coins" rewards count against this — quest/leaderboard payouts
	// are unaffected (see IsReasonCapped).
	DailyEarnCapNIM float64 `json:"daily_earn_cap_nim,omitempty"`

	// QuestRewardOverrides — admin-editable NIM reward per quest template,
	// keyed by "idx:<poolIndex>" (the template's position in questPool, see
	// questPoolKey in game/quest.go — NOT "<questType>:<target>" anymore,
	// since the target itself is now independently overridable via
	// QuestTargetOverrides below and a target-keyed map would orphan itself
	// the moment an admin changed that same template's target). A key with
	// no entry here just uses questPool's hardcoded default reward.
	QuestRewardOverrides map[string]float64 `json:"quest_reward_overrides,omitempty"`

	// QuestTargetOverrides — admin-editable goal number per quest template
	// (e.g. change "Score 1500 points" to require 1800), keyed the same way
	// as QuestRewardOverrides ("idx:<poolIndex>", see questPoolKey). A key
	// with no entry here just uses questPool's hardcoded default target.
	QuestTargetOverrides map[string]int `json:"quest_target_overrides,omitempty"`

	// CoinNIMRate — admin-editable "1 in-game coin = how many NIM" rate,
	// applied to QuestCoins collected during a run (see handleSubmit in
	// handlers/server.go, "Coin → NIM ödülü"). 0 means "not set yet" →
	// falls back to COIN_NIM_RATE env var or the 1.0 NIM/coin default
	// (see CoinNIMRate() in daily_earn_cap.go).
	CoinNIMRate float64 `json:"coin_nim_rate,omitempty"`

	// ── Streak claim reward (see game/streak_reward.go) ─────────────────────
	// Player must actively CLAIM this from the client (like a daily quest —
	// not auto-paid on login). Formula: min(Base + ExtraPerDay*(streakDay-1),
	// Max). All three are *pointers* (unlike DailyEarnCapNIM/CoinNIMRate
	// above) because 0 is a legitimate, meaningful admin choice here — "turn
	// this off" — not just "not configured yet". nil → env var fallback →
	// hardcoded default; non-nil (including a pointer to 0.0) always wins.

	// StreakRewardBaseNIM — reward on day 1 of a streak. nil → env
	// STREAK_REWARD_BASE_NIM → 0.2 NIM default.
	StreakRewardBaseNIM *float64 `json:"streak_reward_base_nim,omitempty"`

	// StreakRewardExtraPerDayNIM — how much MORE the reward grows per
	// additional consecutive day (day 2 = Base + 1*Extra, day 3 = Base +
	// 2*Extra, ...), before the Max cap kicks in. nil → env
	// STREAK_REWARD_EXTRA_PER_DAY_NIM → 0.5 NIM default.
	StreakRewardExtraPerDayNIM *float64 `json:"streak_reward_extra_per_day_nim,omitempty"`

	// StreakRewardMaxNIM — hard ceiling on the claimable amount for any
	// single day, no matter how long the streak — keeps this from becoming
	// an unbounded payout for very long streaks. nil → env
	// STREAK_REWARD_MAX_NIM → 10.0 NIM default.
	StreakRewardMaxNIM *float64 `json:"streak_reward_max_nim,omitempty"`

	// VSFeePercent — admin-editable system fee (in PERCENT, 0–100) taken from a
	// VS match pot on settlement; the winner receives the remaining
	// (100 - VSFeePercent)%. Pointer because 0 is a legitimate choice ("no fee —
	// winner takes the whole pot"). nil → the 5% default (see VSFeeFraction).
	VSFeePercent *float64 `json:"vs_fee_percent,omitempty"`

	// MaxRewardAccountsPerIP — anti-multi-accounting guard (see
	// game/ip_reward_guard.go): the same IP can only receive a NIM reward
	// (streak claim today, initially — see that file's doc comment for how
	// to extend it to other reward paths) for at most this many DISTINCT
	// player accounts per UTC+3 day. A 6th/7th/etc alt account from the same
	// IP that day is blocked with a clear reason, not silently dropped. nil
	// → env MAX_REWARD_ACCOUNTS_PER_IP → 2 accounts default. Minimum
	// enforced at 1 (0 would mean "nobody from any IP ever gets paid",
	// almost certainly not what an admin setting this means).
	MaxRewardAccountsPerIP *int `json:"max_reward_accounts_per_ip,omitempty"`
}

func envBoolDefault(key string, def bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	return v == "1" || v == "true" || v == "TRUE" || v == "True"
}

// defaultAppConfig — used only when nothing has ever been saved to DB yet.
func defaultAppConfig() AppConfig {
	dailyCap := 0.0 // 0 = unset, DailyCapNIM() falls back to env/default
	if v := os.Getenv("DAILY_EARN_CAP_NIM"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			dailyCap = f
		}
	}
	coinRate := 0.0 // 0 = unset, CoinNIMRate() method falls back to env/default
	if v := os.Getenv("COIN_NIM_RATE"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			coinRate = f
		}
	}
	// Streak reward fields stay nil unless an env var is actually set —
	// leaving them nil (not a pointer to 0.0) means the accessor methods in
	// streak_reward.go fall through to their hardcoded defaults, exactly
	// like the "not configured yet" case is supposed to.
	var streakBase, streakExtra, streakMax *float64
	if v := os.Getenv("STREAK_REWARD_BASE_NIM"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			streakBase = &f
		}
	}
	if v := os.Getenv("STREAK_REWARD_EXTRA_PER_DAY_NIM"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			streakExtra = &f
		}
	}
	if v := os.Getenv("STREAK_REWARD_MAX_NIM"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			streakMax = &f
		}
	}
	var maxAccountsPerIP *int
	if v := os.Getenv("MAX_REWARD_ACCOUNTS_PER_IP"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 {
			maxAccountsPerIP = &n
		}
	}

	return AppConfig{
		// Weekly leaderboard starts OFF on purpose (temporarily disabled —
		// not a bug). Both can be flipped back on from the admin panel or
		// via DAILY_LEADERBOARD_ENABLED / WEEKLY_LEADERBOARD_ENABLED env vars.
		DailyLeaderboardEnabled:  envBoolDefault("DAILY_LEADERBOARD_ENABLED", true),
		WeeklyLeaderboardEnabled: envBoolDefault("WEEKLY_LEADERBOARD_ENABLED", false),
		UpdateActive:             false,
		DailyEarnCapNIM:            dailyCap,
		CoinNIMRate:                coinRate,
		StreakRewardBaseNIM:        streakBase,
		StreakRewardExtraPerDayNIM: streakExtra,
		StreakRewardMaxNIM:         streakMax,
		MaxRewardAccountsPerIP:     maxAccountsPerIP,
	}
}

func (s *Store) GetAppConfig() AppConfig {
	cfg := defaultAppConfig()
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyAppConfig))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &cfg)
		})
	})
	return cfg
}

func (s *Store) SaveAppConfig(cfg AppConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyAppConfig), data)
	})
}

// SetUpdateActive — admin-triggered on/off switch. true blocks new games
// from starting (see Main.gd's _check_server_status/_do_start_game); false
// resumes normal play. Replaces the old 3-state "update mode" — see the
// package doc comment above for why that got collapsed to this.
func (s *Store) SetUpdateActive(active bool) (AppConfig, error) {
	cfg := s.GetAppConfig()
	cfg.UpdateActive = active
	if err := s.SaveAppConfig(cfg); err != nil {
		return cfg, err
	}
	log.Printf("[UPDATE] active=%v", cfg.UpdateActive)
	return cfg, nil
}
