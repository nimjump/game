package handlers

// vs_live.go — live spectator relay for the VS Rooms system
// (backend/game/vsroom.go). Not a separate matchmaking system — this rides
// on top of the existing async VSRoom flow (create → pay → play → settle).
//
// While a participant is actually playing their round, they stream their
// run to /backend/vsroom/{id}/live — NOT position/score snapshots, but the
// exact same RLE-encoded input bytes the client already builds for the
// normal replay log (see GameManager.gd's RECORDING-mode encoder). The
// server just buffers those bytes in memory (per room) and fans them out
// to anyone connected to /backend/vsroom/{id}/watch. A spectator who joins
// mid-run gets the full backlog first (in order), then live bytes as they
// arrive — the client feeds this straight into the SAME deterministic
// replay player used for "Watch Replay" (GameManager.gd's PLAYING mode), so
// spectating a live match is pixel-for-pixel the real game, not a
// stand-in visualization. It naturally can't "seek" past data that hasn't
// arrived yet since there's simply nothing there to decode.
//
// On top of the raw input relay, two small control-channel messages keep
// spectators informed without them needing to poll room state:
//   - {"t":"viewers","n":N}          sent on every join/leave
//   - {"t":"status","playing":bool}  sent when the player's stream
//                                    connects/disconnects (e.g. their
//                                    internet drops mid-round) — the client
//                                    shows a "waiting for player" banner and
//                                    freezes on the last received frame
//                                    instead of guessing the match is over.
//
// This replaces the old real-time WS matchmaking system (formerly vs.go,
// now emptied) for the "watch a match live" use case — that system was
// never reachable from the shipped menu in the first place.

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/fasthttp/websocket"
	"github.com/valyala/fasthttp"

	"nimjump-backend/models"
)

const (
	// Caps memory per room — a VS round never remotely approaches this many
	// bytes of RLE input log, so in practice this never trims anything; it's
	// just a hard ceiling against a pathological runaway session.
	vsLiveMaxBufferedBytes = 2_000_000
	vsLiveWriteDeadline    = 5 * time.Second
	vsLiveReadIdleTimeout  = 60 * time.Second
	vsLivePingInterval     = 15 * time.Second
)

// vsLiveMsg — one queued outbound item for a subscriber. `binary`
// distinguishes raw game-input bytes (WS binary frame — the client appends
// these straight onto its replay log) from JSON control messages (WS text
// frame — parsed and acted on, never fed into the replay decoder).
type vsLiveMsg struct {
	binary  bool
	payload []byte
}

type vsLiveSub struct {
	send chan vsLiveMsg
}

type vsLiveRoom struct {
	mu          sync.Mutex
	frames      []byte // concatenated raw RLE input bytes received so far, this run
	subscribers map[*vsLiveSub]struct{}
	playing     bool
}

var (
	vsLiveMu       sync.Mutex
	vsLiveRooms    = map[string]*vsLiveRoom{}
	vsLiveUpgrader = websocket.FastHTTPUpgrader{
		// A real browser (or WebView) always sends a genuine Origin header
		// on a WebSocket handshake — unlike a plain HTTP fetch, it can't be
		// coaxed into omitting or lying about it from page JS. This is the
		// single strongest lock available here: it reliably blocks another
		// website embedding a page that opens a socket straight to our
		// relay, and blocks casual scripts that don't bother spoofing
		// headers. It doesn't stop a dedicated non-browser client that
		// forges Origin on purpose — see origin.go's doc comment for why
		// that's a fundamental limit of any public web client, not
		// something fixable here. The per-participant token check
		// (handleVSRoomLivePlay) and the per-IP rate limit (server.go) are
		// the other two layers that matter more against determined abuse.
		CheckOrigin: func(ctx *fasthttp.RequestCtx) bool {
			origin := string(ctx.Request.Header.Peek("Origin"))
			return IsAllowedOrigin(origin)
		},
	}
)

func getOrCreateVSLiveRoom(roomID string) *vsLiveRoom {
	vsLiveMu.Lock()
	defer vsLiveMu.Unlock()
	r, ok := vsLiveRooms[roomID]
	if !ok {
		r = &vsLiveRoom{subscribers: map[*vsLiveSub]struct{}{}}
		vsLiveRooms[roomID] = r
	}
	return r
}

// IsVSRoomLive — true while a participant is actively streaming their run.
// Used to add a "live" flag to room JSON (handleVSRoomGet/Mine/Open, admin
// vs-rooms list) so the client/admin UI can show a "LIVE" badge without
// opening a WS connection just to check.
func IsVSRoomLive(roomID string) bool {
	vsLiveMu.Lock()
	r, ok := vsLiveRooms[roomID]
	vsLiveMu.Unlock()
	if !ok {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.playing
}

// setPlaying flips the playing flag and tells every current spectator right
// away — this is the signal the client uses to show/hide the "waiting for
// player" banner (e.g. their opponent's internet dropped mid-round).
func (r *vsLiveRoom) setPlaying(v bool) {
	r.mu.Lock()
	r.playing = v
	r.mu.Unlock()
	r.broadcastMeta(map[string]any{"t": "status", "playing": v})
}

func (r *vsLiveRoom) viewerCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.subscribers)
}

func (r *vsLiveRoom) broadcastViewerCount() {
	r.broadcastMeta(map[string]any{"t": "viewers", "n": r.viewerCount()})
}

// broadcastFrame appends raw input bytes to the room's backlog and fans them
// out to every connected spectator as a binary WS message. Non-blocking per
// subscriber — a slow/stuck spectator just misses bytes instead of backing
// up the player's own connection; reconnecting re-sends the full backlog so
// nothing is permanently lost from their point of view.
func (r *vsLiveRoom) broadcastFrame(data []byte) {
	r.mu.Lock()
	r.frames = append(r.frames, data...)
	if len(r.frames) > vsLiveMaxBufferedBytes {
		r.frames = r.frames[len(r.frames)-vsLiveMaxBufferedBytes:]
	}
	msg := vsLiveMsg{binary: true, payload: data}
	for sub := range r.subscribers {
		select {
		case sub.send <- msg:
		default:
		}
	}
	r.mu.Unlock()
}

// broadcastMeta sends a small JSON control message to every current
// subscriber. Never touches the replay backlog.
func (r *vsLiveRoom) broadcastMeta(obj map[string]any) {
	b, err := json.Marshal(obj)
	if err != nil {
		return
	}
	msg := vsLiveMsg{binary: false, payload: b}
	r.mu.Lock()
	for sub := range r.subscribers {
		select {
		case sub.send <- msg:
		default:
		}
	}
	r.mu.Unlock()
}

// addSubscriber registers a new spectator and returns everything needed to
// bring them up to speed immediately: the full backlog so far, whether the
// player is currently actively streaming, and the resulting viewer count.
func (r *vsLiveRoom) addSubscriber() (*vsLiveSub, []byte, bool, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	sub := &vsLiveSub{send: make(chan vsLiveMsg, 256)}
	r.subscribers[sub] = struct{}{}
	backlog := make([]byte, len(r.frames))
	copy(backlog, r.frames)
	return sub, backlog, r.playing, len(r.subscribers)
}

func (r *vsLiveRoom) removeSubscriber(sub *vsLiveSub) {
	r.mu.Lock()
	delete(r.subscribers, sub)
	r.mu.Unlock()
}

// GET /backend/vsroom/{id}/live?token=... — the currently-playing
// participant streams their run's raw input bytes. Auth required via the
// standard ?token= fallback in tokenPlayerID (WS clients can't set custom
// headers). Only the participant whose turn it actually is may stream —
// rejects everyone else, no arbitrary byte injection into someone else's
// match.
func (s *Server) handleVSRoomLivePlay(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		ctx.Error("auth_required", fasthttp.StatusUnauthorized)
		return
	}
	room, err := s.Store.GetVSRoom(roomID)
	if err != nil || room == nil {
		ctx.Error("room_not_found", fasthttp.StatusNotFound)
		return
	}
	isCreator := room.CreatorID == playerID
	isOpponent := room.OpponentID == playerID
	if !isCreator && !isOpponent {
		ctx.Error("not_a_participant", fasthttp.StatusForbidden)
		return
	}
	myTurn := (isCreator && room.Status == models.VSAwaitingCreatorPlay) ||
		(isOpponent && room.Status == models.VSAwaitingOppPlay)
	if !myTurn {
		ctx.Error("not_your_turn", fasthttp.StatusForbidden)
		return
	}

	release, ok := vsLiveTryAcquireConn("play", roomID, realClientIP(ctx), vsLiveMaxConnsPerIPPlay)
	if !ok {
		ctx.Error("too_many_connections", fasthttp.StatusTooManyRequests)
		return
	}
	// NOTE: Upgrade() hijacks the connection and returns almost immediately —
	// the callback below runs for the actual lifetime of the socket. release()
	// must be deferred INSIDE that callback, not out here, or the connection
	// slot would free up the instant Upgrade() returns instead of when the
	// spectator/player actually disconnects.

	liveRoom := getOrCreateVSLiveRoom(roomID)
	liveRoom.mu.Lock()
	liveRoom.frames = nil // fresh run — clear any stale backlog from a previous attempt
	liveRoom.mu.Unlock()

	err = vsLiveUpgrader.Upgrade(ctx, func(conn *websocket.Conn) {
		defer release()
		liveRoom.setPlaying(true)
		defer liveRoom.setPlaying(false)
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(vsLiveReadIdleTimeout))
		for {
			mt, msg, rerr := conn.ReadMessage()
			if rerr != nil {
				return // player disconnected (network drop) or run ended normally
			}
			_ = conn.SetReadDeadline(time.Now().Add(vsLiveReadIdleTimeout))
			if mt == websocket.BinaryMessage && len(msg) > 0 {
				liveRoom.broadcastFrame(msg)
			}
		}
	})
	if err != nil {
		release() // callback never ran (upgrade itself failed) — must release manually
		log.Printf("[VS_LIVE] play-upgrade failed room=%s player=%s err=%v", roomID, playerID[:min(8, len(playerID))], err)
	}
}

// GET /backend/vsroom/{id}/watch?ticket=... — spectator. No player-account
// auth (spectating is meant to be open to "anyone with the room link"), but
// NOT a cold/anonymous connection either: `ticket` must be a still-valid
// signature this exact server issued for this exact room (see
// vs_live_security.go / handleVSRoomGet's `watch_ticket` field) — obtained
// by first calling the real, rate-limited, Origin-checked HTTP API. A
// direct WS connection with no ticket, a stale one, or one for a different
// room is rejected before anything else happens.
//
// Sends the buffered backlog first (as one binary message, in order), then
// the current viewer count + playing status, then a `{"t":"live_start"}`
// marker, then live bytes/control messages as they arrive. A dropped
// connection here is meant to be reconnected by the client — Main.gd
// re-fetches the room (and a fresh ticket) before every reconnect attempt,
// so nothing needs special server-side resume-from-offset logic.
func (s *Server) handleVSRoomLiveWatch(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.GetVSRoom(roomID)
	if err != nil || room == nil {
		ctx.Error("room_not_found", fasthttp.StatusNotFound)
		return
	}

	ticket := string(ctx.QueryArgs().Peek("ticket"))
	if ticket == "" || !VerifyWatchTicket(roomID, ticket) {
		ctx.Error("invalid_or_expired_ticket", fasthttp.StatusForbidden)
		return
	}

	release, ok := vsLiveTryAcquireConn("watch", roomID, realClientIP(ctx), vsLiveMaxConnsPerIPWatch)
	if !ok {
		ctx.Error("too_many_connections", fasthttp.StatusTooManyRequests)
		return
	}

	liveRoom := getOrCreateVSLiveRoom(roomID)
	sub, backlog, playing, count := liveRoom.addSubscriber()
	liveRoom.broadcastViewerCount() // tell existing watchers a new one joined
	// NOTE: cleanup (removeSubscriber/broadcastViewerCount/release) is
	// deferred INSIDE the Upgrade callback below, not here — Upgrade()
	// hijacks the connection and returns almost immediately, well before
	// the socket actually closes, so anything deferred at this level would
	// fire at the wrong time (right after connecting, not on disconnect).
	cleanup := func() {
		liveRoom.removeSubscriber(sub)
		liveRoom.broadcastViewerCount() // tell whoever's left the count went down
		release()
	}

	err = vsLiveUpgrader.Upgrade(ctx, func(conn *websocket.Conn) {
		defer cleanup()
		defer conn.Close()

		if len(backlog) > 0 {
			_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
			if werr := conn.WriteMessage(websocket.BinaryMessage, backlog); werr != nil {
				return
			}
		}
		statusB, _ := json.Marshal(map[string]any{"t": "status", "playing": playing})
		_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
		if werr := conn.WriteMessage(websocket.TextMessage, statusB); werr != nil {
			return
		}
		viewersB, _ := json.Marshal(map[string]any{"t": "viewers", "n": count})
		_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
		if werr := conn.WriteMessage(websocket.TextMessage, viewersB); werr != nil {
			return
		}
		_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
		if werr := conn.WriteMessage(websocket.TextMessage, []byte(`{"t":"live_start"}`)); werr != nil {
			return
		}

		pingTicker := time.NewTicker(vsLivePingInterval)
		defer pingTicker.Stop()

		// Reader goroutine purely to notice a closed connection promptly —
		// spectators aren't expected to send anything meaningful.
		closed := make(chan struct{})
		go func() {
			for {
				if _, _, rerr := conn.ReadMessage(); rerr != nil {
					close(closed)
					return
				}
			}
		}()

		for {
			select {
			case m, ok := <-sub.send:
				if !ok {
					return
				}
				wsType := websocket.TextMessage
				if m.binary {
					wsType = websocket.BinaryMessage
				}
				_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
				if werr := conn.WriteMessage(wsType, m.payload); werr != nil {
					return
				}
			case <-pingTicker.C:
				_ = conn.SetWriteDeadline(time.Now().Add(vsLiveWriteDeadline))
				if werr := conn.WriteMessage(websocket.PingMessage, nil); werr != nil {
					return
				}
			case <-closed:
				return
			}
		}
	})
	if err != nil {
		cleanup() // callback never ran (upgrade itself failed) — must clean up manually
		log.Printf("[VS_LIVE] watch-upgrade failed room=%s err=%v", roomID, err)
	}
}
