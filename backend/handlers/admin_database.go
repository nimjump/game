package handlers

// admin_database.go — Database tab: category overview + clear, and the
// failed-replay archive (now stored in BadgerDB, see game/failed_replay_store.go)
// list + per-entry download.

import (
	"encoding/json"
	"log"

	"github.com/valyala/fasthttp"
)

// GET /backend/admin/database — key-prefix category counts.
func (s *Server) handleAdminDatabaseOverview(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, map[string]any{"categories": s.Store.DatabaseOverview()})
}

// POST /backend/admin/database/clear — body: {"category":"client_logs"}.
// Dangerous categories (wallets, pending_rewards, auth_tokens, nicknames,
// sessions, leaderboard_winners, app_config — see dbCategories'
// Dangerous flag in game/db_admin.go) additionally require
// {"confirm":"<category>"} echoing the category name back.
//
// BUG FIX (security audit): this used to delete an entire category — for
// the dangerous ones, that's every player's wallet registrations, every
// pending/sent reward record, every live session token, etc. — from a
// single POST with nothing beyond "is this an authenticated admin session."
// The `Dangerous` flag already existed on the category definition but was
// only ever used to show an extra warning in the admin UI — never actually
// checked server-side, so it did nothing to stop a CSRF that slipped past
// the origin check, a hijacked/stolen admin session, or a simple misclick
// on the wrong category from permanently destroying real financial
// bookkeeping with zero recoverability and no server-side safety net.
// Requiring the category name to be explicitly echoed back is a cheap,
// effective "are you sure" that a blind/automated request can't satisfy by
// accident.
func (s *Server) handleAdminDatabaseClear(ctx *fasthttp.RequestCtx) {
	var req struct {
		Category string `json:"category"`
		Confirm  string `json:"confirm"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.Category == "" {
		writeErr(ctx, 400, "missing_category")
		return
	}
	for _, cat := range s.Store.DatabaseOverview() {
		if cat.Key == req.Category && cat.Dangerous && req.Confirm != req.Category {
			log.Printf("[ADMIN] database clear BLOCKED (missing confirm): %s", req.Category)
			writeErr(ctx, 400, "confirm_required")
			return
		}
	}
	deleted, err := s.Store.ClearDBCategory(req.Category)
	if err != nil {
		writeErr(ctx, 400, "unknown_category")
		return
	}
	log.Printf("[ADMIN] database category cleared: %s (%d keys)", req.Category, deleted)
	writeJSON(ctx, 200, map[string]any{"ok": true, "category": req.Category, "deleted": deleted})
}

// GET /backend/admin/failed-replay-archive — list (no log bytes, keeps it light).
func (s *Server) handleAdminFailedReplayArchiveList(ctx *fasthttp.RequestCtx) {
	entries := s.Store.ListFailedReplays(200)
	// Strip the (potentially large) log_base64 from the list view — the
	// download endpoint returns it in full for a single entry.
	type listItem struct {
		ID         string         `json:"id"`
		SessionID  string         `json:"session_id,omitempty"`
		Seed       string         `json:"seed,omitempty"`
		Char       int            `json:"char"`
		Category   string         `json:"category"`
		Reason     string         `json:"reason,omitempty"`
		Extra      map[string]any `json:"extra,omitempty"`
		ArchivedAt int64          `json:"archived_at"`
		HasLog     bool           `json:"has_log"`
	}
	out := make([]listItem, len(entries))
	for i, e := range entries {
		out[i] = listItem{
			ID: e.ID, SessionID: e.SessionID, Seed: e.Seed, Char: e.Char,
			Category: e.Category, Reason: e.Reason, Extra: e.Extra,
			ArchivedAt: e.ArchivedAt, HasLog: e.LogBase64 != "",
		}
	}
	writeJSON(ctx, 200, map[string]any{"entries": out, "count": len(out)})
}

// GET /backend/admin/failed-replay-archive/{id}/download — full entry as a
// downloadable JSON file (includes the base64 replay log for manual replay
// binary debugging).
func (s *Server) handleAdminFailedReplayArchiveDownload(ctx *fasthttp.RequestCtx) {
	id, _ := ctx.UserValue("id").(string)
	if id == "" {
		writeErr(ctx, 400, "missing_id")
		return
	}
	entry, err := s.Store.GetFailedReplay(id)
	if err != nil || entry == nil {
		writeErr(ctx, 404, "not_found")
		return
	}
	data, merr := json.MarshalIndent(entry, "", "  ")
	if merr != nil {
		writeErr(ctx, 500, "marshal_error")
		return
	}
	ctx.Response.Header.Set("Content-Disposition", "attachment; filename=\"failed_replay_"+id+".json\"")
	ctx.SetContentType("application/json")
	ctx.SetBody(data)
}
