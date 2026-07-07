package game

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const (
	keyLBConfig   = "lb:config"
	keyLBWinners  = "lb:winners:" // prefix + period key (e.g. "2026-06-17" or "2026-W25")
	keyLBResetPfx = "lb:reset:"   // prefix + periodType ("daily" / "weekly")
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

// ── Admin reset ───────────────────────────────────────────────────────────────
//
// "Reset the daily/weekly leaderboard" doesn't delete any session data —
// scores, replays, alltime standings, and payout history are all left
// alone. Instead it just records the moment the admin clicked reset,
// scoped to whatever day/week is currently open. periodBoundsForType then
// pulls the query window's start forward to that moment, so anything
// submitted before the click drops off the daily/weekly board while
// staying fully intact everywhere else. When the period rolls over
// naturally (next day / next ISO week), the marker's period no longer
// matches the new current period and it's simply ignored — no cron job or
// cleanup needed to "undo" it.

type lbResetMarker struct {
	Period string `json:"period"` // the day/week key this reset applies to
	Ts     int64  `json:"ts"`     // reset moment (Unix seconds)
}

func lbResetKey(periodType string) []byte {
	return []byte(keyLBResetPfx + periodType)
}

// SetLeaderboardReset marks "now" as the cutoff for the CURRENT day (or
// week)'s leaderboard. periodType must be "daily" or "weekly".
//
// It ALSO marks the current period as already-paid (see MarkPeriodPaid /
// keyLBPaidPfx). This is required, not optional: the reset marker only
// affects what the admin/API READS (periodBoundsForType hides pre-reset
// scores), but the background payout loop (StartLeaderboardPayoutLoop /
// PayWinnersForPeriod) computes winners from the RAW, unfiltered scores —
// it never looked at the reset marker at all. Without this, an admin
// reset wiped the leaderboard *view* while the wiped-out scores could
// still be paid out from under it once the period closed. Marking the
// period paid up front makes PayWinnersForPeriod's `IsPeriodPaid` guard
// short-circuit to a no-op (0 winners, no rewards queued) for the period
// being reset, so a reset truly means "these plays don't count" — for
// display AND for payout — with no way to reopen it once the button is
// pressed.
func (s *Store) SetLeaderboardReset(periodType string) (string, error) {
	daily, weekly := CurrentPeriods()
	period := daily
	if periodType == "weekly" {
		period = weekly
	}
	marker := lbResetMarker{Period: period, Ts: time.Now().Unix()}
	data, err := json.Marshal(marker)
	if err != nil {
		return period, err
	}
	err = s.db.Update(func(txn *badger.Txn) error {
		if setErr := txn.Set(lbResetKey(periodType), data); setErr != nil {
			return setErr
		}
		if setErr := txn.Set(lbPaidKey(period), []byte("1")); setErr != nil {
			return setErr
		}
		// Drop any winners snapshot already taken for this period (e.g. from
		// an earlier manual "pay winners" click before the reset) so nothing
		// stale is left for PayWinnersForPeriod to reuse via GetWinners.
		delErr := txn.Delete(winnerKey(period))
		if delErr != nil && delErr != badger.ErrKeyNotFound {
			return delErr
		}
		return nil
	})
	return period, err
}

// getLeaderboardReset — the active reset marker for periodType, if any.
func (s *Store) getLeaderboardReset(periodType string) *lbResetMarker {
	var m lbResetMarker
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(lbResetKey(periodType))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &m)
		})
	})
	if err != nil {
		return nil
	}
	return &m
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

// periodBoundsForType — returns start/end Unix timestamps for a period,
// resolving an empty `period` to the CURRENT day/week instead of skipping
// filtering entirely.
//
// BUG FIX: previously, callers (GetLeaderboardPaged / RankMapForPeriod) did:
//
//	if periodType != "alltime" && period != "" { startTs, endTs = periodBounds(period) }
//
// so an empty `period` string left startTs at 0, and the downstream filter
// (`if startTs > 0 && ...`) never ran at all — a "daily" request silently
// became "alltime". This is why the daily leaderboard was showing scores
// from the whole week (and beyond): any call site that forgot to pre-fill
// `period` (e.g. the admin players-list rank lookup) fell through to
// unfiltered data. Now the empty case is resolved to a real window up
// front, so every caller gets correctly bounded results regardless of
// whether it remembered to pass `period`.
//
// It also applies an admin-triggered reset marker (see SetLeaderboardReset
// below): if the resolved period matches the period the marker was set
// for, the window's start is pulled forward to the reset moment, so
// scores submitted before the reset stop counting. Once the period rolls
// over naturally, the marker's period no longer matches and it's ignored.
func (s *Store) periodBoundsForType(periodType, period string) (int64, int64) {
	if periodType == "alltime" {
		return 0, 0
	}
	if period == "" {
		daily, weekly := CurrentPeriods()
		if periodType == "weekly" {
			period = weekly
		} else {
			period = daily
		}
	}
	start, end := periodBounds(period)
	if m := s.getLeaderboardReset(periodType); m != nil && m.Period == period && m.Ts > start {
		start = m.Ts
	}
	return start, end
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

// RankMapForPeriod computes every ranked player's position for a given
// period in a single pass over all sessions. Used by the admin players list,
// which needs a rank for potentially many players at once — calling
// GetLeaderboardPaged once per player would re-scan+re-sort every session
// for each row; this does the scan/sort once and returns a playerID→rank
// lookup map instead. Applies the exact same filtering rules as
// GetLeaderboardPaged (flagged/unverified/pending sessions excluded, one
// best score per player) so ranks always agree with the real leaderboard.
// len(map) is also the total number of ranked players for that period.
func (s *Store) RankMapForPeriod(periodType, period string) map[string]int {
	all := s.List(false, 0)

	startTs, endTs := s.periodBoundsForType(periodType, period)

	best := map[string]models.Session{}
	for _, sess := range all {
		// (StatePending removed — no session is ever saved with that state,
		// every session is created as either Completed or Flagged at submit
		// time; ServerScore<=0 already excludes anything that never got a
		// real replay-verified score.)
		if sess.Flagged || sess.ServerScore <= 0 {
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
	for _, sess := range best {
		entries = append(entries, sess)
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].ServerScore > entries[j].ServerScore
	})

	ranks := make(map[string]int, len(entries))
	for i, e := range entries {
		pid := e.PlayerID
		if pid == "" {
			pid = e.SessionID
		}
		ranks[pid] = i + 1
	}
	return ranks
}

func (s *Store) GetLeaderboardPaged(periodType, period string, limit, offset int, selfPlayerID string) ([]LBEntry, error) {
	all := s.List(false, 0)

	startTs, endTs := s.periodBoundsForType(periodType, period)

	// Find best score per player
	best := map[string]models.Session{}
	for _, sess := range all {
		// (StatePending removed — no session is ever saved with that state,
		// every session is created as either Completed or Flagged at submit
		// time; ServerScore<=0 already excludes anything that never got a
		// real replay-verified score.)
		if sess.Flagged || sess.ServerScore <= 0 {
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
			if pid == "" {
				pid = e.SessionID
			}
			if pid == selfPlayerID {
				nick := ""
				if pn, pnerr := s.GetNickname(pid); pnerr == nil && pn != nil && pn.Nickname != "" {
					nick = pn.Nickname
				}
				if nick == "" {
					nick = e.Nickname
				}
				if nick == "" {
					p := pid
					if len(p) > 8 {
						p = p[:8]
					}
					nick = p
				}
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
		if pid == "" {
			pid = e.SessionID
		}
		// Prefer PlayerNickname DB over session nickname
		nick := ""
		if pn, pnerr := s.GetNickname(pid); pnerr == nil && pn != nil && pn.Nickname != "" {
			nick = pn.Nickname
		}
		if nick == "" {
			nick = e.Nickname
		}
		if nick == "" {
			p := pid
			if len(p) > 8 {
				p = p[:8]
			}
			nick = p
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
				inPage = true
				break
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

// PreviousClosedPeriod — the most recently ENDED period key for the given
// type: yesterday for "daily", last ISO week for anything else (weekly).
// Used as the default in handleLeaderboardPayWinners so an omitted `period`
// pays out the period that just closed, not the one still in progress.
func PreviousClosedPeriod(periodType string) string {
	now := time.Now().In(utc3)
	if periodType == "weekly" {
		return weeklyPeriodKey(now.AddDate(0, 0, -7))
	}
	return dailyPeriodKey(now.AddDate(0, 0, -1))
}

// ── Automatic payout ────────────────────────────────────────────────────────
//
// Previously the ONLY way winners got paid was someone manually hitting
// POST /bj/leaderboard/pay-winners from the admin panel — there was no
// scheduler anywhere calling it. If nobody remembered to click it for a
// given day/week, that period's winners simply never got paid, silently,
// forever (no error, no missing-payout alert — the money just never left
// the queue because nothing ever asked for it). This adds a background
// loop that pays out each day/week automatically right after it closes.

const keyLBPaidPfx = "lb:paid:" // marks a period as "already paid out"

func lbPaidKey(period string) []byte { return []byte(keyLBPaidPfx + period) }

// IsPeriodPaid — has this period already been paid out?
func (s *Store) IsPeriodPaid(period string) bool {
	paid := false
	_ = s.db.View(func(txn *badger.Txn) error {
		_, err := txn.Get(lbPaidKey(period))
		paid = err == nil
		return nil
	})
	return paid
}

// MarkPeriodPaid — records that a period's payout has been processed, so
// the automatic loop (which checks every few minutes) and a manual admin
// retry never double-pay the same period.
func (s *Store) MarkPeriodPaid(period string) error {
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(lbPaidKey(period), []byte("1"))
	})
}

// PayWinnersForPeriod — computes (or reuses) the winners snapshot for the
// given period and queues NIM rewards for anyone with a non-zero prize.
// Idempotent per period via the lb:paid: marker: calling it twice for the
// same period (once from the automatic loop, once from an admin manual
// re-trigger) queues rewards only once. Returns how many winners were
// queued (0 without error if the period was already paid, or had no
// eligible winners).
func (s *Store) PayWinnersForPeriod(periodType, period string) (int, error) {
	if s.IsPeriodPaid(period) {
		return 0, nil
	}

	pw, err := s.GetWinners(period)
	if err != nil || pw == nil {
		pw, err = s.SnapshotWinners(periodType, period)
		if err != nil {
			return 0, err
		}
	}

	queued := 0
	for _, w := range pw.Winners {
		if w.PrizeNIM <= 0 {
			continue
		}
		reason := fmt.Sprintf("leaderboard:%s:%s:rank%d", periodType, period, w.Rank)
		if _, rerr := s.QueueReward(w.PlayerID, w.PrizeNIM, reason); rerr == nil {
			queued++
		} else {
			log.Printf("[LEADERBOARD_PAYOUT] QueueReward failed player=%s period=%s rank=%d: %v",
				w.PlayerID, period, w.Rank, rerr)
		}
	}

	// Mark paid even if queued==0 (e.g. nobody scored that period) so we
	// don't keep re-snapshotting the same empty period forever.
	if merr := s.MarkPeriodPaid(period); merr != nil {
		log.Printf("[LEADERBOARD_PAYOUT] failed to mark period=%s as paid: %v", period, merr)
	}
	return queued, nil
}

// StartLeaderboardPayoutLoop — runs in the background, checks every 15
// minutes whether yesterday's daily period and last week's weekly period
// have been paid, and pays them automatically if not. Call this once at
// startup next to StartCleanupLoop.
//
// 15 min (not exactly midnight) is deliberate: it's simpler and more
// robust than trying to fire exactly at the UTC+3 day/week boundary, and
// since payout is idempotent (lb:paid: marker) there's no harm in checking
// often — worst case, winners get paid a few minutes late.
func (s *Store) StartLeaderboardPayoutLoop() {
	go func() {
		s.checkAndPayClosedPeriods()
		ticker := time.NewTicker(15 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			s.checkAndPayClosedPeriods()
		}
	}()
}

func (s *Store) checkAndPayClosedPeriods() {
	dp := PreviousClosedPeriod("daily")
	if n, err := s.PayWinnersForPeriod("daily", dp); err != nil {
		log.Printf("[LEADERBOARD_PAYOUT] daily period=%s error: %v", dp, err)
	} else if n > 0 {
		log.Printf("[LEADERBOARD_PAYOUT] daily period=%s paid %d winners", dp, n)
	}

	wp := PreviousClosedPeriod("weekly")
	if n, err := s.PayWinnersForPeriod("weekly", wp); err != nil {
		log.Printf("[LEADERBOARD_PAYOUT] weekly period=%s error: %v", wp, err)
	} else if n > 0 {
		log.Printf("[LEADERBOARD_PAYOUT] weekly period=%s paid %d winners", wp, n)
	}
}

// CurrentPeriods — returns current daily and weekly period keys (UTC+3)
func CurrentPeriods() (daily, weekly string) {
	now := time.Now().In(utc3)
	return dailyPeriodKey(now), weeklyPeriodKey(now)
}
