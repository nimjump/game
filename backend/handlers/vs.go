package handlers

// VS — real-time 1v1 matchmaking + WebSocket input relay
//
// Flow:
//   POST /backend/vs/join          → {room_id, seed, player_slot, invite_url}
//   GET  /backend/vs/ws/{room_id}  → WebSocket upgrade
//
// Message format (JSON, both directions):
//   Client → Server: {"t":"input","tick":42,"dir":1}          dir: -1 left, 0 none, 1 right
//   Client → Server: {"t":"jump","tick":42}
//   Client → Server: {"t":"done","tick":42,"score":1234}      game over
//   Client → Server: {"t":"ping"}
//   Server → Client: {"t":"matched","slot":0,"seed":"…","opponent":"nickname"}
//   Server → Client: {"t":"countdown","n":3}  …  {"t":"countdown","n":0}
//   Server → Client: {"t":"input","tick":42,"dir":1}          relayed from opponent
//   Server → Client: {"t":"jump","tick":42}
//   Server → Client: {"t":"done","tick":42,"score":1234}
//   Server → Client: {"t":"pong"}
//   Server → Client: {"t":"opponent_left"}

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"sync"
	"time"

	fws "github.com/fasthttp/websocket"
	"github.com/valyala/fasthttp"
)

// ── Constants ────────────────────────────────────────────────────────────────

const (
	vsMatchTimeout  = 60 * time.Second   // max wait for opponent
	vsReadDeadline  = 90 * time.Second   // WS read timeout (covers full game)
	vsWriteDeadline = 5 * time.Second
	vsPingInterval  = 15 * time.Second
	vsMaxRooms      = 500                // hard cap
)

// ── Types ────────────────────────────────────────────────────────────────────

type vsMsg struct {
	T     string `json:"t"`
	Tick  int    `json:"tick,omitempty"`
	Dir   int    `json:"dir,omitempty"`   // -1 / 0 / 1
	Score int    `json:"score,omitempty"`
	N     int    `json:"n,omitempty"`     // countdown number
	Slot  int    `json:"slot,omitempty"`  // 0 or 1
	Seed  string `json:"seed,omitempty"`
	Opponent string `json:"opponent,omitempty"`
}

type vsPlayer struct {
	conn     *fws.Conn
	nickname string
	ready    bool          // WS connected
	done     bool          // game finished
	send     chan []byte   // outbound message queue
}

type vsRoom struct {
	id        string
	seed      string
	players   [2]*vsPlayer
	mu        sync.Mutex
	created   time.Time
	started   bool
	inviteOnly bool  // created via invite link — wait for specific second player
}

// ── Global state ─────────────────────────────────────────────────────────────

var (
	vsMu       sync.Mutex
	vsRooms    = map[string]*vsRoom{}
	vsQueue    []*vsRoom   // matchmaking queue (rooms waiting for 2nd player)
)

var vsUpgrader = fws.FastHTTPUpgrader{
	ReadBufferSize:  512,
	WriteBufferSize: 512,
	CheckOrigin:     func(ctx *fasthttp.RequestCtx) bool { return true },
}

// ── HTTP handlers ─────────────────────────────────────────────────────────────

// POST /backend/vs/join
// Body (JSON, optional): {"nickname":"...", "invite":"ROOM_ID"}
// Response: {"room_id":"...","seed":"...","slot":0,"invite_url":"..."}
func (s *Server) handleVSJoin(ctx *fasthttp.RequestCtx) {
	var req struct {
		Nickname string `json:"nickname"`
		Invite   string `json:"invite"`  // join specific room via invite link
	}
	_ = json.Unmarshal(ctx.PostBody(), &req)
	if req.Nickname == "" {
		req.Nickname = "Player"
	}

	vsMu.Lock()
	defer vsMu.Unlock()

	// Hard cap
	if len(vsRooms) >= vsMaxRooms {
		ctx.SetStatusCode(503)
		ctx.SetBodyString(`{"error":"server_full"}`)
		return
	}

	var room *vsRoom
	slot := 0

	if req.Invite != "" {
		// Join via invite link
		r, ok := vsRooms[req.Invite]
		if !ok || r.started || r.players[1] != nil {
			ctx.SetStatusCode(404)
			ctx.SetBodyString(`{"error":"room_not_found"}`)
			return
		}
		room = r
		slot = 1
		room.players[1] = &vsPlayer{nickname: req.Nickname, send: make(chan []byte, 64)}
	} else {
		// Try matchmaking queue first
		for len(vsQueue) > 0 {
			candidate := vsQueue[0]
			vsQueue = vsQueue[1:]
			// Skip expired or already filled rooms
			if candidate.players[1] != nil || time.Since(candidate.created) > vsMatchTimeout {
				if candidate.players[1] == nil {
					// Notify P0 that we timed out
					delete(vsRooms, candidate.id)
				}
				continue
			}
			room = candidate
			slot = 1
			room.players[1] = &vsPlayer{nickname: req.Nickname, send: make(chan []byte, 64)}
			break
		}

		if room == nil {
			// Create new room, wait for opponent
			room = newVSRoom()
			room.players[0] = &vsPlayer{nickname: req.Nickname, send: make(chan []byte, 64)}
			vsRooms[room.id] = room
			vsQueue = append(vsQueue, room)
			slot = 0
		}
	}

	baseURL := os.Getenv("GAME_URL")
	if baseURL == "" {
		baseURL = "https://nimjump.io"
	}
	inviteURL := fmt.Sprintf("%s/?vs=%s", baseURL, room.id)

	writeJSON(ctx, 200, map[string]any{
		"room_id":    room.id,
		"seed":       room.seed,
		"slot":       slot,
		"invite_url": inviteURL,
	})
}

// GET /backend/vs/ws/{room_id}?slot=0&nickname=xxx
func (s *Server) handleVSWebSocket(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("room_id").(string)
	slot   := 0
	if string(ctx.QueryArgs().Peek("slot")) == "1" {
		slot = 1
	}
	nickname := string(ctx.QueryArgs().Peek("nickname"))
	if nickname == "" {
		nickname = "Player"
	}

	vsMu.Lock()
	room, ok := vsRooms[roomID]
	vsMu.Unlock()

	if !ok {
		ctx.SetStatusCode(404)
		return
	}

	err := vsUpgrader.Upgrade(ctx, func(conn *fws.Conn) {
		room.mu.Lock()
		p := room.players[slot]
		if p == nil {
			// Late join (shouldn't happen normally)
			p = &vsPlayer{nickname: nickname, send: make(chan []byte, 64)}
			room.players[slot] = p
		}
		p.conn = conn
		p.ready = true
		p.nickname = nickname
		room.mu.Unlock()

		log.Printf("[VS] ws connected room=%s slot=%d nick=%s", roomID, slot, nickname)

		// Start writer goroutine
		go vsWriter(conn, p)

		// Check if both players are now connected → start countdown
		room.mu.Lock()
		bothReady := room.players[0] != nil && room.players[0].ready &&
			room.players[1] != nil && room.players[1].ready && !room.started
		if bothReady {
			room.started = true
		}
		oppNick := ""
		if slot == 0 && room.players[1] != nil {
			oppNick = room.players[1].nickname
		} else if slot == 1 && room.players[0] != nil {
			oppNick = room.players[0].nickname
		}
		room.mu.Unlock()

		// Send matched message to this player
		sendJSON(p, vsMsg{T: "matched", Slot: slot, Seed: room.seed, Opponent: oppNick})

		if bothReady {
			go vsCountdown(room)
		} else if slot == 0 {
			// P0 is waiting — start timeout goroutine
			go vsWaitForOpponent(room)
		}

		// Reader loop
		vsReader(room, slot, conn, p)

		// Cleanup on disconnect
		room.mu.Lock()
		p.ready = false
		opp := room.players[1-slot]
		room.mu.Unlock()

		if opp != nil && opp.ready {
			sendJSON(opp, vsMsg{T: "opponent_left"})
		}

		log.Printf("[VS] ws disconnected room=%s slot=%d", roomID, slot)
		vsCleanupRoom(roomID)
	})

	if err != nil {
		log.Printf("[VS] upgrade error room=%s: %v", roomID, err)
	}
}

// ── Room helpers ──────────────────────────────────────────────────────────────

func newVSRoom() *vsRoom {
	id   := vsRandID(8)
	seed := fmt.Sprintf("%d", rand.Int63())
	return &vsRoom{
		id:      id,
		seed:    seed,
		created: time.Now(),
	}
}

func vsRandID(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

func vsCleanupRoom(id string) {
	vsMu.Lock()
	defer vsMu.Unlock()
	r, ok := vsRooms[id]
	if !ok {
		return
	}
	// Only delete if both players disconnected
	if (r.players[0] == nil || !r.players[0].ready) &&
		(r.players[1] == nil || !r.players[1].ready) {
		delete(vsRooms, id)
		log.Printf("[VS] room %s deleted", id)
	}
}

// ── Countdown ────────────────────────────────────────────────────────────────

func vsCountdown(room *vsRoom) {
	// Notify both players of opponent nickname
	room.mu.Lock()
	p0, p1 := room.players[0], room.players[1]
	room.mu.Unlock()

	if p0 != nil {
		sendJSON(p0, vsMsg{T: "matched", Slot: 0, Seed: room.seed, Opponent: p1.nickname})
	}
	if p1 != nil {
		sendJSON(p1, vsMsg{T: "matched", Slot: 1, Seed: room.seed, Opponent: p0.nickname})
	}

	// 3 … 2 … 1 … 0 (go!)
	for n := 3; n >= 0; n-- {
		room.mu.Lock()
		p0, p1 = room.players[0], room.players[1]
		room.mu.Unlock()
		if p0 != nil { sendJSON(p0, vsMsg{T: "countdown", N: n}) }
		if p1 != nil { sendJSON(p1, vsMsg{T: "countdown", N: n}) }
		if n > 0 {
			time.Sleep(time.Second)
		}
	}
}

// ── Wait for opponent (P0 side) ───────────────────────────────────────────────

func vsWaitForOpponent(room *vsRoom) {
	deadline := time.NewTimer(vsMatchTimeout)
	defer deadline.Stop()
	ticker  := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-deadline.C:
			// Timeout — tell P0 no one came
			room.mu.Lock()
			p0 := room.players[0]
			room.mu.Unlock()
			if p0 != nil && p0.ready {
				sendJSON(p0, vsMsg{T: "opponent_left"})
			}
			vsCleanupRoom(room.id)
			return
		case <-ticker.C:
			room.mu.Lock()
			bothReady := room.players[0] != nil && room.players[0].ready &&
				room.players[1] != nil && room.players[1].ready && !room.started
			if bothReady {
				room.started = true
			}
			room.mu.Unlock()
			if bothReady {
				vsCountdown(room)
				return
			}
		}
	}
}

// ── WebSocket I/O ─────────────────────────────────────────────────────────────

func vsReader(room *vsRoom, slot int, conn *fws.Conn, self *vsPlayer) {
	for {
		conn.SetReadDeadline(time.Now().Add(vsReadDeadline))
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return
		}

		// Relay everything raw to opponent — no parsing needed
		room.mu.Lock()
		opp := room.players[1-slot]
		room.mu.Unlock()
		if opp != nil && opp.ready {
			opp.send <- raw
		}
	}
}

func vsWriter(conn *fws.Conn, p *vsPlayer) {
	ticker := time.NewTicker(vsPingInterval)
	defer ticker.Stop()
	for {
		select {
		case msg, ok := <-p.send:
			if !ok {
				return
			}
			conn.SetWriteDeadline(time.Now().Add(vsWriteDeadline))
			if err := conn.WriteMessage(fws.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			conn.SetWriteDeadline(time.Now().Add(vsWriteDeadline))
			if err := conn.WriteMessage(fws.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func sendJSON(p *vsPlayer, v any) {
	if p == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	select {
	case p.send <- b:
	default:
		// Channel full — drop (opponent too slow)
	}
}
