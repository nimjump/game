package game

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const sessionTTL = 90 * 24 * time.Hour // 90 days

const keyDevMode = "cfg:developer_mode"

type Store struct{ db *badger.DB }

// globalStore — set once by NewStore(). There is only ever one Store in
// this app; this lets a handful of free functions that don't carry a
// *Store reference (ArchiveFailedReplay, called from deep inside the
// worker pool) still reach the DB. Everything else should keep taking a
// *Store parameter/receiver as normal — this is a narrow exception, not
// a pattern to copy.
var globalStore *Store

func NewStore(db *badger.DB) *Store {
	s := &Store{db: db}
	globalStore = s
	return s
}

// clearPrefix — deletes every key under the given prefix, batching the
// deletes so a very large category can't blow past Badger's per-transaction
// size limit.
func (s *Store) clearPrefix(prefix string) (int, error) {
	var keys [][]byte
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.PrefetchValues = false
		opts.Prefix = []byte(prefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			k := make([]byte, len(it.Item().Key()))
			copy(k, it.Item().Key())
			keys = append(keys, k)
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	deleted := 0
	const batchSize = 1000
	for i := 0; i < len(keys); i += batchSize {
		end := i + batchSize
		if end > len(keys) {
			end = len(keys)
		}
		batch := keys[i:end]
		err = s.db.Update(func(txn *badger.Txn) error {
			for _, k := range batch {
				if derr := txn.Delete(k); derr == nil {
					deleted++
				}
			}
			return nil
		})
		if err != nil {
			return deleted, err
		}
	}
	return deleted, nil
}

// GetDeveloperMode — returns whether developer mode is currently enabled
func (s *Store) GetDeveloperMode() bool {
	var on bool
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyDevMode))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			on = len(v) > 0 && v[0] == 1
			return nil
		})
	})
	return on
}

// SetDeveloperMode — enables or disables developer mode
func (s *Store) SetDeveloperMode(enabled bool) error {
	val := byte(0)
	if enabled {
		val = 1
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyDevMode), []byte{val})
	})
}

func key(id string) []byte    { return []byte("s:" + id) }
func seedKey(seed int64) []byte { return []byte(fmt.Sprintf("seed:%d", seed)) }

func (s *Store) Save(sess *models.Session) error {
	data, _ := json.Marshal(sess)
	return s.db.Update(func(txn *badger.Txn) error {
		if err := txn.SetEntry(badger.NewEntry(key(sess.SessionID), data).WithTTL(sessionTTL)); err != nil {
			return err
		}
		// Seed → SessionID reverse index (same TTL)
		if sess.Seed != 0 {
			return txn.SetEntry(badger.NewEntry(seedKey(sess.Seed), []byte(sess.SessionID)).WithTTL(sessionTTL))
		}
		return nil
	})
}

// SeedExists — has this seed been used before?
func (s *Store) SeedExists(seed int64) bool {
	exists := false
	_ = s.db.View(func(txn *badger.Txn) error {
		_, err := txn.Get(seedKey(seed))
		exists = (err == nil)
		return nil
	})
	return exists
}

func (s *Store) Get(id string) (*models.Session, error) {
	var sess models.Session
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(key(id))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &sess) })
	})
	if err != nil {
		return nil, err
	}
	return &sess, nil
}

// List — sorted by score descending, max limit entries.
func (s *Store) List(onlyFlagged bool, limit int) []models.Session {
	out := []models.Session{}
	_ = s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		pfx := []byte("s:")
		for it.Seek(pfx); it.ValidForPrefix(pfx); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var sess models.Session
				if err := json.Unmarshal(v, &sess); err != nil {
					return nil
				}
				if onlyFlagged && !sess.Flagged {
					return nil
				}
				out = append(out, sess)
				return nil
			})
		}
		return nil
	})
	// insertion sort by server_score desc (small list — ok)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].ServerScore > out[j-1].ServerScore; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// ── Pending session cleanup — REMOVED ─────────────────────────────────────────
//
// This used to hold StartCleanupLoop / logOrphanedSessions / cleanupStalePending,
// which deleted "pending" sessions older than 1 week (StatePending, meant to mark
// a game started-but-not-yet-submitted). Removed because that state was never
// actually reachable: the only place a Session is ever created is the /submit
// handler (see handlers/server.go), and it always saves State as StateCompleted
// or StateFlagged immediately — there was never a separate "start game" call
// that wrote StatePending first. So these functions always found zero orphaned/
// stale-pending sessions; pure dead code kept alive by nothing.

// Delete — removes a session from DB (for cleanup)
func (s *Store) Delete(sessionID string) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Delete(key(sessionID))
	})
}

// ClearAllReplayLogs — wipes the replay log (and replay error) off every
// session, but keeps the session itself — score, state, quest totals,
// rewards already paid out, everything else stays intact. Used by the
// admin "Remove All Replays" button when pushing a new client/replay
// binary, so old replay logs (recorded against the old build) don't
// linger around no longer matching anything.
func (s *Store) ClearAllReplayLogs() (int, error) {
	var ids []string
	err := s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		pfx := []byte("s:")
		for it.Seek(pfx); it.ValidForPrefix(pfx); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var sess models.Session
				if err := json.Unmarshal(v, &sess); err != nil {
					return nil
				}
				if sess.Log != "" {
					ids = append(ids, sess.SessionID)
				}
				return nil
			})
		}
		return nil
	})
	if err != nil {
		return 0, err
	}

	cleared := 0
	for _, id := range ids {
		sess, gerr := s.Get(id)
		if gerr != nil || sess == nil {
			continue
		}
		sess.Log = ""
		sess.ReplayError = ""
		if serr := s.Save(sess); serr == nil {
			cleared++
		}
	}
	return cleared, nil
}
