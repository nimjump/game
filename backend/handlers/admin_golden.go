package handlers

import (
	"encoding/json"
	"log"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// GET /backend/admin/golden-replays — list pinned determinism regression fixtures.
// Replay log itself is omitted from the list response (can be large); only
// metadata needed for the admin table.
func (s *Server) handleAdminGoldenList(ctx *fasthttp.RequestCtx) {
	goldens := s.Store.ListGoldenReplays()
	type out struct {
		ID            string `json:"id"`
		Label         string `json:"label"`
		SourceSession string `json:"source_session,omitempty"`
		Seed          int64  `json:"seed"`
		Char          int    `json:"char"`
		ExpectedScore int    `json:"expected_score"`
		ExpectedTicks int    `json:"expected_ticks"`
		SavedAt       int64  `json:"saved_at"`
	}
	list := make([]out, 0, len(goldens))
	for _, g := range goldens {
		list = append(list, out{
			ID: g.ID, Label: g.Label, SourceSession: g.SourceSession,
			Seed: g.Seed, Char: g.Char,
			ExpectedScore: g.ExpectedScore, ExpectedTicks: g.ExpectedTicks,
			SavedAt: g.SavedAt,
		})
	}
	writeJSON(ctx, 200, map[string]any{"goldens": list, "count": len(list)})
}

// POST /backend/admin/golden-replays — pin an existing, already-verified
// session as a new golden reference. Only makes sense for a session that
// completed cleanly (not flagged) — the current server_score becomes the
// score every future binary/code build must reproduce exactly.
func (s *Server) handleAdminGoldenSave(ctx *fasthttp.RequestCtx) {
	var req struct {
		SessionID string `json:"session_id"`
		Label     string `json:"label"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if req.SessionID == "" {
		writeErr(ctx, 400, "session_id_required")
		return
	}
	sess, err := s.Store.Get(req.SessionID)
	if err != nil {
		writeErr(ctx, 404, "session_not_found")
		return
	}
	if sess.Log == "" {
		writeErr(ctx, 400, "session_has_no_replay_log")
		return
	}
	if sess.Flagged {
		writeErr(ctx, 400, "session_is_flagged_pick_a_clean_one")
		return
	}
	label := req.Label
	if label == "" {
		label = "session " + req.SessionID[:8]
	}
	g := game.GoldenReplay{
		Label:         label,
		SourceSession: req.SessionID,
		Seed:          sess.Seed,
		Char:          sess.Char,
		PlayerSeed:    sess.PlayerSeed,
		LogBase64:     sess.Log,
		ExpectedScore: sess.ServerScore,
		ExpectedTicks: sess.Ticks,
	}
	if err := s.Store.SaveGoldenReplay(g); err != nil {
		writeErr(ctx, 500, "save_failed: "+err.Error())
		return
	}
	log.Printf("[GOLDEN_REPLAY] pinned session=%s label=%q expected_score=%d", req.SessionID[:8], label, sess.ServerScore)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/golden-replays/delete — unpin a golden reference.
func (s *Server) handleAdminGoldenDelete(ctx *fasthttp.RequestCtx) {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || req.ID == "" {
		writeErr(ctx, 400, "bad_json")
		return
	}
	if err := s.Store.DeleteGoldenReplay(req.ID); err != nil {
		writeErr(ctx, 500, "delete_failed: "+err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/golden-replays/self-test — re-simulate every pinned
// golden replay against the CURRENTLY ACTIVE replay binary and report any
// score mismatch. Zero tolerance — a single point of score drift here means
// a code/binary change altered simulation behavior.
func (s *Server) handleAdminGoldenSelfTest(ctx *fasthttp.RequestCtx) {
	goldens := s.Store.ListGoldenReplays()
	if len(goldens) == 0 {
		writeJSON(ctx, 200, map[string]any{"results": []any{}, "pass": true, "total": 0, "failed": 0})
		return
	}
	results := game.RunGoldenSelfTest(goldens)
	failed := 0
	for _, r := range results {
		if !r.Pass {
			failed++
		}
	}
	writeJSON(ctx, 200, map[string]any{
		"results": results,
		"total":   len(results),
		"failed":  failed,
		"pass":    failed == 0,
	})
}
