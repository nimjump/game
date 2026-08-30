package models

// profile.go — the "profile card" payload shown when a player taps another
// player's row on the leaderboard or VS leaderboard (same schema, same panel,
// both entry points — see LeaderboardPanel.gd / VSPanel.gd ->
// ProfileCardPanel.gd on the client).
//
// This is intentionally free of any level/XP system: the card shows only
// aggregate stats and (optionally) leaderboard rank.

// ProfileMatch — one row of a profile card's "recent matches" list.
// HasReplay mirrors game.LBEntry's same field (Log != "") — the client only
// shows a "watch replay" button on a match when this is true, same as
// StatsPanel's recent-games list and the leaderboard already do.
type ProfileMatch struct {
	SessionID   string `json:"session_id"`
	Score       int    `json:"score"`
	Kills       int    `json:"kills"`
	Char        int    `json:"char"`
	Flagged     bool   `json:"flagged"`
	HasReplay   bool   `json:"has_replay"`
	SubmittedAt int64  `json:"submitted_at"`
}

// ProfileCard — full payload for the clickable profile popup. The same shape
// is returned regardless of whether it was opened from the general
// leaderboard or the VS leaderboard (one schema, one panel on the client).
// Viewing ANOTHER player's card requires a valid auth session (see
// handleProfile) — no anonymous/unauthenticated access.
type ProfileCard struct {
	PlayerID       string         `json:"player_id"`
	Nickname       string         `json:"nickname"`
	GamesPlayed    int            `json:"games_played"`
	TotalKills     int            `json:"total_kills"`
	PlayTimeTicks  int            `json:"play_time_ticks"` // client divides by 60 for seconds
	LoginStreak    int            `json:"login_streak"`
	LastSeen       int64          `json:"last_seen"`
	BestScore      int            `json:"best_score"`
	DailyRank      int            `json:"daily_rank"`  // 0 = unranked in today's daily leaderboard
	WeeklyRank     int            `json:"weekly_rank"` // 0 = unranked in this week's leaderboard
	RecentMatches  []ProfileMatch `json:"recent_matches"`
}
