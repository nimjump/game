package game

// daily_earn_cap.go
//
// Günlük kazanım limiti (Daily Earn Cap) — oyun içi NIM kazanımları için.
//
// Kurallar:
//   • Günlük maksimum: 100 NIM (DAILY_EARN_CAP_NIM env ile değiştirilebilir).
//   • Sadece "in_game_coins" reason'lı ödüller cap'e sayılır.
//   • Quest tamamlama ve leaderboard ödülleri cap'e dahil DEĞİLDİR.
//   • Gün sonu UTC+3 gece yarısı sıfırlanır (leaderboard ile aynı timezone).
//   • DB key: "dailycap:<playerID>:<YYYY-MM-DD>"  (48 saat TTL, gün geçince otomatik silinir)
//
// Kullanım — handleSubmit içinde:
//
//   remaining, err := store.DailyCapRemaining(playerID)
//   if err != nil || remaining <= 0 {
//       // cap doldu, ödül gönderme
//   }
//   actualReward := min(coinReward, remaining)
//   store.QueueRewardCapped(playerID, actualReward, "in_game_coins", coinCount)

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const (
	// keyDailyCapPfx — "dailycap:<playerID>:<YYYY-MM-DD>"
	keyDailyCapPfx = "dailycap:"

	// ReasonInGameCoins — oyun içi coin'lerden gelen NIM ödülü reason string'i.
	// QueueReward / QueueRewardCapped çağrısında bu reason kullanılmalı.
	ReasonInGameCoins = "in_game_coins"
)

// defaultDailyCap — varsayılan günlük limit (NIM)
const defaultDailyCap = 100.0

// CoinNIMRate — admin panel'den (AppConfig.CoinNIMRate, BadgerDB) ayarlanan
// "1 coin kaç NIM eder" oranını okur. Hiç ayarlanmamışsa COIN_NIM_RATE env
// değişkenine, o da yoksa 1.0 NIM/coin sabit varsayılana düşer. Store method —
// önceden serbest bir fonksiyondu ve sadece env okuyordu, admin panelden
// değiştirilemiyordu.
func (s *Store) CoinNIMRate() float64 {
	if v := s.GetAppConfig().CoinNIMRate; v > 0 {
		return v
	}
	if v := os.Getenv("COIN_NIM_RATE"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return f
		}
	}
	return 1.0 // default: 1 coin = 1 NIM
}

// DailyCapNIM — admin panel'den (AppConfig.DailyEarnCapNIM, BadgerDB) ayarlanan
// günlük limiti okur. Hiç ayarlanmamışsa DAILY_EARN_CAP_NIM env değişkenine,
// o da yoksa 100 NIM sabit varsayılana düşer. Store method — önceden serbest
// bir fonksiyondu ve sadece env okuyordu, admin panelden değiştirilemiyordu.
func (s *Store) DailyCapNIM() float64 {
	if v := s.GetAppConfig().DailyEarnCapNIM; v > 0 {
		return v
	}
	if v := os.Getenv("DAILY_EARN_CAP_NIM"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return f
		}
	}
	return defaultDailyCap
}

// dailyCapRecord — DB'de saklanan günlük kazanım kaydı
type dailyCapRecord struct {
	PlayerID  string  `json:"player_id"`
	Day       string  `json:"day"`        // "2026-06-28"
	EarnedNIM float64 `json:"earned_nim"` // bugün kazanılan toplam (cap'e dahil olanlar)
	UpdatedAt int64   `json:"updated_at"`
}

// dailyCapKey — DB anahtarı
func dailyCapKey(playerID, day string) []byte {
	return []byte(fmt.Sprintf("%s%s:%s", keyDailyCapPfx, playerID, day))
}

// todayUTC3 — UTC+3'te bugünün tarihi ("2006-01-02")
func todayUTC3() string {
	return time.Now().In(UTC3).Format("2006-01-02")
}

// GetDailyCapRecord — oyuncunun bugünkü kazanım kaydını döner (yoksa sıfır döner).
func (s *Store) GetDailyCapRecord(playerID string) (*dailyCapRecord, error) {
	day := todayUTC3()
	var rec dailyCapRecord
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(dailyCapKey(playerID, day))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &rec)
		})
	})
	if err == badger.ErrKeyNotFound {
		// Bugün hiç kazanmamış — sıfır kayıt döndür
		return &dailyCapRecord{PlayerID: playerID, Day: day, EarnedNIM: 0}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("daily_cap_read: %w", err)
	}
	return &rec, nil
}

// DailyCapRemaining — bugün ne kadar daha NIM kazanılabilir.
// Dönüş değeri 0 ise cap dolmuş, ödül gönderilmemeli.
func (s *Store) DailyCapRemaining(playerID string) (float64, error) {
	rec, err := s.GetDailyCapRecord(playerID)
	if err != nil {
		return 0, err
	}
	cap := s.DailyCapNIM()
	remaining := cap - rec.EarnedNIM
	if remaining < 0 {
		remaining = 0
	}
	return remaining, nil
}

// addDailyCapEarned — kazanılan miktarı atomik olarak DB'ye ekler.
// Gerçekte kazanılan miktarı döner (cap aşımını kırpar).
func (s *Store) addDailyCapEarned(playerID string, requestedNIM float64) (float64, error) {
	day := todayUTC3()
	key := dailyCapKey(playerID, day)
	cap := s.DailyCapNIM()

	// Read-modify-write (tek transaction içinde)
	var actualEarned float64
	err := s.db.Update(func(txn *badger.Txn) error {
		var rec dailyCapRecord
		item, err := txn.Get(key)
		if err == badger.ErrKeyNotFound {
			rec = dailyCapRecord{PlayerID: playerID, Day: day, EarnedNIM: 0}
		} else if err != nil {
			return err
		} else {
			if e := item.Value(func(v []byte) error {
				return json.Unmarshal(v, &rec)
			}); e != nil {
				return e
			}
		}

		remaining := cap - rec.EarnedNIM
		if remaining <= 0 {
			actualEarned = 0
			return nil // cap dolmuş, DB'yi değiştirme
		}

		if requestedNIM > remaining {
			actualEarned = remaining // kırp
		} else {
			actualEarned = requestedNIM
		}

		rec.EarnedNIM += actualEarned
		rec.UpdatedAt = time.Now().Unix()

		data, merr := json.Marshal(&rec)
		if merr != nil {
			return merr
		}
		// TTL: 48 saat (gün rollover'ında otomatik silinsin)
		return txn.SetEntry(badger.NewEntry(key, data).WithTTL(48 * time.Hour))
	})
	if err != nil {
		return 0, fmt.Errorf("daily_cap_update: %w", err)
	}
	return actualEarned, nil
}

// QueueRewardCapped — oyun içi coin ödülü için daily cap uygulayarak QueueReward çağırır.
//
// Parametreler:
//   playerID     — oyuncu ID'si (Nimiq adresi)
//   requestedNIM — bu oyundan kazanılmak istenen NIM miktarı
//   coinCount    — log için coin sayısı (0 geçilebilir)
//
// Dönüş: gönderilen gerçek miktar (0 ise cap dolmuştu, ödül gönderilmedi)
func (s *Store) QueueRewardCapped(playerID string, requestedNIM float64, coinCount int) (float64, error) {
	if requestedNIM <= 0 {
		return 0, nil
	}

	actualNIM, err := s.addDailyCapEarned(playerID, requestedNIM)
	if err != nil {
		return 0, err
	}
	if actualNIM <= 0 {
		log.Printf("[DAILY_CAP] FULL player=%s requested=%.4f NIM — skipped", playerID[:min8s(playerID)], requestedNIM)
		return 0, nil
	}

	reason := fmt.Sprintf("%s:coins=%d", ReasonInGameCoins, coinCount)
	_, err = s.QueueReward(playerID, actualNIM, reason)
	if err != nil {
		// Kazanım ekledik ama ödül kuyruğa girmedi — geri al
		_ = s.subtractDailyCapEarned(playerID, actualNIM)
		return 0, fmt.Errorf("queue_reward: %w", err)
	}

	if actualNIM < requestedNIM {
		log.Printf("[DAILY_CAP] CAPPED player=%s requested=%.4f actual=%.4f NIM (cap=%.0f)",
			playerID[:min8s(playerID)], requestedNIM, actualNIM, s.DailyCapNIM())
	} else {
		log.Printf("[DAILY_CAP] OK player=%s earned=%.4f NIM coins=%d",
			playerID[:min8s(playerID)], actualNIM, coinCount)
	}

	return actualNIM, nil
}

// subtractDailyCapEarned — QueueReward başarısız olursa kazanımı geri alır (rollback).
func (s *Store) subtractDailyCapEarned(playerID string, nimToSubtract float64) error {
	day := todayUTC3()
	key := dailyCapKey(playerID, day)
	return s.db.Update(func(txn *badger.Txn) error {
		item, err := txn.Get(key)
		if err != nil {
			return nil // kayıt yoksa rollback gerekmiyor
		}
		var rec dailyCapRecord
		if e := item.Value(func(v []byte) error { return json.Unmarshal(v, &rec) }); e != nil {
			return e
		}
		rec.EarnedNIM -= nimToSubtract
		if rec.EarnedNIM < 0 {
			rec.EarnedNIM = 0
		}
		rec.UpdatedAt = time.Now().Unix()
		data, _ := json.Marshal(&rec)
		return txn.SetEntry(badger.NewEntry(key, data).WithTTL(48 * time.Hour))
	})
}

// IsReasonCapped — verilen reason string'inin daily cap'e tabi olup olmadığını döner.
// "in_game_coins" → true, quest/leaderboard → false.
func IsReasonCapped(reason string) bool {
	// "in_game_coins:coins=N" formatını kontrol et
	return len(reason) >= len(ReasonInGameCoins) && reason[:len(ReasonInGameCoins)] == ReasonInGameCoins
}

// DailyCapStats — stats endpoint için özet bilgi döner.
type DailyCapStats struct {
	EarnedToday float64 `json:"daily_earned"`    // bugün kazanılan (cap dahili)
	Cap         float64 `json:"daily_cap"`        // günlük limit
	Remaining   float64 `json:"daily_cap_remaining"`
	ResetAt     int64   `json:"daily_cap_reset_at"` // UTC+3 gece yarısı (unix)
	IsFull      bool    `json:"daily_cap_full"`
}

// GetDailyCapStats — stats endpoint'inden dönülecek cap özeti.
func (s *Store) GetDailyCapStats(playerID string) DailyCapStats {
	rec, err := s.GetDailyCapRecord(playerID)
	cap := s.DailyCapNIM()
	if err != nil || rec == nil {
		return DailyCapStats{Cap: cap, Remaining: cap, ResetAt: nextMidnightUTC3()}
	}
	remaining := cap - rec.EarnedNIM
	if remaining < 0 {
		remaining = 0
	}
	return DailyCapStats{
		EarnedToday: rec.EarnedNIM,
		Cap:         cap,
		Remaining:   remaining,
		ResetAt:     nextMidnightUTC3(),
		IsFull:      remaining <= 0,
	}
}

// nextMidnightUTC3 — bir sonraki UTC+3 gece yarısının Unix timestamp'i.
func nextMidnightUTC3() int64 {
	now := time.Now().In(UTC3)
	next := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, UTC3)
	return next.Unix()
}
