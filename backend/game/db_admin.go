package game

// db_admin.go — powers the admin panel's Database tab: lists every known
// key-prefix category with a live count, and lets the admin clear a
// specific category on demand. Deliberately whitelist-based (dbCategories
// below) rather than a raw key browser — showing every individual DB key
// to the admin panel isn't useful and some values (replay logs, auth
// tokens) are large/sensitive; category counts + a targeted clear button
// covers what the admin panel actually needs.

import (
	"fmt"

	badger "github.com/dgraph-io/badger/v4"
)

type dbCategoryDef struct {
	Key         string // stable id used in clear requests
	Prefix      string // raw BadgerDB key prefix
	Label       string
	Description string
	Dangerous   bool // admin UI shows an extra-scary confirmation
}

var dbCategories = []dbCategoryDef{
	{"sessions", "s:", "Game Sessions",
		"Replay sessions — scores, quest totals, replay logs. Clearing loses score/quest history permanently.", true},
	{"seeds", "seed:", "Seed Dedup Index",
		"Used-seed markers (prevents resubmitting the same seed). Safe to clear — sessions are untouched.", false},
	{"auth_tokens", "auth:", "Auth Tokens",
		"Active login sessions. Clearing logs out every currently signed-in player.", true},
	{"nicknames", "nick:", "Nicknames",
		"Player display names.", true},
	{"wallets", "wallet:", "Wallet Registrations",
		"Player Nimiq wallet address links (used to send NIM rewards).", true},
	{"pending_rewards", "reward:", "NIM Reward Queue",
		"Pending and sent NIM payout records. Do not clear unless you're certain — this is real money bookkeeping.", true},
	{"daily_caps", "dailycap:", "Daily Earn Caps",
		"Per-player daily NIM-earn tracking. Safe to reset.", false},
	{"player_quests", "pq:", "Player Daily Quests",
		"Today's assigned quest set per player. Safe to reset — regenerates on next request.", false},
	{"quest_progress", "qp:", "Quest Progress",
		"Per-quest progress counters. Safe to reset.", false},
	{"client_logs", "clog:", "Client Error Logs",
		"Aggregated client-side error/warn logs (also has its own Clear button on the Logs tab).", false},
	{"failed_replays", "failedreplay:", "Failed Replay Archive",
		"Replays that failed to simulate (timeout/crash) or had a score mismatch — also cleared by \"Remove All Replays\".", false},
	{"leaderboard_winners", "lb:winners:", "Leaderboard Winner Snapshots",
		"Recorded past-period winners (used for payout history).", true},
	{"app_config", "cfg:", "App Config",
		"Developer mode, update lock (active/inactive), leaderboard on/off. Clearing resets everything to the .env defaults.", true},
}

type DBCategory struct {
	Key         string `json:"key"`
	Prefix      string `json:"prefix"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Dangerous   bool   `json:"dangerous"`
	Count       int    `json:"count"`
}

// DatabaseOverview — live key count per known category.
func (s *Store) DatabaseOverview() []DBCategory {
	out := make([]DBCategory, 0, len(dbCategories))
	_ = s.db.View(func(txn *badger.Txn) error {
		for _, c := range dbCategories {
			opts := badger.DefaultIteratorOptions
			opts.PrefetchValues = false
			opts.Prefix = []byte(c.Prefix)
			it := txn.NewIterator(opts)
			count := 0
			for it.Rewind(); it.Valid(); it.Next() {
				count++
			}
			it.Close()
			out = append(out, DBCategory{
				Key: c.Key, Prefix: c.Prefix, Label: c.Label,
				Description: c.Description, Dangerous: c.Dangerous, Count: count,
			})
		}
		return nil
	})
	return out
}

// ClearDBCategory — deletes every key under the named category's prefix.
func (s *Store) ClearDBCategory(categoryKey string) (int, error) {
	for _, c := range dbCategories {
		if c.Key == categoryKey {
			return s.clearPrefix(c.Prefix)
		}
	}
	return 0, fmt.Errorf("unknown database category: %q", categoryKey)
}
