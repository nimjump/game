package handlers

// admin_players_list.go — GET /backend/admin/players
//
// Returns all registered players (have at least one nickname entry).
// Each entry includes:
//   - player_id, nickname, set_at
//   - is_active: true if they have a non-expired auth token in DB
//   - token_expires_at: latest token expiry timestamp (if active)
//   - session_count: total game sessions
//   - last_seen: last session submitted_at timestamp

import (
	"time"

	"github.com/valyala/fasthttp"
)

func (s *Server) handleAdminPlayersList(ctx *fasthttp.RequestCtx) {
	now := time.Now().Unix()

	// All registered players (have a nickname record)
	nicknames, err := s.Store.ListAllNicknames()
	if err != nil {
		writeErr(ctx, 500, "failed to list players")
		return
	}

	// Active sessions: playerID → latest ExpiresAt (still in DB = token not expired)
	activeSessions, err := s.Store.ListActiveSessions()
	if err != nil {
		activeSessions = map[string]int64{}
	}

	// Session stats per player from in-memory scan
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

	type playerOut struct {
		PlayerID       string `json:"player_id"`
		Nickname       string `json:"nickname"`
		RegisteredAt   int64  `json:"registered_at"` // nickname SetAt
		IsActive       bool   `json:"is_active"`
		TokenExpiresAt int64  `json:"token_expires_at,omitempty"`
		SessionCount   int    `json:"session_count"`
		LastSeen       int64  `json:"last_seen,omitempty"`
	}

	out := make([]playerOut, 0, len(nicknames))
	for _, pn := range nicknames {
		expiresAt := activeSessions[pn.PlayerID]
		isActive := expiresAt > now

		stat := statMap[pn.PlayerID]
		count := 0
		var lastSeen int64
		if stat != nil {
			count = stat.count
			lastSeen = stat.lastSeen
		}

		out = append(out, playerOut{
			PlayerID:       pn.PlayerID,
			Nickname:       pn.Nickname,
			RegisteredAt:   pn.SetAt,
			IsActive:       isActive,
			TokenExpiresAt: expiresAt,
			SessionCount:   count,
			LastSeen:       lastSeen,
		})
	}

	writeJSON(ctx, 200, map[string]any{
		"total":   len(out),
		"players": out,
	})
}
