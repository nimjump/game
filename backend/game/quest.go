package game

import (
	"crypto/md5"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

// claimingQuests guards against the same (playerID, questID) being claimed
// twice concurrently. handleQuestClaim/handleQuestClaimAll do a plain
// read-Completed/ClaimedAt-then-write with no transactional check-and-set,
// so two requests racing for the same quest (double-click, retried request,
// two tabs) could both read ClaimedAt==0 before either writes it, and both
// would go on to QueueReward — a real double-payout. Same class of bug as
// the reward-send double-dispatch guarded by sendingRewards in nimiq.go;
// this is the equivalent lock for the claim path. Key: playerID+"|"+questID.
var claimingQuests sync.Map

// TryClaimQuestLock claims the in-process lock for (playerID, questID).
// Returns ok=false if another claim for the same pair is already in flight —
// callers should treat that as "already being claimed" and bail out without
// touching the DB or queuing a reward. On success, callers MUST call the
// returned release() when done (success or failure) via defer.
func TryClaimQuestLock(playerID, questID string) (release func(), ok bool) {
	key := playerID + "|" + questID
	if _, already := claimingQuests.LoadOrStore(key, struct{}{}); already {
		return func() {}, false
	}
	return func() { claimingQuests.Delete(key) }, true
}

// today returns today's date in "2006-01-02" format (UTC+3).
func today() string {
	return time.Now().In(utc3).Format("2006-01-02")
}

// DailyQuests returns today's 5 daily quests for a specific player.
// Each player gets a unique, deterministic set based on playerID + day.
// Use GetOrCreatePlayerQuests for the canonical per-player set stored in DB.
//
// Store method (not a free function) because reward amounts can be
// admin-overridden (AppConfig.QuestRewardOverrides, see
// SetQuestRewardOverride below) and that override lives in BadgerDB.
func (s *Store) DailyQuests(playerID string) []models.Quest {
	day := today()
	cfg := s.GetAppConfig()
	quests := make([]models.Quest, 5)
	// used — pool indices already assigned to an earlier slot in THIS same
	// 5-quest set. Passed into generateQuest so slot i+1 knows what slot i
	// already took. See generateQuest's BUG FIX comment: without this, two
	// of the 5 slots could independently hash to the same questPool index
	// and the player would see the exact same quest twice in one day.
	used := map[int]bool{}
	for i := range quests {
		quests[i] = generateQuest(playerID, day, i, cfg.QuestRewardOverrides, cfg.QuestTargetOverrides, used)
	}
	return quests
}

// questPoolKey — the AppConfig override map key for a questPool entry,
// identified by its POSITION in the pool (e.g. "idx:7").
//
// BUG FIX: this used to be keyed by (qtype, target) — e.g. "score:1500" —
// which broke the moment an admin could edit the target itself: changing a
// template's target from 1500 to 1800 silently orphaned any existing reward
// override (still saved under the old "score:1500" key, never looked up
// again since the pool entry now computes "score:1800"). Keying by pool
// index instead makes target and reward overrides for the same template
// independent of each other and of the current target value. questPool is a
// fixed, hand-written slice (not persisted data), so index stability only
// requires not reordering/removing entries in source — reordering the slice
// literal would need re-mapping saved overrides, same as before.
func questPoolKey(idx int) string {
	return fmt.Sprintf("idx:%d", idx)
}

// QuestPoolEntry — one questPool template plus its admin-override status,
// for the admin panel's quest-reward/target editor.
type QuestPoolEntry struct {
	Idx              int     `json:"idx"` // stable key for override calls — see questPoolKey
	QuestType        string  `json:"quest_type"`
	Target           int     `json:"target"`         // effective — override if set, else default
	DefaultTarget    int     `json:"default_target"`
	Description      string  `json:"description"`
	DefaultRewardNIM float64 `json:"default_reward_nim"`
	RewardNIM        float64 `json:"reward_nim"` // effective — override if set, else default
	Overridden       bool    `json:"overridden"`        // reward overridden
	TargetOverridden bool    `json:"target_overridden"`
}

// QuestPoolWithOverrides — every template in questPool with its current
// effective reward AND target (admin override if present, else the
// hardcoded default for each independently).
func (s *Store) QuestPoolWithOverrides() []QuestPoolEntry {
	cfg := s.GetAppConfig()
	rewardOverrides := cfg.QuestRewardOverrides
	targetOverrides := cfg.QuestTargetOverrides
	out := make([]QuestPoolEntry, 0, len(questPool))
	for i, t := range questPool {
		key := questPoolKey(i)

		reward := t.reward
		rewardOverridden := false
		if v, ok := rewardOverrides[key]; ok {
			reward = v
			rewardOverridden = true
		}

		target := t.target
		targetOverridden := false
		if v, ok := targetOverrides[key]; ok {
			target = v
			targetOverridden = true
		}

		out = append(out, QuestPoolEntry{
			Idx:              i,
			QuestType:        string(t.qtype),
			Target:           target,
			DefaultTarget:    t.target,
			Description:      t.desc,
			DefaultRewardNIM: t.reward,
			RewardNIM:        reward,
			Overridden:       rewardOverridden,
			TargetOverridden: targetOverridden,
		})
	}
	return out
}

// SetQuestRewardOverride — admin-triggered. Sets (or, with rewardNIM == nil,
// clears) the NIM reward for the questPool entry at poolIdx.
func (s *Store) SetQuestRewardOverride(poolIdx int, rewardNIM *float64) error {
	if poolIdx < 0 || poolIdx >= len(questPool) {
		return fmt.Errorf("no quest template at idx=%d", poolIdx)
	}
	cfg := s.GetAppConfig()
	if cfg.QuestRewardOverrides == nil {
		cfg.QuestRewardOverrides = map[string]float64{}
	}
	key := questPoolKey(poolIdx)
	if rewardNIM == nil {
		delete(cfg.QuestRewardOverrides, key)
	} else {
		cfg.QuestRewardOverrides[key] = *rewardNIM
	}
	return s.SaveAppConfig(cfg)
}

// SetQuestTargetOverride — admin-triggered. Sets (or, with target == nil,
// clears) the goal number for the questPool entry at poolIdx (e.g. change
// "score:1500" template to require 1800). Independent of the reward
// override — see questPoolKey's comment for why they no longer share a key.
func (s *Store) SetQuestTargetOverride(poolIdx int, target *int) error {
	if poolIdx < 0 || poolIdx >= len(questPool) {
		return fmt.Errorf("no quest template at idx=%d", poolIdx)
	}
	if target != nil && *target <= 0 {
		return fmt.Errorf("target must be > 0")
	}
	cfg := s.GetAppConfig()
	if cfg.QuestTargetOverrides == nil {
		cfg.QuestTargetOverrides = map[string]int{}
	}
	key := questPoolKey(poolIdx)
	if target == nil {
		delete(cfg.QuestTargetOverrides, key)
	} else {
		cfg.QuestTargetOverrides[key] = *target
	}
	return s.SaveAppConfig(cfg)
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
// rewardOverrides/targetOverrides are AppConfig.QuestRewardOverrides /
// QuestTargetOverrides (either may be nil — just means no admin override of
// that kind is active, every template uses its hardcoded default).
func generateQuest(playerID, day string, idx int, rewardOverrides map[string]float64, targetOverrides map[string]int, used map[int]bool) models.Quest {
	h    := md5.Sum([]byte(fmt.Sprintf("%s:%s:%d", playerID, day, idx)))
	seed := int(h[0])<<8 | int(h[1])

	offset  := (idx * (len(questPool) / 5)) % len(questPool)
	poolIdx := (seed + offset) % len(questPool)

	// BUG FIX: seed is independent per idx (idx is part of the hash input),
	// so with 39 pool entries and 5 slots there was ~23% chance (birthday
	// paradox) that two slots landed on the same poolIdx — same quest type,
	// target, and description assigned twice in one day's set of 5 (only
	// the quest ID's idx-suffix differed, so the player just saw a visible
	// duplicate). Deterministically probe forward to the next free pool
	// slot instead of allowing a repeat within this player+day's set.
	for used[poolIdx] {
		poolIdx = (poolIdx + 1) % len(questPool)
	}
	used[poolIdx] = true

	t   := questPool[poolIdx]
	key := questPoolKey(poolIdx)

	reward := t.reward
	if v, ok := rewardOverrides[key]; ok {
		reward = v
	}
	target := t.target
	if v, ok := targetOverrides[key]; ok {
		target = v
	}

	ph   := md5.Sum([]byte(playerID))
	phex := fmt.Sprintf("%x", ph[:3]) // 6 hex chars
	id   := fmt.Sprintf("q_%s_%s_%d", day, phex, idx)
	return models.Quest{
		ID:          id,
		Type:        t.qtype,
		Description: t.desc,
		Target:      target,
		RewardNIM:   reward,
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

	quests := s.DailyQuests(playerID)

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
