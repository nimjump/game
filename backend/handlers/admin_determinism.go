package handlers

import (
	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/determinism-lint — static scan of game/scripts/*.gd for
// known determinism-breaking patterns (bare RNG, wall-clock time, hard
// free(), array-mutation-during-iteration). See backend/game/determinism_lint.go
// for the full rationale behind each rule.
func (s *Server) handleAdminDeterminismLint(ctx *fasthttp.RequestCtx) {
	findings, err := game.RunDeterminismLint()
	if err != nil {
		writeErr(ctx, 500, "lint_failed: "+err.Error())
		return
	}
	warn := 0
	for _, f := range findings {
		if f.Severity == "warn" {
			warn++
		}
	}
	writeJSON(ctx, 200, map[string]any{
		"findings": findings,
		"total":    len(findings),
		"warnings": warn,
		"clean":    len(findings) == 0,
	})
}
