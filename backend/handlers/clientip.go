package handlers

// clientip.go — Cloudflare-aware real client IP resolution.
//
// Problem: behind Cloudflare (or any reverse proxy), ctx.RemoteIP() is always
// the proxy's edge IP, not the visitor's. Naively trusting X-Forwarded-For /
// CF-Connecting-IP instead is spoofable by anyone who talks to the origin
// directly (bypassing Cloudflare) — they just set the header themselves.
//
// Fix (method 2 — the safe one): only trust those headers when the TCP
// connection itself actually originates from a published Cloudflare IP range.
// Otherwise fall back to the raw RemoteIP(). This means:
//   - Real visitors via Cloudflare → correct per-visitor IP, header trusted
//     because the peer really is Cloudflare.
//   - Anyone hitting the origin directly and forging the header → ignored,
//     RemoteIP() (their own real IP) is used instead.
//
// Cloudflare IP ranges are NOT hardcoded here (they change occasionally and
// a baked-in list silently goes stale). Instead they are fetched live from
// Cloudflare's own published endpoints and cached in memory:
//   https://www.cloudflare.com/ips-v4
//   https://www.cloudflare.com/ips-v6
//
// Caching strategy:
//   - StartCloudflareIPRefresher() is called exactly ONCE, at startup. It
//     fetches the lists a single time and caches them in memory. There is
//     no periodic/background re-fetching — the list is loaded once and used
//     for the lifetime of the process.
//   - There is intentionally no hardcoded fallback list baked into the
//     binary. If that one startup fetch fails, the cache just stays empty,
//     which makes isCloudflareIP() return false for everyone — safe by
//     default: it simply means we fall back to trusting ctx.RemoteIP()
//     directly instead of the spoofable headers, exactly like the "not
//     behind Cloudflare at all" case below.

import (
	"bufio"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/valyala/fasthttp"
)

const (
	cfIPv4URL        = "https://www.cloudflare.com/ips-v4"
	cfIPv6URL        = "https://www.cloudflare.com/ips-v6"
	cfIPFetchTimeout = 8 * time.Second
)

var cfIPCache struct {
	mu   sync.RWMutex
	nets []*net.IPNet
}

// StartCloudflareIPRefresher — call once at startup (see server.go /
// StartBackgroundServices). Fetches the current Cloudflare edge ranges a
// single time (blocking, best-effort — a few seconds max) and caches them.
// No periodic re-fetch happens after this.
func StartCloudflareIPRefresher() {
	nets, err := fetchCloudflareCIDRs()
	if err != nil {
		log.Printf("[CLOUDFLARE_IPS] startup fetch failed, CF header trust disabled for this run: %v", err)
		return
	}
	if len(nets) == 0 {
		log.Printf("[CLOUDFLARE_IPS] startup fetch returned an empty list, CF header trust disabled for this run")
		return
	}

	cfIPCache.mu.Lock()
	cfIPCache.nets = nets
	cfIPCache.mu.Unlock()

	log.Printf("[CLOUDFLARE_IPS] loaded once at startup: %d ranges cached", len(nets))
}

// fetchCloudflareCIDRs — pulls both the v4 and v6 lists. Any failure on
// either one fails the whole refresh (so we never cache a half-updated,
// v4-only or v6-only list).
func fetchCloudflareCIDRs() ([]*net.IPNet, error) {
	client := &http.Client{Timeout: cfIPFetchTimeout}

	var all []*net.IPNet
	for _, url := range []string{cfIPv4URL, cfIPv6URL} {
		lines, err := fetchLines(client, url)
		if err != nil {
			return nil, err
		}
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			_, n, perr := net.ParseCIDR(line)
			if perr != nil {
				// Skip a single malformed line rather than failing the whole fetch
				log.Printf("[CLOUDFLARE_IPS] skipping unparsable line from %s: %q", url, line)
				continue
			}
			all = append(all, n)
		}
	}
	return all, nil
}

func fetchLines(client *http.Client, url string) ([]string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, io.ErrUnexpectedEOF
	}
	var lines []string
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return lines, scanner.Err()
}

// isCloudflareIP — is the given IP inside the currently cached (dynamically
// fetched) Cloudflare edge ranges?
func isCloudflareIP(ip net.IP) bool {
	if ip == nil {
		return false
	}
	cfIPCache.mu.RLock()
	defer cfIPCache.mu.RUnlock()
	for _, n := range cfIPCache.nets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// realClientIP — resolves the true visitor IP, safe against header spoofing.
//
// Order:
//  1. If the direct TCP peer (ctx.RemoteIP()) is a Cloudflare edge IP,
//     trust CF-Connecting-IP (Cloudflare's own header, cannot be set by the
//     visitor — CF overwrites it), falling back to the first hop of
//     X-Forwarded-For if CF-Connecting-IP is somehow absent.
//  2. Otherwise (request did not come through Cloudflare, or the Cloudflare
//     IP list hasn't been fetched successfully yet) — use RemoteIP()
//     directly. Headers are NOT trusted in this branch since anyone can
//     forge them.
func realClientIP(ctx *fasthttp.RequestCtx) string {
	peer := ctx.RemoteIP()

	// BUG FIX: with a Cloudflare TUNNEL (cloudflared running locally and
	// dialing this server over loopback) instead of Cloudflare connecting
	// directly to a public origin IP, the TCP peer this server ever sees is
	// ALWAYS 127.0.0.1/::1 — never a real Cloudflare edge IP — so the
	// isCloudflareIP(peer) check below could never pass, and every request
	// (including admin login attempts) logged as ip=127.0.0.1 regardless of
	// who actually connected. Trusting CF-Connecting-IP/X-Forwarded-For for
	// loopback peers too is safe specifically because this server now binds
	// to 127.0.0.1 only (see main.go BIND_HOST) — nothing on the network can
	// reach the loopback interface to forge these headers directly; the only
	// process able to connect at all is cloudflared itself.
	if isCloudflareIP(peer) || peer.IsLoopback() {
		if cf := strings.TrimSpace(string(ctx.Request.Header.Peek("CF-Connecting-IP"))); cf != "" {
			return cf
		}
		if xff := strings.TrimSpace(string(ctx.Request.Header.Peek("X-Forwarded-For"))); xff != "" {
			// First entry = original client (proxies append, don't prepend)
			if idx := strings.Index(xff, ","); idx >= 0 {
				return strings.TrimSpace(xff[:idx])
			}
			return xff
		}
	}

	return peer.String()
}