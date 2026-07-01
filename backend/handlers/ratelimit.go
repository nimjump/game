package handlers

// ratelimit.go — Token bucket rate limiter
//
// Two tiers:
//   guest  (no auth token):  5 req/s   — attack surface is narrow anyway
//   authed (token present):  15 req/s  — normal player will never notice
//
// Per-IP bucket. Cleanup goroutine runs every 5 minutes
// and removes IPs not seen recently — no memory leak.

import (
	"log"
	"sync"
	"time"

	"github.com/valyala/fasthttp"
)

const (
	guestRate  = 5.0  // token/sn — guest
	authedRate = 15.0 // tokens/s — signed user
	burstMult  = 3.0  // instant burst: rate * burstMult (tolerance for short spikes)
	cleanupTTL = 5 * time.Minute
)

type bucket struct {
	tokens    float64
	maxTokens float64
	rate      float64
	lastSeen  time.Time
	mu        sync.Mutex
}

// take — consume one token. returns false if rate limit exceeded.
func (b *bucket) take() bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	now := time.Now()
	elapsed := now.Sub(b.lastSeen).Seconds()
	b.lastSeen = now

	// Refill tokens based on elapsed time
	b.tokens += elapsed * b.rate
	if b.tokens > b.maxTokens {
		b.tokens = b.maxTokens
	}

	if b.tokens < 1.0 {
		return false
	}
	b.tokens--
	return true
}

// RateLimiter — per-IP token bucket manager
type RateLimiter struct {
	mu      sync.RWMutex
	buckets map[string]*bucket
}

func NewRateLimiter() *RateLimiter {
	rl := &RateLimiter{
		buckets: make(map[string]*bucket),
	}
	go rl.cleanup()
	return rl
}

func (rl *RateLimiter) getBucket(ip string, rate float64) *bucket {
	rl.mu.RLock()
	b, ok := rl.buckets[ip]
	rl.mu.RUnlock()
	if ok {
		return b
	}

	rl.mu.Lock()
	defer rl.mu.Unlock()
	// double-check
	if b, ok = rl.buckets[ip]; ok {
		return b
	}
	b = &bucket{
		tokens:    rate * burstMult, // start full — no penalty on first connection
		maxTokens: rate * burstMult,
		rate:      rate,
		lastSeen:  time.Now(),
	}
	rl.buckets[ip] = b
	return b
}

// Allow — does this IP have tokens? isAuthed=true uses higher limit.
func (rl *RateLimiter) Allow(ip string, isAuthed bool) bool {
	rate := guestRate
	if isAuthed {
		rate = authedRate
	}
	return rl.getBucket(ip+":"+tierStr(isAuthed), rate).take()
}

func tierStr(authed bool) string {
	if authed { return "a" }
	return "g"
}

// cleanup — delete buckets not seen recently, runs every 5 minutes
func (rl *RateLimiter) cleanup() {
	ticker := time.NewTicker(cleanupTTL)
	defer ticker.Stop()
	for range ticker.C {
		cutoff := time.Now().Add(-cleanupTTL)
		rl.mu.Lock()
		for ip, b := range rl.buckets {
			b.mu.Lock()
			old := b.lastSeen.Before(cutoff)
			b.mu.Unlock()
			if old {
				delete(rl.buckets, ip)
			}
		}
		rl.mu.Unlock()
	}
}

// Middleware — called before every handler
// isAuthedFn: is this request signed? (has token?)
func (rl *RateLimiter) Middleware(next fasthttp.RequestHandler, isAuthedFn func(*fasthttp.RequestCtx) bool) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		// Skip OPTIONS preflight from rate limiting
		if string(ctx.Method()) == "OPTIONS" {
			next(ctx)
			return
		}

		ip := realClientIP(ctx)
		authed := isAuthedFn(ctx)

		if !rl.Allow(ip, authed) {
			tier := "guest"
			if authed { tier = "authed" }
			log.Printf("[RATELIMIT] blocked ip=%s tier=%s path=%s", ip, tier, ctx.Path())
			ctx.SetStatusCode(429)
			ctx.SetBodyString(`{"error":"rate_limited"}`)
			ctx.Response.Header.Set("Content-Type", "application/json")
			ctx.Response.Header.Set("Retry-After", "1")
			return
		}
		next(ctx)
	}
}
