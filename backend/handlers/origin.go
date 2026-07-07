package handlers

// origin.go — single source of truth for "does this request/connection come
// from somewhere we actually expect" (the game's own domain, our own backend
// domain, or a local dev box). Used by main.go's CORS middleware (rejects
// disallowed browser Origins on every /backend/* HTTP request) and by
// vs_live.go's WebSocket upgrader (rejects disallowed Origins on /live and
// /watch upgrade requests).
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

import "strings"

// allowedOrigins — exact matches. Keep in sync with ApiConfig.gd's
// PROD_BASE / PROD_GAME_URL on the client.
var allowedOrigins = map[string]bool{
	"https://nimjump.zetashare.com":  true, // the game's public URL (ApiConfig.PROD_GAME_URL)
	"https://backbone.zetashare.com": true, // the backend's own URL (ApiConfig.PROD_BASE) — same-origin case
}

// IsAllowedOrigin — true if `origin` is one we recognize, empty (no Origin
// header at all — native clients, some WebViews, and non-browser callers
// never send one; nothing meaningful to check there), or local-dev
// (localhost/127.0.0.1, any port).
func IsAllowedOrigin(origin string) bool {
	if origin == "" {
		return true
	}
	if allowedOrigins[origin] {
		return true
	}
	if strings.HasPrefix(origin, "http://localhost:") || origin == "http://localhost" ||
		strings.HasPrefix(origin, "http://127.0.0.1:") || origin == "http://127.0.0.1" {
		return true
	}
	return false
}
