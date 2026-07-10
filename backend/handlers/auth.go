package handlers

import (
	"encoding/json"
	"log"
	"strings"
	"time"

	"github.com/valyala/fasthttp"
)

// GET /bj/auth/challenge
// Generates a new challenge to be signed
func (s *Server) handleAuthChallenge(ctx *fasthttp.RequestCtx) {
	challenge, err := s.Store.NewChallenge()
	if err != nil {
		writeErr(ctx, 500, "challenge_error")
		return
	}
	log.Printf("[AUTH] challenge issued chal=%s exp=%d", challenge.Challenge, challenge.ExpiresAt)
	writeJSON(ctx, 200, challenge)
}

// POST /bj/auth/verify
// Body: {
//   "challenge":    "bunnyjump_auth_...",
//   "nimiq_address":"NQ...",
//   "public_key":   "64_hex_chars",
//   "signature":    "128_hex_chars"
// }
// Returns session token on success
func (s *Server) handleAuthVerify(ctx *fasthttp.RequestCtx) {
	var req struct {
		Challenge    string `json:"challenge"`
		NimiqAddress string `json:"nimiq_address"`
		PublicKey    string `json:"public_key"`
		Signature    string `json:"signature"`
		DeviceID     string `json:"device_id,omitempty"`
		// Browser/OS metadata for the admin "device support scale" view
		// (game.DeviceBreakdown) — optional, purely informational, never
		// validated/trusted for anything security-relevant.
		UserAgent string `json:"user_agent,omitempty"`
		Platform  string `json:"platform,omitempty"`
		Screen    string `json:"screen,omitempty"`
		DPR       string `json:"dpr,omitempty"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.Challenge == "" || req.NimiqAddress == "" || req.PublicKey == "" || req.Signature == "" {
		writeErr(ctx, 400, "missing_fields")
		return
	}
	// Strict length/format validation before any DB access
	if len(req.Challenge) > 200 {
		writeErr(ctx, 400, "invalid_challenge")
		return
	}
	if len(req.PublicKey) != 64 {
		writeErr(ctx, 400, "invalid_public_key_length")
		return
	}
	if len(req.Signature) != 128 {
		writeErr(ctx, 400, "invalid_signature_length")
		return
	}
	if len(req.NimiqAddress) < 4 || len(req.NimiqAddress) > 44 || req.NimiqAddress[:2] != "NQ" {
		writeErr(ctx, 400, "invalid_nimiq_address")
		return
	}

	log.Printf("[AUTH] verify attempt chal=%s pub=%s sig=%s", req.Challenge, req.PublicKey[:8], req.Signature[:8])
	sess, err := s.Store.VerifyAndLogin(req.Challenge, req.NimiqAddress, req.PublicKey, req.Signature, req.DeviceID)
	if err != nil {
		log.Printf("[AUTH] verify failed addr=%s err=%v", req.NimiqAddress[:min8(req.NimiqAddress)], err)
		// Return a generic error — do not leak internal details.
		writeErr(ctx, 401, "auth_failed")
		return
	}

	log.Printf("[AUTH] login success player=%s token=%s…", sess.PlayerID[:min8(sess.PlayerID)], sess.Token[:8])

	// Best-effort device tracking — never blocks/fails login on error.
	if req.UserAgent != "" || req.Platform != "" {
		if ua := req.UserAgent; len(ua) > 200 { req.UserAgent = ua[:200] }
		if e := s.Store.SetPlayerDevice(sess.PlayerID, req.UserAgent, req.Platform, req.Screen, req.DPR); e != nil {
			log.Printf("[AUTH] device save failed player=%s err=%v", sess.PlayerID[:min8(sess.PlayerID)], e)
		}
	}

	// Streak: read-only. BUG FIX — this used to call RecordDailyActivity
	// here, advancing the streak counter on every fresh sign-in whether or
	// not the player had actually claimed anything, which is exactly why
	// the lobby's "N day streak! Keep it going" toast could fire the
	// instant someone opened the app, before they'd done anything at all.
	// The streak now only advances at actual claim time (see
	// game/streak_reward.go's ClaimStreakReward) — this just reports the
	// current (already-claimed) count for the client's badge/toast.
	streak := s.Store.GetStreak(sess.PlayerID)

	// Best-effort connection-IP history — powers the admin panel's
	// per-player "connection IPs" list (see player_ip.go). Never blocks
	// login on error, same style as the device-tracking call above.
	if ip := realClientIP(ctx); ip != "" {
		if e := s.Store.RecordPlayerIP(sess.PlayerID, ip); e != nil {
			log.Printf("[AUTH] ip record failed player=%s err=%v", sess.PlayerID[:min8(sess.PlayerID)], e)
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"ok":            true,
		"token":         sess.Token,
		"player_id":     sess.PlayerID,
		"nimiq_address": sess.NimiqAddress,
		"device_id":     sess.DeviceID,
		"expires_at":    sess.ExpiresAt,
		"streak":        streak.Count,
	})
}

// GET /bj/auth/me?token=xxx  — checks token validity
func (s *Server) handleAuthMe(ctx *fasthttp.RequestCtx) {
	token := string(ctx.QueryArgs().Peek("token"))
	if token == "" {
		// Bearer header'dan da al
		auth := string(ctx.Request.Header.Peek("Authorization"))
		if strings.HasPrefix(auth, "Bearer ") {
			token = auth[7:]
		}
	}
	if token == "" {
		writeErr(ctx, 401, "token_required")
		return
	}
	sess, err := s.Store.GetSession(token)
	if err != nil || sess == nil {
		writeErr(ctx, 401, "invalid_token")
		return
	}
	if time.Now().Unix() > sess.ExpiresAt {
		writeErr(ctx, 401, "token_expired")
		return
	}
	// Streak: read-only, same as handleAuthVerify above — see that
	// function's comment for why this no longer calls RecordDailyActivity.
	streak := s.Store.GetStreak(sess.PlayerID)

	// Best-effort connection-IP history (see handleAuthVerify above for the
	// same call — this covers session-restore logins too, so an IP that's
	// only ever used to restore an existing session, never to sign in
	// fresh, still shows up in the admin panel).
	if ip := realClientIP(ctx); ip != "" {
		if e := s.Store.RecordPlayerIP(sess.PlayerID, ip); e != nil {
			log.Printf("[AUTH] ip record failed player=%s err=%v", sess.PlayerID[:min8(sess.PlayerID)], e)
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"ok":            true,
		"player_id":     sess.PlayerID,
		"nimiq_address": sess.NimiqAddress,
		"expires_at":    sess.ExpiresAt,
		"streak":        streak.Count,
	})
}
