package game

// golden_replay.go — "golden replay" determinism regression tests.
//
// Problem this solves: the replay simulation system (client WASM vs headless
// server native Godot) is already hardened against cross-platform float
// drift (see Player.gd/EnemyBase.gd position snapping, separated RNG
// streams, fixed-tick physics). But that hardening lives in game code that
// keeps changing — a future edit to Player.gd/GameManager.gd/EnemyBase.gd
// can silently reintroduce non-determinism (or a new replay.exe/replay.zip
// build can behave differently) with nobody noticing until real players
// start getting flagged.
//
// A golden replay is a real, previously-verified replay log pinned together
// with the exact server_score/ticks it produced at the time it was saved.
// Re-running that same log through the CURRENT replay binary must produce
// the EXACT same score — not "within 5% tolerance" like live player
// verification, but bit-for-bit identical, because it's the same
// deterministic simulation replayed against itself. Any mismatch means
// something in the simulation changed and needs investigating before the
// new build/code goes live.

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const goldenReplayPrefix = "goldenreplay:"

// GoldenReplay — one pinned reference replay + the score it must reproduce.
type GoldenReplay struct {
	ID            string `json:"id"`
	Label         string `json:"label"`                 // human description, e.g. "bunny3, long run, mystery box heavy"
	SourceSession string `json:"source_session,omitempty"`
	Seed          int64  `json:"seed"`
	Char          int    `json:"char"`
	PlayerSeed    int64  `json:"player_seed"`
	LogBase64     string `json:"log_base64"`
	ExpectedScore int    `json:"expected_score"`
	ExpectedTicks int    `json:"expected_ticks"`
	SavedAt       int64  `json:"saved_at"`
}

func goldenReplayKey(id string) []byte { return []byte(goldenReplayPrefix + id) }

// SaveGoldenReplay — pins a new reference replay. No TTL — these are
// long-lived regression fixtures, not transient data.
func (s *Store) SaveGoldenReplay(g GoldenReplay) error {
	if g.ID == "" {
		g.ID = fmt.Sprintf("%d", time.Now().UnixNano())
	}
	if g.SavedAt == 0 {
		g.SavedAt = time.Now().Unix()
	}
	data, err := json.Marshal(g)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(goldenReplayKey(g.ID), data)
	})
}

// ListGoldenReplays — all pinned reference replays, oldest first.
func (s *Store) ListGoldenReplays() []GoldenReplay {
	var out []GoldenReplay
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(goldenReplayPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var g GoldenReplay
				if err := json.Unmarshal(v, &g); err == nil {
					out = append(out, g)
				}
				return nil
			})
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].SavedAt < out[j].SavedAt })
	return out
}

// DeleteGoldenReplay — removes one pinned reference replay.
func (s *Store) DeleteGoldenReplay(id string) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Delete(goldenReplayKey(id))
	})
}

// GoldenReplayResult — outcome of re-simulating one golden replay against
// the currently active replay binary.
type GoldenReplayResult struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	Pass          bool   `json:"pass"`
	ExpectedScore int    `json:"expected_score"`
	ActualScore   int    `json:"actual_score"`
	ExpectedTicks int    `json:"expected_ticks"`
	ActualTicks   int    `json:"actual_ticks"`
	Error         string `json:"error,omitempty"`
}

// RunGoldenSelfTest — re-simulates every pinned golden replay against the
// currently active replay binary and checks for an EXACT score match (zero
// tolerance — these are meant to catch any behavior change at all, however
// small). Runs sequentially and deliberately does not use the parallel
// worker pool: this is a manual admin action, not live traffic, and
// sequential keeps the log output easy to read top-to-bottom.
func RunGoldenSelfTest(goldens []GoldenReplay) []GoldenReplayResult {
	results := make([]GoldenReplayResult, 0, len(goldens))
	for _, g := range goldens {
		res := GoldenReplayResult{
			ID:            g.ID,
			Label:         g.Label,
			ExpectedScore: g.ExpectedScore,
			ExpectedTicks: g.ExpectedTicks,
		}
		sim, err := SimulateReplay(g.LogBase64, g.Seed, g.Char, 60, g.PlayerSeed)
		if err != nil {
			res.Error = err.Error()
			log.Printf("[GOLDEN_SELFTEST] FAIL id=%s label=%q sim_error=%v", g.ID, g.Label, err)
			results = append(results, res)
			continue
		}
		res.ActualScore = sim.ServerScore
		res.ActualTicks = sim.Ticks
		res.Pass = sim.ServerScore == g.ExpectedScore
		if res.Pass {
			log.Printf("[GOLDEN_SELFTEST] PASS id=%s label=%q score=%d", g.ID, g.Label, sim.ServerScore)
		} else {
			log.Printf("[GOLDEN_SELFTEST] MISMATCH id=%s label=%q expected=%d actual=%d — determinism regression!",
				g.ID, g.Label, g.ExpectedScore, sim.ServerScore)
		}
		results = append(results, res)
	}
	return results
}
