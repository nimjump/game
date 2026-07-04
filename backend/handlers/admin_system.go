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
		DailyLeaderboardEnabled  *bool    `json:"daily_leaderboard_enabled"`
		WeeklyLeaderboardEnabled *bool    `json:"weekly_leaderboard_enabled"`
		ReplayVersion            *int     `json:"replay_version"`
		DailyEarnCapNIM          *float64 `json:"daily_earn_cap_nim"`
		CoinNIMRate              *float64 `json:"coin_nim_rate"`
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
	if req.DailyEarnCapNIM != nil && *req.DailyEarnCapNIM > 0 {
		cfg.DailyEarnCapNIM = *req.DailyEarnCapNIM
	}
	if req.CoinNIMRate != nil && *req.CoinNIMRate > 0 {
		cfg.CoinNIMRate = *req.CoinNIMRate
	}
	if err := s.Store.SaveAppConfig(cfg); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] config updated: daily=%v weekly=%v replay_version=%d daily_earn_cap_nim=%.4f coin_nim_rate=%.6f",
		cfg.DailyLeaderboardEnabled, cfg.WeeklyLeaderboardEnabled, cfg.ReplayVersion, cfg.DailyEarnCapNIM, cfg.CoinNIMRate)
	writeJSON(ctx, 200, cfg)
}

// GET /backend/admin/device-breakdown — how many distinct players are on
// each platform (captured at wallet-auth verify time, see game/device.go).
func (s *Server) handleAdminDeviceBreakdown(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, map[string]any{"platforms": s.Store.DeviceBreakdown()})
}

// GET /backend/admin/quest-pool — every quest template in the pool
// (game/quest.go questPool), each with its default reward and the current
// effective reward (default, unless an admin override is active).
func (s *Server) handleAdminQuestPool(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, map[string]any{"quests": s.Store.QuestPoolWithOverrides()})
}

// POST /backend/admin/quest-reward
// Body: {"quest_type":"score","target":1500,"reward_nim":5.0}
// Omit reward_nim (or send null) to RESET that template back to its
// hardcoded default reward instead of overriding it.
func (s *Server) handleAdminSetQuestReward(ctx *fasthttp.RequestCtx) {
	var req struct {
		QuestType string   `json:"quest_type"`
		Target    int      `json:"target"`
		RewardNIM *float64 `json:"reward_nim"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.QuestType == "" {
		writeErr(ctx, 400, "quest_type is required")
		return
	}
	if req.RewardNIM != nil && *req.RewardNIM < 0 {
		writeErr(ctx, 400, "reward_nim must be >= 0")
		return
	}
	if err := s.Store.SetQuestRewardOverride(req.QuestType, req.Target, req.RewardNIM); err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	if req.RewardNIM != nil {
		log.Printf("[ADMIN] quest reward override set type=%s target=%d reward=%.4f NIM", req.QuestType, req.Target, *req.RewardNIM)
	} else {
		log.Printf("[ADMIN] quest reward override RESET type=%s target=%d", req.QuestType, req.Target)
	}
	writeJSON(ctx, 200, map[string]any{"quests": s.Store.QuestPoolWithOverrides()})
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
	// Initialized to an empty (non-nil) slice, not "var files []fileInfo" —
	// a nil slice serializes to JSON as "files": null instead of "files":
	// [], and the admin frontend (SystemTab.tsx) calls binary.files.length
	// / .map() on it unguarded. When servergames/ doesn't exist yet (fresh
	// install, before any replay binary has ever been uploaded),
	// os.ReadDir errors out below and this stayed nil — sending "null" —
	// which threw a render exception on the frontend and blanked the
	// entire admin page (no error boundary catches it). Empty slice keeps
	// the JSON shape consistent (always an array) regardless of whether
	// the directory exists.
	files := []fileInfo{}
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

// POST /backend/admin/replay-binary/delete — body: {"file": "replay.pck"}.
// Deletes a single file out of the live servergames dir (shown in the
// System tab's file list). Uses POST+body instead of a DELETE verb/path
// param, matching this codebase's existing convention (see
// /backend/admin/golden-replays/delete) rather than introducing a new
// pattern.
func (s *Server) handleAdminReplayBinaryDelete(ctx *fasthttp.RequestCtx) {
	var req struct {
		File string `json:"file"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}

	// filepath.Base strips any directory components the caller might send
	// (e.g. "../../etc/passwd" -> "passwd", "../.env" -> ".env") — combined
	// with the equality check below, this makes it impossible to delete
	// anything outside servergamesDir() no matter what "file" contains.
	req.File = strings.TrimSpace(req.File)
	name := filepath.Base(req.File)
	if name == "" || name == "." || name == "/" {
		writeErr(ctx, 400, "missing_file")
		return
	}
	// If filepath.Base() changed anything, req.File contained a path
	// separator (e.g. "../../etc/passwd", "sub/dir/file") — reject
	// outright rather than silently sanitizing, so a buggy/malicious
	// client gets a clear error instead of quietly deleting a same-named
	// file it didn't ask for. This, combined with joining only against
	// servergamesDir() below, makes it impossible to delete anything
	// outside that one directory.
	if name != req.File {
		writeErr(ctx, 400, "invalid_filename")
		return
	}

	dir := game.ServerGamesDir()
	target := filepath.Join(dir, name)

	if _, err := os.Stat(target); err != nil {
		writeErr(ctx, 404, "not_found")
		return
	}
	if err := os.Remove(target); err != nil {
		log.Printf("[ADMIN] replay-binary delete failed (%s): %v", target, err)
		writeErr(ctx, 500, "delete_failed")
		return
	}

	// The cached binary path (and the persistent worker pool, which has
	// this same binary open/running) may now point at a file that no
	// longer exists — reset so the next resolve re-checks from scratch,
	// and restart workers so they don't keep running against a binary
	// whose backing file was just deleted out from under them.
	game.ResetBinaryCache()
	go game.RestartAllWorkers()

	log.Printf("[ADMIN] replay-binary file deleted: %s", target)
	writeJSON(ctx, 200, map[string]any{"ok": true, "file": name})
}
