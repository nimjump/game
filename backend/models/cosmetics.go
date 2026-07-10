package models

// CosmeticItem — one purchasable/equippable cosmetic (hat, glasses, outfit,
// shoes). The catalog itself lives in backend/game/cosmetics.go (static Go
// slice, not stored in Badger — it's config, not player data). `ID` must
// match the texture-lookup key used by the client's own catalog
// (game/scripts/CosmeticsCatalog.gd) so the two stay in sync.
type CosmeticItem struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Slot     string  `json:"slot"` // "hat" | "glasses" | "outfit" | "shoes"
	PriceNIM float64 `json:"price_nim"`
}

// PlayerCosmetics — one player's owned + currently-equipped cosmetics.
// Stored as a single JSON blob per player in Badger (key "cosmetics:<id>").
type PlayerCosmetics struct {
	Owned    []string          `json:"owned"`
	Equipped map[string]string `json:"equipped"` // slot -> item_id
}
