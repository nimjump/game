package handlers

// admin_system.go — admin endpoints for:
//   - daily/weekly leaderboard on/off config
//   - game update lock (simple on/off — see handleAdminSetUpdateActive)
//   - "Remove All Replays" (clears replay logs, keeps scores/stats)
//   - uploading a new replay verifier binary (replay.zip / replay.exe)

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/config — current app config (leaderboard toggles,
// update lock state, etc).
func (s *Server) handleAdminGetConfig(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, s.Store.GetAppConfig())
}

// POST /backend/admin/config — update leaderboard toggles / earn caps.
// Body: {"daily_leaderboard_enabled":true,"weekly_leaderboard_enabled":false}
// The update-lock field is intentionally NOT settable here — use
// /backend/admin/update-active instead (see handleAdminSetUpdateActive).
func (s *Server) handleAdminSetConfig(ctx *fasthttp.RequestCtx) {
	var req struct {
		DailyLeaderboardEnabled  *bool    `json:"daily_leaderboard_enabled"`
		WeeklyLeaderboardEnabled *bool    `json:"weekly_leaderboard_enabled"`
		DailyEarnCapNIM          *float64 `json:"daily_earn_cap_nim"`
		CoinNIMRate              *float64 `json:"coin_nim_rate"`
		// Streak claim reward knobs — see game/streak_reward.go.
		// reward(day) = min(Base + ExtraPerDay*(day-1), Max).
		// 0 IS a valid, meaningful value for all three (Base/Extra=0 turns
		// a lever off; Max=0 would zero every claim out) unlike
		// DailyEarnCapNIM/CoinNIMRate above, so this uses >= 0 not > 0 — an
		// admin explicitly setting any of these to 0 must actually take
		// effect, not be silently ignored.
		StreakRewardBaseNIM        *float64 `json:"streak_reward_base_nim"`
		StreakRewardExtraPerDayNIM *float64 `json:"streak_reward_extra_per_day_nim"`
		StreakRewardMaxNIM         *float64 `json:"streak_reward_max_nim"`
		// MaxRewardAccountsPerIP — see game/ip_reward_guard.go. Minimum 1
		// enforced (0 would mean "block every claim from every IP").
		MaxRewardAccountsPerIP *int `json:"max_reward_accounts_per_ip"`
		// VSFeePercent — system fee % taken from a VS pot (0..100). 0 is valid
		// (no fee), so it's a pointer like the streak knobs.
		VSFeePercent *float64 `json:"vs_fee_percent"`
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
	if req.DailyEarnCapNIM != nil && *req.DailyEarnCapNIM > 0 {
		cfg.DailyEarnCapNIM = *req.DailyEarnCapNIM
	}
	if req.CoinNIMRate != nil && *req.CoinNIMRate > 0 {
		cfg.CoinNIMRate = *req.CoinNIMRate
	}
	if req.StreakRewardBaseNIM != nil && *req.StreakRewardBaseNIM >= 0 {
		cfg.StreakRewardBaseNIM = req.StreakRewardBaseNIM
	}
	if req.StreakRewardExtraPerDayNIM != nil && *req.StreakRewardExtraPerDayNIM >= 0 {
		cfg.StreakRewardExtraPerDayNIM = req.StreakRewardExtraPerDayNIM
	}
	if req.StreakRewardMaxNIM != nil && *req.StreakRewardMaxNIM >= 0 {
		cfg.StreakRewardMaxNIM = req.StreakRewardMaxNIM
	}
	if req.MaxRewardAccountsPerIP != nil && *req.MaxRewardAccountsPerIP >= 1 {
		cfg.MaxRewardAccountsPerIP = req.MaxRewardAccountsPerIP
	}
	if req.VSFeePercent != nil && *req.VSFeePercent >= 0 && *req.VSFeePercent <= 100 {
		cfg.VSFeePercent = req.VSFeePercent
	}
	if err := s.Store.SaveAppConfig(cfg); err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] config updated: daily=%v weekly=%v daily_earn_cap_nim=%.4f coin_nim_rate=%.6f streak_base=%v streak_extra=%v streak_max=%v max_accounts_per_ip=%v",
		cfg.DailyLeaderboardEnabled, cfg.WeeklyLeaderboardEnabled, cfg.DailyEarnCapNIM, cfg.CoinNIMRate,
		cfg.StreakRewardBaseNIM, cfg.StreakRewardExtraPerDayNIM, cfg.StreakRewardMaxNIM, cfg.MaxRewardAccountsPerIP)
	writeJSON(ctx, 200, cfg)
}

// GET /backend/admin/leaderboard — same data/params as the public
// /backend/leaderboard (see handlers/stats.go's handleLeaderboard), just
// reachable from the admin panel without an app_sig. The public route
// sits behind corsMiddleware's app_ts/app_sig HMAC check (appsig.go) —
// that's for the game client, and the admin frontend has no business
// holding that signing key. This one is gated by the admin session
// cookie instead (requireAdminSession, see server.go), same as every
// other /backend/admin/* route.
//
//	?period_type=daily|weekly|alltime
//	&period=2026-06-28          (yoksa aktif dönem)
//	&limit=10                   (max 100)
//	&offset=0
//	&player_id=NQ...            (self entry için)
func (s *Server) handleAdminLeaderboard(ctx *fasthttp.RequestCtx) {
	periodType := string(ctx.QueryArgs().Peek("period_type"))
	if periodType == "" {
		periodType = "daily"
	}

	period := string(ctx.QueryArgs().Peek("period"))
	if period == "" && periodType != "alltime" {
		daily, weekly := game.CurrentPeriods()
		if periodType == "weekly" {
			period = weekly
		} else {
			period = daily
		}
	}

	limit := 10
	if raw := ctx.QueryArgs().Peek("limit"); len(raw) > 0 {
		if v, err := strconv.Atoi(string(raw)); err == nil && v > 0 && v <= 100 {
			limit = v
		}
	}
	offset := 0
	if raw := ctx.QueryArgs().Peek("offset"); len(raw) > 0 {
		if v, err := strconv.Atoi(string(raw)); err == nil && v >= 0 {
			offset = v
		}
	}

	selfPlayerID := string(ctx.QueryArgs().Peek("player_id"))

	entries, err := s.Store.GetLeaderboardPaged(periodType, period, limit, offset, selfPlayerID)
	if err != nil {
		writeErr(ctx, 500, "leaderboard_error")
		return
	}
	if entries == nil {
		entries = []game.LBEntry{}
	}

	appCfg := s.Store.GetAppConfig()
	enabled := true
	switch periodType {
	case "daily":
		enabled = appCfg.DailyLeaderboardEnabled
	case "weekly":
		enabled = appCfg.WeeklyLeaderboardEnabled
	}

	writeJSON(ctx, 200, map[string]any{
		"entries":     entries,
		"period":      period,
		"period_type": periodType,
		"limit":       limit,
		"offset":      offset,
		"count":       len(entries),
		"enabled":     enabled,
	})
}

// POST /backend/admin/leaderboard/reset — body: {"period_type":"daily"} or
// {"period_type":"weekly"}. One-button leaderboard reset from the admin
// panel: does NOT delete any sessions, scores, replays, or payout history
// — it just marks "now" as the cutoff for the currently-open day/week, so
// the daily/weekly board (and its rank lookups) only counts scores
// submitted after the click onward. Alltime leaderboard is untouched.
// The marker only applies to the period it was set for, so it naturally
// stops mattering once that day/week rolls over — nothing to clean up.
func (s *Server) handleAdminLeaderboardReset(ctx *fasthttp.RequestCtx) {
	var req struct {
		PeriodType string `json:"period_type"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.PeriodType != "daily" && req.PeriodType != "weekly" {
		writeErr(ctx, 400, "period_type must be daily or weekly")
		return
	}
	period, err := s.Store.SetLeaderboardReset(req.PeriodType)
	if err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] leaderboard reset: period_type=%s period=%s", req.PeriodType, period)
	writeJSON(ctx, 200, map[string]any{
		"ok":          true,
		"period_type": req.PeriodType,
		"period":      period,
	})
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
// Body: {"idx":0,"reward_nim":5.0}
// Omit reward_nim (or send null) to RESET that template back to its
// hardcoded default reward instead of overriding it.
// NOTE: keyed by pool index (`idx`, from QuestPoolWithOverrides), not
// quest_type/target anymore — see questPoolKey's comment in game/quest.go.
func (s *Server) handleAdminSetQuestReward(ctx *fasthttp.RequestCtx) {
	var req struct {
		Idx       int      `json:"idx"`
		RewardNIM *float64 `json:"reward_nim"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.RewardNIM != nil && *req.RewardNIM < 0 {
		writeErr(ctx, 400, "reward_nim must be >= 0")
		return
	}
	if err := s.Store.SetQuestRewardOverride(req.Idx, req.RewardNIM); err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	if req.RewardNIM != nil {
		log.Printf("[ADMIN] quest reward override set idx=%d reward=%.4f NIM", req.Idx, *req.RewardNIM)
	} else {
		log.Printf("[ADMIN] quest reward override RESET idx=%d", req.Idx)
	}
	writeJSON(ctx, 200, map[string]any{"quests": s.Store.QuestPoolWithOverrides()})
}

// POST /backend/admin/quest-target
// Body: {"idx":0,"target":1800}
// Omit target (or send null) to RESET that template back to its hardcoded
// default target instead of overriding it.
func (s *Server) handleAdminSetQuestTarget(ctx *fasthttp.RequestCtx) {
	var req struct {
		Idx    int  `json:"idx"`
		Target *int `json:"target"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if err := s.Store.SetQuestTargetOverride(req.Idx, req.Target); err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	if req.Target != nil {
		log.Printf("[ADMIN] quest target override set idx=%d target=%d", req.Idx, *req.Target)
	} else {
		log.Printf("[ADMIN] quest target override RESET idx=%d", req.Idx)
	}
	writeJSON(ctx, 200, map[string]any{"quests": s.Store.QuestPoolWithOverrides()})
}

// POST /backend/admin/update-active — body: {"active": true|false}
// true = "activate" (block new games from starting, "locked"). false =
// "deactivate" (resume normal play). Replaces the old 3-state update-mode
// endpoint — see backend/game/appconfig.go's package doc comment for why.
func (s *Server) handleAdminSetUpdateActive(ctx *fasthttp.RequestCtx) {
	var req struct {
		Active bool `json:"active"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	cfg, err := s.Store.SetUpdateActive(req.Active)
	if err != nil {
		writeErr(ctx, 500, "save_error")
		return
	}
	log.Printf("[ADMIN] update lock set to active=%v", req.Active)
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
// replay verifier binary. Always activates immediately: saves into the live
// servergames dir, clears the cached binary path, and restarts the
// persistent worker pool. (The old "stage=1, activate later via a
// scheduled Deploy job" path was removed along with the Deploy tab — see
// backend/game/appconfig.go's package doc comment.)
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

	dir := game.ServerGamesDir()
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
