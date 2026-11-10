// NimJump — IPv6-only → IPv4-only Nimiq RPC relay.
//
// Runs on ANY dual-stack box (a €4 VPS, your laptop at home, a Raspberry Pi
// behind a router that still hands out IPv4 — it does not matter). Your
// IPv6-only game server talks to this relay over IPv6; the relay talks to
// rpc.nimiqwatch.com over IPv4. No IPv4 address is ever added to the game
// server.
//
//	build:  cd setup/ipv6-only/relay && go build -o rpc-relay .
//	run:    ./rpc-relay -listen [::]:8848 -target https://rpc.nimiqwatch.com -secret 'a-long-random-string'
//	client: NIMIQ_RPC_URL=http://[2001:db8::5]:8848/a-long-random-string
//
// Design notes
//   - The secret lives in the URL PATH, so the backend needs no new config
//     knob and no extra header plumbing — anything hitting /wrong-path gets
//     a 404 without touching the upstream RPC.
//   - One shared keep-alive client: the relay is not the bottleneck, the
//     provider's rate limit is.
//   - Only POST is forwarded; /healthz answers locally.
//   - A light per-IP token bucket protects the upstream from a retry storm
//     (e.g. 40 pending rewards after an outage).
//   - Logs every failure with the upstream status and a body snippet, so a
//     502/HTML captive-portal page is never mistaken for a JSON-RPC answer.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

type relay struct {
	upstream  string
	secret    string
	client    *http.Client
	maxBody   int64
	rateLimit float64 // requests/minute per IP; 0 = unlimited

	mu      sync.Mutex
	buckets map[string]*bucket
}

func main() {
	listen := flag.String("listen", "[::]:8848", "listen address (IPv6 literal recommended)")
	target := flag.String("target", "https://rpc.nimiqwatch.com", "upstream JSON-RPC URL")
	secret := flag.String("secret", os.Getenv("RELAY_SECRET"), "secret path prefix, e.g. /x8f2… (required unless -no-secret)")
	noSecret := flag.Bool("no-secret", false, "run without a secret path (only if the relay is firewalled to your game server's IPv6 /128)")
	rate := flag.Float64("rate", 120, "max requests per MINUTE per source IP (0 = unlimited)")
	timeout := flag.Duration("timeout", 20*time.Second, "upstream timeout")
	flag.Parse()

	if *secret == "" && !*noSecret {
		log.Fatal("refusing to run without a secret: pass -secret '…' (or -no-secret if the port is firewalled to one IPv6 address)")
	}

	r := &relay{
		upstream:  *target,
		secret:    strings.Trim(*secret, "/"),
		maxBody:   4 << 20,
		rateLimit: *rate,
		buckets:   map[string]*bucket{},
		client: &http.Client{
			Timeout: *timeout,
			Transport: &http.Transport{
				MaxIdleConns:        32,
				MaxIdleConnsPerHost: 16,
				IdleConnTimeout:     90 * time.Second,
				ForceAttemptHTTP2:   true,
			},
			// A redirected POST would leak the RPC body somewhere else.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       120 * time.Second,
		ErrorLog:          log.New(os.Stderr, "[relay] ", log.LstdFlags),
	}
	log.Printf("[relay] listening on %s → %s (prefix /%s, rate %.0f/min)", *listen, r.upstream, r.secret, *rate)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func (r *relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	ip := req.RemoteAddr
	if h, _, err := splitHost(ip); err == nil {
		ip = h
	}

	if req.URL.Path == "/healthz" {
		r.health(w)
		return
	}

	// Path must be "/<secret>", optionally with a trailing slash.
	got := strings.Trim(req.URL.Path, "/")
	if r.secret != "" && got != r.secret {
		http.NotFound(w, req) // say nothing useful to scanners
		return
	}
	if req.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !r.allow(ip) {
		http.Error(w, "slow down", http.StatusTooManyRequests)
		return
	}

	body, err := io.ReadAll(io.LimitReader(req.Body, r.maxBody))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}

	up, err := http.NewRequestWithContext(req.Context(), http.MethodPost, r.upstream, strings.NewReader(string(body)))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	up.Header.Set("Content-Type", "application/json")
	up.Header.Set("Accept", "application/json")
	up.Header.Set("User-Agent", "NimJump-rpc-relay/1.0")

	start := time.Now()
	resp, err := r.client.Do(up)
	if err != nil {
		log.Printf("[relay] upstream error from %s: %v", ip, err)
		http.Error(w, "upstream unreachable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	respBody, rerr := io.ReadAll(io.LimitReader(resp.Body, r.maxBody))
	if rerr != nil {
		log.Printf("[relay] upstream read error: %v", rerr)
		http.Error(w, "upstream read error", http.StatusBadGateway)
		return
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("[relay] upstream %d (%.0fms): %s", resp.StatusCode, ms(start), snippet(respBody))
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	w.Write(respBody)
}

func (r *relay) health(w http.ResponseWriter) {
	start := time.Now()
	resp, err := r.client.Post(r.upstream, "application/json",
		strings.NewReader(`{"jsonrpc":"2.0","method":"getBlockNumber","params":[],"id":1}`))
	ok := err == nil
	height := uint64(0)
	if ok {
		defer resp.Body.Close()
		var out struct {
			Result struct {
				Data uint64 `json:"data"`
			} `json:"result"`
		}
		if json.NewDecoder(resp.Body).Decode(&out) == nil {
			height = out.Result.Data
		}
		ok = resp.StatusCode == 200 && height > 0
	}
	outRatio := map[string]any{
		"relay": "ok",
		"upstream": map[string]any{
			"url":        r.upstream,
			"reachable":  ok,
			"block":      height,
			"latency_ms": ms(start),
		},
	}
	w.Header().Set("Content-Type", "application/json")
	if !ok {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(outRatio)
}

// allow is a simple per-IP token bucket: capacity 30, refilled at rateLimit/min.
func (r *relay) allow(ip string) bool {
	if r.rateLimit <= 0 {
		return true
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	b, ok := r.buckets[ip]
	if !ok {
		b = &bucket{tokens: 30, last: now}
		r.buckets[ip] = b
	}
	b.tokens += now.Sub(b.last).Minutes() * r.rateLimit
	if b.tokens > 60 {
		b.tokens = 60
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func splitHost(hostport string) (string, string, error) {
	if strings.HasPrefix(hostport, "[") {
		if i := strings.LastIndex(hostport, "]"); i > 0 {
			return strings.Trim(hostport[:i+1], "[]"), hostport[i+1:], nil
		}
	}
	i := strings.LastIndex(hostport, ":")
	if i < 0 {
		return hostport, "", nil
	}
	return hostport[:i], hostport[i+1:], nil
}

func ms(t time.Time) float64 { return float64(time.Since(t).Microseconds()) / 1000 }

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return fmt.Sprintf("%q", s)
}
