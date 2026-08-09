package handlers

// seed_batch.go — POST /backend/seeds/issue. Hands an authed player a fresh
// batch of server-signed seeds they can play offline. See
// game/seed_batch.go for the full design rationale.

import (
	"log"

	"github.com/valyala/fasthttp"
)

func (s *Server) handleIssueSeedBatch(ctx *fasthttp.RequestCtx) {
	ip := realClientIP(ctx)

	authedPlayer := s.tokenPlayerID(ctx)
	if authedPlayer == "" {
		log.Printf("[SEED_ISSUE] rejected — no valid auth token ip=%s", ip)
		writeErr(ctx, 401, "auth_required")
		return
	}

	batch, err := s.Store.IssueSeedBatch(authedPlayer)
	if err != nil {
		log.Printf("[SEED_ISSUE] failed player=%s ip=%s err=%v", authedPlayer[:min8(authedPlayer)], ip, err)
		writeErr(ctx, 500, "seed_issue_failed")
		return
	}

	log.Printf("[SEED_ISSUE] ok player=%s count=%d ip=%s", authedPlayer[:min8(authedPlayer)], len(batch), ip)
	writeJSON(ctx, 200, map[string]any{
		"ok":    true,
		"seeds": batch,
	})
}
