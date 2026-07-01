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

func NewStore(db *badger.DB) *Store { return &Store{db: db} }

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

// ── Pending session cleanup & crash recovery ──────────────────────────────────

const pendingExpiry = 7 * 24 * time.Hour // 1 hafta bekleyen session silinir

// StartCleanupLoop — runs in background, deletes pending sessions older than 1 week.
// Cleans up sessions left incomplete due to server crashes.
// StateCompleted sessions are left to Badger's TTL (90 days).
func (s *Store) StartCleanupLoop() {
	go func() {
		// On first run, log recoverable sessions
		s.logOrphanedSessions()
		ticker := time.NewTicker(6 * time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			s.cleanupStalePending()
		}
	}()
}

// logOrphanedSessions — logs sessions left incomplete at startup (pending with GameStartedAt set).
// Used to surface sessions not submitted due to server crash.
func (s *Store) logOrphanedSessions() {
	count := 0
	cutoff := time.Now().Add(-5 * time.Minute).Unix() * 1000 // 5 dakikadan eski
	_ = s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		pfx := []byte("s:")
		for it.Seek(pfx); it.ValidForPrefix(pfx); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var sess models.Session
				if err := json.Unmarshal(v, &sess); err != nil { return nil }
				if sess.State == models.StatePending && sess.GameStartedAt > 0 && sess.GameStartedAt < cutoff {
					count++
				}
				return nil
			})
		}
		return nil
	})
	if count > 0 {
		log.Printf("[CLEANUP] %d orphaned sessions found (started but never submitted — possible crash)", count)
	} else {
		log.Printf("[CLEANUP] no orphaned sessions — clean start")
	}
}

// cleanupStalePending — deletes pending sessions older than 1 week.
// These sessions will never complete (user quit, connection lost, etc.)
func (s *Store) cleanupStalePending() {
	cutoff := time.Now().Add(-pendingExpiry).Unix()
	var toDelete []string
	_ = s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		pfx := []byte("s:")
		for it.Seek(pfx); it.ValidForPrefix(pfx); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var sess models.Session
				if err := json.Unmarshal(v, &sess); err != nil { return nil }
				if sess.State == models.StatePending && sess.CreatedAt < cutoff {
					toDelete = append(toDelete, sess.SessionID)
				}
				return nil
			})
		}
		return nil
	})
	if len(toDelete) == 0 { return }
	deleted := 0
	for _, id := range toDelete {
		_ = s.db.Update(func(txn *badger.Txn) error {
			return txn.Delete(key(id))
		})
		deleted++
	}
	log.Printf("[CLEANUP] deleted %d stale pending sessions (>1 week old)", deleted)
}

// Delete — removes a session from DB (for cleanup)
func (s *Store) Delete(sessionID string) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Delete(key(sessionID))
	})
}
