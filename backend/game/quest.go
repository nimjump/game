package game

import (
	"crypto/md5"
	"encoding/json"
	"fmt"
	"log"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

// today returns today's date in "2006-01-02" format (UTC+3).
func today() string {
	return time.Now().In(utc3).Format("2006-01-02")
}

// DailyQuests returns today's 5 daily quests for a specific player.
// Each player gets a unique, deterministic set based on playerID + day.
// Use GetOrCreatePlayerQuests for the canonical per-player set stored in DB.
func DailyQuests(playerID string) []models.Quest {
	day := today()
	quests := make([]models.Quest, 5)
	for i := range quests {
		quests[i] = generateQuest(playerID, day, i)
	}
	return quests
}

// questPool is the full pool of quest templates used by generateQuest.
// Each entry: (type, target, description, rewardNIM)
type questTemplate struct {
	qtype   models.QuestType
	target  int
	desc    string
	reward  float64
}

var questPool = []questTemplate{
	// ── Score / progress ───────────────────────────────────────────
	{models.QuestScore,        1500,  "Score 1500 points in a single match",             10.0},
	{models.QuestScore,        2500,  "Score 2500 points in a single match",             15.0},
	{models.QuestScore,        4000,  "Score 4000 points in a single match",             20.0},
	{models.QuestTotalScore,   5000,  "Earn 5000 total points today",                    12.0},
	{models.QuestTotalScore,   10000, "Earn 10 000 total points today",                  18.0},

	// ── Match count ────────────────────────────────────────────────
	{models.QuestGames,        3,     "Play 3 matches today (300+ points each)",          8.0},
	{models.QuestGames5,       5,     "Play 5 matches today (300+ points each)",         12.0},
	{models.QuestGames10,      10,    "Play 10 matches today (300+ points each) — keep the streak alive!", 20.0},

	// ── Enemy kills ────────────────────────────────────────────────
	{models.QuestKills,        10,    "Kill 10 enemies in a single match",                8.0},
	{models.QuestKills,        20,    "Kill 20 enemies in a single match",               12.0},
	{models.QuestKills,        30,    "Kill 30 enemies in a single match",               18.0},
	{models.QuestKillsTotal,   40,    "Kill 40 enemies across all matches today",        12.0},
	{models.QuestKillsTotal,   80,    "Kill 80 enemies across all matches today",        18.0},
	{models.QuestMosquito,     5,     "Stomp 5 mosquitoes",                               8.0},
	{models.QuestMosquito,     10,    "Stomp 10 mosquitoes",                             12.0},
	{models.QuestFlying,       8,     "Kill 8 flying enemies",                           10.0},
	{models.QuestFlying,       15,    "Kill 15 flying enemies",                          15.0},
	{models.QuestNoDmgKill,    3,     "Kill 3 enemies without taking any damage",        10.0},
	{models.QuestNoDmgKill,    6,     "Kill 6 enemies without taking any damage",        15.0},
	{models.QuestMultiKill,    3,     "Kill 3 different enemy types in one match",       12.0},

	// ── Platform / movement ────────────────────────────────────────
	{models.QuestAltitude,     2000,  "Reach score 2000 in a single match",              12.0},
	{models.QuestAltitude,     3500,  "Reach score 3500 in a single match",              16.0},
	{models.QuestNoHit,        1000,  "Reach 1000 points without taking any damage",     15.0},
	{models.QuestSpeedrun,     1,     "Reach 1000 points in under 90 seconds",           15.0},

	// ── Coins / items ─────────────────────────────────────────────
	{models.QuestCoinTotal,    10,    "Collect 10 coins today",                           8.0},
	{models.QuestCoinTotal,    25,    "Collect 25 coins today",                          12.0},
	{models.QuestCoinMatch,    5,     "Collect 5 coins in one match",                     8.0},
	{models.QuestCoinMatch,    8,     "Collect 8 coins in one match",                    12.0},
	{models.QuestGoldenCarot,  2,     "Collect 2 golden carrots in one match",           12.0},
	{models.QuestGoldenCarot,  4,     "Collect 4 golden carrots in one match",           18.0},
	{models.QuestItemHunter,   5,     "Pick up 5 different item types today",            12.0},
	{models.QuestPowerup,      3,     "Use 3 powerups in one match",                     10.0},
	{models.QuestPowerup,      6,     "Use 6 powerups in one match",                     15.0},
	{models.QuestNoCoins,      1,     "Reach 500+ points without collecting any coins",  12.0},

	// ── Style / challenge ─────────────────────────────────────────
	{models.QuestStreak,       3,     "Pass 500 points in 3 separate matches today",     15.0},
	{models.QuestPacifist,     500,   "Reach 500 points without killing a single enemy", 15.0},
	{models.QuestNoDmgMatch,   1,     "Complete a match with min 500 points and no damage taken", 20.0},
	{models.QuestHighJumpOnly, 200,   "Reach height 200 using only jumps (no powerups)", 15.0},
	{models.QuestMirrorRun,    1,     "Score 500+ points during a mirror-debuff run",    15.0},
}

// generateQuest deterministically picks a quest for a specific player+day+slot.
func generateQuest(playerID, day string, idx int) models.Quest {
	h    := md5.Sum([]byte(fmt.Sprintf("%s:%s:%d", playerID, day, idx)))
	seed := int(h[0])<<8 | int(h[1])

	offset := (idx * (len(questPool) / 5)) % len(questPool)
	t      := questPool[(seed+offset)%len(questPool)]

	ph   := md5.Sum([]byte(playerID))
	phex := fmt.Sprintf("%x", ph[:3]) // 6 hex chars
	id   := fmt.Sprintf("q_%s_%s_%d", day, phex, idx)
	return models.Quest{
		ID:          id,
		Type:        t.qtype,
		Description: t.desc,
		Target:      t.target,
		RewardNIM:   t.reward,
		Day:         day,
	}
}

// playerQuestsKey returns the DB key for a player's daily quest list.
func playerQuestsKey(playerID, day string) []byte {
	return []byte(fmt.Sprintf("pq:%s:%s", playerID, day))
}

// GetOrCreatePlayerQuests returns the player's quest set for today.
func (s *Store) GetOrCreatePlayerQuests(playerID string) ([]models.Quest, error) {
	day := today()
	key := playerQuestsKey(playerID, day)

	var existing []models.Quest
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(key)
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &existing)
		})
	})
	if err == nil && len(existing) == 5 {
		return existing, nil
	}
	if err != nil && err != badger.ErrKeyNotFound {
		return nil, fmt.Errorf("quest DB read error: %w", err)
	}

	quests := DailyQuests(playerID)

	data, _ := json.Marshal(quests)
	_ = s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(
			badger.NewEntry(key, data).WithTTL(48 * time.Hour),
		)
	})
	log.Printf("[QUESTS] generated new set for player=%s day=%s", playerID, day)
	return quests, nil
}

// ── Quest Store ───────────────────────────────────────────────────────────────

func questProgressKey(playerID, questID string) []byte {
	return []byte(fmt.Sprintf("qp:%s:%s", playerID, questID))
}

// GetProgress returns a player's progress on a single quest.
func (s *Store) GetProgress(playerID, questID string) (*models.PlayerQuestProgress, error) {
	var p models.PlayerQuestProgress
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(questProgressKey(playerID, questID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &p) })
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &p, err
}

// SaveProgress persists quest progress.
func (s *Store) SaveProgress(p *models.PlayerQuestProgress) error {
	data, _ := json.Marshal(p)
	ttl := 48 * time.Hour // keep for 2 days
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(
			badger.NewEntry(questProgressKey(p.PlayerID, p.QuestID), data).WithTTL(ttl),
		)
	})
}

// UpdateQuestProgressFromReplay updates a player's daily quest progress
// based on the counters extracted from a server-side replay simulation.
func (s *Store) UpdateQuestProgressFromReplay(playerID string, result *GodotReplayResult, quests []models.Quest) {
	if playerID == "" || !result.QuestHasResult {
		return
	}
	day := today()

	for _, q := range quests {
		prog, _ := s.GetProgress(playerID, q.ID)
		if prog == nil {
			prog = &models.PlayerQuestProgress{
				PlayerID:  playerID,
				QuestID:   q.ID,
				Day:       day,
				Target:    q.Target,
				RewardNIM: q.RewardNIM,
			}
		}
		if prog.ClaimedAt > 0 {
			continue
		}

		var newProgress int
		switch q.Type {

		// ── Score ────────────────────────────────────────────────────────
		case models.QuestScore:
			newProgress = max(prog.Progress, result.ServerScore)
		case models.QuestTotalScore:
			newProgress = prog.Progress + result.ServerScore

		// ── Match count — only counts matches that scored at least 300 ─────
		case models.QuestGames, models.QuestGames5, models.QuestGames10:
			newProgress = prog.Progress
			if result.ServerScore >= 300 {
				newProgress = prog.Progress + 1
			}

		// ── Enemy kills ───────────────────────────────────────────────────
		case models.QuestKills:
			newProgress = max(prog.Progress, result.QuestKills)
		case models.QuestKillsTotal:
			newProgress = prog.Progress + result.QuestKills
		case models.QuestMosquito:
			newProgress = prog.Progress + result.QuestMosquitoKills
		case models.QuestFlying:
			newProgress = max(prog.Progress, result.QuestFlyingKills)
		case models.QuestNoDmgKill:
			if !result.QuestTookDamage {
				newProgress = max(prog.Progress, result.QuestKills)
			} else {
				newProgress = max(prog.Progress, result.QuestKillsNoDmg)
			}
		case models.QuestMultiKill:
			newProgress = max(prog.Progress, result.QuestEnemyTypes)

		// ── Platform / movement ───────────────────────────────────────────
		case models.QuestAltitude:
			// Bir maçta X skora ulaş (yükseklik yerine skor kontrolü)
			newProgress = max(prog.Progress, result.ServerScore)
		case models.QuestNoHit:
			// Hasar almadan 1000 puana ulaş kontrolü
			if !result.QuestTookDamage {
				newProgress = max(prog.Progress, result.ServerScore)
			} else {
				newProgress = prog.Progress
			}
		case models.QuestSpeedrun:
			if result.ServerScore >= 1000 && result.Ticks/60 <= 90 {
				newProgress = 1
			} else {
				newProgress = prog.Progress
			}

		// ── Coins / items ─────────────────────────────────────────────────
		case models.QuestCoinTotal:
			newProgress = prog.Progress + result.QuestCoins
		case models.QuestCoinMatch:
			newProgress = max(prog.Progress, result.QuestCoins)
		case models.QuestGoldenCarot:
			newProgress = max(prog.Progress, result.QuestGoldenCarrots)
		case models.QuestItemHunter:
			newProgress = max(prog.Progress, result.QuestItemTypes)
		case models.QuestPowerup:
			newProgress = max(prog.Progress, result.QuestPowerups)
		case models.QuestNoCoins:
			// Hiç altın toplamadan en az 500 puan yapmış mı kontrolü
			if result.QuestNoCoins && result.ServerScore >= 500 {
				newProgress = 1
			} else {
				newProgress = prog.Progress
			}

		// ── Style / challenge ─────────────────────────────────────────────
		case models.QuestStreak:
			// 3 ayrı maçta da ayrı ayrı 500 puanı geçme kontrolü (geçerse +1 ilerler, hedef 3)
			if result.ServerScore >= 500 {
				newProgress = prog.Progress + 1
			} else {
				newProgress = prog.Progress
			}
		case models.QuestPacifist:
			if result.QuestKills == 0 && result.ServerScore >= 500 {
				newProgress = 1
			} else {
				newProgress = prog.Progress
			}
		case models.QuestNoDmgMatch:
			// Hiç hasar almadan en az 500 puanla maçı bitirme kontrolü
			if !result.QuestTookDamage && result.ServerScore >= 500 {
				newProgress = 1
			} else {
				newProgress = prog.Progress
			}
		case models.QuestHighJumpOnly:
			if !result.QuestUsedPowerup {
				newProgress = max(prog.Progress, result.QuestHighestY)
			} else {
				newProgress = prog.Progress
			}
		case models.QuestMirrorRun:
			if result.QuestUsedMirror && result.ServerScore >= 500 {
				newProgress = 1
			} else {
				newProgress = prog.Progress
			}

		default:
			continue
		}

		if newProgress <= prog.Progress {
			continue
		}
		prog.Progress = newProgress
		if prog.Progress >= prog.Target && !prog.Completed {
			prog.Completed = true
			log.Printf("[QUEST_PROGRESS] player=%s quest=%s(%s) COMPLETED (%d/%d)",
				playerID, q.ID, q.Type, prog.Progress, prog.Target)
		}
		if err := s.SaveProgress(prog); err != nil {
			log.Printf("[QUEST_PROGRESS] save error player=%s quest=%s: %v", playerID, q.ID, err)
		}
	}
}

// AllProgress returns all of a player's quest progress entries for today.
func (s *Store) AllProgress(playerID, day string) []models.PlayerQuestProgress {
	out := []models.PlayerQuestProgress{}
	prefix := []byte(fmt.Sprintf("qp:%s:q_%s_", playerID, day))
	_ = s.db.View(func(txn *badger.Txn) error {
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()
		for it.Seek(prefix); it.ValidForPrefix(prefix); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var p models.PlayerQuestProgress
				if err := json.Unmarshal(v, &p); err == nil {
					out = append(out, p)
				}
				return nil
			})
		}
		return nil
	})
	return out
}