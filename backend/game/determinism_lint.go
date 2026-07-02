package game

// determinism_lint.go — static scanner over the Godot game scripts
// (game/scripts/*.gd) that flags code patterns known to break
// client-vs-server replay determinism. This exists so that a future edit to
// Player.gd/GameManager.gd/EnemyBase.gd/etc. that reintroduces a
// determinism bug gets caught automatically (as an admin-visible red flag)
// instead of silently shipping and only showing up later as a wave of
// flagged player replays.
//
// This is a heuristic regex scan, not a real GDScript parser — it can have
// false positives (a flagged line that's actually fine) but is tuned to
// have very few false NEGATIVES for the specific bug classes this project
// has already been bitten by:
//
//   1. Bare randf()/randi()/randomize() — gameplay-affecting randomness
//      MUST go through a seeded, dedicated RandomNumberGenerator (_rng),
//      never the engine's global RNG, or replays are unreproducible.
//   2. Wall-clock time (Time.get_unix_time_from_system, Time.get_ticks_msec,
//      OS.get_unix_time, OS.get_ticks_msec) used anywhere it could feed
//      into gameplay state — server replay runs in a burst, not in
//      real-time, so wall-clock reads there will never match what the
//      client saw during the original real-time play session.
//   3. Node.free() instead of Node.queue_free() — this is the exact root
//      cause of the 0xC0000005 (STATUS_ACCESS_VIOLATION) headless crash
//      found and fixed in GameManager._discard_node(): a hard free() can
//      leave a dangling reference (e.g. a captured lambda) that crashes on
//      next access. queue_free() defers destruction safely.
//   4. Mutating an array (.append/.erase/.remove_at) on the exact same
//      array a `for` loop is currently iterating over — undefined
//      iteration behavior, can skip elements or crash.
//
// Lines can be explicitly whitelisted by ending them with the comment
// `# determinism-ok` — used for cosmetic-only code that's already gated
// behind an `_is_headless` return and doesn't affect score/physics.

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type DeterminismFinding struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Rule     string `json:"rule"`
	Severity string `json:"severity"` // "warn" | "info"
	Message  string `json:"message"`
	Snippet  string `json:"snippet"`
}

var (
	reBareRand    = regexp.MustCompile(`(?:^|[^\w.])(randf(?:_range)?|randi(?:_range)?|randomize)\s*\(`)
	reSeededRand  = regexp.MustCompile(`\b(_rng|_visual_rng|_shake_rng)\.\s*(randf|randi)`)
	reWallClock   = regexp.MustCompile(`\b(Time\.get_unix_time_from_system|Time\.get_ticks_msec|Time\.get_ticks_usec|OS\.get_unix_time|OS\.get_ticks_msec)\s*\(`)
	reHardFree    = regexp.MustCompile(`(?:^|[^\w.])(\w+)\.free\(\)`)
	reQueueFree   = regexp.MustCompile(`\.queue_free\(\)`)
	reForIn       = regexp.MustCompile(`^\s*for\s+\w+\s+in\s+(\w+)\s*:`)
	reArrMutate   = regexp.MustCompile(`\b(\w+)\.(append|erase|remove_at|push_back|push_front|pop_back|pop_front)\s*\(`)
	reWhitelisted = regexp.MustCompile(`#\s*determinism-ok\b`)
)

// gameScriptsDir — resolves the game/scripts directory to scan.
// Priority: GAME_SCRIPTS_DIR env → ../game/scripts (mirrors ADMIN_DIR convention).
func gameScriptsDir() string {
	if env := os.Getenv("GAME_SCRIPTS_DIR"); env != "" {
		return env
	}
	return filepath.Join("..", "game", "scripts")
}

// RunDeterminismLint — scans every .gd file in gameScriptsDir() and returns
// all findings, sorted by file then line.
func RunDeterminismLint() ([]DeterminismFinding, error) {
	dir := gameScriptsDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %w", dir, err)
	}

	var findings []DeterminismFinding
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".gd") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		f, err := lintFile(path, e.Name())
		if err != nil {
			continue // unreadable file — skip, don't fail the whole scan
		}
		findings = append(findings, f...)
	}

	sort.Slice(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		return findings[i].Line < findings[j].Line
	})
	return findings, nil
}

func lintFile(path, name string) ([]DeterminismFinding, error) {
	fh, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer fh.Close()

	var findings []DeterminismFinding
	// Track the array name currently being iterated by the innermost `for`
	// loop, and the indent level that loop body is at, so we can flag
	// mutation of that SAME array inside the loop body only (not just
	// anywhere later in the file).
	type loopCtx struct {
		arrayName string
		indent    int
	}
	var loopStack []loopCtx

	scanner := bufio.NewScanner(fh)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if reWhitelisted.MatchString(line) {
			continue
		}
		indent := len(line) - len(strings.TrimLeft(line, "\t "))

		// Pop loop contexts we've dedented out of.
		for len(loopStack) > 0 && indent <= loopStack[len(loopStack)-1].indent {
			loopStack = loopStack[:len(loopStack)-1]
		}

		// Rule 1: bare RNG calls not going through a seeded generator.
		if reBareRand.MatchString(line) && !reSeededRand.MatchString(line) {
			findings = append(findings, DeterminismFinding{
				File: name, Line: lineNo, Rule: "bare_rng", Severity: "warn",
				Message: "Bare randf()/randi()/randomize() call — gameplay-affecting randomness must go through a seeded RandomNumberGenerator (_rng), never the engine's global RNG, or replays won't be reproducible across client/server. If this is purely cosmetic (never affects score/physics), append \"# determinism-ok\" to the line.",
				Snippet: trimmed,
			})
		}

		// Rule 2: wall-clock time reads.
		if reWallClock.MatchString(line) {
			findings = append(findings, DeterminismFinding{
				File: name, Line: lineNo, Rule: "wall_clock", Severity: "warn",
				Message: "Wall-clock time read (Time/OS get_*_time). Server replay runs the whole session in one fast-forwarded burst, not in real-time — any gameplay logic driven by wall-clock time will diverge between the original client session and the server re-simulation. Fine for UI/network timestamps; not fine for anything that changes score, position, or RNG consumption. Append \"# determinism-ok\" if this is confirmed non-gameplay.",
				Snippet: trimmed,
			})
		}

		// Rule 3: hard free() instead of queue_free().
		if m := reHardFree.FindStringSubmatch(line); m != nil && !reQueueFree.MatchString(line) {
			findings = append(findings, DeterminismFinding{
				File: name, Line: lineNo, Rule: "hard_free", Severity: "warn",
				Message: fmt.Sprintf("%s.free() — hard, synchronous free. This is the exact root cause of the 0xC0000005 headless access-violation crash found in GameManager._discard_node(): if anything else still holds a live reference (a captured lambda, a cached array entry) and touches it after a hard free(), Godot either logs a freed-capture warning or crashes outright. Use .queue_free() instead unless you've specifically verified nothing else can reference this node afterward. Append \"# determinism-ok\" once verified safe.", m[1]),
				Snippet: trimmed,
			})
		}

		// Track `for x in arr:` loop starts.
		if m := reForIn.FindStringSubmatch(line); m != nil {
			loopStack = append(loopStack, loopCtx{arrayName: m[1], indent: indent})
			continue
		}

		// Rule 4: mutating the array currently being iterated, inside its own loop body.
		if len(loopStack) > 0 {
			if m := reArrMutate.FindStringSubmatch(line); m != nil {
				for _, ctx := range loopStack {
					if m[1] == ctx.arrayName {
						findings = append(findings, DeterminismFinding{
							File: name, Line: lineNo, Rule: "mutate_during_iteration", Severity: "warn",
							Message: fmt.Sprintf("%s.%s() called while a `for` loop is iterating over %s — mutating an array during iteration over itself has undefined behavior in Godot (can skip elements or crash). Use a reverse index loop (for i in range(arr.size()-1, -1, -1)) to remove safely instead.", m[1], m[2], m[1]),
							Snippet: trimmed,
						})
						break
					}
				}
			}
		}
	}
	return findings, scanner.Err()
}
