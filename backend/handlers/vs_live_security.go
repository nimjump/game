package handlers

// vs_live_security.go — extra hardening for the VS live relay, on top of
// Origin checking (origin.go) and the per-IP rate limiter (ratelimit.go)
// already applied to every /backend/vsroom/{id}/live and /watch request.
//
// Honesty note, same as origin.go: nothing here makes the endpoint
// literally unreachable from outside — the client is a public downloadable
// WASM build, so there is no secret that can survive being shipped to every
// visitor. What this DOES do is require anyone connecting to first go
// through the real, rate-limited, Origin-checked HTTP API (GET
// /backend/vsroom/{id}) to obtain a short-lived signed ticket before the
// WebSocket upgrade is accepted at all — a cold, direct connection to the
// raw WS URL with a guessed/scraped room ID (no ticket, or an expired one)
// is rejected outright. Combined with the per-IP concurrent-connection cap
// below, this closes off the two cheapest classes of outside abuse: blind
// scanning/connecting without ever touching our real API, and one IP
// opening large numbers of sockets to burn server resources.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strconv"
	"strings"
	"sync"
	"time"
)

// vsWatchTicketSecret — random per-process key, generated once at startup.
// Tickets only need to be valid for the lifetime of this process; a restart
// invalidates any tickets currently in flight, which just means an already-
// connected spectator's next reconnect re-fetches a fresh one (see
// Main.gd's _vs_watch_open_socket, which always re-fetches the room right
// before every connection attempt, including reconnects).
var vsWatchTicketSecret = func() []byte {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand failing is essentially unheard-of on any real target
		// platform; fall back to a fixed key rather than crash the process
		// over a feature that's defense-in-depth on top of Origin+rate
		// limiting anyway.
		return []byte("nimjump-vs-watch-ticket-fallback-key")
	}
	return b
}()

const vsWatchTicketTTL = 1 * time.Hour

// MakeWatchTicket — "<expiryUnix>.<hexHMAC>", HMAC over roomID+expiry so it
// can't be replayed for a different room or extended past its expiry.
// Included in the JSON response of GET /backend/vsroom/{id} (see
// handleVSRoomGet) — the spectator client must have fetched the room
// through that real endpoint to get one.
func MakeWatchTicket(roomID string) string {
	expiry := time.Now().Add(vsWatchTicketTTL).Unix()
	mac := hmacFor(roomID, expiry)
	return strconv.FormatInt(expiry, 10) + "." + mac
}

// VerifyWatchTicket — checks format, expiry, and HMAC match for this room.
func VerifyWatchTicket(roomID, ticket string) bool {
	parts := strings.SplitN(ticket, ".", 2)
	if len(parts) != 2 {
		return false
	}
	expiry, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return false
	}
	if time.Now().Unix() > expiry {
		return false
	}
	expectedMAC := hmacFor(roomID, expiry)
	// Constant-time compare — this is a real signature check, not just a
	// string equality, so it shouldn't leak timing information either.
	return subtle.ConstantTimeCompare([]byte(expectedMAC), []byte(parts[1])) == 1
}

func hmacFor(roomID string, expiry int64) string {
	h := hmac.New(sha256.New, vsWatchTicketSecret)
	h.Write([]byte(roomID))
	h.Write([]byte(":"))
	h.Write([]byte(strconv.FormatInt(expiry, 10)))
	return hex.EncodeToString(h.Sum(nil))
}

// ── Per-IP concurrent connection cap ────────────────────────────────────
// Separate from the per-second rate limiter in ratelimit.go (which only
// throttles how often an IP can attempt a NEW handshake) — this caps how
// many of THIS ROOM's live/watch sockets from the same IP can be open at
// once, so a single client can't cheaply pin down server resources by
// opening a pile of long-lived connections instead of rapid short ones.
const (
	vsLiveMaxConnsPerIPWatch = 5 // same IP watching one room — different IPs are unlimited
	vsLiveMaxConnsPerIPPlay  = 2 // a real player only ever streams one round at a time
)

var (
	vsLiveConnCountMu sync.Mutex
	// key: kind + ":" + roomID + ":" + ip, e.g. "watch:abc123:1.2.3.4" — the
	// cap is scoped to ONE room per IP, not globally across every room that
	// IP happens to be watching, per the intended limit: "at most 5 people
	// from the same IP can watch a given match; different IPs are
	// unlimited." Watching several unrelated matches from one IP is fine.
	vsLiveConnCount = map[string]int{}
)

// vsLiveTryAcquireConn — returns a release func and true if under the cap
// for this (kind, room, ip) combination, or (nil, false) if already at the
// limit.
func vsLiveTryAcquireConn(kind, roomID, ip string, max int) (func(), bool) {
	key := kind + ":" + roomID + ":" + ip
	vsLiveConnCountMu.Lock()
	if vsLiveConnCount[key] >= max {
		vsLiveConnCountMu.Unlock()
		return nil, false
	}
	vsLiveConnCount[key]++
	vsLiveConnCountMu.Unlock()
	release := func() {
		vsLiveConnCountMu.Lock()
		vsLiveConnCount[key]--
		if vsLiveConnCount[key] <= 0 {
			delete(vsLiveConnCount, key)
		}
		vsLiveConnCountMu.Unlock()
	}
	return release, true
}
