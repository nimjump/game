package models

// QuestType — quest types
type QuestType string

const (
	// ── Score / progress ──────────────────────────────────────────────
	QuestScore        QuestType = "score"        // reach X points in one match
	QuestTotalScore   QuestType = "totalscore"   // earn X total points today

	// ── Match count ───────────────────────────────────────────────────
	QuestGames        QuestType = "games"        // play X matches today
	QuestGames5       QuestType = "games5"       // play 5 matches today
	QuestGames10      QuestType = "games10"      // play 10 matches today

	// ── Enemy kills ───────────────────────────────────────────────────
	QuestKills        QuestType = "kills"        // kill X enemies in one match
	QuestKillsTotal   QuestType = "killstotal"   // kill X enemies today (cumulative)
	QuestMosquito     QuestType = "mosquito"     // stomp X mosquitoes
	QuestFlying       QuestType = "flying"       // kill X flying enemies
	QuestNoDmgKill    QuestType = "nodmgkill"    // kill X enemies without taking damage
	QuestMultiKill    QuestType = "multikill"    // kill 3 different enemy types in one match

	// ── Platform / movement ──────────────────────────────────────────
	QuestAltitude     QuestType = "altitude"     // reach score X in one match
	QuestNoHit        QuestType = "nohit"        // reach 1000 points without taking damage
	QuestSpeedrun     QuestType = "speedrun"     // reach 1000 points in under 90 s

	// ── Coins / items ─────────────────────────────────────────────────
	QuestCoinTotal    QuestType = "cointotal"    // collect X coins total today
	QuestCoinMatch    QuestType = "coinmatch"    // collect X coins in one match
	QuestGoldenCarot  QuestType = "goldencarot"  // collect X golden carrots in one match
	QuestItemHunter   QuestType = "itemhunter"   // collect 5 different item types today
	QuestNoCoins      QuestType = "nocoins"      // reach min 500 points without collecting any coins
	QuestPowerup      QuestType = "powerup"      // use X powerups in one match

	// ── Style / challenge ─────────────────────────────────────────────
	QuestStreak       QuestType = "streak"       // pass 500 points in 3 separate matches today
	QuestPacifist     QuestType = "pacifist"     // reach 500 points without killing any enemy
	QuestNoDmgMatch   QuestType = "nodmgmatch"   // complete a match with min 500 points and no damage taken
	QuestHighJumpOnly QuestType = "highjumponly" // reach X height using only jump (no powerups)
	QuestMirrorRun    QuestType = "mirrorrun"    // play a match with mirror debuff active
)

// Quest — definition of a daily quest
type Quest struct {
	ID          string    `json:"id"`
	Type        QuestType `json:"type"`
	Description string    `json:"description"`
	Target      int       `json:"target"`       // target value
	RewardNIM   float64   `json:"reward_nim"`   // NIM reward (e.g. 0.01)
	Day         string    `json:"day"`          // "2026-06-12" format
}

// PlayerQuestProgress — tracks a player's quest progress
type PlayerQuestProgress struct {
	PlayerID  string  `json:"player_id"`
	QuestID   string  `json:"quest_id"`
	Day       string  `json:"day"`
	Progress  int     `json:"progress"`   // mevcut ilerleme
	Target    int     `json:"target"`
	Completed bool    `json:"completed"`
	ClaimedAt int64   `json:"claimed_at,omitempty"` // set when NIM sent
	RewardNIM float64 `json:"reward_nim"`
}