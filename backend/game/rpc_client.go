package game

// ─────────────────────────────────────────────────────────────────────────────
// Nimiq JSON-RPC client — hardened, IPv6-only-friendly transport
//
// Why this file exists
// --------------------
// The original implementation (game/nimiq.go, nimiqRPCCall) did this on EVERY
// single RPC call:
//
//     client := &http.Client{Timeout: 20 * time.Second}
//     resp, err := client.Post(rpcURL, ...)
//
// which means: a brand-new TCP connection + TLS handshake + no keep-alive, no
// HTTP status check (a 502/503 HTML page from a proxy was happily "parsed" as
// JSON and reported as `rpc_parse`), no retry, no failover, no rate-limit
// handling and no way to control which address family is used. On an
// IPv6-only host talking to an IPv4-only endpoint (rpc.nimiqwatch.com has an
// A record and NO AAAA), that combination is exactly what turns one flaky
// lookup into a stream of confusing errors — and, with the reward retry loop,
// into real rate-limit bans.
//
// What this gives you instead:
//
//   • one shared, pooled Transport per endpoint set (keep-alive, HTTP/2,
//     proper idle conn limits) — no more handshake per call;
//   • explicit address-family control via NIMIQ_RPC_NETWORK:
//         auto   → happy-eyeballs (v6 first, v4 fallback)      [default]
//         ipv6   → ONLY tcp6; a v4-only endpoint fails loudly
//         ipv4   → ONLY tcp4
//         nat64  → resolve normally, prefer native v6, and for a v4-only
//                  endpoint synthesise a NAT64 address (64:ff9b::/96 by
//                  default) so an IPv6-only host can reach it WITHOUT ever
//                  being given a public IPv4 address;
//   • optional SOCKS5 / HTTP proxy (NIMIQ_RPC_PROXY) — e.g. a WireGuard or
//     SSH tunnel to a dual-stack box, for when you don't control DNS/NAT64;
//   • endpoint failover: NIMIQ_RPC_URLS="https://a,https://b" — dead
//     endpoints are put in a short cooldown instead of being hammered;
//   • retry with exponential backoff + jitter on TRANSIENT failures only
//     (dial/TLS/timeout, HTTP 429/5xx, JSON-RPC "Rate limit exceeded"),
//     never on logical errors (e.g. "Transaction already in mempool");
//   • HTTP status validation, body size limit, JSON-RPC id check;
//   • a short TTL cache for read-only getBlockNumber (the reward loop asks
//     for it constantly) so we stop burning the provider's rate limit;
//   • RPCDiagnostics() so the admin panel / startup log can say *why* the
//     RPC is unreachable (no AAAA? NAT64 broken? proxy down?) instead of a
//     bare "rpc_connect: dial tcp ... no route to host".
//
// Nothing here changes the on-wire JSON-RPC contract: same methods, same
// params, same result shapes the rest of the code already parses.
// ─────────────────────────────────────────────────────────────────────────────

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ── network mode ─────────────────────────────────────────────────────────────

type rpcNetMode string

const (
	rpcNetAuto  rpcNetMode = "auto"
	rpcNetIPv6  rpcNetMode = "ipv6"
	rpcNetIPv4  rpcNetMode = "ipv4"
	rpcNetNAT64 rpcNetMode = "nat64"
)

func parseRPCNetMode(s string) (rpcNetMode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "auto", "any", "happy-eyeballs":
		return rpcNetAuto, nil
	case "ipv6", "v6", "inet6", "ipv6only", "ipv6-only":
		return rpcNetIPv6, nil
	case "ipv4", "v4", "inet", "ipv4only", "ipv4-only":
		return rpcNetIPv4, nil
	case "nat64", "clat", "464xlat", "dns64":
		return rpcNetNAT64, nil
	default:
		return rpcNetAuto, fmt.Errorf("invalid NIMIQ_RPC_NETWORK %q (want auto|ipv6|ipv4|nat64)", s)
	}
}

// ── config from env ──────────────────────────────────────────────────────────

type rpcClientConfig struct {
	endpoints     []string
	mode          rpcNetMode
	nat64Prefixes []netip.Prefix
	proxyURL      *url.URL
	timeout       time.Duration
	maxRetries    int
	backoff       time.Duration
	blockCache    time.Duration
	userAgent     string
	// hmacSecret turns every RPC request into a signed one (see callOnce).
	// Used when the endpoint is a hardened relay/Worker that refuses
	// unsigned traffic: even someone who discovers the URL cannot use it.
	hmacSecret string
}

func rpcEnvDuration(key string, def time.Duration) time.Duration {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return time.Duration(n) * time.Millisecond
		}
		if d, err := time.ParseDuration(v); err == nil && d >= 0 {
			return d
		}
	}
	return def
}

func rpcEnvInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return def
}

// readRPCConfig builds the client config from the environment. The endpoint
// URL itself still comes from the caller (GetNimiqConfig → NIMIQ_RPC_URL or
// the admin-panel override stored in Badger), so nothing about the existing
// configuration flow changes.
func readRPCConfig(primaryURL string) (rpcClientConfig, error) {
	cfg := rpcClientConfig{
		mode:       rpcNetAuto,
		timeout:    rpcEnvDuration("NIMIQ_RPC_TIMEOUT_MS", 12*time.Second),
		maxRetries: rpcEnvInt("NIMIQ_RPC_MAX_RETRIES", 3),
		backoff:    rpcEnvDuration("NIMIQ_RPC_BACKOFF_MS", 250*time.Millisecond),
		blockCache: rpcEnvDuration("NIMIQ_RPC_BLOCK_CACHE_MS", 2*time.Second),
		userAgent:  "NimJump-backend/1.0 (+nimiq-jsonrpc)",
	}

	// Endpoint list: NIMIQ_RPC_URLS wins (ordered failover), else the single
	// RPCURL from config/env.
	var raw []string
	if extra := strings.TrimSpace(os.Getenv("NIMIQ_RPC_URLS")); extra != "" {
		for _, p := range strings.FieldsFunc(extra, func(r rune) bool { return r == ',' || r == ';' || r == ' ' || r == '\n' }) {
			raw = append(raw, strings.TrimSpace(p))
		}
	}
	if len(raw) == 0 && strings.TrimSpace(primaryURL) != "" {
		raw = []string{strings.TrimSpace(primaryURL)}
	}
	seen := map[string]bool{}
	for _, u := range raw {
		if u == "" || seen[u] {
			continue
		}
		if _, err := url.Parse(u); err != nil {
			return cfg, fmt.Errorf("invalid RPC url %q: %w", u, err)
		}
		seen[u] = true
		cfg.endpoints = append(cfg.endpoints, u)
	}

	mode, err := parseRPCNetMode(os.Getenv("NIMIQ_RPC_NETWORK"))
	if err != nil {
		return cfg, err
	}
	cfg.mode = mode

	// NAT64 prefix (RFC 6052 /96 only — that is what every public NAT64
	// gateway uses, and the only length that maps cleanly onto an IPv4).
	// Comma-separated list is allowed: public NAT64 gateways are shared and
	// rate limited, so having a second prefix to fall back to is real
	// resilience, not gold-plating.
	rawPfxs := strings.TrimSpace(os.Getenv("NIMIQ_NAT64_PREFIX"))
	if rawPfxs == "" {
		rawPfxs = "64:ff9b::/96"
	}
	for _, raw := range strings.FieldsFunc(rawPfxs, func(r rune) bool { return r == ',' || r == ';' || r == ' ' }) {
		p, perr := netip.ParsePrefix(strings.TrimSpace(raw))
		if perr != nil {
			return cfg, fmt.Errorf("invalid NIMIQ_NAT64_PREFIX %q: %w", raw, perr)
		}
		if p.Bits() != 96 {
			return cfg, fmt.Errorf("NIMIQ_NAT64_PREFIX must be a /96 (got %s) — only /96 puts the IPv4 in the last 32 bits", p)
		}
		cfg.nat64Prefixes = append(cfg.nat64Prefixes, p)
	}
	if len(cfg.nat64Prefixes) == 0 {
		return cfg, errors.New("NIMIQ_NAT64_PREFIX is empty")
	}

	cfg.hmacSecret = strings.TrimSpace(os.Getenv("NIMIQ_RPC_HMAC_SECRET"))

	if proxy := strings.TrimSpace(os.Getenv("NIMIQ_RPC_PROXY")); proxy != "" {
		pu, perr := url.Parse(proxy)
		if perr != nil {
			return cfg, fmt.Errorf("invalid NIMIQ_RPC_PROXY: %w", perr)
		}
		switch strings.ToLower(pu.Scheme) {
		case "socks5", "socks5h", "socks":
			// handled by our own dialer (no external dependency)
		case "http", "https":
			// handled by net/http's Transport.Proxy (CONNECT)
		default:
			return cfg, fmt.Errorf("NIMIQ_RPC_PROXY scheme %q unsupported (use socks5:// or http://)", pu.Scheme)
		}
		cfg.proxyURL = pu
	}
	return cfg, nil
}

// ── endpoint health ──────────────────────────────────────────────────────────

type rpcEndpoint struct {
	url       string
	fails     atomic.Int32
	downUntil atomic.Int64 // unix nano
	lastOK    atomic.Int64 // unix nano
	lastErr   atomic.Value // string
	lastFam   atomic.Value // "ipv4" | "ipv6" | "ipv6-nat64"
}

func (e *rpcEndpoint) healthy() bool {
	return time.Now().UnixNano() >= e.downUntil.Load()
}

func (e *rpcEndpoint) markOK() {
	e.fails.Store(0)
	e.downUntil.Store(0)
	e.lastOK.Store(time.Now().UnixNano())
}

func (e *rpcEndpoint) markFail(err error) {
	n := e.fails.Add(1)
	e.lastErr.Store(err.Error())
	// Cooldown grows with consecutive failures, capped at 60s. Short enough
	// that a one-off network blip doesn't sideline an endpoint for long.
	cooldown := time.Duration(n) * 10 * time.Second
	if cooldown > 60*time.Second {
		cooldown = 60 * time.Second
	}
	e.downUntil.Store(time.Now().Add(cooldown).UnixNano())
}

// ── client ───────────────────────────────────────────────────────────────────

type rpcClient struct {
	cfg       rpcClientConfig
	endpoints []*rpcEndpoint
	http      *http.Client
	next      atomic.Uint64

	blockMu     sync.Mutex
	blockCached uint32
	blockAt     time.Time

	// one-shot log de-duplication ("we already told you NAT64 works")
	logMu  sync.Mutex
	logged map[string]bool

	// lastFam is diagnostic only: which address family the most recent
	// successful dial used ("ipv6" / "ipv4" / "ipv6-nat64").
	lastFam atomic.Value
}

// clients are cached per unique config so we don't rebuild a Transport (and
// lose the connection pool) on every call, while still honouring an RPC URL
// changed at runtime from the admin panel.
var (
	rpcClientsMu sync.Mutex
	rpcClients   = map[string]*rpcClient{}
)

func getRPCClient(primaryURL string) (*rpcClient, error) {
	cfg, err := readRPCConfig(primaryURL)
	if err != nil {
		return nil, err
	}
	key := string(cfg.mode) + "|" + cfg.nat64PrefixString() + "|" + cfg.timeout.String() +
		"|" + strconv.Itoa(cfg.maxRetries) + "|" + cfg.blockCache.String() + "|" + strings.Join(cfg.endpoints, ",")
	if cfg.proxyURL != nil {
		key += "|" + cfg.proxyURL.Redacted()
	}
	if cfg.hmacSecret != "" {
		sum := sha256.Sum256([]byte(cfg.hmacSecret))
		key += "|hmac:" + hex.EncodeToString(sum[:8])
	}
	rpcClientsMu.Lock()
	defer rpcClientsMu.Unlock()
	if c, ok := rpcClients[key]; ok {
		return c, nil
	}
	c, err := newRPCClient(cfg)
	if err != nil {
		return nil, err
	}
	// Keep the map from growing forever if someone flips URLs in the panel.
	if len(rpcClients) > 8 {
		rpcClients = map[string]*rpcClient{}
	}
	rpcClients[key] = c
	return c, nil
}

// nat64PrefixString is the comma-joined prefix list, for cache keys/logs.
func (cfg rpcClientConfig) nat64PrefixString() string {
	parts := make([]string, 0, len(cfg.nat64Prefixes))
	for _, p := range cfg.nat64Prefixes {
		parts = append(parts, p.String())
	}
	return strings.Join(parts, ",")
}

func newRPCClient(cfg rpcClientConfig) (*rpcClient, error) {
	if len(cfg.endpoints) == 0 {
		return nil, errors.New("no Nimiq RPC endpoint configured (set NIMIQ_RPC_URL)")
	}
	c := &rpcClient{cfg: cfg, logged: map[string]bool{}}
	for _, u := range cfg.endpoints {
		c.endpoints = append(c.endpoints, &rpcEndpoint{url: u})
	}

	dial := c.dialContext
	tr := &http.Transport{
		DialContext:           dial,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: cfg.timeout,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
	}
	if cfg.proxyURL != nil && (cfg.proxyURL.Scheme == "http" || cfg.proxyURL.Scheme == "https") {
		tr.Proxy = http.ProxyURL(cfg.proxyURL)
	}
	c.http = &http.Client{
		Transport: tr,
		Timeout:   cfg.timeout,
		// Never follow redirects: a captive portal / misconfigured proxy
		// answering 302 would otherwise get our JSON-RPC body POSTed elsewhere.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return c, nil
}

// noteFamily records which address family a connection actually used.
func (c *rpcClient) noteFamily(conn net.Conn, synth bool) {
	if conn == nil {
		return
	}
	ra, ok := conn.RemoteAddr().(*net.TCPAddr)
	if !ok || ra.IP == nil {
		return
	}
	switch {
	case synth:
		c.lastFam.Store("ipv6-nat64")
	case ra.IP.To4() != nil:
		c.lastFam.Store("ipv4")
	case ra.IP.To16() != nil:
		c.lastFam.Store("ipv6")
	}
}

func (c *rpcClient) logOnce(key, format string, args ...any) {
	c.logMu.Lock()
	already := c.logged[key]
	c.logged[key] = true
	c.logMu.Unlock()
	if !already {
		log.Printf(format, args...)
	}
}

// ── dialing (the whole point of this file) ───────────────────────────────────

func (c *rpcClient) dialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	if c.cfg.proxyURL != nil {
		switch strings.ToLower(c.cfg.proxyURL.Scheme) {
		case "socks5", "socks5h", "socks":
			// Remote DNS: the SOCKS server resolves the name, which is
			// exactly what you want when the local host is IPv6-only and
			// the name only has an A record.
			return socks5DialContext(ctx, c.cfg.proxyURL, addr, c.cfg.timeout)
		}
		// http(s) proxy → Transport.Proxy already handles it; addr here is
		// the proxy's own address.
	}

	d := &net.Dialer{Timeout: c.cfg.timeout, KeepAlive: 30 * time.Second}

	switch c.cfg.mode {
	case rpcNetIPv6:
		// Hard IPv6-only: if the host has no AAAA record this fails with a
		// message that actually says so, instead of a generic dial error.
		return c.dialFamily(ctx, d, "tcp6", addr, true)
	case rpcNetIPv4:
		return c.dialFamily(ctx, d, "tcp4", addr, false)
	case rpcNetNAT64:
		return c.dialNAT64(ctx, d, addr)
	default: // auto: let the Go dialer do happy eyeballs (v6 preferred)
		conn, err := d.DialContext(ctx, "tcp", addr)
		if err == nil {
			c.noteFamily(conn, false)
		}
		return conn, err
	}
}

// dialFamily resolves host and dials only addresses of the requested family.
func (c *rpcClient) dialFamily(ctx context.Context, d *net.Dialer, network, addr string, wantV6 bool) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if ip := net.ParseIP(host); ip != nil {
		return d.DialContext(ctx, network, addr) // literal address, nothing to resolve
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, fmt.Errorf("dns lookup %s: %w", host, err)
	}
	var lastErr error
	for _, ip := range ips {
		isV6 := ip.Is6() && !ip.Is4In6()
		if isV6 != wantV6 {
			continue
		}
		conn, derr := d.DialContext(ctx, network, net.JoinHostPort(ip.Unmap().String(), port))
		if derr == nil {
			c.noteFamily(conn, false)
			return conn, nil
		}
		lastErr = derr
	}
	if lastErr == nil {
		if wantV6 {
			return nil, fmt.Errorf("no AAAA record for %s — this endpoint is IPv4-only; use NIMIQ_RPC_NETWORK=nat64, a proxy (NIMIQ_RPC_PROXY) or an IPv6-capable endpoint", host)
		}
		return nil, fmt.Errorf("no A record for %s", host)
	}
	return nil, lastErr
}

// dialNAT64 makes an IPv4-only endpoint reachable from an IPv6-only host by
// dialling the NAT64 gateway instead: <prefix>::<ipv4>. TLS SNI / Host header
// stay untouched (the URL host is what http.Transport uses for TLS), so the
// provider's certificate still validates.
func (c *rpcClient) dialNAT64(ctx context.Context, d *net.Dialer, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	// Try every configured prefix, in order. Within a prefix, try every
	// candidate address before moving on.
	synth := func(v4 netip.Addr) []string {
		out := make([]string, 0, len(c.cfg.nat64Prefixes))
		for _, pfx := range c.cfg.nat64Prefixes {
			out = append(out, net.JoinHostPort(nat64Synthesize(pfx, v4).String(), port))
		}
		return out
	}
	dialCandidates := func(targets []string, synth bool) (net.Conn, error) {
		var lastErr error
		for _, target := range targets {
			conn, err := d.DialContext(ctx, "tcp6", target)
			if err == nil {
				c.noteFamily(conn, synth)
				if synth {
					c.logOnce("nat64-ok", "[NIMIQ-RPC] NAT64 path OK via %s", target)
				}
				return conn, nil
			}
			lastErr = err
		}
		if lastErr == nil {
			lastErr = errors.New("no candidate address")
		}
		return nil, lastErr
	}
	dialV6 := func(target string, synth bool) (net.Conn, error) {
		return dialCandidates([]string{target}, synth)
	}

	// Literal address?
	if ip, perr := netip.ParseAddr(host); perr == nil {
		if ip.Is4() || ip.Is4In6() {
			return dialCandidates(synth(ip), true)
		}
		return dialV6(addr, false)
	}

	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, fmt.Errorf("dns lookup %s: %w", host, err)
	}
	// 1) A native AAAA record always beats translation.
	for _, ip := range ips {
		if ip.Is6() && !ip.Is4In6() {
			conn, derr := dialV6(net.JoinHostPort(ip.String(), port), false)
			if derr == nil {
				return conn, nil
			}
		}
	}
	// 2) Otherwise NAT64 the first A record.
	var lastErr error
	for _, ip := range ips {
		if ip.Is6() && !ip.Is4In6() {
			continue
		}
		conn, derr := dialCandidates(synth(ip), true)
		if derr == nil {
			return conn, nil
		}
		lastErr = derr
	}
	if lastErr == nil {
		return nil, fmt.Errorf("no usable address for %s (no AAAA to use natively, no A to translate)", host)
	}
	return nil, fmt.Errorf("NAT64 to %s via %s failed: %w (is the NAT64 route/prefix configured on this host? see setup/ipv6-only/)", host, c.cfg.nat64PrefixString(), lastErr)
}

// nat64Synthesize maps an IPv4 address into the NAT64 prefix (RFC 6052 for a
// /96 prefix: the IPv4 goes into the last 32 bits). Pure function so it can be
// unit-tested without a live NAT64 gateway.
func nat64Synthesize(prefix netip.Prefix, v4 netip.Addr) netip.Addr {
	b := prefix.Masked().Addr().As16()
	v := v4.Unmap().As4()
	copy(b[12:16], v[:])
	return netip.AddrFrom16(b)
}

// ── JSON-RPC plumbing ───────────────────────────────────────────────────────

type nimRPCReq struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
	ID      int    `json:"id"`
}

type nimRPCResp struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"` // can be null, string, or object
	ID      json.RawMessage `json:"id"`
}

// rpcCodedError is a JSON-RPC level error (the request reached the node and
// the node said no). These are NOT retried — retrying "Transaction already in
// mempool" or "Invalid transaction" just wastes rate limit.
type rpcCodedError struct {
	Code    int
	Message string
	Data    string
}

func (e *rpcCodedError) Error() string {
	if e.Data != "" {
		return fmt.Sprintf("rpc_err %d: %s | data=%s", e.Code, e.Message, e.Data)
	}
	return fmt.Sprintf("rpc_err %d: %s", e.Code, e.Message)
}

// retryable reports whether a failure is worth another attempt.
func retryable(err error) bool {
	if err == nil {
		return false
	}
	var ce *rpcCodedError
	if errors.As(err, &ce) {
		msg := strings.ToLower(ce.Message + " " + ce.Data)
		// Providers commonly surface throttling as a JSON-RPC error instead
		// of HTTP 429.
		return strings.Contains(msg, "rate limit") ||
			strings.Contains(msg, "too many requests") ||
			strings.Contains(msg, "try again") ||
			strings.Contains(msg, "timeout") ||
			strings.Contains(msg, "busy") ||
			strings.Contains(msg, "unavailable")
	}
	if errors.Is(err, context.Canceled) {
		return false
	}
	// Everything else at transport level (dial, TLS, EOF, 429, 5xx) is worth
	// a retry — including "already in mempool", which the node reports as a
	// coded error anyway and is therefore not retried.
	return true
}

// call performs one logical RPC call: endpoint selection, retries with
// backoff, and failover.
func (c *rpcClient) call(method string, params []any) (any, error) {
	if params == nil {
		params = []any{}
	}
	// Free, honest optimisation: the reward loop asks for the block number
	// far more often than blocks are produced.
	if method == "getBlockNumber" && c.cfg.blockCache > 0 {
		c.blockMu.Lock()
		if !c.blockAt.IsZero() && time.Since(c.blockAt) < c.cfg.blockCache {
			v := c.blockCached
			c.blockMu.Unlock()
			return map[string]any{"data": float64(v), "metadata": nil}, nil
		}
		c.blockMu.Unlock()
	}

	var lastErr error
	attempts := c.cfg.maxRetries + 1
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			// exponential backoff with jitter: 250ms, 500ms, 1s, ... ±25%
			base := c.cfg.backoff * time.Duration(1<<uint(attempt-1))
			if base > 10*time.Second {
				base = 10 * time.Second
			}
			jitter := time.Duration(rand.Int63n(int64(base/2 + 1)))
			time.Sleep(base/2 + jitter)
		}

		ep := c.pickEndpoint()
		if ep == nil {
			return nil, fmt.Errorf("%w (all endpoints cooling down, last error: %v)", errors.New("rpc_unavailable"), lastErr)
		}

		res, err := c.callOnce(ep, method, params)
		if err == nil {
			ep.markOK()
			if method == "getBlockNumber" && c.cfg.blockCache > 0 {
				if m, ok := res.(map[string]any); ok {
					if n, ok := m["data"].(float64); ok {
						c.blockMu.Lock()
						c.blockCached = uint32(n)
						c.blockAt = time.Now()
						c.blockMu.Unlock()
					}
				}
			}
			return res, nil
		}
		lastErr = err
		if !retryable(err) {
			return nil, err
		}
		ep.markFail(err)
		log.Printf("[NIMIQ-RPC] %s via %s failed (attempt %d/%d): %v", method, ep.url, attempt+1, attempts, err)
	}
	return nil, fmt.Errorf("rpc_failed after %d attempts: %w", attempts, lastErr)
}

// pickEndpoint returns a healthy endpoint, round-robin, or (if every endpoint
// is cooling down) the one whose cooldown expires soonest.
func (c *rpcClient) pickEndpoint() *rpcEndpoint {
	if len(c.endpoints) == 1 {
		return c.endpoints[0]
	}
	start := int(c.next.Add(1)-1) % len(c.endpoints)
	for i := 0; i < len(c.endpoints); i++ {
		ep := c.endpoints[(start+i)%len(c.endpoints)]
		if ep.healthy() {
			return ep
		}
	}
	return nil
}

func (c *rpcClient) callOnce(ep *rpcEndpoint, method string, params []any) (any, error) {
	reqID := int(c.next.Add(1))
	body, err := json.Marshal(nimRPCReq{JSONRPC: "2.0", Method: method, Params: params, ID: reqID})
	if err != nil {
		return nil, fmt.Errorf("rpc_encode: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep.url, strings.NewReader(string(body)))
	if err != nil {
		return nil, fmt.Errorf("rpc_request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.cfg.userAgent)

	// Signed request (NIMIQ_RPC_HMAC_SECRET). The worker/relay on the other
	// side recomputes HMAC-SHA256(secret, "<unix ts>.<raw body>") and rejects
	// anything that doesn't match or is older than its timestamp window — so
	// a leaked URL alone is useless, and a captured request can't be replayed
	// beyond ~60 s. Signature covers the timestamp, so it can't be swapped.
	if c.cfg.hmacSecret != "" {
		ts := strconv.FormatInt(time.Now().Unix(), 10)
		mac := hmac.New(sha256.New, []byte(c.cfg.hmacSecret))
		mac.Write([]byte(ts))
		mac.Write([]byte("."))
		mac.Write(body)
		req.Header.Set("X-NJ-Ts", ts)
		req.Header.Set("X-NJ-Sig", hex.EncodeToString(mac.Sum(nil)))
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("rpc_connect: %w", err)
	}
	defer resp.Body.Close()

	// Cap the body: a broken proxy returning an endless stream must not be
	// able to OOM the backend.
	limited := io.LimitReader(resp.Body, 8<<20)
	raw, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("rpc_read: %w", err)
	}

	if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
		snippet := strings.TrimSpace(string(raw))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return nil, fmt.Errorf("rpc_http_%d: %s", resp.StatusCode, snippet)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// 4xx other than 429: wrong URL, blocked, auth — retrying won't help.
		return nil, &rpcCodedError{Code: resp.StatusCode, Message: fmt.Sprintf("http %d from %s", resp.StatusCode, ep.url), Data: strings.TrimSpace(string(raw[:min(len(raw), 200)]))}
	}

	if fam, ok := c.lastFam.Load().(string); ok {
		ep.lastFam.Store(fam)
	}

	var r nimRPCResp
	if err := json.Unmarshal(raw, &r); err != nil {
		snippet := strings.TrimSpace(string(raw))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return nil, fmt.Errorf("rpc_parse: %w (body starts with %q — is %s really a JSON-RPC endpoint?)", err, snippet, ep.url)
	}

	// JSON-RPC error field: may be null, a string, or {code,message,data}.
	if len(r.Error) > 0 && string(r.Error) != "null" {
		var obj struct {
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if json.Unmarshal(r.Error, &obj) == nil && (obj.Message != "" || obj.Code != 0) {
			data := ""
			if len(obj.Data) > 0 && string(obj.Data) != "null" {
				data = strings.Trim(string(obj.Data), `"`)
			}
			return nil, &rpcCodedError{Code: obj.Code, Message: obj.Message, Data: data}
		}
		return nil, &rpcCodedError{Message: strings.Trim(string(r.Error), `"`)}
	}

	if len(r.Result) == 0 {
		return nil, fmt.Errorf("rpc_empty_result from %s", ep.url)
	}
	var result any
	if err := json.Unmarshal(r.Result, &result); err != nil {
		return nil, fmt.Errorf("rpc_result_parse: %w", err)
	}
	return result, nil
}

// ── diagnostics ─────────────────────────────────────────────────────────────

// RPCDiagnostics is a snapshot of the RPC transport state, meant for the
// startup log and for an admin-panel "System" tab. Query it when the RPC
// misbehaves: it tells you the mode you're in, which endpoints are cooling
// down and the exact last error per endpoint.
func RPCDiagnostics(primaryURL string) map[string]any {
	c, err := getRPCClient(primaryURL)
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	eps := make([]map[string]any, 0, len(c.endpoints))
	for _, ep := range c.endpoints {
		fam, _ := ep.lastFam.Load().(string)
		lerr, _ := ep.lastErr.Load().(string)
		lastOK := ep.lastOK.Load()
		okStr := ""
		if lastOK > 0 {
			okStr = time.Unix(0, lastOK).UTC().Format(time.RFC3339)
		}
		eps = append(eps, map[string]any{
			"url":        ep.url,
			"healthy":    ep.healthy(),
			"fails":      ep.fails.Load(),
			"last_ok":    okStr,
			"last_error": lerr,
			"family":     fam,
		})
	}
	out := map[string]any{
		"ok":           true,
		"network_mode": string(c.cfg.mode),
		"nat64_prefix": c.cfg.nat64PrefixString(),
		"timeout":      c.cfg.timeout.String(),
		"max_retries":  c.cfg.maxRetries,
		"block_cache":  c.cfg.blockCache.String(),
		"endpoints":    eps,
	}
	if c.cfg.proxyURL != nil {
		out["proxy"] = c.cfg.proxyURL.Redacted()
	}
	out["hmac_signed"] = c.cfg.hmacSecret != ""
	return out
}

// NimiqRPCStartupCheck runs once at boot and logs how the RPC is reachable —
// or, if it isn't, *why* (no AAAA, NAT64 route missing, proxy refused, …).
// It never blocks startup: the reward loop keeps retrying either way.
func NimiqRPCStartupCheck(primaryURL string) {
	c, err := getRPCClient(primaryURL)
	if err != nil {
		log.Printf("[NIMIQ-RPC] config error: %v", err)
		return
	}
	log.Printf("[NIMIQ-RPC] mode=%s endpoints=%d nat64=%s proxy=%v",
		c.cfg.mode, len(c.endpoints), c.cfg.nat64PrefixString(), c.cfg.proxyURL != nil)

	done := make(chan struct{})
	go func() {
		defer close(done)
		start := time.Now()
		// Single attempt: startup must not sit in a retry loop. If this
		// fails, the reward loop's retries are the real recovery path.
		ep := c.pickEndpoint()
		if ep == nil {
			log.Printf("[NIMIQ-RPC] no endpoint available")
			return
		}
		res, err := c.callOnce(ep, "getBlockNumber", nil)
		if err != nil {
			if c.cfg.mode == rpcNetAuto || c.cfg.mode == rpcNetIPv6 {
				log.Printf("[NIMIQ-RPC] WARNING: cannot reach the Nimiq RPC (%v).", err)
				log.Printf("[NIMIQ-RPC] If this host is IPv6-only and the endpoint is IPv4-only (rpc.nimiqwatch.com has no AAAA), set NIMIQ_RPC_NETWORK=nat64 (with a NAT64 route) — or NIMIQ_RPC_PROXY=socks5://… — see setup/ipv6-only/README.md")
			} else {
				log.Printf("[NIMIQ-RPC] WARNING: cannot reach the Nimiq RPC (%v)", err)
			}
			return
		}
		height := uint32(0)
		if m, ok := res.(map[string]any); ok {
			if n, ok := m["data"].(float64); ok {
				height = uint32(n)
			}
		}
		log.Printf("[NIMIQ-RPC] reachable ✓ block=%d in %s", height, time.Since(start).Round(time.Millisecond))
	}()
	select {
	case <-done:
	case <-time.After(3 * c.cfg.timeout):
		log.Printf("[NIMIQ-RPC] startup probe still pending after %s — continuing", 3*c.cfg.timeout)
	}
}

// NimiqRPCCallForDiagnostics exposes a single RPC call for cmd/rpccheck (and
// for any future admin-panel "test this endpoint" button).
func NimiqRPCCallForDiagnostics(rpcURL, method string) (any, error) {
	return nimiqRPCCall(rpcURL, method, nil)
}
