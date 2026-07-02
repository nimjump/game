package game

// replay_staging.go — lets the admin upload a new replay verifier binary
// without activating it immediately, so it can be bundled into a scheduled
// deploy job (see deploy_job.go) and swapped in atomically together with
// the Cloudflare Pages deploy + replay version bump, at whatever trigger
// the admin picked (now / a specific time / daily leaderboard end / weekly
// leaderboard end).

import (
	"fmt"
	"os"
	"path/filepath"
)

// StagedReplayDir — subfolder of the servergames dir holding an uploaded
// binary that hasn't been activated yet.
func StagedReplayDir() string {
	return filepath.Join(ServerGamesDir(), "staged")
}

// HasStagedReplayBinary — is there a staged file waiting for activation?
func HasStagedReplayBinary() (filename string, ok bool) {
	dir := StagedReplayDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		return e.Name(), true
	}
	return "", false
}

// ClearStagedReplayBinary — discards whatever's staged (e.g. admin cancels
// a scheduled job, or uploads a replacement).
func ClearStagedReplayBinary() error {
	dir := StagedReplayDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		_ = os.Remove(filepath.Join(dir, e.Name()))
	}
	return nil
}

// ActivateStagedReplayBinary — moves the staged file into the live
// servergames dir (overwriting whatever's there), cleans up any
// previously-extracted zip contents, resets the cached binary path, and
// restarts the persistent worker pool. Returns the activated filename.
func ActivateStagedReplayBinary() (string, error) {
	stagedDir := StagedReplayDir()
	name, ok := HasStagedReplayBinary()
	if !ok {
		return "", fmt.Errorf("no staged replay binary to activate")
	}

	liveDir := ServerGamesDir()
	if err := os.MkdirAll(liveDir, 0755); err != nil {
		return "", fmt.Errorf("mkdir live dir: %w", err)
	}
	// MkdirAll's perm is masked by the process umask (root commonly runs
	// with umask 077) — explicit chmod bypasses that, so a privilege-dropped
	// Godot worker (see privdrop_unix.go, only applies if this process is
	// root) can actually traverse into this directory to read the binary/pck.
	if err := os.Chmod(liveDir, 0755); err != nil {
		fmt.Printf("[REPLAY_STAGING] chmod 0755 failed for %s: %v\n", liveDir, err)
	}

	srcPath := filepath.Join(stagedDir, name)
	dstPath := filepath.Join(liveDir, name)
	data, err := os.ReadFile(srcPath)
	if err != nil {
		return "", fmt.Errorf("read staged file: %w", err)
	}
	if err := os.WriteFile(dstPath, data, 0755); err != nil {
		return "", fmt.Errorf("write live file: %w", err)
	}
	// Same umask concern as above — this file (replay.zip, or a directly
	// uploaded "replay" binary) must be world-readable+executable so the
	// privilege-dropped worker can run it.
	if err := os.Chmod(dstPath, 0755); err != nil {
		fmt.Printf("[REPLAY_STAGING] chmod 0755 failed for %s: %v\n", dstPath, err)
	}

	if name == "replay.zip" {
		os.Remove(filepath.Join(liveDir, "replay"))
		os.Remove(filepath.Join(liveDir, "replay.pck"))
	}

	_ = os.Remove(srcPath)
	ResetBinaryCache()
	RestartAllWorkers()
	return name, nil
}
