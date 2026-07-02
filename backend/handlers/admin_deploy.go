package handlers

// admin_deploy.go — scheduled deploy jobs: bundle a Cloudflare Pages push,
// a staged replay binary activation, and a replay version bump into one
// job, triggered now / at a specific time / when the daily leaderboard
// ends / when the weekly leaderboard ends. See game/deploy_job.go for the
// actual close-safe execution logic.

import (
	"encoding/json"
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/deploy/status — Cloudflare config presence + staged
// binary presence, so the admin UI knows what's available to schedule.
func (s *Server) handleAdminDeployStatus(ctx *fasthttp.RequestCtx) {
	_, _, project, dir, branch, configured := game.CloudflareConfigured()
	stagedName, hasStaged := game.HasStagedReplayBinary()
	writeJSON(ctx, 200, map[string]any{
		"cloudflare_configured": configured,
		"cloudflare_project":    project,
		"cloudflare_export_dir": dir,
		"cloudflare_branch":     branch,
		"staged_binary":         stagedName,
		"has_staged_binary":     hasStaged,
	})
}

// POST /backend/admin/deploy/schedule
// Body: {
//   "trigger": "now"|"at"|"daily_lb_end"|"weekly_lb_end",
//   "at_unix": 1234567890,              // required if trigger == "at"
//   "activate_replay_binary": true,     // requires a staged binary (upload with stage=1 first)
//   "deploy_cloudflare": true,
//   "new_replay_version": 3             // optional, 0 = don't change
// }
func (s *Server) handleAdminScheduleDeploy(ctx *fasthttp.RequestCtx) {
	var req struct {
		Trigger              string `json:"trigger"`
		AtUnix               int64  `json:"at_unix"`
		ActivateReplayBinary bool   `json:"activate_replay_binary"`
		DeployCloudflare     bool   `json:"deploy_cloudflare"`
		NewReplayVersion     int    `json:"new_replay_version"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	job, err := s.Store.ScheduleDeployJob(
		game.DeployTrigger(req.Trigger), req.AtUnix,
		req.ActivateReplayBinary, req.DeployCloudflare, req.NewReplayVersion,
	)
	if err != nil {
		ctx.SetStatusCode(400)
		writeJSON(ctx, 400, map[string]any{"error": err.Error()})
		return
	}
	log.Printf("[ADMIN] deploy job scheduled: %s", job.ID)
	writeJSON(ctx, 200, job)
}

// GET /backend/admin/deploy/jobs — recent job history (includes current pending/running).
func (s *Server) handleAdminListDeployJobs(ctx *fasthttp.RequestCtx) {
	writeJSON(ctx, 200, map[string]any{"jobs": s.Store.ListDeployJobs(30)})
}

// POST /backend/admin/deploy/jobs/{id}/cancel — only works while still pending.
func (s *Server) handleAdminCancelDeployJob(ctx *fasthttp.RequestCtx) {
	id, _ := ctx.UserValue("id").(string)
	if id == "" {
		writeErr(ctx, 400, "missing_id")
		return
	}
	if err := s.Store.CancelPendingDeployJob(id); err != nil {
		ctx.SetStatusCode(400)
		writeJSON(ctx, 400, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true})
}
