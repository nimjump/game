package handlers

import (
	"encoding/json"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/valyala/fasthttp"
)

var nicknameRe = regexp.MustCompile(`^[a-z0-9]{1,20}$`)

// sanitizeNickname — boşluk, özel karakter siler, küçük harfe çevirir, maxLen'e kırpar
func sanitizeNickname(s string, maxLen int) string {
	s = strings.ToLower(strings.TrimSpace(s))
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			out = append(out, c)
		}
	}
	if len(out) > maxLen {
		out = out[:maxLen]
	}
	return string(out)
}

// GET /backend/nickname?player_id=NQ...
func (s *Server) handleNicknameGet(ctx *fasthttp.RequestCtx) {
	playerID := string(ctx.QueryArgs().Peek("player_id"))
	if playerID == "" {
		// Try from auth token
		playerID = s.tokenPlayerID(ctx)
	}
	if playerID == "" {
		writeErr(ctx, 400, "missing_player_id")
		return
	}
	pn, err := s.Store.GetNickname(playerID)
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if pn == nil {
		writeJSON(ctx, 200, map[string]any{
			"player_id":    playerID,
			"nickname":     "",
			"set_at":       0,
			"cooldown_end": 0,
		})
		return
	}
	writeJSON(ctx, 200, map[string]any{
		"player_id":    pn.PlayerID,
		"nickname":     pn.Nickname,
		"set_at":       pn.SetAt,
		"cooldown_end": pn.CooldownEnd,
		"on_cooldown":  time.Now().Unix() < pn.CooldownEnd,
	})
}

// POST /backend/nickname
// Body: {"nickname": "myname"}
// Requires auth token
func (s *Server) handleNicknameSet(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}

	var req struct {
		Nickname string `json:"nickname"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	req.Nickname = sanitizeNickname(req.Nickname, 20)
	if !nicknameRe.MatchString(req.Nickname) {
		writeErr(ctx, 400, "invalid_nickname")
		return
	}

	pn, err := s.Store.SetNickname(playerID, req.Nickname)
	if err != nil {
		msg := err.Error()
		if strings.HasPrefix(msg, "cooldown:") {
			writeErr(ctx, 429, msg)
			return
		}
		if strings.HasPrefix(msg, "nickname_locked_until:") {
			writeErr(ctx, 409, msg)
			return
		}
		if msg == "nickname_taken" {
			writeErr(ctx, 409, "nickname_taken")
			return
		}
		writeErr(ctx, 400, msg)
		return
	}
	log.Printf("[NICKNAME] player=%s nickname=%s cooldown_end=%d", playerID[:min(8, len(playerID))], pn.Nickname, pn.CooldownEnd)
	writeJSON(ctx, 200, map[string]any{
		"ok":           true,
		"nickname":     pn.Nickname,
		"cooldown_end": pn.CooldownEnd,
	})
}

// GET /backend/nickname/check?nickname=foo — public availability check
func (s *Server) handleNicknameCheck(ctx *fasthttp.RequestCtx) {
	nick := strings.ToLower(strings.TrimSpace(string(ctx.QueryArgs().Peek("nickname"))))
	if !nicknameRe.MatchString(nick) {
		writeJSON(ctx, 200, map[string]any{"available": false, "reason": "invalid_format"})
		return
	}
	owner, err := s.Store.GetPlayerByNickname(nick)
	if err != nil {
		writeErr(ctx, 500, "db_error")
		return
	}
	if owner != "" {
		writeJSON(ctx, 200, map[string]any{"available": false, "reason": "taken"})
		return
	}
	writeJSON(ctx, 200, map[string]any{"available": true})
}
