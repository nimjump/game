package handlers

// origin.go — single source of truth for "does this request/connection come
// from somewhere we actually expect" (the game's own domain, our own backend
// domain, or a local dev box). Used by main.go's CORS middleware (rejects
// disallowed browser Origins on every /backend/* HTTP request).
//
// Important honesty check: this is a real, meaningful hardening layer
// against "some other website's JS quietly calls our API" or "a random
// script pretends to be a browser tab hitting our WebSocket" — browsers
// always send a genuine Origin header on cross-origin fetches and on every
// WebSocket handshake, and they can't be scripted into lying about it from
// inside a real browser context. It is NOT a substitute for real
// authentication (tokens, room-turn checks, etc — all still enforced
// separately) because a non-browser client (curl, a bot, a custom script)
// can set an arbitrary Origin header itself with zero effort. "Impossible
// for outside connections" isn't achievable for a public web game whose
// entire client is downloadable JS/WASM — there's no secret that survives
// being shipped to every visitor's browser. What this DOES reliably block:
// other real websites/apps embedding or scripting against our API from
// inside an actual browser, and it raises the bar for casual/automated
// scanning that doesn't bother spoofing headers.

import (
	"log"
	"os"
	"strings"
)

// allowedOrigins — exact matches. Keep in sync with ApiConfig.gd's
// PROD_BASE / PROD_GAME_URL on the client.
var allowedOrigins = map[string]bool{
	"https://nimjump.zetashare.com":  true, // the game's public URL (ApiConfig.PROD_GAME_URL)
	"https://backbone.zetashare.com": true, // the backend's own URL (ApiConfig.PROD_BASE) — same-origin case
}

// extraAllowedOrigins — populated once at startup from the EXTRA_ALLOWED_ORIGINS
// env var (comma-separated), so local tooling can allowlist origins that don't
// exist as fixed values (unlike the two production hosts above). Concretely:
// devtools/start-dev-tunnels.js generates a fresh random *.trycloudflare.com
// hostname for the admin panel and the game frontend on every single run, so
// those can never be hardcoded here — devtools sets EXTRA_ALLOWED_ORIGINS to
// "<admin tunnel url>,<frontend tunnel url>" before starting this backend,
// which is exactly what the admin panel's and the game's own browser-side
// fetch() calls send as Origin when hitting this API through the backend
// tunnel. Without this, local dev/testing through the tunnels would ALWAYS
// 403 here with "origin_not_allowed" even after the admin app itself is
// correctly pointed at the right backend tunnel URL.
var extraAllowedOrigins = loadExtraAllowedOrigins()

// allowTrycloudflareOrigins — BUG FIX: the exact-match EXTRA_ALLOWED_ORIGINS
// list above only ever contains the admin/frontend tunnel URLs known at the
// moment THIS backend process started. In practice that went stale
// constantly during devtools testing: refreshing a browser tab that had a
// tunnel URL open from a previous run, a backend restart picking up new
// tunnel URLs while an old tab/bookmark is still open, or just running
// devtools twice in a row — any of these leaves a real browser tab pointed
// at a *.trycloudflare.com origin that isn't in that exact-match list
// anymore, and every request from it 403s here (which the browser reports
// as a CORS failure, not the actual "origin_not_allowed" body, since a
// preflight failure never gets to show the real response). Rather than
// chase exact-match staleness forever, ALLOW_TRYCLOUDFLARE_ORIGINS (set by
// devtools' backend spawn env, alongside EXTRA_ALLOWED_ORIGINS) allows ANY
// https://*.trycloudflare.com origin outright — safe specifically because
// this is opt-in via an env var only devtools ever sets (never set in
// production/.env.example), and trycloudflare.com quick-tunnel hostnames
// are random/unguessable and torn down the moment devtools exits, so this
// never widens what a production deployment accepts.
var allowTrycloudflareOrigins = os.Getenv("ALLOW_TRYCLOUDFLARE_ORIGINS") == "true"

func loadExtraAllowedOrigins() map[string]bool {
	m := map[string]bool{}
	raw := os.Getenv("EXTRA_ALLOWED_ORIGINS")
	if raw == "" {
		return m
	}
	var added []string
	for _, o := range strings.Split(raw, ",") {
		o = strings.TrimSpace(o)
		if o == "" {
			continue
		}
		m[o] = true
		added = append(added, o)
	}
	if len(added) > 0 {
		log.Printf("[CORS] EXTRA_ALLOWED_ORIGINS: allowing %v in addition to the fixed production origins", added)
	}
	return m
}

// IsAllowedOrigin — true if `origin` is one we recognize, empty (no Origin
// header at all — native clients, some WebViews, and non-browser callers
// never send one; nothing meaningful to check there), local-dev
// (localhost/127.0.0.1, any port), or explicitly allowlisted via
// EXTRA_ALLOWED_ORIGINS (see above — devtools' tunnel URLs).
func IsAllowedOrigin(origin string) bool {
	if origin == "" {
		return true
	}
	if allowedOrigins[origin] {
		return true
	}
	if extraAllowedOrigins[origin] {
		return true
	}
	if allowTrycloudflareOrigins && strings.HasPrefix(origin, "https://") && strings.HasSuffix(origin, ".trycloudflare.com") {
		return true
	}
	if strings.HasPrefix(origin, "http://localhost:") || origin == "http://localhost" ||
		strings.HasPrefix(origin, "http://127.0.0.1:") || origin == "http://127.0.0.1" {
		return true
	}
	return false
}
