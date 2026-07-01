package game

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const (
	keyNicknamePfx     = "nick:"     // nick:<player_id> → PlayerNickname
	keyNicknameLockPfx = "nicklock:" // nicklock:<nickname> → NicknameLock
	keyNicknameIdx     = "nickidx:"  // nickidx:<nickname> → player_id (reverse index)
	nicknameCooldown   = 30 * 24 * time.Hour
)

var nicknameRe = regexp.MustCompile(`^[a-z0-9]{1,20}$`)

func validateNickname(s string) error {
	if !nicknameRe.MatchString(s) {
		return fmt.Errorf("invalid_nickname: only a-z 0-9 max 20 chars")
	}
	return nil
}

// GetNickname returns the player's current nickname record, or nil if none set.
func (s *Store) GetNickname(playerID string) (*models.PlayerNickname, error) {
	var pn models.PlayerNickname
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyNicknamePfx + playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &pn)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &pn, err
}

// GetPlayerByNickname returns the player_id for a given nickname, or "" if not found.
func (s *Store) GetPlayerByNickname(nickname string) (string, error) {
	nickname = strings.ToLower(strings.TrimSpace(nickname))
	var playerID string
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyNicknameIdx + nickname))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			playerID = string(v)
			return nil
		})
	})
	if err == badger.ErrKeyNotFound {
		return "", nil
	}
	return playerID, err
}

// SetNickname attempts to set a new nickname for playerID.
// Returns error if: invalid format, already taken, player on cooldown, nickname on lock.
func (s *Store) SetNickname(playerID, nickname string) (*models.PlayerNickname, error) {
	nickname = strings.ToLower(strings.TrimSpace(nickname))
	if err := validateNickname(nickname); err != nil {
		return nil, err
	}

	now := time.Now()

	// Check player cooldown
	existing, err := s.GetNickname(playerID)
	if err != nil {
		return nil, err
	}
	if existing != nil && now.Unix() < existing.CooldownEnd {
		return nil, fmt.Errorf("cooldown: can change after %d", existing.CooldownEnd)
	}

	// Check nickname lock (released but not yet claimable)
	var lock models.NicknameLock
	lockErr := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyNicknameLockPfx + nickname))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &lock)
		})
	})
	if lockErr == nil && now.Unix() < lock.LockedUntil {
		return nil, fmt.Errorf("nickname_locked_until: %d", lock.LockedUntil)
	}

	// Check uniqueness (reverse index)
	currentOwner, err := s.GetPlayerByNickname(nickname)
	if err != nil {
		return nil, err
	}
	if currentOwner != "" && currentOwner != playerID {
		return nil, fmt.Errorf("nickname_taken")
	}

	// Release old nickname
	if existing != nil && existing.Nickname != "" && existing.Nickname != nickname {
		oldNick := existing.Nickname
		// Remove reverse index for old nickname
		_ = s.db.Update(func(txn *badger.Txn) error {
			return txn.Delete([]byte(keyNicknameIdx + oldNick))
		})
		// Lock old nickname for 30 days
		lockData, _ := json.Marshal(models.NicknameLock{
			Nickname:    oldNick,
			ReleasedBy:  playerID,
			LockedUntil: now.Add(nicknameCooldown).Unix(),
		})
		ttl := nicknameCooldown + time.Hour
		_ = s.db.Update(func(txn *badger.Txn) error {
			return txn.SetEntry(
				badger.NewEntry([]byte(keyNicknameLockPfx+oldNick), lockData).WithTTL(ttl),
			)
		})
	}

	// Save new nickname record
	pn := &models.PlayerNickname{
		PlayerID:    playerID,
		Nickname:    nickname,
		SetAt:       now.Unix(),
		CooldownEnd: now.Add(nicknameCooldown).Unix(),
	}
	data, _ := json.Marshal(pn)
	err = s.db.Update(func(txn *badger.Txn) error {
		// Save player nickname record
		if e := txn.Set([]byte(keyNicknamePfx+playerID), data); e != nil {
			return e
		}
		// Save reverse index
		return txn.Set([]byte(keyNicknameIdx+nickname), []byte(playerID))
	})
	return pn, err
}

// ListAllNicknames — scans all nick: keys and returns every registered player.
// Returns slice of PlayerNickname sorted by SetAt descending (newest first).
func (s *Store) ListAllNicknames() ([]*models.PlayerNickname, error) {
	pfx := []byte(keyNicknamePfx)
	var results []*models.PlayerNickname
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = pfx
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			var pn models.PlayerNickname
			if e := it.Item().Value(func(v []byte) error {
				return json.Unmarshal(v, &pn)
			}); e == nil {
				results = append(results, &pn)
			}
		}
		return nil
	})
	// Sort newest first
	for i := 0; i < len(results)-1; i++ {
		for j := i + 1; j < len(results); j++ {
			if results[j].SetAt > results[i].SetAt {
				results[i], results[j] = results[j], results[i]
			}
		}
	}
	return results, err
}
