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

	srcPath := filepath.Join(stagedDir, name)
	dstPath := filepath.Join(liveDir, name)
	data, err := os.ReadFile(srcPath)
	if err != nil {
		return "", fmt.Errorf("read staged file: %w", err)
	}
	if err := os.WriteFile(dstPath, data, 0755); err != nil {
		return "", fmt.Errorf("write live file: %w", err)
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
