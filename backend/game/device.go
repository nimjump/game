package game

// device.go — tracks what device/browser each player is actually using,
// captured at wallet-auth verify time (see handleAuthVerify /
// SetPlayerDevice), since that's the one touchpoint virtually every real
// player hits (unlike client-log entries, which only exist for players who
// happened to trigger an error/warn). This is what backs the admin panel's
// "what devices are our players on" view — previously that only existed
// per logged-error-message in the Logs tab (client_log_store.go's
// "devices" field), which only covers players who hit a bug, not the whole
// player base.

import (
	"encoding/json"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const keyPlayerDevicePfx = "device:" // + playerID

type PlayerDevice struct {
	PlayerID   string `json:"player_id"`
	UserAgent  string `json:"user_agent"`
	Platform   string `json:"platform"`
	Screen     string `json:"screen"`
	DPR        string `json:"dpr"`
	UpdatedAt  int64  `json:"updated_at"`
}

// SetPlayerDevice — upserts the device info seen at this player's most
// recent successful wallet-auth verify. Best-effort: called fire-and-forget
// from handleAuthVerify, never blocks/fails the login itself.
func (s *Store) SetPlayerDevice(playerID, userAgent, platform, screen, dpr string) error {
	if playerID == "" {
		return nil
	}
	pd := PlayerDevice{
		PlayerID:  playerID,
		UserAgent: userAgent,
		Platform:  platform,
		Screen:    screen,
		DPR:       dpr,
		UpdatedAt: time.Now().Unix(),
	}
	data, err := json.Marshal(pd)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyPlayerDevicePfx+playerID), data)
	})
}

func (s *Store) GetPlayerDevice(playerID string) (*PlayerDevice, error) {
	var pd PlayerDevice
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyPlayerDevicePfx + playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &pd)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &pd, err
}

// DeviceBreakdownEntry — one row of the admin "device support scale" view.
type DeviceBreakdownEntry struct {
	Platform string `json:"platform"`
	Count    int    `json:"count"`
}

// DeviceBreakdown — how many distinct players are on each platform bucket
// (as reported by their own browser/OS at last login), sorted by count
// descending. This is the real "what are our players actually using" view —
// scan all device: records once.
func (s *Store) DeviceBreakdown() []DeviceBreakdownEntry {
	counts := map[string]int{}
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(keyPlayerDevicePfx)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.ValidForPrefix(opts.Prefix); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var pd PlayerDevice
				if err := json.Unmarshal(v, &pd); err != nil {
					return nil
				}
				key := pd.Platform
				if key == "" {
					key = "unknown"
				}
				counts[key]++
				return nil
			})
		}
		return nil
	})
	out := make([]DeviceBreakdownEntry, 0, len(counts))
	for k, v := range counts {
		out = append(out, DeviceBreakdownEntry{Platform: k, Count: v})
	}
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].Count > out[i].Count {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}
