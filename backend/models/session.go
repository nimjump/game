package models

import (
	"encoding/json"
	"fmt"
	"strconv"
)

type SessionState string

const (
	StateCompleted    SessionState = "completed"
	StateFlagged      SessionState = "flagged"
	StateReplayFailed SessionState = "replay_failed"
)

// Session - a NimJump game session record.
// Seed is stored as int64 in DB but serialized as string in JSON
// (JS float64 precision loss: 2^53 < max int64).
type Session struct {
	SessionID      string
	Seed           int64
	State          SessionState
	PlayerID       string // nimiq address
	Nickname       string // display name (first 8 chars)
	ClientScore    int
	ServerScore    int
	Ticks          int
	Char           int
	// GyroActive — was gyro tilt control active during this match. Drives the
	// gyro-only movement ramp (see game/scripts/Player.gd's
	// set_gyro_control_active doc comment) so server-side replay verification
	// applies the same ramp the client did when recording. Threaded through
	// exactly the same pipeline as Char.
	GyroActive     bool
	PlayerSeed     int64
	Log            string
	Flagged        bool
	Reason         string
	CreatedAt      int64
	SubmittedAt    int64
	TotalKills     int
	TotalPlatforms int
	ReplayError    string // non-empty when replay simulation failed after all retries
	// Encryption — single-use per session, stored in DB, never sent to client
	AESKey     string `json:"aes_key,omitempty"`
	AESIV      string `json:"aes_iv,omitempty"`
	HMACSecret string `json:"hmac_secret,omitempty"`
}

// sessionJSON is the wire format — seed as string to avoid JS float64 precision loss.
type sessionJSON struct {
	SessionID      string       `json:"session_id"`
	Seed           string       `json:"seed"`
	State          SessionState `json:"state"`
	PlayerID       string       `json:"player_id,omitempty"`
	Nickname       string       `json:"nickname,omitempty"`
	ClientScore    int          `json:"client_score"`
	ServerScore    int          `json:"server_score"`
	Ticks          int          `json:"ticks"`
	Char           int          `json:"char"`
	GyroActive     bool         `json:"gyro_active,omitempty"`
	PlayerSeed     string       `json:"player_seed,omitempty"`
	Log            string       `json:"log,omitempty"`
	Flagged        bool         `json:"flagged"`
	Reason         string       `json:"reason,omitempty"`
	CreatedAt      int64        `json:"created_at"`
	SubmittedAt    int64        `json:"submitted_at,omitempty"`
	TotalKills     int          `json:"total_kills,omitempty"`
	TotalPlatforms int          `json:"total_platforms,omitempty"`
	ReplayError    string       `json:"replay_error,omitempty"`
	AESKey         string       `json:"aes_key,omitempty"`
	AESIV          string       `json:"aes_iv,omitempty"`
	HMACSecret     string       `json:"hmac_secret,omitempty"`
}

// sessionLegacyJSON is for reading old DB records where seed was stored as number.
//
// NOTE: old records on disk may still contain a "game_started_at" key from
// before that field was removed from the Go model — json.Unmarshal simply
// ignores JSON keys with no matching struct field, so those old bytes decode
// fine here, the value is just dropped.
type sessionLegacyJSON struct {
	SessionID   string       `json:"session_id"`
	Seed        int64        `json:"seed"`
	State       SessionState `json:"state"`
	PlayerID    string       `json:"player_id,omitempty"`
	Nickname    string       `json:"nickname,omitempty"`
	ClientScore int          `json:"client_score"`
	ServerScore int          `json:"server_score"`
	Ticks       int          `json:"ticks"`
	Char        int          `json:"char"`
	GyroActive  bool         `json:"gyro_active,omitempty"`
	Log         string       `json:"log,omitempty"`
	Flagged     bool         `json:"flagged"`
	Reason      string       `json:"reason,omitempty"`
	CreatedAt   int64        `json:"created_at"`
	SubmittedAt int64        `json:"submitted_at,omitempty"`
}

func (s Session) MarshalJSON() ([]byte, error) {
	playerSeedStr := ""
	if s.PlayerSeed != 0 {
		playerSeedStr = fmt.Sprintf("%d", s.PlayerSeed)
	}
	j := sessionJSON{
		SessionID:      s.SessionID,
		Seed:           fmt.Sprintf("%d", s.Seed),
		State:          s.State,
		PlayerID:       s.PlayerID,
		Nickname:       s.Nickname,
		ClientScore:    s.ClientScore,
		ServerScore:    s.ServerScore,
		Ticks:          s.Ticks,
		Char:           s.Char,
		GyroActive:     s.GyroActive,
		PlayerSeed:     playerSeedStr,
		Log:            s.Log,
		Flagged:        s.Flagged,
		Reason:         s.Reason,
		CreatedAt:      s.CreatedAt,
		SubmittedAt:    s.SubmittedAt,
		TotalKills:     s.TotalKills,
		TotalPlatforms: s.TotalPlatforms,
		ReplayError:    s.ReplayError,
		AESKey:         s.AESKey,
		AESIV:          s.AESIV,
		HMACSecret:     s.HMACSecret,
	}
	return json.Marshal(j)
}

func (s *Session) UnmarshalJSON(data []byte) error {
	// Try new format first (seed as string "12345678...")
	var j sessionJSON
	if err := json.Unmarshal(data, &j); err == nil && j.Seed != "" {
		seed, parseErr := strconv.ParseInt(j.Seed, 10, 64)
		if parseErr == nil {
			var playerSeed int64
			if j.PlayerSeed != "" {
				playerSeed, _ = strconv.ParseInt(j.PlayerSeed, 10, 64)
			}
			s.SessionID      = j.SessionID
			s.Seed           = seed
			s.State          = j.State
			s.PlayerID       = j.PlayerID
			s.Nickname       = j.Nickname
			s.ClientScore    = j.ClientScore
			s.ServerScore    = j.ServerScore
			s.Ticks          = j.Ticks
			s.Char           = j.Char
			s.GyroActive     = j.GyroActive
			s.PlayerSeed     = playerSeed
			s.Log            = j.Log
			s.Flagged        = j.Flagged
			s.Reason         = j.Reason
			s.CreatedAt      = j.CreatedAt
			s.SubmittedAt    = j.SubmittedAt
			s.TotalKills     = j.TotalKills
			s.TotalPlatforms = j.TotalPlatforms
			s.ReplayError    = j.ReplayError
			s.AESKey         = j.AESKey
			s.AESIV          = j.AESIV
			s.HMACSecret     = j.HMACSecret
			return nil
		}
	}
	// Fallback: old format (seed as number) — for existing DB records
	var leg sessionLegacyJSON
	if err := json.Unmarshal(data, &leg); err != nil {
		return err
	}
	s.SessionID   = leg.SessionID
	s.Seed        = leg.Seed
	s.State       = leg.State
	s.PlayerID    = leg.PlayerID
	s.Nickname    = leg.Nickname
	s.ClientScore = leg.ClientScore
	s.ServerScore = leg.ServerScore
	s.Ticks       = leg.Ticks
	s.Char        = leg.Char
	s.Log         = leg.Log
	s.Flagged     = leg.Flagged
	s.Reason      = leg.Reason
	s.CreatedAt   = leg.CreatedAt
	s.SubmittedAt = leg.SubmittedAt
	return nil
}
