package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"strconv"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/models"
)

// VS Rooms — async 1v1 "VS" challenge with optional NIM entry fee.
// See backend/game/vsroom.go for the full flow description.

// vsMaxEntryNIM — NOT a product limit on how big a stake can be: the wallet
// itself already blocks paying more than you actually hold, so there's no need
// to cap what someone chooses to bet. This ceiling exists ONLY as an overflow
// guard for the NIM→luna math (NIM * 100000 must stay well inside int64, which
// overflows around ~92 trillion NIM). 1 billion is astronomically above any
// real stake while keeping that math provably safe.
const vsMaxEntryNIM = 1_000_000_000
// Free (0 NIM) rooms are no longer allowed — every room needs a real stake.
// The client keypad defaults to 100 and refuses to submit below this, but
// enforce it here too since the client can't be trusted alone.
const vsMinEntryNIM = 5

// POST /backend/vsroom/create
// Body: {"entry_nim": 100}   (must be >= vsMinEntryNIM — free rooms aren't allowed)
func (s *Server) handleVSRoomCreate(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	var req struct {
		EntryNIM  float64 `json:"entry_nim"`
		IsPrivate bool    `json:"is_private"`
	}
	_ = json.Unmarshal(ctx.PostBody(), &req)
	if req.EntryNIM < vsMinEntryNIM || req.EntryNIM > vsMaxEntryNIM {
		writeErr(ctx, 400, "bad_entry_amount")
		return
	}
	// Entry fee is whole NIM only — the client keypad no longer even offers a
	// decimal key, but a raw API caller could still send a fractional value,
	// so enforce it here too.
	if req.EntryNIM != math.Trunc(req.EntryNIM) {
		writeErr(ctx, 400, "entry_amount_must_be_whole")
		return
	}

	nick := "Player"
	if pn, err := s.Store.GetNickname(playerID); err == nil && pn != nil && pn.Nickname != "" {
		nick = pn.Nickname
	}

	room, err := s.Store.CreateVSRoom(playerID, nick, req.EntryNIM, req.IsPrivate)
	if err != nil {
		log.Printf("[VSROOM] create failed player=%s err=%v", playerID, err)
		writeErr(ctx, 500, "create_failed")
		return
	}

	writeJSON(ctx, 200, map[string]any{
		"ok": true,
		// Strip the seed: a just-created room is unpaid, so the creator must
		// not see it yet (see game.StripVSSeed / canSeeVSSeed — closes the
		// free create->peek-seed->cancel grinding exploit). The seed arrives
		// on the next room GET once the creator has actually paid.
		"room":        game.StripVSSeed(*room, playerID),
		"invite_url":  vsRoomInviteURL(room.ShortCode),
		"pay_to":      s.Store.GetNimiqConfig().WalletAddress,
		"pay_amount":  room.EntryNIM,
		"pay_memo":    vsRoomMemoForRole(room.ID, "creator"),
	})
}

// GET /backend/vsroom/{id} — {id} accepts EITHER the long internal room ID OR
// the short public ?vs= code (invite links carry the short code). Tries the
// exact ID first, then resolves it as a ShortCode.
func (s *Server) handleVSRoomGet(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.GetVSRoom(roomID)
	if err != nil || room == nil {
		// Not an internal ID — maybe it's a public short code from an invite link.
		room, err = s.Store.GetVSRoomByShortCode(roomID)
	}
	if err != nil || room == nil {
		writeErr(ctx, 404, "room_not_found")
		return
	}
	playerID := s.tokenPlayerID(ctx)
	// SECURITY: this route is intentionally reachable without auth (a shared
	// invite link has to work before the recipient signs in), so anyone who
	// knows/guesses the room ID could otherwise read the shared game seed
	// before playing their own round. Strip it unless the caller is actually
	// one of the room's two participants.
	viewRoom := game.StripVSSeed(*room, playerID)
	resp := map[string]any{"ok": true, "room": viewRoom, "invite_url": vsRoomInviteURL(room.ShortCode)}

	// If the caller is a participant who still needs to pay, include the same
	// pay_to/pay_amount/pay_memo fields create/join return — lets the panel
	// re-fetch a room (e.g. after its poll timer ticks) without losing the
	// ability to show the Pay button.
	if playerID != "" && room.EntryNIM > 0 {
		var role string
		if playerID == room.CreatorID && !room.CreatorPaid {
			role = "creator"
		} else if playerID == room.OpponentID && !room.OpponentPaid {
			role = "opponent"
		} else if room.OpponentID == "" && playerID == room.PendingOpponentID {
			// Pay-to-join: this player tapped Accept and is the pending payer.
			// They're NOT a committed opponent yet (OpponentID is still empty and
			// nobody sees them as joined), but THEY need their Pay button back on
			// a re-fetch. viewer_is_pending_opponent tells their own client to
			// treat them as the paying opponent.
			role = "opponent"
			resp["viewer_is_pending_opponent"] = true
		}
		if role != "" {
			resp["pay_to"] = s.Store.GetNimiqConfig().WalletAddress
			resp["pay_amount"] = room.EntryNIM
			resp["pay_memo"] = vsRoomMemoForRole(room.ID, role)
		}
	}

	writeJSON(ctx, 200, resp)
}

// POST /backend/vsroom/{id}/join
func (s *Server) handleVSRoomJoin(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	roomID := ctx.UserValue("id").(string)

	nick := "Player"
	if pn, err := s.Store.GetNickname(playerID); err == nil && pn != nil && pn.Nickname != "" {
		nick = pn.Nickname
	}

	room, err := s.Store.JoinVSRoom(roomID, playerID, nick)
	if err != nil {
		log.Printf("[VSROOM] join failed room=%s player=%s err=%v", roomID, playerID, err)
		writeErr(ctx, 409, err.Error())
		return
	}

	cfg := s.Store.GetNimiqConfig()
	resp := map[string]any{
		"ok": true,
		// Strip the seed — a paid room's opponent has only RESERVED the slot to
		// pay; they haven't committed yet, so they must not scout the level
		// before paying (see game.canSeeVSSeed). Delivered once they've paid.
		"room":       game.StripVSSeed(*room, playerID),
		"pay_to":     cfg.WalletAddress,
		"pay_amount": room.EntryNIM,
		"pay_memo":   vsRoomMemoForRole(room.ID, "opponent"),
	}
	// For a paid room the join didn't commit them — flag them as the pending
	// payer so their own client shows the Pay button (OpponentID is still empty
	// and no one else sees them as joined until the payment confirms).
	if room.EntryNIM > 0 && room.OpponentID == "" {
		resp["viewer_is_pending_opponent"] = true
	}
	writeJSON(ctx, 200, resp)
}

// POST /backend/vsroom/{id}/pay
// Body: {"tx_hash": "..."}   — submitted after the player's wallet sends the entry-fee tx
func (s *Server) handleVSRoomConfirmPayment(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	roomID := ctx.UserValue("id").(string)
	var req struct {
		TxHash string `json:"tx_hash"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || req.TxHash == "" {
		writeErr(ctx, 400, "missing_tx_hash")
		return
	}

	room, err := s.Store.ConfirmVSRoomPayment(roomID, playerID, req.TxHash)
	if err != nil {
		log.Printf("[VSROOM] pay confirm failed room=%s player=%s err=%v", roomID, playerID, err)
		writeErr(ctx, 400, err.Error())
		return
	}
	// Payment just succeeded, so canSeeVSSeed now returns the seed to this
	// player — but route it through StripVSSeed anyway (defense-in-depth: if
	// the paid flag somehow isn't set, the seed still won't leak).
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": game.StripVSSeed(*room, playerID)})
}

// POST /backend/vsroom/{id}/start
// Claims the caller's SINGLE play attempt BEFORE their run begins. This is the
// network-safe lock: once this returns ok, that side is marked played forever,
// so a later dropped score-submit can never earn them a fresh replay. The client
// MUST get a 200 here before starting the round; if this call fails (offline),
// the round simply never starts and nothing is lost. Returns the room with the
// seed so the round runs from the authoritative server seed.
func (s *Server) handleVSRoomStartPlay(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.ClaimVSRoomPlay(roomID, playerID)
	if err != nil {
		// "already_played" is a normal, expected outcome (double-tap, a retry
		// after a lost response, or reopening the room) — the client turns it into
		// "you've already played this match" and shows the result/waiting screen.
		log.Printf("[VSROOM] start-play refused room=%s player=%s err=%v", roomID, playerID, err)
		writeErr(ctx, 409, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": game.StripVSSeed(*room, playerID)})
}

// POST /backend/vsroom/{id}/cancel
func (s *Server) handleVSRoomCancel(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	roomID := ctx.UserValue("id").(string)
	if err := s.Store.CancelVSRoom(roomID, playerID); err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// queryPage reads limit/offset query params shared by every paginated VS
// list endpoint. limit<=0 (or missing) falls back to def; offset<0 clamps to 0.
func queryPage(ctx *fasthttp.RequestCtx, def int) (limit, offset int) {
	limit = def
	if v := string(ctx.QueryArgs().Peek("limit")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	if v := string(ctx.QueryArgs().Peek("offset")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			offset = n
		}
	}
	return
}

// GET /backend/vsroom/mine?limit=&offset=  — this player's rooms (creator or
// opponent), newest first, paginated. Player-created room count is
// unbounded (they can open as many paid rooms as they can afford), so this
// can no longer just silently truncate at a fixed count — the response
// includes "total" and "offset" so the client can page through everything.
func (s *Server) handleVSRoomMine(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	limit, offset := queryPage(ctx, 30)
	rooms, total, err := s.Store.ListVSRoomsByPlayer(playerID, limit, offset)
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	writeJSON(ctx, 200, map[string]any{
		"ok": true, "rooms": rooms, "total": total, "offset": offset, "limit": limit,
	})
}

// GET /backend/vsroom/pending-count — number of this player's matches that
// are waiting on THEM (opponent joined, not finished, they haven't played
// their round yet). Drives the red "it's your turn" badge on the VS tab in
// the main menu. Cheap enough to poll periodically.
func (s *Server) handleVSRoomPendingCount(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	n, err := s.Store.CountVSRoomsNeedingAction(playerID)
	if err != nil {
		writeErr(ctx, 500, "count_failed")
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "count": n})
}

// GET /backend/vsroom/open?limit=&offset= — public browse list: rooms open
// for anyone to join (not private, not the caller's own, not expired/full).
// Private rooms deliberately never appear here — they only work via their
// invite link.
func (s *Server) handleVSRoomOpen(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx) // optional — browsing doesn't require auth
	limit, offset := queryPage(ctx, 30)
	// ListOpenVSRooms doesn't support offset internally (it's a smaller,
	// naturally-bounded "browse" list) — apply offset/limit via the shared
	// pagination helper on top of its result.
	all, err := s.Store.ListOpenVSRooms(playerID, 0)
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	page, total := game.PaginateVSRooms(all, limit, offset)
	// Public/unauthenticated browsing — never a participant of a room they
	// haven't joined yet, so strip the seed from every entry unconditionally.
	rooms := make([]models.VSRoom, len(page))
	for i, r := range page {
		rooms[i] = game.StripVSSeed(r, "")
	}
	writeJSON(ctx, 200, map[string]any{
		"ok": true, "rooms": rooms, "total": total, "offset": offset, "limit": limit,
	})
}

// POST /backend/vsroom/{id}/forfeit — request to mutually bail out of a
// matched room. Only takes effect (cancel + full refund) once both sides
// have requested it.
func (s *Server) handleVSRoomForfeit(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.RequestVSForfeit(roomID, playerID)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": game.StripVSSeed(*room, playerID)})
}

// ── Admin ────────────────────────────────────────────────────────────────────

// GET /backend/admin/vs-rooms?limit=&offset=
func (s *Server) handleAdminVSRooms(ctx *fasthttp.RequestCtx) {
	all, err := s.Store.ListVSRooms()
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	limit, offset := queryPage(ctx, 100)
	rooms, total := game.PaginateVSRooms(all, limit, offset)
	writeJSON(ctx, 200, map[string]any{
		"ok": true, "rooms": rooms, "total": total, "offset": offset, "limit": limit,
	})
}

// POST /backend/admin/vs-rooms/sweep — force-run the expiry/settlement sweep now
func (s *Server) handleAdminVSRoomsSweep(ctx *fasthttp.RequestCtx) {
	s.Store.SweepExpiredVSRooms()
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/vs-rooms/{id}/cancel — force-close any non-terminal
// room (including an already-matched, both-paid one — this is the admin
// dispute/intervention path) and refund whichever side(s) actually paid in.
func (s *Server) handleAdminVSRoomCancel(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.AdminCancelAndRefundVSRoom(roomID)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": room})
}

// POST /backend/admin/vs-rooms/reconcile-payments — force-run the payment
// reconciler now instead of waiting for its next automatic pass (every 90s).
func (s *Server) handleAdminVSRoomsReconcile(ctx *fasthttp.RequestCtx) {
	s.Store.ReconcileVSPayments()
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/vs-rooms/{id}/resolve — declare the winner of a disputed /
// under-review match and pay it out. Body: {"outcome":"creator|opponent|tie"}.
func (s *Server) handleAdminVSRoomResolve(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	var req struct {
		Outcome string `json:"outcome"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeErr(ctx, 400, "bad_json")
		return
	}
	room, err := s.Store.AdminResolveVSRoomWinner(roomID, req.Outcome)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": room})
}

// POST /backend/admin/vs-rooms/{id}/reopen — wipe scores + review, fresh seed,
// reset the play window so both funded players can replay the match cleanly.
func (s *Server) handleAdminVSRoomReopen(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.AdminReopenVSRoom(roomID)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": room})
}

// ── helpers ──────────────────────────────────────────────────────────────────

// vsRoomInviteURL builds the shareable link from the room's PUBLIC ShortCode
// (not the long internal ID) — "?vs=1903". The backend resolves that code back
// to the room on the GET route (see handleVSRoomGet).
func vsRoomInviteURL(shortCode string) string {
	baseURL := os.Getenv("GAME_URL")
	if baseURL == "" {
		baseURL = "https://nimjump.io"
	}
	return fmt.Sprintf("%s/?vs=%s", baseURL, shortCode)
}

func vsRoomMemoForRole(roomID, role string) string {
	r := "c"
	if role == "opponent" {
		r = "o"
	}
	return game.VSRoomMemo(roomID, r)
}
