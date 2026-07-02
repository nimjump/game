package game

import (
	"archive/zip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GodotReplayResult — result returned from headless Godot
type GodotReplayResult struct {
	ServerScore int    `json:"server_score"`
	Ticks       int    `json:"ticks"`
	Error       string `json:"error,omitempty"`

	// Quest counters — parsed from [QUEST_RESULT] stdout line
	QuestKills         int  `json:"kills"`
	QuestFlyingKills   int  `json:"flying_kills"`
	QuestMosquitoKills int  `json:"mosquito_kills"`
	QuestPlatforms     int  `json:"platforms"`
	QuestCoins         int  `json:"coins"`
	QuestGoldenCarrots int  `json:"golden_carrots"`
	QuestPowerups      int  `json:"powerups"`
	QuestTookDamage    bool `json:"took_damage"`
	QuestItemTypes     int  `json:"item_types"`   // distinct item type count
	QuestLivesLeft     int  `json:"lives_left"`
	QuestUsedMirror    bool `json:"used_mirror"`
	QuestUsedPowerup   bool `json:"used_powerup"`
	QuestNoCoins       bool `json:"no_coins"`     // zero coins collected
	QuestEnemyTypes    int  `json:"enemy_types"`  // distinct enemy types killed
	QuestComboMax      int  `json:"combo_max"`    // highest kill combo
	QuestNoHitMax      int  `json:"nohit_max"`    // best no-damage platform streak
	QuestKillsNoDmg    int  `json:"kills_no_dmg"` // kills while no damage taken
	QuestHighestY      int  `json:"highest_y"`    // max altitude (game units)
	QuestHasResult     bool `json:"quest_has_result"` // true if [QUEST_RESULT] line was parsed
}

// replayBinaryPath — cikartilmis binary yolunu onbellekte tutar
var (
	_cachedBin     string
	_cachedBinOnce sync.Once
)

// ── Paralel replay worker pool ────────────────────────────────────────────────
// How many parallel Godot processes can run — auto-tuned to CPU cores.
// Too few: queue grows. Too many: RAM/CPU blows up.
// Formula: max(2, CPU/2) — 2 on 4-core, 4 on 8-core, etc.
var replaySem chan struct{}

func init() {
	// Override with REPLAY_WORKERS env (for production tuning)
	// Default: min(20, max(4, CPU*2)) — headless Godot is light, more I/O bound than CPU bound
	workers := runtime.NumCPU() * 2
	if workers < 4  { workers = 4  }
	if workers > 20 { workers = 20 }
	if env := os.Getenv("REPLAY_WORKERS"); env != "" {
		if n, err := strconv.Atoi(env); err == nil && n > 0 && n <= 50 {
			workers = n
		}
	}
	replaySem = make(chan struct{}, workers)
	log.Printf("[REPLAY_POOL] paralel worker: %d (CPU=%d)", workers, runtime.NumCPU())
}

// ReplayQueueLen — number of replays currently being processed (filled slots)
func ReplayQueueLen() int {
	return len(replaySem)
}

// ReplaySemCap — max parallel workers
func ReplaySemCap() chan struct{} {
	return replaySem
}

// ServerGamesDir — exported wrapper, used by the admin replay-binary
// upload endpoint to know where to save the uploaded replay.zip/replay.exe.
func ServerGamesDir() string { return servergamesDir() }

// ResetBinaryCache — clears the cached binary path so godotBinary() re-
// resolves it on next call. Call after uploading a new replay.zip /
// replay.exe via the admin panel, then RestartAllWorkers() so the
// persistent worker pool actually picks it up.
func ResetBinaryCache() {
	_cachedBin = ""
	_cachedBinOnce = sync.Once{}
}

// servergamesDir — replay binary + replay.zip klasoru.
// Priority: SERVERGAMES_DIR env → working directory/servergames → next to executable/servergames
func servergamesDir() string {
	// explicit override — production tuning
	if env := os.Getenv("SERVERGAMES_DIR"); env != "" {
		return env
	}

	// first check working directory (for go run and development)
	if wd, err := os.Getwd(); err == nil {
		candidate := filepath.Join(wd, "servergames")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	// then check next to the executable (for production binary)
	exe, err := os.Executable()
	if err != nil {
		return "servergames"
	}
	// go run gecici dizin kullanir, onu atla
	exeDir := filepath.Dir(exe)
	candidate := filepath.Join(exeDir, "servergames")
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	// fallback: working directory
	if wd, err := os.Getwd(); err == nil {
		return filepath.Join(wd, "servergames")
	}
	return "servergames"
}

// extractLinuxBinary — extracts ALL files from replay.zip into sgDir.
// The zip contains the Linux binary ("replay") and its data file ("replay.pck").
// Both must exist side-by-side for Godot to run.
func extractLinuxBinary(sgDir string) (string, error) {
	zipPath := filepath.Join(sgDir, "replay.zip")
	binPath := filepath.Join(sgDir, "replay")

	// Already extracted — check both binary and pck exist
	pckPath := filepath.Join(sgDir, "replay.pck")
	binOK  := func() bool { _, e := os.Stat(binPath); return e == nil }()
	pckOK  := func() bool { _, e := os.Stat(pckPath); return e == nil }()
	if binOK && pckOK {
		log.Printf("[REPLAY] already extracted: %s", binPath)
		return binPath, nil
	}

	if _, err := os.Stat(zipPath); err != nil {
		return "", fmt.Errorf("replay.zip not found: %s", zipPath)
	}

	log.Printf("[REPLAY] extracting replay.zip -> %s", sgDir)

	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return "", fmt.Errorf("zip open failed: %w", err)
	}
	defer r.Close()

	var foundBin bool
	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		name := filepath.Base(f.Name)
		outPath := filepath.Join(sgDir, name)

		// Skip if already exists
		if _, err := os.Stat(outPath); err == nil {
			log.Printf("[REPLAY] already exists, skipping: %s", name)
			if name == "replay" { foundBin = true }
			continue
		}

		rc, err := f.Open()
		if err != nil {
			return "", fmt.Errorf("zip entry open failed (%s): %w", name, err)
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return "", fmt.Errorf("zip read failed (%s): %w", name, err)
		}

		perm := os.FileMode(0644)
		if name == "replay" || !strings.Contains(name, ".") {
			perm = 0755 // executable
		}
		if err := os.WriteFile(outPath, data, perm); err != nil {
			return "", fmt.Errorf("write failed (%s): %w", name, err)
		}
		// os.WriteFile's perm arg is masked by the process umask (e.g. root
		// often runs with umask 077, silently turning our requested 0644
		// into 0600). Explicit os.Chmod bypasses umask entirely, guaranteeing
		// the exact mode — needed so a privilege-dropped ("nobody") Godot
		// child (see privdrop_unix.go) can actually read replay.pck /
		// execute the replay binary even when this Go process is root.
		if err := os.Chmod(outPath, perm); err != nil {
			log.Printf("[REPLAY] chmod %o failed for %s: %v", perm, outPath, err)
		}
		log.Printf("[REPLAY] extracted: %s (%d bytes, perm=%o)", name, len(data), perm)
		if name == "replay" { foundBin = true }
	}

	if !foundBin {
		return "", fmt.Errorf("replay binary not found in zip")
	}
	return binPath, nil
}

// godotBinary — finds the replay binary automatically.
// Priority: GODOT_BIN env → servergames/ folder (tries all known names) → PATH
func godotBinary() string {
	if env := os.Getenv("GODOT_BIN"); env != "" {
		return env
	}

	_cachedBinOnce.Do(func() {
		sgDir := servergamesDir()

		// Try every known binary name in order — works on both Windows and Linux
		// without caring which OS we are on. .exe is ignored by the kernel on Linux,
		// but os.Stat will find it and exec.Command will fail gracefully.
		// We validate by actually running --version below.
		candidates := []string{
			filepath.Join(sgDir, "replay.exe"),   // Windows (Godot export)
			filepath.Join(sgDir, "replay"),        // Linux (extracted or placed manually)
			filepath.Join(sgDir, "godot.exe"),
			filepath.Join(sgDir, "godot"),
		}

		for _, c := range candidates {
			if _, err := os.Stat(c); err != nil {
				continue // file does not exist
			}
			// On Linux, skip .exe files — they can't execute
			if runtime.GOOS != "windows" && strings.HasSuffix(c, ".exe") {
				log.Printf("[REPLAY] skipping .exe on linux: %s", c)
				continue
			}
			_cachedBin = c
			log.Printf("[REPLAY] binary found: %s (os=%s)", c, runtime.GOOS)
			return
		}

		// Linux only: try extracting from replay.zip (may contain a linux build)
		if runtime.GOOS != "windows" {
			if path, err := extractLinuxBinary(sgDir); err == nil {
				_cachedBin = path
				log.Printf("[REPLAY] Linux binary extracted from zip: %s", path)
				return
			}
		}

		// Last resort: system PATH
		for _, name := range []string{"godot4", "godot", "Godot"} {
			if path, err := exec.LookPath(name); err == nil {
				_cachedBin = path
				log.Printf("[REPLAY] binary found in PATH: %s", path)
				return
			}
		}

		log.Printf("[REPLAY] WARNING: no binary found in servergames/ or PATH. Set GODOT_BIN env.")
	})

	return _cachedBin
}

// HealthMonitor — replay binary'inin sagligini izler
type HealthMonitor struct {
	mu          sync.Mutex
	lastCheckOK bool
	lastCheck   time.Time
}

var globalMonitor = &HealthMonitor{}

// StartReplayMonitor — arka planda binary'i duzenli olarak test eder
// call only once (from main or server init)
func StartReplayMonitor() {
	go func() {
		time.Sleep(5 * time.Second)
		for {
			globalMonitor.check()
			time.Sleep(2 * time.Minute)
		}
	}()
}

func (m *HealthMonitor) check() {
	bin := godotBinary()
	if bin == "" {
		m.mu.Lock()
		m.lastCheckOK = false
		m.lastCheck = time.Now()
		m.mu.Unlock()
		log.Printf("[REPLAY_HEALTH] binary not found")
		return
	}

	// Health check: binary file must exist and be executable.
	// We do NOT run --version because Godot 4 may return non-zero exit codes
	// for --version on some builds, causing false negatives.
	info, err := os.Stat(bin)
	ok := err == nil && !info.IsDir() && info.Size() > 1024*1024 // >1MB = real binary
	m.mu.Lock()
	m.lastCheckOK = ok
	m.lastCheck = time.Now()
	m.mu.Unlock()
	if ok {
		log.Printf("[REPLAY_HEALTH] OK - %s (%d MB)", bin, info.Size()/1024/1024)
	} else {
		log.Printf("[REPLAY_HEALTH] FAIL - %s: %v", bin, err)
	}
}

func (m *HealthMonitor) resetCache() {
	m.mu.Lock()
	defer m.mu.Unlock()
	_cachedBin = ""
	_cachedBinOnce = sync.Once{}
}

// ReplayBinaryStatus — health status for admin
func ReplayBinaryStatus() map[string]interface{} {
	globalMonitor.mu.Lock()
	monitorOK := globalMonitor.lastCheckOK
	t := globalMonitor.lastCheck
	globalMonitor.mu.Unlock()

	bin := godotBinary()

	// If monitor hasn't run yet (first 5 seconds), check directly from file stat
	fileOK := false
	if bin != "" {
		if info, err := os.Stat(bin); err == nil && !info.IsDir() && info.Size() > 1024*1024 {
			fileOK = true
		}
	}

	return map[string]interface{}{
		"binary":     bin,
		"healthy":    monitorOK || fileOK, // true if either check passes
		"last_check": t.Format(time.RFC3339),
		"runtime":    runtime.GOOS,
		"sgdir":      servergamesDir(),
	}
}

// SimulateReplay — simulate replay log with Godot headless and return server score
func SimulateReplay(replayLogB64 string, seed int64, charIdx int, timeoutSec int, playerSeedOpt ...int64) (*GodotReplayResult, error) {
	var playerSeed int64
	if len(playerSeedOpt) > 0 {
		playerSeed = playerSeedOpt[0]
	}
	// Semaphore: max N parallel Godot processes — wait for slot, no timeout (queue)
	queuePos := len(replaySem) + 1
	if queuePos > 1 {
		log.Printf("[REPLAY_POOL] waiting in queue position=%d", queuePos)
	}
	replaySem <- struct{}{}        // slot al (dolu ise bekle)
	defer func() { <-replaySem }() // done, release slot

	bin := godotBinary()
	if bin == "" {
		return nil, fmt.Errorf("godot binary not found - servergames/replay.exe (Windows) or servergames/replay.zip (Linux) required")
	}

	tmpDir := os.TempDir()
	nano := time.Now().UnixNano()
	logFile := filepath.Join(tmpDir, fmt.Sprintf("replay_%d.b64", nano))
	outFile := filepath.Join(tmpDir, fmt.Sprintf("replay_result_%d.json", nano))
	// Separate dir for Godot crash logs — Godot writes godot.log here
	crashLogDir := filepath.Join(tmpDir, fmt.Sprintf("godot_crash_%d", nano))
	_ = os.MkdirAll(crashLogDir, 0755)

	defer os.Remove(outFile)
	defer os.RemoveAll(crashLogDir)

	raw, err := base64.StdEncoding.DecodeString(replayLogB64)
	if err != nil {
		return nil, fmt.Errorf("replay log decode error: %w", err)
	}

	// RLE decode: count each byte as that many ticks (0xFF = 3-byte delta marker, skip)
	var rleDecodedTicks int
	for i := 0; i < len(raw); {
		b := raw[i]
		if b == 0xFF {
			i += 3
			continue
		}
		cnt := (int(b) >> 2) & 0x3F
		if cnt < 1 { cnt = 1 }
		rleDecodedTicks += cnt
		i++
	}
	log.Printf("[REPLAY_SIM] raw_bytes=%d rle_decoded_ticks=%d seed=%d player_seed=%d", len(raw), rleDecodedTicks, seed, playerSeed)

	// 0644 (not 0600): same reasoning as replay_worker.go's job file — when
	// this process is root, the Godot child is dropped to an unprivileged
	// user (privdrop_unix.go) and needs to actually be able to read this.
	if err := os.WriteFile(logFile, raw, 0644); err != nil {
		return nil, fmt.Errorf("log dosyasi yazilamadi: %w", err)
	}
	// os.WriteFile's perm is masked by the process umask (root often runs
	// with umask 077) — explicit chmod bypasses that entirely.
	if err := os.Chmod(logFile, 0644); err != nil {
		log.Printf("[REPLAY_SIM] chmod 0644 failed for %s: %v", logFile, err)
	}

	// Timeout: fast-sim runs all ticks in one blocking frame (seek_to_tick while loop).
	// Startup + asset load ~3-8s on a real server. 30s is a very safe ceiling.
	// Old 4x frame-based approach needed 300s for a 20-min game; no longer needed.
	if timeoutSec <= 0 {
		timeoutSec = 30
	}

	args := []string{
		"--headless",              // rendering + display fully off (Godot 4 standard)
		"--audio-driver", "Dummy", // skip audio thread init
		// Each process writes to its own user-data-dir — no conflicts
		"--user-data-dir", crashLogDir,
		"--",
		"--server-replay",
		"--seed", strconv.FormatInt(seed, 10),
		"--char", strconv.Itoa(charIdx),
		"--log", logFile,
		"--out", outFile,
		"--player-seed", strconv.FormatInt(playerSeed, 10),
	}

	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(),
		"DISPLAY=",                     // prevent X11 connection attempt
		"PULSE_SERVER=",                // prevent PulseAudio connection attempt
		"ALSA_CARD=",                   // prevent ALSA device probe
	)

	// Same root→unprivileged-user drop as the persistent worker pool (see
	// privdrop_unix.go / replay_worker.go) — this one-shot path is used by
	// the admin panel's manual replay re-verify, so it needs the identical
	// protection against Godot hanging when started as root.
	applyPrivDrop(cmd, crashLogDir)

	var stdoutBuf, stderrBuf strings.Builder
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		globalMonitor.resetCache()
		return nil, fmt.Errorf("godot start failed: %w", err)
	}
	go func() { done <- cmd.Wait() }()

	var waitErr error
	select {
	case waitErr = <-done:
		if waitErr != nil {
			log.Printf("[REPLAY_SIM] godot exit: %v", waitErr)
		}
	case <-time.After(time.Duration(timeoutSec) * time.Second):
		_ = cmd.Process.Kill()
		log.Printf("[REPLAY_SIM] TIMEOUT log_file=%s stdout=%q stderr=%q",
			logFile, stdoutBuf.String(), stderrBuf.String())
		return nil, fmt.Errorf("godot replay timeout (%ds)", timeoutSec)
	}

	// stdout/stderr her zaman logla
	stdoutStr := stdoutBuf.String()
	if so := strings.TrimSpace(stdoutStr); so != "" {
		log.Printf("[REPLAY_SIM] godot stdout: %s", so)
	}
	if se := strings.TrimSpace(stderrBuf.String()); se != "" {
		log.Printf("[REPLAY_SIM] godot stderr: %s", se)
	}

	data, err := os.ReadFile(outFile)
	if err != nil {
		// Result file missing — Godot may have crashed after writing stdout
		// Try to recover server_score from [QUEST_RESULT] stdout line
		log.Printf("[REPLAY_SIM] result file missing, keeping log_file for debug: %s (wait_err=%v)",
			logFile, waitErr)
		logCrashDetails(crashLogDir, seed)
		// Attempt stdout recovery
		var recovered GodotReplayResult
		parseQuestResult(stdoutStr, &recovered)
		if recovered.QuestHasResult && recovered.ServerScore > 0 {
			log.Printf("[REPLAY_SIM] stdout_recovery: server_score=%d", recovered.ServerScore)
			os.Remove(logFile)
			return &recovered, nil
		}
		return nil, fmt.Errorf("result file could not be read: %w", err)
	}
	os.Remove(logFile)

	var result GodotReplayResult
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("result JSON parse error: %w (raw: %s)", err, string(data))
	}

	// Parse [QUEST_RESULT] line from Godot stdout
	parseQuestResult(stdoutStr, &result)

	return &result, nil
}

// parseQuestResult scans Godot stdout for a "[QUEST_RESULT] {...}" line
// and fills in the quest counter fields of the result struct.
func parseQuestResult(stdout string, result *GodotReplayResult) {
	const prefix = "[QUEST_RESULT] "
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		jsonPart := line[len(prefix):]
		var qr struct {
			Score         int  `json:"score"`
			Ticks         int  `json:"ticks"`
			Kills         int  `json:"kills"`
			FlyingKills   int  `json:"flying_kills"`
			MosquitoKills int  `json:"mosquito_kills"`
			Platforms     int  `json:"platforms"`
			Coins         int  `json:"coins"`
			GoldenCarrots int  `json:"golden_carrots"`
			Powerups      int  `json:"powerups"`
			TookDamage    bool `json:"took_damage"`
			ItemTypes     int  `json:"item_types"`
			LivesLeft     int  `json:"lives_left"`
			UsedMirror    bool `json:"used_mirror"`
			UsedPowerup   bool `json:"used_powerup"`
			NoCoins       bool `json:"no_coins"`
			EnemyTypes    int  `json:"enemy_types"`
			ComboMax      int  `json:"combo_max"`
			NoHitMax      int  `json:"nohit_max"`
			KillsNoDmg    int  `json:"kills_no_dmg"`
			HighestY      int  `json:"highest_y"`
		}
		if err := json.Unmarshal([]byte(jsonPart), &qr); err != nil {
			log.Printf("[QUEST_RESULT] parse error: %v (raw: %s)", err, jsonPart)
			return
		}
		result.ServerScore        = qr.Score
		result.QuestKills         = qr.Kills
		result.QuestFlyingKills   = qr.FlyingKills
		result.QuestMosquitoKills = qr.MosquitoKills
		result.QuestPlatforms     = qr.Platforms
		result.QuestCoins         = qr.Coins
		result.QuestGoldenCarrots = qr.GoldenCarrots
		result.QuestPowerups      = qr.Powerups
		result.QuestTookDamage    = qr.TookDamage
		result.QuestItemTypes     = qr.ItemTypes
		result.QuestLivesLeft     = qr.LivesLeft
		result.QuestUsedMirror    = qr.UsedMirror
		result.QuestUsedPowerup   = qr.UsedPowerup
		result.QuestNoCoins       = qr.NoCoins
		result.QuestEnemyTypes    = qr.EnemyTypes
		result.QuestComboMax      = qr.ComboMax
		result.QuestNoHitMax      = qr.NoHitMax
		result.QuestKillsNoDmg    = qr.KillsNoDmg
		result.QuestHighestY      = qr.HighestY
		result.QuestHasResult     = true
		log.Printf("[QUEST_RESULT] kills=%d fly=%d mosq=%d plat=%d coins=%d golden=%d pw=%d dmg=%v itypes=%d lives=%d combo=%d nohit=%d hy=%d",
			qr.Kills, qr.FlyingKills, qr.MosquitoKills, qr.Platforms, qr.Coins, qr.GoldenCarrots,
			qr.Powerups, qr.TookDamage, qr.ItemTypes, qr.LivesLeft, qr.ComboMax, qr.NoHitMax, qr.HighestY)
		return
	}
}

// logCrashDetails — scans and logs files written by Godot to its user-data-dir.
// Godot 4 headless typically writes crash / print_error output to
// <user-data-dir>/logs/godot.log or directly to stderr.
func logCrashDetails(crashLogDir string, seed int64) {
	// Possible log paths Godot 4 may write to
	candidates := []string{
		filepath.Join(crashLogDir, "logs", "godot.log"),
		filepath.Join(crashLogDir, "godot.log"),
		filepath.Join(crashLogDir, "logs", "godot_crash.log"),
	}

	found := false
	for _, p := range candidates {
		content, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		found = true
		// Log only last 4KB — crash is usually at the end
		text := string(content)
		if len(text) > 4096 {
			text = "...(truncated)...\n" + text[len(text)-4096:]
		}
		log.Printf("[REPLAY_CRASH] seed=%d godot_log=%s:\n%s", seed, p, text)
	}

	if !found {
		// List directory contents
		entries, err := os.ReadDir(crashLogDir)
		if err != nil {
			log.Printf("[REPLAY_CRASH] seed=%d crashLogDir okunamadi: %v", seed, err)
			return
		}
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		log.Printf("[REPLAY_CRASH] seed=%d crashLogDir=%s contents: %v (godot.log not found)", seed, crashLogDir, names)

		// Alt dizinlere de bak
		_ = filepath.Walk(crashLogDir, func(path string, info os.FileInfo, err error) error {
			if err != nil || inf