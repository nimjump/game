package main

// adminproc.go — starts the Next.js admin app as a child process of the
// Go backend, so `go run .` (or the compiled binary) is the only thing
// that needs to be started by hand. This isn't just "spawn npm start" —
// the backend fully bootstraps the admin app itself before ever trying to
// run it:
//
//   1. If admin/node_modules doesn't exist yet → runs `npm install`.
//   2. If ADMIN_START_CMD is a production start (the default, "npm
//      start") and there's no production build yet (no .next/BUILD_ID)
//      → runs `npm run build`.
//   3. Only then starts the actual admin app.
//
// So a totally fresh checkout, or a machine where you forgot to build
// after pulling new admin code, both just work off a single `go run .` —
// no separate `cd admin && npm install && npm run build` step required.
//
// If the admin process ever exits after that — crash, `npm` hiccup,
// whatever — it's restarted automatically with a backoff (re-checking
// steps 1/2 first, which are cheap no-ops once already satisfied), for as
// long as the backend itself keeps running. When the backend shuts down,
// the admin process is killed with it (see the ctx passed in from main).

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// startAdminSupervisor launches and supervises the admin app. Runs entirely
// in background goroutines; returns immediately. Set ADMIN_AUTOSTART=false
// to disable (e.g. if you'd rather run/manage the admin app yourself, or
// run it on a separate host).
func startAdminSupervisor(ctx context.Context) {
	if v := os.Getenv("ADMIN_AUTOSTART"); v == "0" || strings.EqualFold(v, "false") {
		log.Printf("[ADMIN_PROC] ADMIN_AUTOSTART=%s — not starting the admin app automatically (start it yourself: cd admin && npm install && npm run build && npm start)", v)
		return
	}

	dir := os.Getenv("ADMIN_DIR")
	if dir == "" {
		dir = "../admin" // matches this repo's layout — admin/ next to backend/
	}
	absDir, err := filepath.Abs(dir)
	if err != nil {
		log.Printf("[ADMIN_PROC] bad ADMIN_DIR %q: %v — not starting admin app", dir, err)
		return
	}
	if fi, statErr := os.Stat(absDir); statErr != nil || !fi.IsDir() {
		log.Printf("[ADMIN_PROC] admin dir not found at %s — not starting admin app (set ADMIN_DIR if the admin app lives elsewhere, or ADMIN_AUTOSTART=false to silence this)", absDir)
		return
	}
	if _, err := exec.LookPath("npm"); err != nil {
		log.Printf("[ADMIN_PROC] npm not found on PATH — not starting admin app (Node.js/npm must be installed on this machine; set ADMIN_AUTOSTART=false to silence this)")
		return
	}

	cmdLine := os.Getenv("ADMIN_START_CMD")
	if cmdLine == "" {
		cmdLine = "npm start" // production — built automatically below if needed
	}
	parts := strings.Fields(cmdLine)
	if len(parts) == 0 {
		log.Printf("[ADMIN_PROC] ADMIN_START_CMD is empty — not starting admin app")
		return
	}

	go superviseAdmin(ctx, absDir, parts)
}

func superviseAdmin(ctx context.Context, dir string, cmdParts []string) {
	backoff := time.Second
	const maxBackoff = 30 * time.Second

	for {
		if ctx.Err() != nil {
			return
		}

		// Cheap on every iteration after the first: just two os.Stat calls
		// once node_modules/.next already exist. Expensive (npm install /
		// npm run build) only the first time, or after you wipe those
		// folders, or with ADMIN_REBUILD_ON_START=true.
		if err := prepareAdminApp(ctx, dir, cmdParts); err != nil {
			log.Printf("[ADMIN_BUILD] %v — retrying in %s", err, backoff)
			if !sleepOrDone(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff, maxBackoff)
			continue
		}

		// Same idea as the early port probe in main.go: check ADMIN_PORT is
		// actually free before spawning `npm start`. Without this, a second
		// instance of this backend (e.g. `go run .` started by hand while
		// the systemd/service-managed one is already running) would spawn
		// its own `npm start`, watch it fail deep inside Next.js trying to
		// bind the same port, and keep retrying with backoff forever — a
		// confusing "it's stuck in some loop, is it ballooning?" symptom
		// instead of a clear one-line explanation.
		if busyAddr := adminPortBusy(); busyAddr != "" {
			log.Printf("[ADMIN_PROC] %s is already in use — most likely another instance of this backend (and its admin app) is already running. Not starting a duplicate; will keep checking every %s. Stop the other instance first if this isn't expected.", busyAddr, backoff)
			if !sleepOrDone(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff, maxBackoff)
			continue
		}

		log.Printf("[ADMIN_PROC] starting admin app (%s) in %s", strings.Join(cmdParts, " "), dir)
		cctx, cancel := context.WithCancel(ctx)
		cmd := exec.CommandContext(cctx, cmdParts[0], cmdParts[1:]...)
		cmd.Dir = dir
		cmd.Env = os.Environ()

		stdout, _ := cmd.StdoutPipe()
		stderr, _ := cmd.StderrPipe()
		startedAt := time.Now()

		if startErr := cmd.Start(); startErr != nil {
			cancel()
			log.Printf("[ADMIN_PROC] failed to start: %v — retrying in %s", startErr, backoff)
			if !sleepOrDone(ctx, backoff) {
				return
			}
			backoff = nextBackoff(backoff, maxBackoff)
			continue
		}

		go streamPrefixed("[ADMIN]", stdout)
		go streamPrefixed("[ADMIN]", stderr)

		waitErr := cmd.Wait()
		cancel()

		if ctx.Err() != nil {
			// Backend is shutting down — this exit is expected, not a crash.
			log.Printf("[ADMIN_PROC] admin app stopped (backend shutting down)")
			return
		}

		ran := time.Since(startedAt)
		if waitErr != nil {
			log.Printf("[ADMIN_PROC] admin app exited after %s: %v", ran.Round(time.Second), waitErr)
		} else {
			log.Printf("[ADMIN_PROC] admin app exited cleanly after %s (unexpected — it's supposed to keep serving)", ran.Round(time.Second))
		}

		// Stayed up a good while before dying → probably a real, one-off
		// crash rather than a config problem — reset the backoff so a
		// single blip doesn't leave it waiting 30s next time.
		if ran > 30*time.Second {
			backoff = time.Second
		} else {
			backoff = nextBackoff(backoff, maxBackoff)
		}
		log.Printf("[ADMIN_PROC] restarting admin app in %s", backoff)
		if !sleepOrDone(ctx, backoff) {
			return
		}
	}
}

// prepareAdminApp makes sure the admin app is actually runnable before
// superviseAdmin tries to start it: installs npm dependencies if missing,
// and — for a production start command — builds it if there's no build
// yet (or unconditionally, if ADMIN_REBUILD_ON_START=true).
func prepareAdminApp(ctx context.Context, dir string, cmdParts []string) error {
	nodeModules := filepath.Join(dir, "node_modules")
	if _, err := os.Stat(nodeModules); os.IsNotExist(err) {
		log.Printf("[ADMIN_BUILD] node_modules not found — running npm install in %s (first run only, can take a minute)", dir)
		if err := runBuildStep(ctx, dir, "npm", "install"); err != nil {
			return fmt.Errorf("npm install failed: %w", err)
		}
		log.Printf("[ADMIN_BUILD] npm install done")
	}

	if !isProductionStart(cmdParts) {
		return nil // e.g. "npm run dev" — no build step, Next.js compiles on the fly
	}

	forceRebuild := envTrue("ADMIN_REBUILD_ON_START")
	buildIDPath := filepath.Join(dir, ".next", "BUILD_ID")
	_, statErr := os.Stat(buildIDPath)
	needsBuild := forceRebuild || os.IsNotExist(statErr)
	if !needsBuild {
		return nil
	}

	reason := "no production build found (.next/BUILD_ID missing)"
	if forceRebuild {
		reason = "ADMIN_REBUILD_ON_START=true"
	}
	log.Printf("[ADMIN_BUILD] %s — running npm run build in %s (can take a minute)", reason, dir)
	if err := runBuildStep(ctx, dir, "npm", "run", "build"); err != nil {
		return fmt.Errorf("npm run build failed: %w", err)
	}
	log.Printf("[ADMIN_BUILD] build complete")
	return nil
}

// isProductionStart — true for "npm start" / "npm run start", false for
// "npm run dev" (dev mode compiles on request, no separate build step).
func isProductionStart(cmdParts []string) bool {
	return strings.Contains(strings.Join(cmdParts, " "), "start")
}

func envTrue(key string) bool {
	v := os.Getenv(key)
	return v == "1" || strings.EqualFold(v, "true")
}

// runBuildStep runs one setup command (npm install / npm run build) to
// completion, streaming its output with an [ADMIN_BUILD] prefix. Bounded
// by a generous timeout so a genuinely hung install/build doesn't wedge
// the supervisor forever.
func runBuildStep(ctx context.Context, dir string, name string, args ...string) error {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(cctx, name, args...)
	cmd.Dir = dir
	cmd.Env = os.Environ()

	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		return err
	}
	go streamPrefixed("[ADMIN_BUILD]", stdout)
	go streamPrefixed("[ADMIN_BUILD]", stderr)
	return cmd.Wait()
}

// adminPortBusy checks whether ADMIN_PORT (default 3001, same default
// admin_proxy.go's adminPort() uses) is already occupied by something else.
// Returns the "host:port" string if busy, or "" if free.
func adminPortBusy() string {
	port := os.Getenv("ADMIN_PORT")
	if port == "" {
		port = "3001"
	}
	addr := "127.0.0.1:" + port
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return addr
	}
	ln.Close()
	return ""
}

// sleepOrDone waits for d, or returns false early if ctx is cancelled.
func sleepOrDone(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

func nextBackoff(cur, max time.Duration) time.Duration {
	next := cur * 2
	if next > max {
		return max
	}
	return next
}

func streamPrefixed(prefix string, r io.Reader) {
	if r == nil {
		return
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		log.Printf("%s %s", prefix, sc.Text())
	}
}
