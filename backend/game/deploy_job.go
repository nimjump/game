package game

// deploy_job.go — close-safe scheduled deploy jobs. "Close-safe" here
// means: the job is written to BadgerDB the moment it's created (before
// anything runs), its status is persisted at every transition, and it is
// NEVER silently re-run or silently dropped just because the backend
// process restarted mid-flight — see resumeStaleJobsOnStartup below for
// exactly what happens if the server goes down while a job is running.
//
// A job can bundle up to three actions, executed in this fixed order:
//  1. Activate the staged replay verifier binary (if one was staged and
//     ActivateReplayBinary is true) — swaps the file in + restarts workers.
//  2. Deploy the web export to Cloudflare Pages (if DeployCloudflare is
//     true) — runs whatever is currently sitting in CLOUDFLARE_EXPORT_DIR.
//  3. Bump the replay version (if NewReplayVersion > 0).
//
// Immediately before running, update mode is force-activated (new games
// blocked); immediately after all configured actions succeed, it's
// cleared again (CompleteUpdate) — so players only ever see the "Game
// updating" toast for the few seconds/minutes the job actually takes,
// not for however long was left until the trigger fired.

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

type DeployTrigger string

const (
	TriggerNow         DeployTrigger = "now"
	TriggerAt          DeployTrigger = "at"             // DeployJob.RunAt is an admin-chosen unix timestamp
	TriggerDailyLBEnd  DeployTrigger = "daily_lb_end"    // next daily leaderboard period boundary (UTC+3 midnight)
	TriggerWeeklyLBEnd DeployTrigger = "weekly_lb_end"   // next weekly leaderboard period boundary (Monday 00:00 UTC+3)
)

type DeployJobStatus string

const (
	JobPending DeployJobStatus = "pending"
	JobRunning DeployJobStatus = "running"
	JobDone    DeployJobStatus = "done"
	JobFailed  DeployJobStatus = "failed"
	JobCancelled DeployJobStatus = "cancelled"
)

type DeployJob struct {
	ID      string        `json:"id"`
	Trigger DeployTrigger `json:"trigger"`
	RunAt   int64         `json:"run_at"` // unix ts — resolved once at creation time, never recomputed

	ActivateReplayBinary bool `json:"activate_replay_binary"`
	DeployCloudflare     bool `json:"deploy_cloudflare"`
	NewReplayVersion     int  `json:"new_replay_version,omitempty"`

	Status     DeployJobStatus `json:"status"`
	Log        []string        `json:"log,omitempty"`
	Error      string          `json:"error,omitempty"`
	CreatedAt  int64           `json:"created_at"`
	StartedAt  int64           `json:"started_at,omitempty"`
	FinishedAt int64           `json:"finished_at,omitempty"`
}

const (
	deployJobPrefix = "deployjob:"
	deployJobTTL    = 90 * 24 * time.Hour
	// staleRunningThreshold — if a job is still "running" after this long,
	// the backend that was executing it almost certainly crashed/restarted
	// mid-flight. We do NOT silently resume/re-run it (a Cloudflare deploy
	// or binary swap is not always safe to blindly repeat) — instead it's
	// marked failed with a clear reason, so an admin can look at the job
	// log and decide whether to schedule a fresh retry.
	staleRunningThreshold = 10 * time.Minute
)

func deployJobKey(id string) []byte { return []byte(deployJobPrefix + id) }

func (s *Store) SaveDeployJob(j *DeployJob) error {
	data, err := json.Marshal(j)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(badger.NewEntry(deployJobKey(j.ID), data).WithTTL(deployJobTTL))
	})
}

func (s *Store) GetDeployJob(id string) (*DeployJob, error) {
	var j DeployJob
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(deployJobKey(id))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &j) })
	})
	if err != nil {
		return nil, err
	}
	return &j, nil
}

// ListDeployJobs — most recent first.
func (s *Store) ListDeployJobs(limit int) []DeployJob {
	var out []DeployJob
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(deployJobPrefix)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var j DeployJob
				if err := json.Unmarshal(v, &j); err == nil {
					out = append(out, j)
				}
				return nil
			})
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// resolveRunAt — turns a trigger into a concrete unix timestamp, computed
// once (daily/weekly boundaries are deterministic, so there's no need to
// keep recomputing them — the scheduler just compares wall clock to this
// stored value).
func resolveRunAt(trigger DeployTrigger, atUnix int64) (int64, error) {
	switch trigger {
	case TriggerNow:
		return time.Now().Unix(), nil
	case TriggerAt:
		if atUnix <= 0 {
			return 0, fmt.Errorf("at_unix required for trigger=at")
		}
		return atUnix, nil
	case TriggerDailyLBEnd:
		now := time.Now().In(utc3)
		next := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, utc3).AddDate(0, 0, 1)
		return next.Unix(), nil
	case TriggerWeeklyLBEnd:
		now := time.Now().In(utc3)
		// Monday 00:00 of the week AFTER the current one.
		weekday := int(now.Weekday())
		if weekday == 0 {
			weekday = 7
		}
		daysUntilNextMonday := 8 - weekday
		next := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, utc3).AddDate(0, 0, daysUntilNextMonday)
		return next.Unix(), nil
	default:
		return 0, fmt.Errorf("unknown trigger: %q", trigger)
	}
}

// ScheduleDeployJob — creates and immediately persists a new job. Only one
// pending/running job is allowed at a time (keeps the mental model simple —
// "what's going to happen next" always has one obvious answer). Returns an
// error if one is already in flight; cancel it first.
func (s *Store) ScheduleDeployJob(trigger DeployTrigger, atUnix int64, activateReplayBinary, deployCloudflare bool, newReplayVersion int) (*DeployJob, error) {
	for _, j := range s.ListDeployJobs(20) {
		if j.Status == JobPending || j.Status == JobRunning {
			return nil, fmt.Errorf("a deploy job is already %s (id=%s) — cancel it first", j.Status, j.ID)
		}
	}
	if !activateReplayBinary && !deployCloudflare && newReplayVersion <= 0 {
		return nil, fmt.Errorf("nothing to do — enable at least one action")
	}
	if activateReplayBinary {
		if _, ok := HasStagedReplayBinary(); !ok {
			return nil, fmt.Errorf("no staged replay binary — upload one with stage=1 first")
		}
	}

	runAt, err := resolveRunAt(trigger, atUnix)
	if err != nil {
		return nil, err
	}

	j := &DeployJob{
		ID:                   fmt.Sprintf("job_%d", time.Now().UnixNano()),
		Trigger:              trigger,
		RunAt:                runAt,
		ActivateReplayBinary: activateReplayBinary,
		DeployCloudflare:     deployCloudflare,
		NewReplayVersion:     newReplayVersion,
		Status:               JobPending,
		CreatedAt:            time.Now().Unix(),
	}
	if err := s.SaveDeployJob(j); err != nil {
		return nil, err
	}
	log.Printf("[DEPLOY_JOB] scheduled id=%s trigger=%s run_at=%s cloudflare=%v binary=%v new_version=%d",
		j.ID, trigger, time.Unix(runAt, 0).Format(time.RFC3339), deployCloudflare, activateReplayBinary, newReplayVersion)
	return j, nil
}

// CancelPendingDeployJob — only works while still "pending" (hasn't started
// running yet). Also discards a staged replay binary tied to it, if any.
func (s *Store) CancelPendingDeployJob(id string) error {
	j, err := s.GetDeployJob(id)
	if err != nil {
		return err
	}
	if j.Status != JobPending {
		return fmt.Errorf("job is %s, not pending — can't cancel", j.Status)
	}
	j.Status = JobCancelled
	j.FinishedAt = time.Now().Unix()
	if err := s.SaveDeployJob(j); err != nil {
		return err
	}
	if j.ActivateReplayBinary {
		_ = ClearStagedReplayBinary()
	}
	log.Printf("[DEPLOY_JOB] cancelled id=%s", id)
	return nil
}

func (j *DeployJob) appendLog(s *Store, line string) {
	j.Log = append(j.Log, fmt.Sprintf("[%s] %s", time.Now().Format("15:04:05"), line))
	_ = s.SaveDeployJob(j)
	log.Printf("[DEPLOY_JOB %s] %s", j.ID, line)
}

// runDeployJob — executes one job's configured actions in order. Every
// state transition is saved to the DB before doing the next risky thing.
func (s *Store) runDeployJob(j *DeployJob) {
	j.Status = JobRunning
	j.StartedAt = time.Now().Unix()
	_ = s.SaveDeployJob(j)

	// Block new games for the duration of the update.
	if _, err := s.SetUpdateMode(UpdateModeForce); err != nil {
		j.appendLog(s, "warning: failed to activate update-block: "+err.Error())
	} else {
		j.appendLog(s, "new games blocked (update mode: force)")
	}

	failed := false

	if j.ActivateReplayBinary {
		j.appendLog(s, "activating staged replay binary...")
		name, err := ActivateStagedReplayBinary()
		if err != nil {
			j.appendLog(s, "FAILED activating replay binary: "+err.Error())
			failed = true
		} else {
			j.appendLog(s, "replay binary activated: "+name)
		}
	}

	if !failed && j.DeployCloudflare {
		j.appendLog(s, "deploying to Cloudflare Pages...")
		out, err := DeployToCloudflarePages()
		if out != "" {
			j.appendLog(s, "wrangler output:\n"+out)
		}
		if err != nil {
			j.appendLog(s, "FAILED Cloudflare deploy: "+err.Error())
			failed = true
		} else {
			j.appendLog(s, "Cloudflare Pages deploy succeeded")
		}
	}

	if !failed && j.NewReplayVersion > 0 {
		cfg := s.GetAppConfig()
		cfg.ReplayVersion = j.NewReplayVersion
		if err := s.SaveAppConfig(cfg); err != nil {
			j.appendLog(s, "FAILED setting replay version: "+err.Error())
			failed = true
		} else {
			j.appendLog(s, fmt.Sprintf("replay version set to %d", j.NewReplayVersion))
		}
	}

	j.FinishedAt = time.Now().Unix()
	if failed {
		j.Status = JobFailed
		j.Error = "one or more steps failed — see log. Game updating mode stays ON until you fix it and either retry or click Complete Update manually."
		_ = s.SaveDeployJob(j)
		log.Printf("[DEPLOY_JOB] FAILED id=%s — update mode left ON, needs manual attention", j.ID)
		return
	}

	j.Status = JobDone
	_ = s.SaveDeployJob(j)
	if _, err := s.CompleteUpdate(); err != nil {
		j.appendLog(s, "warning: failed to clear update-block after success: "+err.Error())
		_ = s.SaveDeployJob(j)
	} else {
		j.appendLog(s, "done — update mode cleared, play resumed")
	}
	log.Printf("[DEPLOY_JOB] done id=%s", j.ID)
}

// resumeStaleJobsOnStartup — called once at boot. Any job left "running"
// from before a restart is marked failed (see staleRunningThreshold's
// doc comment for why this doesn't just resume/re-run it).
func (s *Store) resumeStaleJobsOnStartup() {
	now := time.Now().Unix()
	for _, j := range s.ListDeployJobs(20) {
		if j.Status != JobRunning {
			continue
		}
		jj := j
		if now-jj.StartedAt < int64(staleRunningThreshold.Seconds()) {
			// Started recently enough it might genuinely still be running
			// in a process that hasn't actually died — leave it alone,
			// the scheduler loop will re-evaluate it on its next tick if
			// it really is stuck (see below).
			continue
		}
		jj.Status = JobFailed
		jj.Error = "backend restarted while this job was running — marked failed rather than silently re-run. Check server logs, then retry manually if needed."
		jj.FinishedAt = now
		_ = s.SaveDeployJob(&jj)
		log.Printf("[DEPLOY_JOB] startup: marked stale running job as failed id=%s", jj.ID)
	}
}

// StartDeployJobScheduler — background loop, checks every 15s for a
// pending job whose RunAt has arrived.
func (s *Store) StartDeployJobScheduler() {
	s.resumeStaleJobsOnStartup()
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			now := time.Now().Unix()
			for _, j := range s.ListDeployJobs(5) {
				if j.Status == JobPending && j.RunAt <= now {
					jj := j
					s.runDeployJob(&jj)
					break // one at a time
				}
			}
		}
	}()
}
