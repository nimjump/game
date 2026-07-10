package handlers

// admin_players_list.go — GET /backend/admin/players
//
// Returns every player who has EVER played a session or set a nickname —
// previously this only listed players with a nickname record, which meant
// anyone who signed in and played without ever opening the "Display Name"
// overlay simply never showed up here at all (the tab could look almost
// empty even with plenty of real players). It's now built from the union of
// nickname records and distinct PlayerIDs seen in the session store.
//
// Each entry includes:
//   - player_id, nickname, set_at
//   - is_active: true if they have a non-expired auth token in DB
//   - token_expires_at: latest token expiry timestamp (if active)
//   - session_count: total game sessions
//   - last_seen: last session submitted_at timestamp
//   - quests_completed/quests_total: today's daily quest progress
//   - daily_rank/weekly_rank: leaderboard position (0 = not ranked this period)
//   - daily_cap: how much of today's NIM earn cap they've used

import (
	"time"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

func (s *Server) handleAdminPlayersList(ctx *fasthttp.RequestCtx) {
	now := time.Now().Unix()

	// Nickname records (some players never set one — see comment above).
	nicknames, err := s.Store.ListAllNicknames()
	if err != nil {
		writeErr(ctx, 500, "failed to list players")
		return
	}
	nickByID := make(map[string]*models.PlayerNickname, len(nicknames))
	for _, pn := range nicknames {
		nickByID[pn.PlayerID] = pn
	}

	// Active sessions: playerID → latest ExpiresAt (still in DB = token not expired)
	activeSessions, err := s.Store.ListActiveSessions()
	if err != nil {
		activeSessions = map[string]int64{}
	}

	// Session stats per player from in-memory scan — this pass also gives us
	// every distinct PlayerID that has ever actually played, regardless of
	// whether they ever set a nickname.
	type playerStat struct {
		count    int
		lastSeen int64
	}
	statMap := map[string]*playerStat{}
	allSessions := s.Store.List(false, 0)
	for _, sess := range allSessions {
		if sess.PlayerID == "" {
			continue
		}
		ts := sess.SubmittedAt
		if ts == 0 {
			ts = sess.CreatedAt
		}
		if e, ok := statMap[sess.PlayerID]; ok {
			e.count++
			if ts > e.lastSeen {
				e.lastSeen = ts
			}
		} else {
			statMap[sess.PlayerID] = &playerStat{count: 1, lastSeen: ts}
		}
	}

	// Union of "has a nickname" and "has played at least one session".
	allIDs := make(map[string]bool, len(nickByID)+len(statMap))
	for pid := range nickByID {
		allIDs[pid] = true
	}
	for pid := range statMap {
		allIDs[pid] = true
	}

	type playerBasic struct {
		playerID     string
		nickname     string
		registeredAt int64
		isActive     bool
		expiresAt    int64
		count        int
		lastSeen     int64
	}
	basics := make([]playerBasic, 0, len(allIDs))
	for pid := range allIDs {
		nickname := ""
		var registeredAt int64
		if pn := nickByID[pid]; pn != nil {
			nickname = pn.Nickname
			registeredAt = pn.SetAt
		}
		expiresAt := activeSessions[pid]
		stat := statMap[pid]
		count := 0
		var lastSeen int64
		if stat != nil {
			count = stat.count
			lastSeen = stat.lastSeen
		}
		basics = append(basics, playerBasic{
			playerID: pid, nickname: nickname, registeredAt: registeredAt,
			isActive: expiresAt > now, expiresAt: expiresAt, count: count, lastSeen: lastSeen,
		})
	}
	// Newest-registered first (nickname-less players, registeredAt=0, sort
	// last) — a stable default order so pagination pages don't shuffle
	// between requests.
	for i := 0; i < len(basics)-1; i++ {
		for j := i + 1; j < len(basics); j++ {
			if basics[j].registeredAt > basics[i].registeredAt {
				basics[i], basics[j] = basics[j], basics[i]
			}
		}
	}

	total := len(basics)
	limit, offset := queryPage(ctx, 50)
	if offset < 0 {
		offset = 0
	}
	end := total
	if offset > total {
		offset = total
	}
	if limit > 0 && offset+limit < total {
		end = offset + limit
	}
	pageBasics := basics[offset:end]

	// Leaderboard rank + today's quest completion + daily cap usage — these
	// need one DB read (or a map lookup) per player, so only compute them for
	// the page actually being returned, not the whole player base. The rank
	// maps themselves are still built once per period (not once per player)
	// regardless of page size — see RankMapForPeriod's doc comment.
	dailyPeriod, weeklyPeriod := game.CurrentPeriods()
	dailyRanks := s.Store.RankMapForPeriod("daily", dailyPeriod)
	weeklyRanks := s.Store.RankMapForPeriod("weekly", weeklyPeriod)
	today := time.Now().In(game.UTC3).Format("2006-01-02")

	// Lifetime NIM received per player — one full scan of "sent" rewards
	// (not per-player, per-page-row) so this stays a single pass regardless
	// of how many players are on the current page.
	sentRewards, _ := s.Store.ListRewards(string(models.RewardSent))
	nimReceived := make(map[string]float64, len(sentRewards))
	for _, r := range sentRewards {
		nimReceived[r.PlayerID] += r.AmountNIM
	}

	type playerOut struct {
		PlayerID        string             `json:"player_id"`
		Nickname        string             `json:"nickname"`
		RegisteredAt    int64              `json:"registered_at"` // nickname SetAt (0 if never set one)
		IsActive        bool               `json:"is_active"`
		TokenExpiresAt  int64              `json:"token_expires_at,omitempty"`
		SessionCount    int                `json:"session_count"`
		LastSeen        int64              `json:"last_seen,omitempty"`
		QuestsCompleted int                `json:"quests_completed"`
		QuestsTotal     int                `json:"quests_total"`
		DailyRank       int                `json:"daily_rank"`  // 0 = not ranked this period
		WeeklyRank      int                `json:"weekly_rank"` // 0 = not ranked this period
		DailyCap        game.DailyCapStats `json:"daily_cap"`
		TotalNIMReceived float64           `json:"total_nim_received"`
		Streak          int                `json:"streak"`
	}

	out := make([]playerOut, 0, len(pageBasics))
	for _, b := range pageBasics {
		// Today's quests: DailyQuests() is a pure/deterministic generator (no
		// DB write) — deliberately NOT using GetOrCreatePlayerQuests here,
		// which would persist a fresh quest set for every player merely from
		// loading this admin list, including players who haven't opened the
		// game in months.
		quests := s.Store.DailyQuests(b.playerID)
		progresses := s.Store.AllProgress(b.playerID, today)
		progByQuest := make(map[string]bool, len(progresses))
		for _, p := range progresses {
			if p.Completed {
				progByQuest[p.QuestID] = true
			}
		}
		completed := 0
		for _, q := range quests {
			if progByQuest[q.ID] {
				completed++
			}
		}

		out = append(out, playerOut{
			PlayerID:        b.playerID,
			Nickname:        b.nickname,
			RegisteredAt:    b.registeredAt,
			IsActive:        b.isActive,
			TokenExpiresAt:  b.expiresAt,
			SessionCount:    b.count,
			LastSeen:        b.lastSeen,
			QuestsCompleted: completed,
			QuestsTotal:     len(quests),
			DailyRank:       dailyRanks[b.playerID],
			WeeklyRank:      weeklyRanks[b.playerID],
			DailyCap:        s.Store.GetDailyCapStats(b.playerID),
			TotalNIMReceived: nimReceived[b.playerID],
			Streak:          s.Store.GetStreak(b.playerID).Count,
		})
	}

	writeJSON(ctx, 200, map[string]any{
		"total": total, "offset": offset, "limit": limit,
		"players": out,
	})
}
