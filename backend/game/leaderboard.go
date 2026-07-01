package game

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const (
	keyLBConfig  = "lb:config"
	keyLBWinners = "lb:winners:" // prefix + period key (e.g. "2026-06-17" or "2026-W25")
)

// UTC3 — fixed UTC+3 timezone used for all period calculations
var UTC3 = time.FixedZone("UTC+3", 3*60*60)

// utc3 — internal alias
var utc3 = UTC3

// ── Config ────────────────────────────────────────────────────────────────────

func (s *Store) GetLeaderboardConfig() (models.LeaderboardConfig, error) {
	cfg := models.DefaultLeaderboardConfig()
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyLBConfig))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &cfg)
		})
	})
	if err == badger.ErrKeyNotFound {
		return cfg, nil // return defaults
	}
	return cfg, err
}

func (s *Store) SaveLeaderboardConfig(cfg models.LeaderboardConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyLBConfig), data)
	})
}

// ── Period helpers ────────────────────────────────────────────────────────────

// dailyPeriodKey — "2026-06-17"
func dailyPeriodKey(t time.Time) string {
	return t.Format("2006-01-02")
}

// weeklyPeriodKey — "2026-W25"
func weeklyPeriodKey(t time.Time) string {
	year, week := t.ISOWeek()
	return fmt.Sprintf("%d-W%02d", year, week)
}

// periodBounds — returns start and end Unix timestamps for a period
func periodBounds(period string) (int64, int64) {
	loc := utc3
	now := time.Now().In(loc)

	if len(period) == 10 { // "2026-06-17"
		t, err := time.ParseInLocation("2006-01-02", period, loc)
		if err != nil {
			return 0, now.Unix()
		}
		start := t.Unix()
		end := t.Add(24 * time.Hour).Unix()
		return start, end
	}

	// "2026-W25"
	var year, week int
	if _, err := fmt.Sscanf(period, "%d-W%d", &year, &week); err != nil {
		return 0, now.Unix()
	}
	// ISO week 1'in pazartesisini bul
	jan4 := time.Date(year, 1, 4, 0, 0, 0, 0, loc)
	weekday := int(jan4.Weekday())
	if weekday == 0 {
		weekday = 7
	}
	monday := jan4.AddDate(0, 0, -(weekday-1)+7*(week-1))
	start := monday.Unix()
	end := monday.AddDate(0, 0, 7).Unix()
	return start, end
}

// ── Leaderboard query ─────────────────────────────────────────────────────────

type LBEntry struct {
	Rank        int    `json:"rank"`
	PlayerID    string `json:"player_id"`
	Nickname    string `json:"nickname"`
	ServerScore int    `json:"server_score"`
	Char        int    `json:"char"`
	SubmittedAt int64  `json:"submitted_at"`
	SessionID   string `json:"session_id"`
	HasReplay   bool   `json:"has_replay"`
	IsSelf      bool   `json:"is_self,omitempty"`
}

// GetLeaderboard — returns filtered leaderboard by period type and period key.
// periodType: "daily" | "weekly" | "alltime"
// period: "2026-06-17" (daily), "2026-W25" (weekly), "" (alltime)
func (s *Store) GetLeaderboard(periodType, period string, limit int) ([]LBEntry, error) {
	return s.GetLeaderboardPaged(periodType, period, limit, 0, "")
}

func (s *Store) GetLeaderboardPaged(periodType, period string, limit, offset int, selfPlayerID string) ([]LBEntry, error) {
	all := s.List(false, 0)

	var startTs, endTs int64
	if periodType != "alltime" && period != "" {
		startTs, endTs = periodBounds(period)
	}

	// Find best score per player
	best := map[string]models.Session{}
	for _, sess := range all {
		if sess.Flagged || sess.ServerScore <= 0 || sess.State == models.StatePending {
			continue
		}
		if startTs > 0 && (sess.SubmittedAt < startTs || sess.SubmittedAt >= endTs) {
			continue
		}
		pid := sess.PlayerID
		if pid == "" {
			pid = sess.SessionID
		}
		if prev, ok := best[pid]; !ok || sess.ServerScore > prev.ServerScore {
			best[pid] = sess
		}
	}

	entries := make([]models.Session, 0, len(best))
	for _, s := range best {
		entries = append(entries, s)
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].ServerScore > entries[j].ServerScore
	})

	total := len(entries)

	// Find our own rank (before truncating)
	selfEntry := LBEntry{}
	selfFound := false
	if selfPlayerID != "" {
		for i, e := range entries {
			pid := e.PlayerID
			if pid == "" { pid = e.SessionID }
			if pid == selfPlayerID {
				nick := ""
				if pn, pnerr := s.GetNickname(pid); pnerr == nil && pn != nil && pn.Nickname != "" {
					nick = pn.Nickname
				}
				if nick == "" { nick = e.Nickname }
				if nick == "" { p := pid; if len(p) > 8 { p = p[:8] }; nick = p }
				selfEntry = LBEntry{
					Rank: i + 1, PlayerID: e.PlayerID, Nickname: nick,
					ServerScore: e.ServerScore, Char: e.Char,
					SubmittedAt: e.SubmittedAt, SessionID: e.SessionID, HasReplay: e.Log != "",
				}
				selfFound = true
				break
			}
		}
	}
	_ = selfFound

	// Offset + limit uygula
	if offset > 0 && offset < len(entries) {
		entries = entries[offset:]
	} else if offset >= len(entries) {
		entries = nil
	}
	if limit > 0 && len(entries) > limit {
		entries = entries[:limit]
	}

	out := make([]LBEntry, len(entries))
	for i, e := range entries {
		pid := e.PlayerID
		if pid == "" { pid = e.SessionID }
		// Prefer PlayerNickname DB over session nickname
		nick := ""
		if pn, pnerr := s.GetNickname(pid); pnerr == nil && pn != nil && pn.Nickname != "" {
			nick = pn.Nickname
		}
		if nick == "" {
			nick = e.Nickname
		}
		if nick == "" {
			p := pid; if len(p) > 8 { p = p[:8] }; nick = p
		}
		out[i] = LBEntry{
			Rank:        offset + i + 1,
			PlayerID:    e.PlayerID,
			Nickname:    nick,
			ServerScore: e.ServerScore,
			Char:        e.Char,
			SubmittedAt: e.SubmittedAt,
			SessionID:   e.SessionID,
			HasReplay:   e.Log != "",
		}
	}

	// selfEntry'yi response'a ekle (zaten listede varsa tekrar eklemiyoruz)
	if selfFound {
		inPage := false
		for _, o := range out {
			if o.PlayerID == selfEntry.PlayerID {
				inPage = true; break
			}
		}
		if !inPage {
			selfEntry.IsSelf = true
			out = append(out, selfEntry)
		}
	}

	_ = total
	return out, nil
}

// ── Winner snapshots ──────────────────────────────────────────────────────────

func winnerKey(periodKey string) []byte {
	return []byte(keyLBWinners + periodKey)
}

// SnapshotWinners — computes winners for the given period and saves to BadgerDB.
// Called at end of each period (or on-demand from admin).
func (s *Store) SnapshotWinners(periodType, period string) (*models.PeriodWinners, error) {
	cfg, err := s.GetLeaderboardConfig()
	if err != nil {
		return nil, err
	}

	entries, err := s.GetLeaderboard(periodType, period, 3)
	if err != nil {
		return nil, err
	}

	prizes := cfg.Daily
	if periodType == "weekly" {
		prizes = cfg.Weekly
	}
	prizeList := []float64{prizes.First, prizes.Second, prizes.Third}

	winners := make([]models.WinnerEntry, len(entries))
	for i, e := range entries {
		prize := 0.0
		if i < len(prizeList) {
			prize = prizeList[i]
		}
		winners[i] = models.WinnerEntry{
			Rank:        e.Rank,
			PlayerID:    e.PlayerID,
			Nickname:    e.Nickname,
			ServerScore: e.ServerScore,
			Char:        e.Char,
			PrizeNIM:    prize,
			SessionID:   e.SessionID,
		}
	}

	pw := &models.PeriodWinners{
		Period:     period,
		PeriodType: periodType,
		Winners:    winners,
		ClosedAt:   time.Now().Unix(),
	}

	data, err := json.Marshal(pw)
	if err != nil {
		return nil, err
	}

	err = s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(winnerKey(period), data)
	})
	return pw, err
}

// GetWinners — returns saved winners for a recorded period
func (s *Store) GetWinners(period string) (*models.PeriodWinners, error) {
	var pw models.PeriodWinners
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(winnerKey(period))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &pw)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &pw, err
}

// ListWinners — returns all recorded period winners (newest first)
func (s *Store) ListWinners() ([]models.PeriodWinners, error) {
	prefix := []byte(keyLBWinners)
	var out []models.PeriodWinners

	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = prefix
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			err := it.Item().Value(func(v []byte) error {
				var pw models.PeriodWinners
				if e := json.Unmarshal(v, &pw); e == nil {
					out = append(out, pw)
				}
				return nil
			})
			if err != nil {
				return err
			}
		}
		return nil
	})

	// Sort by ClosedAt
	sort.Slice(out, func(i, j int) bool {
		return out[i].ClosedAt > out[j].ClosedAt
	})
	return out, err
}

// CurrentPeriods — returns current daily and weekly period keys (UTC+3)
func CurrentPeriods() (daily, weekly string) {
	now := time.Now().In(utc3)
	return dailyPeriodKey(now), weeklyPeriodKey(now)
}
