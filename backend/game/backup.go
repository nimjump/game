package game

import (
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// backup.go — periodic + on-demand BadgerDB backups, uploaded to Cloudflare
// R2 (see r2.go for the actual upload client).
//
// WHY: BadgerDB lives entirely on one disk (DB_PATH). Every player's NIM
// balance, quest progress, VS room/match history, and archived replays are
// only ever written there — there was previously no backup mechanism of any
// kind. If that disk is lost or corrupted, everything is gone with no way
// back. This closes that gap: a full snapshot is taken on a timer, streamed
// to R2, and old snapshots beyond the retention window are pruned so storage
// doesn't grow forever.
//
// Configured entirely via env vars (see backend/.env.example):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET
//   BACKUP_INTERVAL_HOURS (default 6)
//   BACKUP_RETENTION_COUNT (default 28 — ~7 days at the default interval)
// If the R2_* vars aren't set, the scheduler simply never runs (logged once
// at startup) — a fresh dev checkout without R2 configured behaves exactly
// as before, no errors, no spam.

const (
	defaultBackupIntervalHours  = 6
	defaultBackupRetentionCount = 28
	backupObjectPrefix          = "backups/"
)

// BackupStatus is a snapshot of the last backup attempt, surfaced to the
// admin panel so "is this actually working" is answerable at a glance
// instead of requiring a log dive or a trip to the R2 dashboard.
type BackupStatus struct {
	Configured      bool   `json:"configured"`
	LastAttemptAt   int64  `json:"last_attempt_at,omitempty"`
	LastSuccessAt   int64  `json:"last_success_at,omitempty"`
	LastError       string `json:"last_error,omitempty"`
	LastObjectKey   string `json:"last_object_key,omitempty"`
	LastSizeBytes   int64  `json:"last_size_bytes,omitempty"`
	IntervalHours   int    `json:"interval_hours"`
	RetentionCount  int    `json:"retention_count"`
}

var (
	backupStatusMu sync.Mutex
	backupStatus   BackupStatus
	backupRunning  sync.Mutex
)

func backupIntervalHours() int {
	if v := os.Getenv("BACKUP_INTERVAL_HOURS"); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil && n > 0 {
			return n
		}
	}
	return defaultBackupIntervalHours
}

func backupRetentionCount() int {
	if v := os.Getenv("BACKUP_RETENTION_COUNT"); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil && n > 0 {
			return n
		}
	}
	return defaultBackupRetentionCount
}

// GetBackupStatus — read-only snapshot for the admin panel.
func GetBackupStatus() BackupStatus {
	backupStatusMu.Lock()
	st := backupStatus
	backupStatusMu.Unlock()
	_, configured := loadR2Config()
	st.Configured = configured
	st.IntervalHours = backupIntervalHours()
	st.RetentionCount = backupRetentionCount()
	return st
}

func setBackupStatus(mutate func(*BackupStatus)) {
	backupStatusMu.Lock()
	defer backupStatusMu.Unlock()
	mutate(&backupStatus)
}

// StartBackupScheduler kicks off the periodic backup loop. No-ops (logs
// once, returns) if R2 isn't configured — call unconditionally from main.go,
// same as every other background service.
func (s *Store) StartBackupScheduler() {
	if _, ok := loadR2Config(); !ok {
		log.Printf("[BACKUP] R2 not configured (R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET) — automatic backups disabled")
		return
	}
	interval := time.Duration(backupIntervalHours()) * time.Hour
	log.Printf("[BACKUP] scheduler started: every %s, keeping last %d snapshots", interval, backupRetentionCount())

	SafeGo("BackupScheduler", func() {
		// One backup shortly after startup (not instantly — let the DB/worker
		// pool finish settling first) so a box that's been down for a while
		// doesn't wait a full interval before its first fresh snapshot.
		time.Sleep(2 * time.Minute)
		SafeCall("BackupRun", func() { s.RunBackupNow() })

		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			SafeCall("BackupRun", func() { s.RunBackupNow() })
		}
	})
}

// RunBackupNow performs one full BadgerDB backup and uploads it to R2,
// then prunes old snapshots beyond the retention count. Safe to call from
// both the scheduler and an admin-triggered manual request — a second call
// while one is already in flight returns an error immediately instead of
// running two backups concurrently against the same DB.
func (s *Store) RunBackupNow() error {
	cfg, ok := loadR2Config()
	if !ok {
		return fmt.Errorf("R2 not configured")
	}
	if !backupRunning.TryLock() {
		return fmt.Errorf("a backup is already in progress")
	}
	defer backupRunning.Unlock()
	return s.runBackupNowLocked(cfg)
}

// failBackup logs, records, and Telegram-alerts on a backup failure (mirrors
// the existing low-wallet-balance alert pattern in nimiq.go) — a silently
// broken backup system is worse than no backup system, since it creates
// false confidence. Always returns the error unchanged for the caller.
func (s *Store) failBackup(err error) error {
	log.Printf("[BACKUP] FAILED: %v", err)
	setBackupStatus(func(st *BackupStatus) { st.LastError = err.Error() })
	s.SendTelegramDirect(fmt.Sprintf("⚠️ NimJump DB backup FAILED: %v", err))
	return err
}

// pruneOldBackups keeps only the most recent backupRetentionCount() objects
// under backups/ in R2, deleting the rest. Object keys are
// "backups/nimjump-<UTC timestamp>.badgerbak" — lexicographic sort on the
// ISO-8601-ish timestamp is also chronological sort, so no need to parse
// LastModified.
func (s *Store) pruneOldBackups(cfg r2Config) error {
	objects, err := r2ListObjects(cfg, backupObjectPrefix)
	if err != nil {
		return fmt.Errorf("list: %w", err)
	}
	keep := backupRetentionCount()
	if len(objects) <= keep {
		return nil
	}
	sort.Slice(objects, func(i, j int) bool { return objects[i].Key < objects[j].Key })
	toDelete := objects[:len(objects)-keep]
	var errs []string
	for _, obj := range toDelete {
		if err := r2DeleteObject(cfg, obj.Key); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", obj.Key, err))
			continue
		}
		log.Printf("[BACKUP] pruned old snapshot %s", obj.Key)
	}
	if len(errs) > 0 {
		return fmt.Errorf("failed to delete %d/%d old snapshots: %s", len(errs), len(toDelete), strings.Join(errs, "; "))
	}
	return nil
}

// RestoreBackup replaces the ENTIRE live database with the contents of the
// given R2 snapshot. This is the disaster-recovery path an admin reaches
// for after real data loss/corruption — irreversible by nature, so it takes
// several precautions:
//
//  1. Fully downloads the chosen snapshot to a local temp file first. Never
//     touches the live DB until the download is confirmed complete — a
//     dropped connection mid-download aborts cleanly with the live DB
//     completely untouched.
//  2. Takes a fresh "pre-restore" safety snapshot of whatever's live RIGHT
//     NOW and uploads it to R2 before wiping anything. If the admin picked
//     the wrong backup, or restores by mistake, the state right before the
//     restore is never actually gone — it's one more object in the same R2
//     bucket. This step is a hard prerequisite: if it fails (e.g. R2 is
//     unreachable), the restore is aborted rather than proceeding blind.
//  3. Only then: DB.DropAll() (wipes every key) followed by DB.Load() (a
//     bulk-imports the downloaded snapshot's entries) — Badger's own
//     documented restore procedure.
//
// Shares the same backupRunning lock as RunBackupNow so a scheduled
// automatic backup can never tick in the middle of a restore (or vice
// versa) — both touch the same underlying DB.Backup/DB.Load machinery.
func (s *Store) RestoreBackup(key string) error {
	cfg, ok := loadR2Config()
	if !ok {
		return fmt.Errorf("R2 not configured")
	}
	if !backupRunning.TryLock() {
		return fmt.Errorf("a backup or restore is already in progress")
	}
	defer backupRunning.Unlock()

	log.Printf("[RESTORE] starting restore from %s", key)
	s.SendTelegramDirect(fmt.Sprintf("⏳ NimJump DB restore STARTING from snapshot %s — this will briefly disrupt live traffic.", key))

	// 1. Download the chosen snapshot fully, before touching anything live.
	body, err := r2GetObject(cfg, key)
	if err != nil {
		return s.failRestore(fmt.Errorf("download snapshot %s: %w", key, err))
	}
	tmpFile, err := os.CreateTemp("", "nimjump-restore-*.badgerbak")
	if err != nil {
		body.Close()
		return s.failRestore(fmt.Errorf("create temp file: %w", err))
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)
	written, copyErr := io.Copy(tmpFile, body)
	body.Close()
	closeErr := tmpFile.Close()
	if copyErr != nil {
		return s.failRestore(fmt.Errorf("download snapshot %s: %w", key, copyErr))
	}
	if closeErr != nil {
		return s.failRestore(fmt.Errorf("close temp file: %w", closeErr))
	}
	if written == 0 {
		return s.failRestore(fmt.Errorf("downloaded snapshot %s is empty — refusing to restore", key))
	}
	log.Printf("[RESTORE] downloaded %s (%s) to %s", key, r2FormatBytes(written), tmpPath)

	// 2. Mandatory safety net: snapshot current live state before wiping it.
	//    Uses the normal RunBackupNow path directly (not through the lock —
	//    we already hold it), so this pre-restore snapshot lands in the same
	//    backups/ prefix as every other automatic/manual backup and is
	//    subject to the same retention pruning.
	if err := s.runBackupNowLocked(cfg); err != nil {
		return s.failRestore(fmt.Errorf("safety snapshot before restore failed, aborting restore (live DB untouched): %w", err))
	}
	log.Printf("[RESTORE] pre-restore safety snapshot uploaded — proceeding with restore")

	// 3. Point of no return: wipe the live DB, then bulk-load the snapshot.
	if err := s.db.DropAll(); err != nil {
		return s.failRestore(fmt.Errorf("DropAll failed mid-restore — DB may be left EMPTY, restart and restore again immediately: %w", err))
	}
	f, err := os.Open(tmpPath)
	if err != nil {
		return s.failRestore(fmt.Errorf("reopen downloaded snapshot for load — DB is currently EMPTY, restore again immediately: %w", err))
	}
	defer f.Close()
	if err := s.db.Load(f, 256); err != nil {
		return s.failRestore(fmt.Errorf("Load failed mid-restore — DB may be partially loaded, restore again immediately: %w", err))
	}

	log.Printf("[RESTORE] complete — DB restored from %s", key)
	s.SendTelegramDirect(fmt.Sprintf("✅ NimJump DB restore COMPLETE from snapshot %s.", key))
	return nil
}

func (s *Store) failRestore(err error) error {
	log.Printf("[RESTORE] FAILED: %v", err)
	s.SendTelegramDirect(fmt.Sprintf("🛑 NimJump DB restore FAILED: %v", err))
	return err
}

// runBackupNowLocked is RunBackupNow's actual body, factored out so
// RestoreBackup (which already holds backupRunning) can take its mandatory
// pre-restore safety snapshot without deadlocking on its own lock.
func (s *Store) runBackupNowLocked(cfg r2Config) error {
	setBackupStatus(func(st *BackupStatus) { st.LastAttemptAt = time.Now().Unix() })

	tmpFile, err := os.CreateTemp("", "nimjump-backup-*.badgerbak")
	if err != nil {
		return s.failBackup(fmt.Errorf("create temp file: %w", err))
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)

	_, err = s.db.Backup(tmpFile, 0)
	closeErr := tmpFile.Close()
	if err != nil {
		return s.failBackup(fmt.Errorf("badger backup: %w", err))
	}
	if closeErr != nil {
		return s.failBackup(fmt.Errorf("close temp file: %w", closeErr))
	}

	info, err := os.Stat(tmpPath)
	if err != nil {
		return s.failBackup(fmt.Errorf("stat temp file: %w", err))
	}
	if info.Size() == 0 {
		return s.failBackup(fmt.Errorf("badger backup produced an empty file — refusing to upload"))
	}

	f, err := os.Open(tmpPath)
	if err != nil {
		return s.failBackup(fmt.Errorf("reopen temp file: %w", err))
	}
	defer f.Close()

	key := backupObjectPrefix + "nimjump-" + time.Now().UTC().Format("20060102T150405Z") + ".badgerbak"
	if err := r2PutObject(cfg, key, f, info.Size(), "application/octet-stream"); err != nil {
		return s.failBackup(fmt.Errorf("upload to R2: %w", err))
	}

	log.Printf("[BACKUP] uploaded %s (%s) to R2", key, r2FormatBytes(info.Size()))
	setBackupStatus(func(st *BackupStatus) {
		st.LastSuccessAt = time.Now().Unix()
		st.LastObjectKey = key
		st.LastSizeBytes = info.Size()
		st.LastError = ""
	})

	if err := s.pruneOldBackups(cfg); err != nil {
		log.Printf("[BACKUP] prune warning: %v", err)
	}
	return nil
}

// ListBackups — recent R2 snapshots, newest first, for the admin panel.
func ListBackups() ([]r2Object, error) {
	cfg, ok := loadR2Config()
	if !ok {
		return nil, fmt.Errorf("R2 not configured")
	}
	objects, err := r2ListObjects(cfg, backupObjectPrefix)
	if err != nil {
		return nil, err
	}
	sort.Slice(objects, func(i, j int) bool { return objects[i].Key > objects[j].Key })
	return objects, nil
}
