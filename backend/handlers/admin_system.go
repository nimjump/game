package handlers

// admin_system.go — admin endpoints for:
//   - daily/weekly leaderboard on/off + replay version config
//   - game update mode (force / normal) + completing an update
//   - "Remove All Replays" (clears replay logs, keeps scores/stats)
//   - uploading a new replay verifier binary (replay.zip / replay.exe)

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/config — current app config (leaderboard toggles,
// update mode, replay version).
func (s *Server) handleAdminGetConfig(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, s.Store.GetAppConfig())
}

// POST /backend/admin/config — update leaderboard toggles / replay version.
// Body: {"daily_leaderboard_enabled":true,"weekly_leaderboard_enabled":false,"replay_version":2}
// Update-mode fields are intentionally NOT settable here — use
// /backend/admin/update-mode so the scheduling logic stays consistent.
func (s *Server) handleAdminSetConfig(ctx *fasthttp.RequestCtx) {
	var req struct {
		DailyLeaderboardEnabled  *bool `json:"daily_leaderboard_enabled"`
		WeeklyLeaderboardEnabled *bool `json:"weekly_leaderboard_enabled"`
		ReplayVersion            *int  `json:"replay_version"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	cfg := s.Store.GetAppConfig()
	if req.DailyLeaderboardEnabled != nil {
		cfg.DailyLeaderboardEnabled = *req.DailyLeaderboardEnabled
	}
	if req.WeeklyLeaderboardEnabled != nil {
		cfg.WeeklyLeaderboardEnabled = *req.WeeklyLeaderboardEnabled
	}
	if req.ReplayVersion != nil && *req.ReplayVersion > 0 {
		cfg.ReplayVersion = *req.ReplayVersion
	}
	if err := s.Store.SaveAppConfig(cfg); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] config updated: daily=%v weekly=%v replay_version=%d",
		cfg.DailyLeaderboardEnabled, cfg.WeeklyLeaderboardEnabled, cfg.ReplayVersion)
	writeJSON(ctx, 200, cfg)
}

// POST /backend/admin/update-mode — body: {"mode":"off"|"force"|"normal"}
func (s *Server) handleAdminSetUpdateMode(ctx *fasthttp.RequestCtx) {
	var req struct {
		Mode string `json:"mode"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	switch req.Mode {
	case game.UpdateModeOff, game.UpdateModeForce, game.UpdateModeNormal:
	default:
		writeErr(ctx, 400, "invalid_mode")
		return
	}
	cfg, err := s.Store.SetUpdateMode(req.Mode)
	if err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	writeJSON(ctx, 200, cfg)
}

// POST /backend/admin/update-complete — resumes normal play.
func (s *Server) handleAdminCompleteUpdate(ctx *fasthttp.RequestCtx) {
	cfg, err := s.Store.CompleteUpdate()
	if err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] update completed — game resumed")
	writeJSON(ctx, 200, cfg)
}

// POST /backend/admin/replays/clear-all — wipes every replay log (+ the
// failed-replay archive, both in the DB), keeps sessions/scores/stats intact.
func (s *Server) handleAdminClearAllReplays(ctx *fasthttp.RequestCtx) {
	cleared, err := s.Store.ClearAllReplayLogs()
	if err != nil {
		writeErr(ctx, 500, "clear_error")
		return
	}
	archived := s.Store.ClearFailedReplays()
	log.Printf("[ADMIN] cleared %d replay logs + %d archived failed-replay entries", cleared, archived)
	writeJSON(ctx, 200, map[string]any{
		"ok":               true,
		"sessions_cleared": cleared,
		"archive_deleted":  archived,
	})
}

// GET /backend/admin/replay-binary — current binary status + files in the
// servergames dir, for the admin UI.
func (s *Server) handleAdminReplayBinaryStatus(ctx *fasthttp.RequestCtx) {
	dir := game.ServerGamesDir()
	rs := game.ReplayBinaryStatus()

	type fileInfo struct {
		Name       string `json:"name"`
		Size       int64  `json:"size"`
		ModifiedAt int64  `json:"modified_at"`
	}
	var files []fileInfo
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			info, ierr := e.Info()
			if ierr != nil {
				continue
			}
			files = append(files, fileInfo{
				Name:       e.Name(),
				Size:       info.Size(),
				ModifiedAt: info.ModTime().Unix(),
			})
		}
	}

	writeJSON(ctx, 200, map[string]any{
		"dir":     dir,
		"healthy": rs["healthy"],
		"binary":  rs["binary"],
		"files":   files,
	})
}

// POST /backend/admin/replay-binary — multipart/form-data upload, field
// "file". Accepts a .zip (Linux build) or .exe (Windows/Godot export)
// replay verifier binary.
//
// By default (no "stage" field, or "stage" != "1") it activates
// immediately: saves into the live servergames dir, clears the cached
// binary path, and restarts the persistent worker pool.
//
// With form field "stage=1", the upload is saved to a staging folder
// instead and NOT activated — use this when you want to bundle the binary
// swap into a scheduled deploy job (admin panel → Deploy tab) so it goes
// live atomically together with the Cloudflare Pages deploy + replay
// version bump, at whatever trigger you picked.
func (s *Server) handleAdminReplayBinaryUpload(ctx *fasthttp.RequestCtx) {
	fh, err := ctx.FormFile("file")
	if err != nil {
		writeErr(ctx, 400, "no_file")
		return
	}

	name := strings.ToLower(fh.Filename)
	var target string
	switch {
	case strings.HasSuffix(name, ".zip"):
		target = "replay.zip"
	case strings.HasSuffix(name, ".exe"):
		target = "replay.exe"
	default:
		writeErr(ctx, 400, "expected_zip_or_exe")
		return
	}

	stage := string(ctx.FormValue("stage")) == "1"

	dir := game.ServerGamesDir()
	if stage {
		dir = game.StagedReplayDir()
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("[ADMIN] replay binary upload: mkdir failed: %v", err)
		writeErr(ctx, 500, "mkdir_failed")
		return
	}
	destPath := filepath.Join(dir, target)
	if err := fasthttp.SaveMultipartFile(fh, destPath); err != nil {
		log.Printf("[ADMIN] replay binary upload: save failed: %v", err)
		writeErr(ctx, 500, "save_failed")
		return
	}

	if stage {
		log.Printf("[ADMIN] replay binary staged: %s (%d bytes) — will activate on the next scheduled deploy job", target, fh.Size)
		writeJSON(ctx, 200, map[string]any{
			"ok": true, "file": target, "size": fh.Size, "dir": dir, "staged": true,
		})
		return
	}

	// Fresh zip landed — drop any previously-extracted binary/pck so the
	// next resolve extracts clean from the new zip instead of reusing stale files.
	if target == "replay.zip" {
		os.Remove(filepath.Join(dir, "replay"))
		os.Remove(filepath.Join(dir, "replay.pck"))
	}

	game.ResetBinaryCache()
	log.Printf("[ADMIN] replay binary updated: %s (%d bytes) — restarting worker pool", target, fh.Size)
	go game.RestartAllWorkers()

	writeJSON(ctx, 200, map[string]any{
		"ok":   true,
		"file": target,
		"size": fh.Size,
		"dir":  dir,
		"staged": false,
	})
}
