package game

// cloudflare_deploy.go — pushes the web export folder to Cloudflare Pages
// straight from the admin panel, via the Wrangler CLI (run through `npx`,
// so no global install is required — but Node/npm must be on PATH, which
// is already true on this server since the admin Next.js app needs it).
//
// Auth is via CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID env vars —
// Wrangler reads both automatically for non-interactive deploys, no
// `wrangler login` / browser flow needed. Nothing beyond these env vars
// is required; there is no wrangler.toml in this project (see README
// section 16) and this doesn't add one — it passes --project-name on the
// command line instead.

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// CloudflareConfigured — are the minimum env vars present to attempt a deploy?
func CloudflareConfigured() (token, accountID, project, dir, branch string, ok bool) {
	token = os.Getenv("CLOUDFLARE_API_TOKEN")
	accountID = os.Getenv("CLOUDFLARE_ACCOUNT_ID")
	project = os.Getenv("CLOUDFLARE_PAGES_PROJECT")
	dir = os.Getenv("CLOUDFLARE_EXPORT_DIR")
	if dir == "" {
		dir = "../export" // matches this repo's layout — backend/ and export/ are siblings
	}
	branch = os.Getenv("CLOUDFLARE_PAGES_BRANCH")
	if branch == "" {
		branch = "main"
	}
	ok = token != "" && accountID != "" && project != ""
	return
}

// DeployToCloudflarePages — runs `npx wrangler pages deploy` against
// CLOUDFLARE_EXPORT_DIR. Whatever is sitting in that folder AT THE TIME
// THIS RUNS gets deployed — there's no separate "build" step here, this
// assumes you've already exported + run setup/build.py (see README 5, 11).
// Returns the full command output (for the admin UI / job log) and an
// error if the command failed or wasn't configured.
func DeployToCloudflarePages() (output string, err error) {
	token, accountID, project, dir, branch, ok := CloudflareConfigured()
	if !ok {
		return "", fmt.Errorf("cloudflare not configured — set CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_PAGES_PROJECT in backend/.env")
	}
	if _, statErr := os.Stat(dir); statErr != nil {
		return "", fmt.Errorf("export dir not found: %s (%w) — export the web build and run setup/build.py first", dir, statErr)
	}

	// Deploys can take a while (150MB+ of assets on a slow link) — generous
	// but bounded timeout so a hung upload doesn't wedge the job forever.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	args := []string{
		"--yes", "wrangler@3", "pages", "deploy", dir,
		"--project-name=" + project,
		"--branch=" + branch,
		"--commit-dirty=true",
	}
	cmd := exec.CommandContext(ctx, "npx", args...)
	cmd.Env = append(os.Environ(),
		"CLOUDFLARE_API_TOKEN="+token,
		"CLOUDFLARE_ACCOUNT_ID="+accountID,
		"CI=true", // wrangler: skip interactive prompts
	)

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	runErr := cmd.Run()
	out := strings.TrimSpace(buf.String())

	if ctx.Err() == context.DeadlineExceeded {
		return out, fmt.Errorf("cloudflare deploy timed out after 10 minutes")
	}
	if runErr != nil {
		return out, fmt.Errorf("wrangler deploy failed: %w", runErr)
	}
	return out, nil
}
