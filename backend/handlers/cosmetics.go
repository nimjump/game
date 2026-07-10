package handlers

// cosmetics.go — Karakter özelleştirme (şapka/gözlük/kıyafet/ayakkabı) HTTP handler'ları.
//
// Endpoint'ler:
//   GET  /backend/cosmetics/catalog  → tüm satılan item'lar + bu oyuncunun sahip/giydiği
//   POST /backend/cosmetics/buy      → {item_id, tx_hash} — NIM ödemesini doğrula, aç
//   POST /backend/cosmetics/equip    → {slot, item_id} — item_id="" ise çıkar

import (
	"encoding/json"

	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
)

// itemOut — catalog item plus the exact pay_memo the client must send with
// its payment for THIS player. Computed server-side (same helper the buy
// verification uses) so the client never has to construct/guess the memo
// string itself — same pattern as VS room's pay_to/pay_memo on the room object.
type itemOut struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Slot     string  `json:"slot"`
	PriceNIM float64 `json:"price_nim"`
	PayMemo  string  `json:"pay_memo"`
}

// GET /backend/cosmetics/catalog
func (s *Server) handleCosmeticsCatalog(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	pc := s.Store.GetCosmetics(playerID)
	cfg := s.Store.GetNimiqConfig()

	out := make([]itemOut, 0, len(game.CosmeticCatalog))
	for _, item := range game.CosmeticCatalog {
		out = append(out, itemOut{
			ID:       item.ID,
			Name:     item.Name,
			Slot:     item.Slot,
			PriceNIM: item.PriceNIM,
			PayMemo:  game.CosmeticMemo(item.ID, playerID),
		})
	}

	writeJSON(ctx, 200, map[string]any{
		"catalog":  out,
		"pay_to":   cfg.WalletAddress,
		"owned":    pc.Owned,
		"equipped": pc.Equipped,
	})
}

// POST /backend/cosmetics/buy  {"item_id": "...", "tx_hash": "..."}
func (s *Server) handleCosmeticsBuy(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	var req struct {
		ItemID string `json:"item_id"`
		TxHash string `json:"tx_hash"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || req.ItemID == "" || req.TxHash == "" {
		writeErr(ctx, 400, "missing_fields")
		return
	}
	pc, err := s.Store.ConfirmCosmeticPurchase(playerID, req.ItemID, req.TxHash)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "owned": pc.Owned, "equipped": pc.Equipped})
}

// POST /backend/cosmetics/equip  {"slot": "hat", "item_id": "hat_red_cap"}  (item_id="" → unequip)
func (s *Server) handleCosmeticsEquip(ctx *fasthttp.RequestCtx) {
	playerID := s.tokenPlayerID(ctx)
	if playerID == "" {
		writeErr(ctx, 401, "auth_required")
		return
	}
	var req struct {
		Slot   string `json:"slot"`
		ItemID string `json:"item_id"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil || req.Slot == "" {
		writeErr(ctx, 400, "missing_slot")
		return
	}
	pc, err := s.Store.EquipCosmetic(playerID, req.Slot, req.ItemID)
	if err != nil {
		writeErr(ctx, 400, err.Error())
		return
	}
	writeJSON(ctx, 200, map[string]any{"ok": true, "owned": pc.Owned, "equipped": pc.Equipped})
}
