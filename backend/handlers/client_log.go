package handlers

// client_log.go — Client-side error logs: collect, deduplicate, expose to admin.
//
// POST   /backend/client-log          — no auth required; rate-limited
// GET    /backend/admin/client-logs   — admin: list grouped logs
// DELETE /backend/admin/client-logs   — admin: clear all logs
// GET    /backend/admin/replay-failed — admin: list replay_failed sessions

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/valyala/fasthttp"
)

// POST /backend/client-log
// Auth NOT required — logs arrive before/without wallet auth.
// Body: {
//   "entries": [{ "level": "error|warn|info", "message": "...", "ts": unix_ms }],
//   "user_agent": "...",
//   "screen": "390x844",
//   "platform": "iPhone / iOS 17",
//   "dpr": 3
// }
func (s *Server) handleClientLog(ctx *fasthttp.RequestCtx) {
	// Body size limit — 16KB
	if len(ctx.PostBody()) > 16*1024 {
		writeErr(ctx, 413, "payload_too_large")
		return
	}

	var req struct {
		Entries []struct {
			Level   string `json:"level"`
			Message string `json:"message"`
		} `json:"entries"`
		UserAgent string `json:"user_agent,omitempty"`
		Screen    string `json:"screen,omitempty"`
		Platform  string `json:"platform,omitempty"`
		DPR       string `json:"dpr,omitempty"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}

	// Max 30 entries per request
	if len(req.Entries) > 30 {
		req.Entries = req.Entries[:30]
	}

	// Build device string from client-supplied metadata (not spoofable-critical, just debug info)
	ua := req.UserAgent
	if len(ua) > 150 { ua = ua[:150] }
	screen := req.Screen
	platform := req.Platform
	dpr := req.DPR

	device := buildDeviceString(ua, screen, platform, dpr)

	// IP — from request (proxy-aware)
	ip := string(ctx.Request.Header.Peek("X-Real-IP"))
	if ip == "" { ip = string(ctx.Request.Header.Peek("X-Forwarded-For")) }
	if ip == "" { ip = ctx.RemoteIP().String() }
	// Keep only first IP if comma-separated
	if idx := strings.Index(ip, ","); idx >= 0 { ip = strings.TrimSpace(ip[:idx]) }
	if len(ip) > 45 { ip = ip[:45] }

	// Player ID from auth token — optional
	playerID := s.tokenPlayerID(ctx)

	// Capacity check — hard cap at 500 unique messages
	if s.Store.ClientLogCount() >= 500 {
		writeJSON(ctx, 200, map[string]any{"ok": true, "dropped": true})
		return
	}

	saved := 0
	for _, e := range req.Entries {
		level := e.Level
		if level != "error" && level != "warn" && level != "info" { level = "info" }

		msg := strings.TrimSpace(e.Message)
		if len(msg) > 400 { msg = msg[:400] }
		if msg == "" { continue }

		if err := s.Store.UpsertClientLog(level, msg, playerID, ip, device); err != nil {
			log.Printf("[CLIENT_LOG] upsert error: %v", err)
		} else {
			saved++
		}
	}

	writeJSON(ctx, 200, map[string]any{"ok": true, "saved": saved})
}

func buildDeviceString(ua, screen, platform, dpr string) string {
	parts := []string{}
	if platform != "" { parts = append(parts, platform) }
	if screen != ""   { parts = append(parts, screen) }
	if dpr != ""      { parts = append(parts, "DPR="+dpr) }
	if ua != ""       { parts = append(parts, ua) }
	s := strings.Join(parts, " | ")
	if len(s) > 200 { s = s[:200] }
	return s
}

// GET /backend/admin/client-logs?level=error&limit=200
func (s *Server) handleAdminClientLogs(ctx *fasthttp.RequestCtx) {
	limit := 200
	if raw := ctx.QueryArgs().Peek("limit"); len(raw) > 0 {
		if v, err := fastAtoiSafe(string(raw)); err == nil && v > 0 && v <= 500 {
			limit = v
		}
	}
	levelFilter := string(ctx.QueryArgs().Peek("level"))

	logs := s.Store.ListClientLogs(levelFilter, limit)
	total := s.Store.ClientLogCount()

	writeJSON(ctx, 200, map[string]any{
		"logs":  logs,
		"count": len(logs),
		"total": total,
	})
}

// DELETE /backend/admin/client-logs
func (s *Server) handleAdminDeleteClientLogs(ctx *fasthttp.RequestCtx) {
	deleted := s.Store.DeleteAllClientLogs()
	log.Printf("[ADMIN] client logs cleared: %d", deleted)
	writeJSON(ctx, 200, map[string]any{"ok": true, "deleted": deleted})
}

// GET /backend/admin/replay-failed
func (s *Server) handleAdminReplayFailed(ctx *fasthttp.RequestCtx) {
	all := s.Store.List(false, 0)
	type failedOut struct {
		SessionID   string `json:"session_id"`
		PlayerID    string `json:"player_id"`
		Nickname    string `json:"nickname"`
		ClientScore int    `json:"client_score"`
		ReplayError string `json:"replay_error"`
		SubmittedAt int64  `json:"submitted_at"`
		HasLog      bool   `json:"has_log"`
	}
	var out []failedOut
	for _, sess := range all {
		if string(sess.State) != "replay_failed" { continue }
		out = append(out, failedOut{
			SessionID:   sess.SessionID,
			PlayerID:    sess.PlayerID,
			Nickname:    sess.Nickname,
			ClientScore: sess.ClientScore,
			ReplayError: sess.ReplayError,
			SubmittedAt: sess.SubmittedAt,
			HasLog:      sess.Log != "",
		})
	}
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].SubmittedAt > out[i].SubmittedAt { out[i], out[j] = out[j], out[i] }
		}
	}
	if out == nil { out = []failedOut{} }
	writeJSON(ctx, 200, map[string]any{"sessions": out, "count": len(out)})
}

func fastAtoiSafe(s string) (int, error) {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' { return 0, fmt.Errorf("not int") }
		n = n*10 + int(c-'0')
	}
	return n, nil
}
