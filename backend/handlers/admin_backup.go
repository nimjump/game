package handlers

// admin_backup.go — Database tab: R2 off-site backup status, manual
// trigger, and recent-snapshot listing. See game/backup.go for the actual
// backup/upload/prune logic.

import (
	"encoding/json"
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/backup — status of the automatic backup system
// (configured?, last success/failure, interval/retention settings).
func (s *Server) handleAdminBackupStatus(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, game.GetBackupStatus())
}

// GET /backend/admin/backup/list — recent snapshots actually sitting in R2,
// newest first, so an admin can confirm backups are landing without leaving
// the panel.
func (s *Server) handleAdminBackupList(ctx *fasthttp.RequestCtx) {
	objects, err := game.ListBackups()
	if err != nil {
		writeErr(ctx, 400, "list_failed: "+err.Error())
		return
	}
	type item struct {
		Key          string `json:"key"`
		Size         int64  `json:"size"`
		LastModified string `json:"last_modified"`
	}
	out := make([]item, 0, len(objects))
	for _, o := range objects {
		out = append(out, item{Key: o.Key, Size: o.Size, LastModified: o.LastModified})
	}
	writeJSON(ctx, 200, map[string]any{"backups": out})
}

// POST /backend/admin/backup/run — trigger an out-of-schedule backup right
// now. Runs synchronously (a Badger backup + R2 upload for a game DB this
// size is a matter of seconds, not minutes) so the admin gets an immediate
// pass/fail instead of having to poll a job status.
func (s *Server) handleAdminBackupRun(ctx *fasthttp.RequestCtx) {
	if err := s.Store.RunBackupNow(); err != nil {
		log.Printf("[ADMIN] manual backup failed: %v", err)
		writeErr(ctx, 500, "backup_failed: "+err.Error())
		return
	}
	writeJSON(ctx, 200, game.GetBackupStatus())
}

// POST /backend/admin/backup/restore — body: {"key": "backups/...", "confirm": "<same key>"}.
// Wipes the ENTIRE live database and replaces it with the chosen snapshot —
// see Store.RestoreBackup's doc comment for the full safety sequence
// (downloads first, takes a pre-restore safety snapshot, only then wipes).
// Same "echo the exact target back" confirmation pattern as
// handleAdminDatabaseClear's dangerous categories, except here the whole DB
// is the target, so the confirm value must match the snapshot key exactly —
// a blind/automated or fat-fingered request can't satisfy this by accident.
// Runs synchronously — can take longer than a plain backup (download +
// safety snapshot + wipe + reload), so the admin UI should show a clear
// "in progress, do not close this" state while waiting.
func (s *Server) handleAdminBackupRestore(ctx *fasthttp.RequestCtx) {
	var req struct {
		Key     string `json:"key"`
		Confirm string `json:"confirm"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.Key == "" {
		writeErr(ctx, 400, "missing_key")
		return
	}
	if req.Confirm != req.Key {
		writeErr(ctx, 400, "confirm_required")
		return
	}
	log.Printf("[ADMIN] DB restore requested from key=%s", req.Key)
	if err := s.Store.RestoreBackup(req.Key); err != nil {
		log.Printf("[ADMIN] restore failed: %v", err)
		writeErr(ctx, 500, "restore_failed: "+err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true})
}
