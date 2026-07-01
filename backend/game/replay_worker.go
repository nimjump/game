package game

// Persistent Godot worker pool — dosya-polling mimarisi
//
// Mimari:
//   Go  → /tmp/wrk_job_<wid>_<nano>.json  yazar
//   Godot → dosyayı okur, siler, replay simüle eder
//   Godot → /tmp/wrk_result_<nano>.json   yazar
//   Go  → sonuç dosyasını polling ile okur
//
// Her worker = bir kalıcı Godot headless process.
// Crash → otomatik restart (2s bekleme).
// 500 iş → sağlıklı restart (memory leak önlemi).
// 24 saatte bir → tüm worker'ları sırayla restart.
//
// ── FIX (2026-06-30): "result timeout" zincirleme hatası ──────────────────────
//
// ESKİ DAVRANIŞ (bug):
//   SimulateReplayFast çağıranı 60s sonra pes ediyordu, ama worker'ın
//   processJobs/runJob döngüsü işi GÖRMEZDEN GELMİYORDU — worker hâlâ
//   90 saniyeye kadar o "terk edilmiş" (orphan) job ile meşgul kalıyordu.
//   Bu sırada retry mekanizması YENİ bir job kuyruğa atıyordu, ama worker
//   meşgul olduğu için o da bekliyordu. Tek worker varsa (varsayılan!) bu
//   3-4 dakikalık zincirleme tıkanmaya yol açıyordu — loglarda görülen tam
//   olarak buydu (attempt 1 → 60s bekle → worker hâlâ eski job'da →
//   attempt 2 → worker restart olunca yeni job alır → tekrar 60s → ...).
//
// YENİ DAVRANIŞ (fix):
//   1. Her job'a submittedAt + bir "cancelled" flag eklendi. Caller
//      timeout'ta pes ettiğinde flag set edilir.
//   2. processJobs, kuyruktan bir job çekince ÖNCE flag'e bakar — eğer
//      caller zaten pes etmişse (kuyrukta timeoutSec'ten uzun bekleyen
//      job), worker o işi hiç Godot'a yazmadan atlar → worker anında boşa
//      çıkar, sıradaki gerçek job'a geçer.
//   3. runJob artık sabit 90s değil, job'un KENDİ timeout'una göre bir
//      deadline kullanır (submittedAt + timeoutSec + küçük tampon). Yani
//      caller 60s'de pes ediyorsa, worker da ~65s'de pes eder — 90s'lik
//      fazladan orphan bekleme süresi ortadan kalkar.
//   4. Her aşamada (queue wait, exec time, deadline) detaylı log basılır,
//      böylece "Godot mu yavaş, yoksa kuyrukta mı bekliyor" net ayrılır.
//   5. Varsayılan worker sayısı 1'den 2'ye çıkarıldı — tek worker, tek bir
//      yavaş job'un TÜM oyuncuları kilitlemesi anlamına geliyordu.

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// ── Tipler ────────────────────────────────────────────────────────────────────

type workerJob struct {
	Seed       string `json:"seed"`        // string — int64 > 2^53, JSON float64 precision loss olur
	Char       int    `json:"char"`
	PlayerSeed string `json:"player_seed"` // string — aynı sebep
	Log        string `json:"log"`         // hex-encoded raw replay bytes
	Out        string `json:"out"`         // result JSON path (written by Godot)
}

type godotWorker struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	id      int
	alive   bool
	jobs    int
	born    time.Time
	lastJob time.Time
}

type workerPool struct {
	mu      sync.Mutex
	workers []*godotWorker
	jobCh   chan workerPoolJob
	size    int
	jobDir  string // dir for job/result files
}

type workerPoolJob struct {
	job         workerJob
	result      chan workerPoolResult
	jobID       string        // kısa trace ID — loglarda job'u takip etmek için
	submittedAt time.Time     // kuyruğa eklendiği an
	timeoutSec  int           // caller'ın bekleyeceği max süre
	cancelled   *atomic.Bool  // caller pes ettiğinde true olur
}

type workerPoolResult struct {
	result *GodotReplayResult
	err    error
}

// ── Singleton pool ─────────────────────────────────────────────────────────────

var (
	_pool     *workerPool
	_poolOnce sync.Once
)

func workerCount() int {
	if env := os.Getenv("REPLAY_WORKERS"); env != "" {
		var n int
		if _, err := fmt.Sscan(env, &n); err == nil && n > 0 && n <= 20 {
			return n
		}
	}
	// FIX: varsayılan 1 → 2. Tek worker, tek bir yavaş/sorunlu job geldiğinde
	// arkasındaki TÜM oyuncuların replay'ini kilitliyordu. 2 worker, bir job
	// takılsa bile diğer worker'ın işlemeye devam etmesini sağlar.
	return 2
}

// GetWorkerPool — singleton, ilk çağrıda başlatılır (main.go'dan warmup çağrısı yapılıyor)
func GetWorkerPool() *workerPool {
	_poolOnce.Do(func() {
		jobDir := os.TempDir()
		size := workerCount()
		p := &workerPool{
			size:   size,
			jobCh:  make(chan workerPoolJob, size*8),
			jobDir: jobDir,
		}
		p.workers = make([]*godotWorker, size)
		for i := 0; i < size; i++ {
			w := &godotWorker{id: i + 1}
			p.workers[i] = w
			go p.runWorker(w)
		}
		go p.dailyRestart()
		_pool = p
		log.Printf("[WORKER_POOL] started size=%d job_dir=%s", size, jobDir)
	})
	return _pool
}

// ── Public API ─────────────────────────────────────────────────────────────────

// jobIDCounter — trace ID üretmek için basit atomik sayaç (nano time çakışmasın diye)
var jobIDCounter int64

func nextJobID(seed int64) string {
	n := atomic.AddInt64(&jobIDCounter, 1)
	return fmt.Sprintf("j%d_seed%d", n, seed%100000)
}

// SimulateReplayFast — persistent worker pool kullanır, SimulateReplay ile aynı imza
func SimulateReplayFast(replayLogB64 string, seed int64, charIdx int, timeoutSec int, playerSeedOpt ...int64) (*GodotReplayResult, error) {
	var playerSeed int64
	if len(playerSeedOpt) > 0 {
		playerSeed = playerSeedOpt[0]
	}

	raw, err := base64.StdEncoding.DecodeString(replayLogB64)
	if err != nil {
		return nil, fmt.Errorf("replay log decode: %w", err)
	}

	nano := time.Now().UnixNano()
	outFile := filepath.Join(os.TempDir(), fmt.Sprintf("wrk_result_%d.json", nano))

	job := workerJob{
		Seed:       fmt.Sprintf("%d", seed),
		Char:       charIdx,
		PlayerSeed: fmt.Sprintf("%d", playerSeed),
		Log:        hex.EncodeToString(raw),
		Out:        outFile,
	}

	if timeoutSec <= 0 {
		timeoutSec = 60
	}

	jobID := nextJobID(seed)
	cancelled := &atomic.Bool{}
	submittedAt := time.Now()

	resultCh := make(chan workerPoolResult, 1)
	poolJob := workerPoolJob{
		job:         job,
		result:      resultCh,
		jobID:       jobID,
		submittedAt: submittedAt,
		timeoutSec:  timeoutSec,
		cancelled:   cancelled,
	}

	pool := GetWorkerPool()
	qLenBefore := len(pool.jobCh)
	log.Printf("[REPLAY_JOB] %s queued seed=%d char=%d timeout=%ds queue_len_before=%d",
		jobID, seed, charIdx, timeoutSec, qLenBefore)

	pool.jobCh <- poolJob

	select {
	case res := <-resultCh:
		waited := time.Since(submittedAt)
		if res.err != nil {
			log.Printf("[REPLAY_JOB] %s FAILED after %.1fs: %v", jobID, waited.Seconds(), res.err)
		} else {
			log.Printf("[REPLAY_JOB] %s OK after %.1fs score=%d", jobID, waited.Seconds(), res.result.ServerScore)
		}
		return res.result, res.err
	case <-time.After(time.Duration(timeoutSec) * time.Second):
		// FIX: caller pes ediyor — cancelled flag'i set et ki processJobs/runJob
		// bu işi hâlâ kuyrukta veya çalışıyorsa erkenden terk edebilsin.
		cancelled.Store(true)
		os.Remove(outFile)
		log.Printf("[REPLAY_JOB] %s CALLER TIMEOUT after %ds — marking cancelled (queue_len_now=%d)",
			jobID, timeoutSec, len(pool.jobCh))
		return nil, fmt.Errorf("worker pool timeout (%ds) seed=%d job=%s", timeoutSec, seed, jobID)
	}
}

// SimulateReplayWithRetry — worker bizim hatamızdan fail edebilir (crash, restart, timeout).
// Max 3 deneme (ilk + 2 retry). Hepsi başarısız olursa nil döner → caller StateReplayFailed yazar.
// Backoff: 3s → 6s
func SimulateReplayWithRetry(sessionID, replayLogB64 string, seed int64, charIdx int, playerSeed int64, ticks int) *GodotReplayResult {
	sid8 := sessionID
	if len(sid8) > 8 {
		sid8 = sid8[:8]
	}

	timeoutSec := ReplayTimeoutSec(ticks)
	const maxAttempts = 3
	backoff := []time.Duration{3 * time.Second, 6 * time.Second}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		attemptStart := time.Now()
		result, err := SimulateReplayFast(replayLogB64, seed, charIdx, timeoutSec, playerSeed)
		if err == nil {
			if attempt > 1 {
				log.Printf("[REPLAY_RETRY] success session=%s attempt=%d elapsed=%.1fs",
					sid8, attempt, time.Since(attemptStart).Seconds())
			}
			return result
		}
		lastErr = err
		if attempt < maxAttempts {
			wait := backoff[attempt-1]
			log.Printf("[REPLAY_RETRY] attempt=%d/%d session=%s err=%v — retry in %s (pool_status: queue_len=%d timeout=%ds ticks=%d)",
				attempt, maxAttempts, sid8, err, wait, len(GetWorkerPool().jobCh), timeoutSec, ticks)
			time.Sleep(wait)
		}
	}
	log.Printf("[REPLAY_RETRY] FAILED after %d attempts session=%s last_err=%v timeout=%ds ticks=%d", maxAttempts, sid8, lastErr, timeoutSec, ticks)
	return nil
}

// ReplayTimeoutSec — uzun replay'ler için dinamik süre (60s sabit timeout worker'ı erken kesiyordu).
func ReplayTimeoutSec(ticks int) int {
	sec := 45 + ticks/15
	if sec < 90 {
		sec = 90
	}
	if sec > 600 {
		sec = 600
	}
	return sec
}

// WorkerPoolStatus — admin/debug için pool durumu
func WorkerPoolStatus() map[string]interface{} {
	p := GetWorkerPool()
	p.mu.Lock()
	defer p.mu.Unlock()

	workers := make([]map[string]interface{}, len(p.workers))
	for i, w := range p.workers {
		w.mu.Lock()
		workers[i] = map[string]interface{}{
			"id":       w.id,
			"alive":    w.alive,
			"jobs":     w.jobs,
			"born":     w.born.Format(time.RFC3339),
			"last_job": w.lastJob.Format(time.RFC3339),
		}
		w.mu.Unlock()
	}
	return map[string]interface{}{
		"size":      p.size,
		"queue_len": len(p.jobCh),
		"queue_cap": cap(p.jobCh),
		"workers":   workers,
	}
}

// ── Worker lifecycle ───────────────────────────────────────────────────────────

// runWorker — her worker için goroutine: başlat, işle, crash'te restart
func (p *workerPool) runWorker(w *godotWorker) {
	for {
		if err := p.startProcess(w); err != nil {
			log.Printf("[WORKER#%d] start failed: %v — retry in 5s", w.id, err)
			time.Sleep(5 * time.Second)
			continue
		}
		p.processJobs(w)
		log.Printf("[WORKER#%d] exited after %d jobs — restarting in 2s", w.id, w.jobs)
		time.Sleep(2 * time.Second)
		w.mu.Lock()
		w.jobs = 0
		w.alive = false
		w.mu.Unlock()
	}
}

// startProcess — Godot'u başlatır, stdout'tan "[WORKER#N] READY" bekler
func (p *workerPool) startProcess(w *godotWorker) error {
	bin := godotBinary()
	if bin == "" {
		return fmt.Errorf("godot binary not found")
	}

	crashDir := filepath.Join(os.TempDir(), fmt.Sprintf("godot_wkr_%d_%d", w.id, time.Now().UnixNano()))
	_ = os.MkdirAll(crashDir, 0755)

	wid := fmt.Sprintf("%d", w.id)
	cmd := exec.Command(bin,
		"--headless",
		"--audio-driver", "Dummy",
		"--user-data-dir", crashDir,
		"--", "--server-worker",
	)
	cmd.Env = append(os.Environ(),
		"WORKER_JOB_DIR="+p.jobDir,
		"WORKER_ID="+wid,
		"DISPLAY=",
		"PULSE_SERVER=",
	)

	// stdout → pipe; okuma goroutine'i READY satırını arar, geri kalanını loglar
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		pw.Close()
		return fmt.Errorf("cmd.Start: %w", err)
	}

	// process bitince yazma ucunu kapat → scanner EOF görür
	go func() { cmd.Wait(); pw.Close() }()

	w.mu.Lock()
	w.cmd = cmd
	w.born = time.Now()
	w.alive = false
	w.mu.Unlock()

	readyCh := make(chan bool, 1)
	readyLine := fmt.Sprintf("[WORKER#%s] READY", wid)
	go func() {
		scanner := bufio.NewScanner(pr)
		for scanner.Scan() {
			line := scanner.Text()
			log.Printf("[WORKER#%d] %s", w.id, line)
			if line == readyLine {
				readyCh <- true
				// Kalan satırları loglamaya devam et
				for scanner.Scan() {
					log.Printf("[WORKER#%d] %s", w.id, scanner.Text())
				}
				return
			}
		}
		readyCh <- false
	}()

	select {
	case ok := <-readyCh:
		if !ok {
			cmd.Process.Kill()
			return fmt.Errorf("worker did not send READY")
		}
	case <-time.After(30 * time.Second):
		cmd.Process.Kill()
		return fmt.Errorf("worker READY timeout")
	}

	w.mu.Lock()
	w.alive = true
	w.mu.Unlock()
	log.Printf("[WORKER#%d] ready (pid=%d)", w.id, cmd.Process.Pid)
	return nil
}

// processJobs — worker hazır, job kanalından iş al
func (p *workerPool) processJobs(w *godotWorker) {
	for jobMsg := range p.jobCh {
		// ── FIX: caller zaten pes etmiş mi? ──────────────────────────────────
		// Job kuyrukta timeoutSec'ten uzun süre bekleyip caller'ın select'i
		// zaten timeout ile dönmüşse, bu işi Godot'a hiç yazmadan atla.
		// Bu, worker'ı anında boşaltır ve sıradaki canlı job'a geçmesini sağlar
		// — orphan job'ların worker'ı bloke etmesini önler.
		queueWait := time.Since(jobMsg.submittedAt)
		if jobMsg.cancelled.Load() {
			log.Printf("[WORKER#%d] %s SKIPPED — caller already gave up (queue_wait=%.1fs)",
				w.id, jobMsg.jobID, queueWait.Seconds())
			continue
		}
		if queueWait > time.Duration(jobMsg.timeoutSec)*time.Second {
			// cancelled flag henüz set edilmemiş olabilir (race) ama mantıken
			// caller artık beklemiyor — yine de atla, sonucu kimse okumayacak.
			log.Printf("[WORKER#%d] %s SKIPPED — queue_wait=%.1fs exceeded caller timeout=%ds (stale job)",
				w.id, jobMsg.jobID, queueWait.Seconds(), jobMsg.timeoutSec)
			continue
		}

		w.mu.Lock()
		if !w.alive {
			w.mu.Unlock()
			go func() { p.jobCh <- jobMsg }() // işi geri koy
			return
		}
		w.lastJob = time.Now()
		w.jobs++
		jobNum := w.jobs
		w.mu.Unlock()

		log.Printf("[WORKER#%d] %s START job#%d queue_wait=%.1fs", w.id, jobMsg.jobID, jobNum, queueWait.Seconds())

		execStart := time.Now()
		res, err := p.runJob(w, jobMsg, jobNum)
		execElapsed := time.Since(execStart)

		if err != nil {
			log.Printf("[WORKER#%d] %s job#%d ERROR after exec=%.1fs (queue_wait was %.1fs): %v",
				w.id, jobMsg.jobID, jobNum, execElapsed.Seconds(), queueWait.Seconds(), err)
			// cancelled ise caller zaten kanaldan vazgeçmiş olabilir — gönderim
			// non-blocking olmalı ki burada da takılmasın.
			select {
			case jobMsg.result <- workerPoolResult{err: err}:
			default:
			}
			// Hata → process'i öldür, runWorker restart eder
			w.mu.Lock()
			w.alive = false
			w.mu.Unlock()
			if w.cmd != nil && w.cmd.Process != nil {
				w.cmd.Process.Kill()
			}
			return
		}

		log.Printf("[WORKER#%d] %s job#%d DONE exec=%.1fs (queue_wait was %.1fs) score=%d",
			w.id, jobMsg.jobID, jobNum, execElapsed.Seconds(), queueWait.Seconds(), res.ServerScore)
		select {
		case jobMsg.result <- workerPoolResult{result: res}:
		default:
			// caller zaten timeout olup kanalı terk etmiş — sonucu boşa düştü,
			// ama en azından worker artık boşa çıktı, sıradaki job'a geçiyor.
			log.Printf("[WORKER#%d] %s job#%d result discarded — caller already timed out", w.id, jobMsg.jobID, jobNum)
		}

		// 500 işten sonra graceful restart
		if jobNum >= 500 {
			log.Printf("[WORKER#%d] 500 jobs — graceful restart", w.id)
			p.killWorker(w)
			return
		}
	}
}

// ── Failed replay archive ────────────────────────────────────────────────────
//
// İki ayrı "başarısız replay" senaryosu var, ikisi de aynı arşive düşüyor:
//   1. Worker pool timeout/cancel/crash (runJob içinde) — simülasyon hiç
//      sonuçlanamadı.
//   2. Score mismatch (server.go handleSubmit, replay_handlers.go admin retry
//      içinde) — simülasyon bitti ama server_score ile client_score 5%
//      toleransın dışında, ParseFlagReason flagged döndü.
//
// Eski davranış ikisinde de delili (replay log) siliyordu — bir sonraki
// sefere aynı şüpheli seed/oyunu debug etmek için elle log toplaman
// gerekiyordu. Artık her iki durum da otomatik olarak failedReplayDir altına
// JSON olarak arşivleniyor: seed, char, player_seed, orijinal base64 replay
// log'u, kategori ("worker_timeout" | "worker_cancelled" | "worker_died" |
// "score_mismatch"), detaylı sebep ve zaman damgası.
//
// Manuel debug için: bu dosyadaki "log_base64" alanını --log argümanıyla
// replay binary'sine ver (önce base64 decode et), --seed/--char/--player-seed
// de aynı dosyadan oku.

const failedReplayDirName = "failed_replays"

// failedReplayDir — JOB_DIR/failed_replays, yoksa oluşturur.
// Worker pool zaten bir jobDir kullanıyor (os.TempDir()); server.go tarafındaki
// score-mismatch çağrıları da aynı kökü kullanır (ArchiveFailedReplayDefaultDir).
func failedReplayDir(jobDir string) string {
	dir := filepath.Join(jobDir, failedReplayDirName)
	_ = os.MkdirAll(dir, 0755)
	return dir
}

// ArchiveFailedReplayDefaultDir — jobDir bilmeyen çağıranlar (server.go gibi)
// için worker pool ile aynı kökü kullanır, böylece tüm arşiv tek klasörde toplanır.
func ArchiveFailedReplayDefaultDir() string {
	return GetWorkerPool().jobDir
}

// ArchiveFailedReplay — public API. logB64 doğrudan base64 (zaten elindeyse hex'e
// çevirmene gerek yok). category örn: "worker_timeout", "worker_cancelled",
// "worker_died", "score_mismatch".
func ArchiveFailedReplay(jobDir string, sessionID, seed string, charIdx int, playerSeed string, logB64, category, reason string, extra map[string]any) {
	entry := map[string]any{
		"session_id":   sessionID,
		"seed":         seed,
		"char":         charIdx,
		"player_seed":  playerSeed,
		"log_base64":   logB64,
		"category":     category,
		"reason":       reason,
		"archived_at":  time.Now().Format(time.RFC3339),
	}
	for k, v := range extra {
		entry[k] = v
	}

	data, err := json.MarshalIndent(entry, "", "  ")
	if err != nil {
		log.Printf("[FAILED_REPLAY_ARCHIVE] marshal error session=%s: %v", sessionID, err)
		return
	}

	dir := failedReplayDir(jobDir)
	idTag := sessionID
	if idTag == "" {
		idTag = "job"
	}
	fname := fmt.Sprintf("%s_%s_%d.json", category, idTag, time.Now().UnixNano())
	outPath := filepath.Join(dir, fname)
	if err := os.WriteFile(outPath, data, 0644); err != nil {
		log.Printf("[FAILED_REPLAY_ARCHIVE] write error session=%s: %v", sessionID, err)
		return
	}
	log.Printf("[FAILED_REPLAY_ARCHIVE] saved category=%s session=%s seed=%s reason=%q -> %s",
		category, sessionID, seed, reason, outPath)
}

// archiveFailedReplay — internal helper used by runJob (worker pool tarafı).
// job.Log burada hex-encoded (workerJob.Log formatı) — orijinal base64'e çeviriyoruz
// ki ArchiveFailedReplay'e geçen log'la format tutarlı olsun (handleReplay endpoint'i
// de replay_log'u base64 döner).
func archiveFailedReplay(jobDir string, job workerJob, jobID, category, reason string, queueWait, execWait time.Duration) {
	rawBytes, hexErr := hex.DecodeString(job.Log)
	logB64 := ""
	if hexErr == nil {
		logB64 = base64.StdEncoding.EncodeToString(rawBytes)
	}
	decodeErrStr := ""
	if hexErr != nil {
		decodeErrStr = hexErr.Error()
	}

	ArchiveFailedReplay(jobDir, "", job.Seed, job.Char, job.PlayerSeed, logB64, category, reason, map[string]any{
		"job_id":           jobID,
		"log_decode_error": decodeErrStr,
		"queue_wait_sec":   queueWait.Seconds(),
		"exec_wait_sec":    execWait.Seconds(),
	})
}

// runJob — job dosyasını yazar, result dosyasını polling ile okur
//
// FIX: deadline artık sabit 90s değil, jobMsg.submittedAt + timeoutSec + tampon.
// Böylece worker, caller'ın zaten pes ettiği bir job için fazladan ~30s daha
// beklemiyor — kendi deadline'ı caller'ınkiyle hizalı.
func (p *workerPool) runJob(w *godotWorker, jobMsg workerPoolJob, jobNum int) (*GodotReplayResult, error) {
	job := jobMsg.job

	// Job dosyası: wrk_job_<wid>_<nano>.json
	jobFile := filepath.Join(p.jobDir,
		fmt.Sprintf("wrk_job_%d_%d.json", w.id, time.Now().UnixNano()))

	data, err := json.Marshal(job)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	// Atomik yazma: önce .tmp, sonra rename
	tmpFile := jobFile + ".tmp"
	if err := os.WriteFile(tmpFile, data, 0600); err != nil {
		return nil, fmt.Errorf("write job file: %w", err)
	}
	if err := os.Rename(tmpFile, jobFile); err != nil {
		os.Remove(tmpFile)
		return nil, fmt.Errorf("rename job file: %w", err)
	}

	// Deadline: caller'ın submittedAt'ından itibaren timeoutSec + 5s tampon.
	// Eski kod burada sabit "time.Now().Add(90*time.Second)" kullanıyordu —
	// bu da caller 60s'de pes ettiğinde worker'ın 30s fazladan, kimsenin
	// beklemediği bir sonucu beklemesine sebep oluyordu.
	deadline := jobMsg.submittedAt.Add(time.Duration(jobMsg.timeoutSec)*time.Second + 5*time.Second)
	if time.Now().After(deadline) {
		// Zaten kuyrukta çok beklemiş, en azından minimal bir pencere ver
		deadline = time.Now().Add(5 * time.Second)
	}

	pollCount := 0
	for time.Now().Before(deadline) {
		pollCount++

		// FIX: caller iptal ettiyse hemen çık, gereksiz beklemeyi kes
		if jobMsg.cancelled.Load() {
			os.Remove(jobFile)
			os.Remove(job.Out)
			reason := fmt.Sprintf("cancelled by caller mid-flight (polled %dx)", pollCount)
			archiveFailedReplay(p.jobDir, job, jobMsg.jobID, "worker_cancelled", reason, time.Since(jobMsg.submittedAt), time.Since(jobMsg.submittedAt))
			return nil, fmt.Errorf("cancelled by caller mid-flight seed=%s worker#%d job#%d (polled %dx)",
				job.Seed, w.id, jobNum, pollCount)
		}

		rdata, rerr := os.ReadFile(job.Out)
		if rerr == nil && len(rdata) > 5 {
			var result GodotReplayResult
			if jerr := json.Unmarshal(rdata, &result); jerr == nil {
				os.Remove(job.Out)
				return &result, nil
			}
		}
		// Process ölü mü?
		w.mu.Lock()
		alive := w.alive
		w.mu.Unlock()
		if !alive {
			os.Remove(jobFile) // job dosyası hâlâ varsa temizle
			reason := fmt.Sprintf("worker died mid-job (polled %dx)", pollCount)
			archiveFailedReplay(p.jobDir, job, jobMsg.jobID, "worker_died", reason, time.Since(jobMsg.submittedAt), time.Since(jobMsg.submittedAt))
			return nil, fmt.Errorf("worker#%d died during job#%d (polled %dx)", w.id, jobNum, pollCount)
		}
		time.Sleep(100 * time.Millisecond)
	}

	reason := fmt.Sprintf("result timeout (polled %dx, deadline=%s)", pollCount, deadline.Format(time.RFC3339))
	archiveFailedReplay(p.jobDir, job, jobMsg.jobID, "worker_timeout", reason, time.Since(jobMsg.submittedAt), time.Since(jobMsg.submittedAt))
	os.Remove(jobFile)
	os.Remove(job.Out)
	return nil, fmt.Errorf("result timeout seed=%s worker#%d job#%d deadline=%s (polled %dx)",
		job.Seed, w.id, jobNum, deadline.Format(time.RFC3339), pollCount)
}

// killWorker — QUIT job dosyası yazar, kısa bekle, sonra zorla öldür
func (p *workerPool) killWorker(w *godotWorker) {
	w.mu.Lock()
	w.alive = false
	wid := w.id
	w.mu.Unlock()

	quitFile := filepath.Join(p.jobDir, fmt.Sprintf("wrk_job_%d_quit.json", wid))
	os.WriteFile(quitFile, []byte("QUIT"), 0600)
	time.Sleep(2 * time.Second)
	os.Remove(quitFile)

	w.mu.Lock()
	if w.cmd != nil && w.cmd.Process != nil {
		w.cmd.Process.Kill()
	}
	w.mu.Unlock()
}

// dailyRestart — her 24 saatte bir tüm worker'ları sırayla yeniden başlat
func (p *workerPool) dailyRestart() {
	for {
		time.Sleep(24 * time.Hour)
		log.Printf("[WORKER_POOL] daily restart")
		p.mu.Lock()
		for _, w := range p.workers {
			p.killWorker(w)
			time.Sleep(1 * time.Second)
		}
		p.mu.Unlock()
	}
}