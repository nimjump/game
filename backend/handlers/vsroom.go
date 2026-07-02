package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// VS Rooms — async 1v1 "VS" challenge with optional NIM entry fee.
// See backend/game/vsroom.go for the full flow description.

const vsMaxEntryNIM = 100_000 // sanity cap — avoid fat-finger/overflow room amounts

// POST /backend/vsroom/create
// Body: {"entry_nim": 0}   (0 or omitted = free room)
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
	if req.EntryNIM < 0 || req.EntryNIM > vsMaxEntryNIM {
		writeErr(ctx, 400, "bad_entry_amount")
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
		"ok":          true,
		"room":        room,
		"invite_url":  vsRoomInviteURL(room.ID),
		"pay_to":      s.Store.GetNimiqConfig().WalletAddress,
		"pay_amount":  room.EntryNIM,
		"pay_memo":    vsRoomMemoForRole(room.ID, "creator"),
	})
}

// GET /backend/vsroom/{id}
func (s *Server) handleVSRoomGet(ctx *fasthttp.RequestCtx) {
	roomID := ctx.UserValue("id").(string)
	room, err := s.Store.GetVSRoom(roomID)
	if err != nil || room == nil {
		writeErr(ctx, 404, "room_not_found")
		return
	}
	resp := map[string]any{"ok": true, "room": room, "invite_url": vsRoomInviteURL(room.ID)}

	// If the caller is a participant who still needs to pay, include the same
	// pay_to/pay_amount/pay_memo fields create/join return — lets the panel
	// re-fetch a room (e.g. after its poll timer ticks) without losing the
	// ability to show the Pay button.
	if playerID := s.tokenPlayerID(ctx); playerID != "" && room.EntryNIM > 0 {
		var role string
		if playerID == room.CreatorID && !room.CreatorPaid {
			role = "creator"
		} else if playerID == room.OpponentID && !room.OpponentPaid {
			role = "opponent"
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
	writeJSON(ctx, 200, map[string]any{
		"ok":         true,
		"room":       room,
		"pay_to":     cfg.WalletAddress,
		"pay_amount": room.EntryNIM,
		"pay_memo":   vsRoomMemoForRole(room.ID, "opponent"),
	})
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
	writeJSON(ctx, 200, map[string]any{"ok": true, "room": room})
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

// GET /backend/vsroom/mine  — this player's rooms (creator or opponent), newest first
func (s *Server) handleVSRoomMine(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	limit := 30
	if v := string(ctx.QueryArgs().Peek("limit")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	rooms, err := s.Store.ListVSRoomsByPlayer(playerID, limit)
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "rooms": rooms})
}

// GET /backend/vsroom/open — public browse list: rooms open for anyone to
// join (not private, not the caller's own, not expired/full). Private rooms
// deliberately never appear here — they only work via their invite link.
func (s *Server) handleVSRoomOpen(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx) // optional — browsing doesn't require auth
	limit := 30
	if v := string(ctx.QueryArgs().Peek("limit")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	rooms, err := s.Store.ListOpenVSRooms(playerID, limit)
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "rooms": rooms})
}

// ── Admin ────────────────────────────────────────────────────────────────────

// GET /backend/admin/vs-rooms
func (s *Server) handleAdminVSRooms(ctx *fasthttp.RequestCtx) {
	rooms, err := s.Store.ListVSRooms()
	if err != nil {
		writeErr(ctx, 500, "list_failed")
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "rooms": rooms})
}

// POST /backend/admin/vs-rooms/sweep — force-run the expiry/settlement sweep now
func (s *Server) handleAdminVSRoomsSweep(ctx *fasthttp.RequestCtx) {
	s.Store.SweepExpiredVSRooms()
	writeJSON(ctx, 200, map[string]any{"ok": true})
}

// POST /backend/admin/vs-rooms/{id}/cancel — force-close a room nobody has
// joined yet and refund the creator's payment if they'd already paid in.
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

// ── helpers ──────────────────────────────────────────────────────────────────

func vsRoomInviteURL(roomID string) string {
	baseURL := os.Getenv("GAME_URL")
	if baseURL == "" {
		baseURL = "https://nimjump.io"
	}
	return fmt.Sprintf("%s/?vsroom=%s", baseURL, roomID)
}

func vsRoomMemoForRole(roomID, role string) string {
	r := "c"
	if role == "opponent" {
		r = "o"
	}
	return game.VSRoomMemo(roomID, r)
}
