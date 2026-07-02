package game

// failed_replay_store.go — failed-replay archive, stored in BadgerDB (NOT
// disk files). Every time replay simulation fails outright (worker crash,
// worker timeout, cancelled job) or a client/server score mismatch is
// detected, an entry lands here — downloadable from the admin panel's
// Database tab instead of digging through server disk files.

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const (
	failedReplayPrefix = "failedreplay:"
	failedReplayTTL    = 30 * 24 * time.Hour // 30 days
)

type FailedReplayEntry struct {
	ID         string         `json:"id"`
	SessionID  string         `json:"session_id,omitempty"`
	Seed       string         `json:"seed,omitempty"`
	Char       int            `json:"char"`
	PlayerSeed string         `json:"player_seed,omitempty"`
	LogBase64  string         `json:"log_base64,omitempty"`
	Category   string         `json:"category"` // "worker_timeout" | "worker_cancelled" | "worker_died" | "score_mismatch"
	Reason     string         `json:"reason,omitempty"`
	Extra      map[string]any `json:"extra,omitempty"`
	ArchivedAt int64          `json:"archived_at"`
}

func failedReplayKey(id string) []byte { return []byte(failedReplayPrefix + id) }

// SaveFailedReplay — persists one archive entry.
func (s *Store) SaveFailedReplay(entry FailedReplayEntry) error {
	if entry.ID == "" {
		entry.ID = fmt.Sprintf("%d", time.Now().UnixNano())
	}
	if entry.ArchivedAt == 0 {
		entry.ArchivedAt = time.Now().Unix()
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(badger.NewEntry(failedReplayKey(entry.ID), data).WithTTL(failedReplayTTL))
	})
}

// ListFailedReplays — most recent first.
func (s *Store) ListFailedReplays(limit int) []FailedReplayEntry {
	var out []FailedReplayEntry
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(failedReplayPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var e FailedReplayEntry
				if err := json.Unmarshal(v, &e); err == nil {
					out = append(out, e)
				}
				return nil
			})
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].ArchivedAt > out[j].ArchivedAt })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// GetFailedReplay — single entry, full detail (including the log), for download.
func (s *Store) GetFailedReplay(id string) (*FailedReplayEntry, error) {
	var e FailedReplayEntry
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(failedReplayKey(id))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &e) })
	})
	if err != nil {
		return nil, err
	}
	return &e, nil
}

// ClearFailedReplays — deletes every archived entry. Used by the admin
// "Remove All Replays" button.
func (s *Store) ClearFailedReplays() int {
	deleted, err := s.clearPrefix(failedReplayPrefix)
	if err != nil {
		log.Printf("[FAILED_REPLAY_ARCHIVE] clear error: %v", err)
	}
	return deleted
}

// ArchiveFailedReplay — public API, called from replay_worker.go and from
// handlers (score-mismatch path). jobDir is accepted for backward source
// compatibility with existing call sites but is no longer used — everything
// is stored in the DB now, not on disk.
func ArchiveFailedReplay(jobDir string, sessionID, seed string, charIdx int, playerSeed string, logB64, category, reason string, extra map[string]any) {
	_ = jobDir
	if globalStore == nil {
		log.Printf("[FAILED_REPLAY_ARCHIVE] no DB store available yet — dropping session=%s", sessionID)
		return
	}
	entry := FailedReplayEntry{
		SessionID:  sessionID,
		Seed:       seed,
		Char:       charIdx,
		PlayerSeed: playerSeed,
		LogBase64:  logB64,
		Category:   category,
		Reason:     reason,
		Extra:      extra,
	}
	if err := globalStore.SaveFailedReplay(entry); err != nil {
		log.Printf("[FAILED_REPLAY_ARCHIVE] save error session=%s: %v", sessionID, err)
		return
	}
	log.Printf("[FAILED_REPLAY_ARCHIVE] saved category=%s session=%s seed=%s reason=%q", category, sessionID, seed, reason)
}

// ArchiveFailedReplayDefaultDir — kept for source compatibility with
// existing callers (handlers/server.go, handlers/replay_handlers.go) that
// pass a jobDir into ArchiveFailedReplay. The value is no longer used
// (archive lives in the DB now), but changing every call site's signature
// isn't worth it for a parameter that's just ignored.
func ArchiveFailedReplayDefaultDir() string {
	return GetWorkerPool().jobDir
}
