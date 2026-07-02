//go:build windows

package game

// privdrop_windows.go — no-op counterpart to privdrop_unix.go. Windows has
// no root/EUID-0 concept and exec.Cmd has no Credential-based privilege
// drop the same way, so there is nothing to do here — this file exists
// purely so replay.go / replay_worker.go can call applyPrivDrop()
// unconditionally on every platform without build-tag branching at each
// call site.

import "os/exec"

func applyPrivDrop(cmd *exec.Cmd, dataDirs ...string) {
	// no-op on Windows
}
