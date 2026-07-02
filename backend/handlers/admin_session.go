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
	return strings.EqualFold(proto, "https")
}

func setAdminCookie(ctx *fasthttp.RequestCtx, token string) {
	c := fasthttp.AcquireCookie()
	defer fasthttp.ReleaseCookie(c)
	c.SetKey(adminCookieName)
	c.SetValue(token)
	c.SetPath("/")
	c.SetHTTPOnly(true)
	c.SetSecure(adminCookieSecure(ctx))
	c.SetSameSite(fasthttp.CookieSameSiteLaxMode)
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
	c.SetSameSite(fasthttp.CookieSameSiteLaxMode)
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
			ctx.Redirect(base+"/login", fasthttp.StatusFound)
			return
		}
		next(ctx)
	}
}
