//go:build !windows

package game

// privdrop_unix.go — automatically drops root privileges for spawned Godot
// worker/verifier child processes.
//
// WHY: Godot's headless engine hangs/misbehaves when started as root/EUID 0
// on Linux (the engine itself prints "Started the engine as root/superuser
// — subsystems like audio may not work correctly" and, in practice, the
// persistent worker's "[WORKER#N] READY" line can simply never arrive,
// which surfaces here as a "worker READY timeout" loop). Rather than
// requiring whoever runs this backend to remember to create a dedicated
// non-root system user and a systemd unit before things work correctly,
// this makes it work correctly no matter who starts the Go process: if the
// Go process itself is root, every Godot child process it spawns is
// automatically re-executed as the unprivileged "nobody" user instead.
//
// The Go process (and thus BadgerDB, the HTTP server, port binding, etc.)
// is completely unaffected — only the exec.Cmd for the Godot binary gets
// this treatment, via exec.Cmd.SysProcAttr.Credential, which is exactly
// what "sudo -u nobody godot ..." would do, just done for you at the
// syscall level before exec.
//
// Override the target user with GODOT_WORKER_USER (must already exist on
// the system) if "nobody" isn't available or isn't desired.

import (
	"log"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"sync"
	"syscall"
)

var (
	privDropOnce sync.Once
	privDropCred *syscall.Credential
	privDropInfo string // for logging once
)

// dropRootCredential — returns a *syscall.Credential to assign to a spawned
// Godot child's cmd.SysProcAttr so it runs as an unprivileged user, or nil
// if the current process isn't root (nothing to drop).
func dropRootCredential() *syscall.Credential {
	if os.Geteuid() != 0 {
		return nil // not root — nothing to do, run normally
	}

	privDropOnce.Do(func() {
		username := os.Getenv("GODOT_WORKER_USER")
		if username == "" {
			username = "nobody"
		}

		u, err := user.Lookup(username)
		var uid, gid uint64
		if err == nil {
			uid, _ = strconv.ParseUint(u.Uid, 10, 32)
			gid, _ = strconv.ParseUint(u.Gid, 10, 32)
		} else {
			// "nobody" not resolvable via NSS for some reason (rare, some
			// minimal containers) — 65534 is the de-facto standard
			// nobody/nogroup UID/GID on essentially every Linux distro.
			log.Printf("[PRIVDROP] user lookup for %q failed (%v) — falling back to uid/gid 65534", username, err)
			uid, gid = 65534, 65534
		}

		privDropCred = &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
		privDropInfo = username
		log.Printf("[PRIVDROP] backend running as root (euid=0) — Godot worker/verifier child processes will drop to user=%q uid=%d gid=%d. Override with GODOT_WORKER_USER env.", username, uid, gid)
	})

	return privDropCred
}

// applyPrivDrop — if the current process is root, sets cmd.SysProcAttr so
// the child drops to an unprivileged user, and relaxes the permissions on
// dataDir (a scratch temp dir the Go process just created as root, e.g.
// --user-data-dir) so the now-unprivileged child can still write into it.
// No-op (cmd untouched) if not running as root.
func applyPrivDrop(cmd *exec.Cmd, dataDirs ...string) {
	cred := dropRootCredential()
	if cred == nil {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: cred}
	for _, dir := range dataDirs {
		if dir == "" {
			continue
		}
		// 0777: these are ephemeral, non-sensitive scratch dirs (Godot
		// user-data-dir / job-result polling dirs) that live under the
		// OS temp dir — world-writable is the simplest way to guarantee
		// the dropped-privilege child (owned by a different uid than the
		// root-created dir) can actually write its output/result files.
		if err := os.Chmod(dir, 0777); err != nil {
			log.Printf("[PRIVDROP] chmod 0777 failed for %s: %v", dir, err)
		}
	}
}
