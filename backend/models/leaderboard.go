package models

// LeaderboardPrizes — prize amounts (NIM) for a period
type LeaderboardPrizes struct {
	First  float64 `json:"first"`
	Second float64 `json:"second"`
	Third  float64 `json:"third"`
}

// LeaderboardConfig — prize configuration adjustable by admin
type LeaderboardConfig struct {
	Daily  LeaderboardPrizes `json:"daily"`
	Weekly LeaderboardPrizes `json:"weekly"`
}

// DefaultLeaderboardConfig — default prize amounts
func DefaultLeaderboardConfig() LeaderboardConfig {
	return LeaderboardConfig{
		Daily: LeaderboardPrizes{
			First:  100,
			Second: 50,
			Third:  30,
		},
		Weekly: LeaderboardPrizes{
			First:  500,
			Second: 300,
			Third:  100,
		},
	}
}

// WinnerEntry — winner for a given period
type WinnerEntry struct {
	Rank        int     `json:"rank"`
	PlayerID    string  `json:"player_id"`
	Nickname    string  `json:"nickname"`
	ServerScore int     `json:"server_score"`
	Char        int     `json:"char"`
	PrizeNIM    float64 `json:"prize_nim"`
	SessionID   string  `json:"session_id"`
}

// PeriodWinners — bir periyodun kazananlar listesi
type PeriodWinners struct {
	Period    string        `json:"period"`      // "2026-06-17" (daily) or "2026-W25" (weekly)
	PeriodType string       `json:"period_type"` // "daily" | "weekly"
	Winners   []WinnerEntry `json:"winners"`
	ClosedAt  int64         `json:"closed_at"`
}
