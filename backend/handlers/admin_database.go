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

// POST /backend/admin/database/clear — body: {"category":"client_logs"}
func (s *Server) handleAdminDatabaseClear(ctx *fasthttp.RequestCtx) {
	var req struct {
		Category string `json:"category"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.Category == "" {
		writeErr(ctx, 400, "missing_category")
		return
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
