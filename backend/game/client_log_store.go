package game

import (
	"crypto/md5"
	"encoding/json"
	"fmt"
	"log"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

// ClientLogEntry — oyundan gelen hata/uyarı log kaydı.
// Aynı mesaj tekrar gelirse count artar, players listesi büyür.
type ClientLogEntry struct {
	// ID = "clog:" + md5(level+message) → aynı hata tek satırda toplanır
	ID        string   `json:"id"`
	Level     string   `json:"level"`    // "error" | "warn" | "info"
	Message   string   `json:"message"`
	Count     int      `json:"count"`
	Players   []string `json:"players"`  // unique player ID'leri
	IPs       []string `json:"ips"`      // unique IP'ler
	Devices   []string `json:"devices"`  // "iPhone 14 Pro / iOS 17.2" gibi
	CreatedAt int64    `json:"created_at"` // ilk görülme
	UpdatedAt int64    `json:"updated_at"` // son görülme
}

const (
	clientLogPrefix = "clog:"
	clientLogTTL    = 14 * 24 * time.Hour // 14 gün
	clientLogMax    = 500                  // DB'de tutulacak max unique mesaj
)

func clientLogKey(msgHash string) []byte { return []byte(clientLogPrefix + msgHash) }

func msgHash(level, message string) string {
	h := md5.Sum([]byte(level + ":" + message))
	return fmt.Sprintf("%x", h)
}

// UpsertClientLog — aynı mesaj gelirse count'u artır, yeni gelirse oluştur.
func (s *Store) UpsertClientLog(level, message, playerID, ip, device string) error {
	hash := msgHash(level, message)
	key := clientLogKey(hash)
	now := time.Now().Unix()

	return s.db.Update(func(txn *badger.Txn) error {
		var entry ClientLogEntry

		item, err := txn.Get(key)
		if err == nil {
			// Mevcut kayıt — güncelle
			_ = item.Value(func(v []byte) error {
				return json.Unmarshal(v, &entry)
			})
			entry.Count++
			entry.UpdatedAt = now
			if playerID != "" && !contains(entry.Players, playerID) {
				if len(entry.Players) < 20 {
					entry.Players = append(entry.Players, playerID)
				}
			}
			if ip != "" && !contains(entry.IPs, ip) {
				if len(entry.IPs) < 20 {
					entry.IPs = append(entry.IPs, ip)
				}
			}
			if device != "" && !contains(entry.Devices, device) {
				if len(entry.Devices) < 10 {
					entry.Devices = append(entry.Devices, device)
				}
			}
		} else {
			// Yeni kayıt
			entry = ClientLogEntry{
				ID:        hash,
				Level:     level,
				Message:   message,
				Count:     1,
				Players:   []string{},
				IPs:       []string{},
				Devices:   []string{},
				CreatedAt: now,
				UpdatedAt: now,
			}
			if playerID != "" { entry.Players = []string{playerID} }
			if ip != ""       { entry.IPs     = []string{ip} }
			if device != ""   { entry.Devices = []string{device} }
		}

		data, merr := json.Marshal(&entry)
		if merr != nil {
			return merr
		}
		return txn.SetEntry(badger.NewEntry(key, data).WithTTL(clientLogTTL))
	})
}

func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s { return true }
	}
	return false
}

// ListClientLogs — tüm client log'larını döner, en çok tekrarlanan önce.
func (s *Store) ListClientLogs(levelFilter string, limit int) []ClientLogEntry {
	var out []ClientLogEntry
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(clientLogPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			var e ClientLogEntry
			_ = it.Item().Value(func(v []byte) error {
				return json.Unmarshal(v, &e)
			})
			if e.ID == "" { continue }
			if levelFilter != "" && e.Level != levelFilter { continue }
			out = append(out, e)
		}
		return nil
	})
	// En çok tekrarlanan önce; eşitlik durumunda en yeni önce
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].Count > out[i].Count ||
				(out[j].Count == out[i].Count && out[j].UpdatedAt > out[i].UpdatedAt) {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// DeleteAllClientLogs — tüm client log kayıtlarını siler.
func (s *Store) DeleteAllClientLogs() int {
	var keys [][]byte
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.PrefetchValues = false
		opts.Prefix = []byte(clientLogPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			k := make([]byte, len(it.Item().Key()))
			copy(k, it.Item().Key())
			keys = append(keys, k)
		}
		return nil
	})
	deleted := 0
	_ = s.db.Update(func(txn *badger.Txn) error {
		for _, k := range keys {
			if err := txn.Delete(k); err == nil { deleted++ }
		}
		return nil
	})
	log.Printf("[CLIENT_LOG] deleted %d entries", deleted)
	return deleted
}

// ClientLogCount — mevcut kayıt sayısını döner.
func (s *Store) ClientLogCount() int {
	count := 0
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.PrefetchValues = false
		opts.Prefix = []byte(clientLogPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() { count++ }
		return nil
	})
	return count
}
