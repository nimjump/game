package handlers

// admin_proxy.go — serves the admin panel from the same port as the
// backend API. External requests hit http://<host>:<PORT>/<ADMIN_BASE_PATH>/... ;
// this file reverse-proxies those requests to the Next.js admin app (which
// keeps running separately, e.g. `npm start`, on ADMIN_PORT).
//
// Because the backend is exposed to the public internet, every admin UI
// route and every /backend/admin/* API route is protected — via a proper
// login page + session cookie now, see admin_session.go. Credentials
// still come from the ADMIN_USERNAME / ADMIN_PASSWORD env vars (checked
// once, at login time). If they aren't set, admin routes are locked
// (fail closed) rather than left open.
//
// Everything here — port, URL prefix, proxy target, credentials — comes
// from env vars (backend/.env). Nothing is hardcoded except the fallback
// values used only when the corresponding env var is unset.

import (
	"log"
	"os"
	"strings"
	"time"

	"github.com/valyala/fasthttp"
)

var adminProxyClient = &fasthttp.Client{
	MaxConnsPerHost:     64,
	ReadTimeout:         15 * time.Second,
	WriteTimeout:        15 * time.Second,
	MaxIdleConnDuration: 30 * time.Second,
}

// adminPort — port the Next.js admin app listens on. Must match ADMIN_PORT
// in admin/.env. Read from env, no value baked into the source.
func adminPort() string {
	p := os.Getenv("ADMIN_PORT")
	if p == "" {
		p = "3001"
	}
	return p
}

// adminBasePath — URL prefix the admin app is served under (both here and
// via admin/next.config.js's basePath). Must match ADMIN_BASE_PATH in
// admin/.env. Read from env, no value baked into the source.
func adminBasePath() string {
	p := os.Getenv("ADMIN_BASE_PATH")
	if p == "" {
		p = "/admin"
	}
	return strings.TrimSuffix(p, "/")
}

// adminProxyTarget — base URL of the running Next.js admin app.
// ADMIN_PROXY_URL wins if set (e.g. admin app on a different host);
// otherwise built from ADMIN_PORT.
func adminProxyTarget() string {
	t := os.Getenv("ADMIN_PROXY_URL")
	if t == "" {
		t = "http://127.0.0.1:" + adminPort()
	}
	return strings.TrimSuffix(t, "/")
}

// handleAdminProxy — forwards the request as-is (method, headers, body) to
// the Next.js admin app and streams the response back.
func (s *Server) handleAdminProxy(ctx *fasthttp.RequestCtx) {
	target := adminProxyTarget() + string(ctx.RequestURI())

	req := fasthttp.AcquireRequest()
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseRequest(req)
	defer fasthttp.ReleaseResponse(resp)

	ctx.Request.Header.CopyTo(&req.Header)
	req.Header.SetMethod(string(ctx.Method()))
	req.Header.Del("Connection")
	req.SetRequestURI(target)
	req.SetBody(ctx.PostBody())

	if err := adminProxyClient.Do(req, resp); err != nil {
		log.Printf("[ADMIN_PROXY] unreachable path=%s err=%v", ctx.Path(), err)
		ctx.SetStatusCode(502)
		ctx.SetContentType("text/plain; charset=utf-8")
		ctx.SetBodyString("Admin panel unreachable — is the admin app running? (cd admin && npm start)")
		return
	}

	resp.Header.CopyTo(&ctx.Response.Header)
	ctx.Response.Header.Del("Connection")
	ctx.SetStatusCode(resp.StatusCode())
	ctx.SetBody(resp.Body())
}

// ── Credentials (session/login logic lives in admin_session.go) ────────────

// basicAuthConfigured — reads ADMIN_USERNAME / ADMIN_PASSWORD from env.
// Both must be set. Kept under this name for the login handler
// (adminCredentialsConfigured in admin_session.go just wraps it) — the
// name is a holdover from when these were checked via an HTTP Basic Auth
// header; now they're only ever checked once, at /backend/admin/login.
func basicAuthConfigured() (user, pass string, ok bool) {
	user = os.Getenv("ADMIN_USERNAME")
	pass = os.Getenv("ADMIN_PASSWORD")
	return user, pass, user != "" && pass != ""
}
