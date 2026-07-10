package handlers

// admin_session.go — cookie-based admin login. Replaces the old browser
// Basic-Auth popup with a proper /admin/login page: the page POSTs
// {username, password} to /backend/admin/login, the backend checks them
// against ADMIN_USERNAME / ADMIN_PASSWORD (same env vars as before —
// nothing new to configure) and, on success, sets an HttpOnly session
// cookie. Every other admin route (both the /backend/admin/* API and the
// proxied /admin/* Next.js pages) then just checks that cookie.

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"strings"

	"github.com/valyala/fasthttp"
)

const adminCookieName = "nimjump_admin"

// adminCredentialsConfigured — reads ADMIN_USERNAME / ADMIN_PASSWORD from
// env. Both must be set, otherwise admin auth is locked (fail closed).
func adminCredentialsConfigured() (user, pass string, ok bool) {
	return basicAuthConfigured()
}

func adminCookieSecure(ctx *fasthttp.RequestCtx) bool {
	if ctx.IsTLS() {
		return true
	}
	proto := string(ctx.Request.Header.Peek("X-Forwarded-Proto"))
	if strings.EqualFold(proto, "https") {
		return true
	}
	// BUG FIX: the X-Forwarded-Proto check above never fired behind a
	// Cloudflare Quick Tunnel (devtools' setup — see realClientIP's own bug
	// fix comment in clientip.go for the same underlying fact) because
	// `cloudflared tunnel --url http://localhost:PORT` doesn't add that
	// header when forwarding to a plain-HTTP local origin. So this always
	// evaluated to false during tunnel testing, which meant Secure was
	// never set on the cookie, which meant the SameSite=None fix in
	// adminCookieSameSite below could never actually engage either (a
	// SameSite=None cookie without Secure is rejected outright by the
	// browser, so the fallback silently stayed on Lax — the exact
	// cross-site "login bounces back to /login" bug persisted even after
	// that fix). CF-Connecting-IP is Cloudflare's own header, present on
	// every request that came through Cloudflare's edge (which, same as
	// realClientIP's reasoning, is TLS/HTTPS by definition on the public
	// side — Cloudflare tunnels don't serve plain HTTP publicly) — its
	// mere presence is a reliable "this arrived over HTTPS" signal even
	// when the hop to this local process itself is plain HTTP.
	if string(ctx.Request.Header.Peek("CF-Connecting-IP")) != "" {
		return true
	}
	return false
}

// adminCookieSameSite — Lax normally, but None when the request is over
// HTTPS (adminCookieSecure). BUG THIS FIXES: in the devtools/tunnel dev
// setup, the admin Next.js app and the Go backend are deliberately served
// from two DIFFERENT Cloudflare Quick Tunnel hostnames (see
// devtools/start-dev-tunnels.js's comment on why admin is run directly
// instead of proxied) — so every admin-panel fetch() to the backend
// (adminLogin, adminMe, and every other call in lib/api.ts, all sent with
// credentials:"include") is a genuinely cross-SITE request. A SameSite=Lax
// cookie is NEVER attached to cross-site fetch/XHR requests (Lax only
// covers top-level cross-site navigations) — so login would succeed and
// set the cookie fine, but the very next adminMe() cross-site check would
// see no cookie at all, look logged-out, and bounce straight back to
// /login. Looked exactly like "I type the right password, it just
// reloads." SameSite=None fixes that; it requires Secure (browsers reject
// None cookies without it), which adminCookieSecure(ctx) already
// guarantees is only claimed true over real HTTPS (the tunnel case) — over
// plain HTTP local dev (same-origin, no tunnel) this still returns Lax,
// which works fine there and avoids the browser rejecting the cookie
// outright for lacking Secure.
func adminCookieSameSite(ctx *fasthttp.RequestCtx) fasthttp.CookieSameSite {
	if adminCookieSecure(ctx) {
		return fasthttp.CookieSameSiteNoneMode
	}
	return fasthttp.CookieSameSiteLaxMode
}

func setAdminCookie(ctx *fasthttp.RequestCtx, token string) {
	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	c.SetKey(adminCookieName)
	c.SetValue(token)
	c.SetPath("/")
	c.SetHTTPOnly(true)
	c.SetSecure(adminCookieSecure(ctx))
	c.SetSameSite(adminCookieSameSite(ctx))
	c.SetMaxAge(7 * 24 * 60 * 60)
	ctx.Response.Header.SetCookie(c)
}

func clearAdminCookie(ctx *fasthttp.RequestCtx) {
	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	c.SetKey(adminCookieName)
	c.SetValue("")
	c.SetPath("/")
	c.SetHTTPOnly(true)
	c.SetSecure(adminCookieSecure(ctx))
	c.SetSameSite(adminCookieSameSite(ctx))
	c.SetMaxAge(-1)
	ctx.Response.Header.SetCookie(c)
}

// AdminFallback — exported session-gated proxy wrapper, for main.go's
// catch-all static-file route to delegate to. This is a defensive safety
// net: the dedicated /admin routes registered in Register() should always
// win for /admin/* paths, but if the router ever resolves the root
// "/{filepath:*}" static-file wildcard first for some path shape we
// didn't anticipate, this makes sure it still reaches the admin app
// (with the login gate) instead of 404ing against ../webexport.
func (s *Server) AdminFallback(ctx *fasthttp.RequestCtx) {
	s.requireAdminSessionPage(s.handleAdminProxy)(ctx)
}

func (s *Server) adminSessionOK(ctx *fasthttp.RequestCtx) bool {
	token := string(ctx.Request.Header.Cookie(adminCookieName))
	return s.Store.ValidAdminSession(token)
}

// POST /backend/admin/login — body: {"username": "...", "password": "..."}
func (s *Server) handleAdminLogin(ctx *fasthttp.RequestCtx) {
	user, pass, configured := adminCredentialsConfigured()
	if !configured {
		log.Printf("[ADMIN_AUTH] ADMIN_USERNAME / ADMIN_PASSWORD not set — admin login locked. Set them in .env")
		ctx.SetStatusCode(503)
		writeJSON(ctx, 503, map[string]any{"error": "admin_not_configured"})
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	userOK := subtle.ConstantTimeCompare([]byte(req.Username), []byte(user)) == 1
	passOK := subtle.ConstantTimeCompare([]byte(req.Password), []byte(pass)) == 1
	if !userOK || !passOK {
		log.Printf("[ADMIN_AUTH] failed login attempt (user=%q ip=%s)", req.Username, realClientIP(ctx))
		ctx.SetStatusCode(401)
		writeJSON(ctx, 401, map[string]any{"error": "invalid_credentials"})
		return
	}
	token, err := s.Store.CreateAdminSession()
	if err != nil {
		log.Printf("[ADMIN_AUTH] session create failed: %v", err)
		ctx.SetStatusCode(500)
		writeJSON(ctx, 500, map[string]any{"error": "session_create_failed"})
		return
	}
	setAdminCookie(ctx, token)
	log.Printf("[ADMIN_AUTH] login ok (ip=%s)", realClientIP(ctx))
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/logout
func (s *Server) handleAdminLogout(ctx *fasthttp.RequestCtx) {
	token := string(ctx.Request.Header.Cookie(adminCookieName))
	s.Store.DeleteAdminSession(token)
	clearAdminCookie(ctx)
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// GET /backend/admin/me — lets the login page (and the app shell) check
// whether the visitor already has a valid session.
func (s *Server) handleAdminMe(ctx *fasthttp.RequestCtx) {
	// Same reasoning as the no-store header on requireAdminSessionPage's
	// redirect — this must never be served stale/cached, it's the exact
	// check the login page uses to decide whether to bounce forward.
	ctx.Response.Header.Set("Cache-Control", "no-store, no-cache, must-revalidate")
	writeJSON(ctx, 200, map[string]any{"authenticated": s.adminSessionOK(ctx)})
}

// requireAdminSession — for /backend/admin/* JSON API routes. 401 JSON on
// no/invalid session (never a redirect — these are called via fetch()).
func (s *Server) requireAdminSession(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		if string(ctx.Method()) == "OPTIONS" {
			next(ctx)
			return
		}
		if _, _, ok := adminCredentialsConfigured(); !ok {
			ctx.SetStatusCode(503)
			writeJSON(ctx, 503, map[string]any{"error": "admin_not_configured"})
			return
		}
		if !s.adminSessionOK(ctx) {
			ctx.SetStatusCode(401)
			writeJSON(ctx, 401, map[string]any{"error": "not_authenticated"})
			return
		}
		next(ctx)
	}
}

// requireAdminSessionPage — for the proxied /admin/* Next.js pages.
// Redirects to the login page on failure instead of returning JSON.
// Always lets the login page itself and Next.js's own static assets
// through unauthenticated — otherwise the login page couldn't load its
// own JS/CSS to render the login form in the first place.
func (s *Server) requireAdminSessionPage(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		base := adminBasePath()
		path := string(ctx.Path())
		if path == base+"/login" ||
			strings.HasPrefix(path, base+"/_next/") ||
			strings.HasPrefix(path, base+"/favicon") {
			next(ctx)
			return
		}
		if _, _, ok := adminCredentialsConfigured(); !ok {
			ctx.SetStatusCode(503)
			ctx.SetBodyString("Admin auth not configured")
			return
		}
		if !s.adminSessionOK(ctx) {
			// A 302 with no Cache-Control is fair game for the browser to
			// cache heuristically (redirects are cacheable by default per
			// HTTP spec unless told otherwise). That's exactly the bug this
			// was causing: visit /admin while logged out -> browser caches
			// this "-> /login" redirect for the GET / request -> log in
			// successfully, cookie is set fine -> hard-navigate back to
			// /admin -> browser serves the STALE cached redirect straight
			// back to /login without even asking the server, cookie or no
			// cookie. Looked exactly like "I log in and it just bounces me
			// back." Explicit no-store means this redirect is never cached,
			// so every visit to a protected page actually re-checks the
			// session cookie server-side like it's supposed to.
			ctx.Response.Header.Set("Cache-Control", "no-store, no-cache, must-revalidate")
			ctx.Response.Header.Set("Pragma", "no-cache")
			ctx.Redirect(base+"/login", fasthttp.StatusFound)
			return
		}
		next(ctx)
	}
}
