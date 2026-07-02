package game

// appconfig.go — runtime-toggleable app settings, admin-controlled and
// persisted in BadgerDB. Defaults come from env vars (backend/.env) on
// first read; after that, admin panel changes (saved to DB) always win.
//
// Covers:
//   - daily / weekly leaderboard on-off switches
//   - game update mode (force / normal) + whether new games are blocked
//   - replay version — must match the client's submitted version or the
//     replay is rejected (see handleSubmit in handlers/server.go)

import (
	"encoding/json"
	"log"
	"os"
	"strconv"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const keyAppConfig = "cfg:app"

// Update modes
const (
	UpdateModeOff    = "off"    // normal operation
	UpdateModeForce  = "force"  // block new games immediately
	UpdateModeNormal = "normal" // block new games once the current weekly leaderboard period ends
)

type AppConfig struct {
	DailyLeaderboardEnabled  bool `json:"daily_leaderboard_enabled"`
	WeeklyLeaderboardEnabled bool `json:"weekly_leaderboard_enabled"`

	UpdateMode   string `json:"update_mode"`   // "off" | "force" | "normal"
	UpdateActive bool   `json:"update_active"` // true = new games are currently blocked

	// UpdateScheduledWeek — the weekly period key (e.g. "2026-W26") that was
	// current when "normal" mode was requested. When CurrentPeriods() rolls
	// past this week, UpdateActive flips to true automatically.
	UpdateScheduledWeek string `json:"update_scheduled_week,omitempty"`

	ReplayVersion int `json:"replay_version"` // client must submit a matching client_version
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
	replayVer := 1
	if v := os.Getenv("REPLAY_VERSION"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			replayVer = n
		}
	}
	return AppConfig{
		// Weekly leaderboard starts OFF on purpose (temporarily disabled —
		// not a bug). Both can be flipped back on from the admin panel or
		// via DAILY_LEADERBOARD_ENABLED / WEEKLY_LEADERBOARD_ENABLED env vars.
		DailyLeaderboardEnabled:  envBoolDefault("DAILY_LEADERBOARD_ENABLED", true),
		WeeklyLeaderboardEnabled: envBoolDefault("WEEKLY_LEADERBOARD_ENABLED", false),
		UpdateMode:               UpdateModeOff,
		UpdateActive:             false,
		ReplayVersion:            replayVer,
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

// SetUpdateMode — admin-triggered. "force" blocks new games right away.
// "normal" waits until the current weekly leaderboard period ends. "off"
// clears everything (same as CompleteUpdate).
func (s *Store) SetUpdateMode(mode string) (AppConfig, error) {
	cfg := s.GetAppConfig()
	cfg.UpdateMode = mode
	switch mode {
	case UpdateModeForce:
		cfg.UpdateActive = true
		cfg.UpdateScheduledWeek = ""
	case UpdateModeNormal:
		cfg.UpdateActive = false
		_, weekly := CurrentPeriods()
		cfg.UpdateScheduledWeek = weekly
	default: // "off"
		cfg.UpdateMode = UpdateModeOff
		cfg.UpdateActive = false
		cfg.UpdateScheduledWeek = ""
	}
	if err := s.SaveAppConfig(cfg); err != nil {
		return cfg, err
	}
	log.Printf("[UPDATE_MODE] set mode=%s active=%v scheduled_week=%s", cfg.UpdateMode, cfg.UpdateActive, cfg.UpdateScheduledWeek)
	return cfg, nil
}

// CompleteUpdate — admin-triggered, resumes normal play after an update
// has been pushed (new client build + new replay binary both live).
func (s *Store) CompleteUpdate() (AppConfig, error) {
	return s.SetUpdateMode(UpdateModeOff)
}

// StartUpdateScheduler — background loop. Every minute, checks whether a
// "normal" mode update is waiting for the weekly leaderboard period to
// roll over; if it has, flips UpdateActive on automatically.
func (s *Store) StartUpdateScheduler() {
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			cfg := s.GetAppConfig()
			if cfg.UpdateMode != UpdateModeNormal || cfg.UpdateActive || cfg.UpdateScheduledWeek == "" {
				continue
			}
			_, weekly := CurrentPeriods()
			if weekly != cfg.UpdateScheduledWeek {
				cfg.UpdateActive = true
				if err := s.SaveAppConfig(cfg); err != nil {
					log.Printf("[UPDATE_MODE] auto-activate save failed: %v", err)
					continue
				}
				log.Printf("[UPDATE_MODE] weekly period rolled over (%s -> %s) — update now ACTIVE, new games blocked",
					cfg.UpdateScheduledWeek, weekly)
			}
		}
	}()
}
