package game

// cosmetics.go — Karakter özelleştirme: şapka / gözlük / kıyafet / ayakkabı.
//
// Satın alma NIM ile yapılır ve VS room giriş ücreti akışıyla AYNI doğrulama
// makinesini kullanır (verifyIncomingVSPayment / txMatchesVSPayment,
// vsroom.go) — sadece memo şeması farklı ("cosmetic:<item_id>:<player_id>").
// Katalog burada sabit bir Go slice'ı olarak tutuluyor (DB'de değil — bu
// config, oyuncu verisi değil). Yeni asset eklerken sadece bu slice'a yeni
// bir CosmeticItem eklemek yeterli; `ID` alanı client'taki
// game/scripts/CosmeticsCatalog.gd içindeki texture-lookup key'iyle birebir
// aynı olmalı.

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"

	"nimjump-backend/models"
)

const cosmeticsKeyPrefix = "cosmetics:"

// cosmeticsLocks — per-player mutex serializing all read-modify-write access
// to a player's PlayerCosmetics record. Same pattern/reason as vsRoomLock in
// vsroom.go: GetCosmetics -> mutate Owned/Equipped -> saveCosmetics is a
// classic TOCTOU "lost update" if two writers race (e.g. two purchases in
// quick succession, a live buy racing the 90s background reconciler pass, or
// a buy racing an equip). Without this lock a player could pay real NIM for
// two items and have one purchase silently clobbered by the other's stale
// read — house never loses money, but a paying customer can be denied goods
// they already paid for, with no automatic recovery.
//
// BUG FIX (security audit): added — previously ConfirmCosmeticPurchase,
// ReconcileCosmeticPayments, and EquipCosmetic all did unlocked
// read-append-save on the same record.
var cosmeticsLocks sync.Map // playerID → *sync.Mutex

func cosmeticsLock(playerID string) *sync.Mutex {
	v, _ := cosmeticsLocks.LoadOrStore(playerID, &sync.Mutex{})
	return v.(*sync.Mutex)
}

// CosmeticCatalog — satılan tüm kozmetikler. Gerçek asset'ler eklendikçe
// buraya yeni satırlar eklenir; fiyatlar admin panelinden değil şu an
// sadece kod üzerinden değiştiriliyor (basit tutmak için — istenirse
// ileride AppConfig gibi DB'ye taşınabilir).
var CosmeticCatalog = []models.CosmeticItem{
	{ID: "hat_red_cap", Name: "Red Cap", Slot: "hat", PriceNIM: 5},
	{ID: "hat_top_hat", Name: "Top Hat", Slot: "hat", PriceNIM: 10},
	{ID: "hat_party", Name: "Party Hat", Slot: "hat", PriceNIM: 8},
	{ID: "glasses_shades", Name: "Cool Shades", Slot: "glasses", PriceNIM: 5},
	{ID: "glasses_nerd", Name: "Nerd Glasses", Slot: "glasses", PriceNIM: 4},
	{ID: "shoes_sneakers", Name: "Sneakers", Slot: "shoes", PriceNIM: 5},
	{ID: "shoes_boots", Name: "Boots", Slot: "shoes", PriceNIM: 6},
	{ID: "outfit_tux", Name: "Tuxedo", Slot: "outfit", PriceNIM: 15},
	{ID: "outfit_superhero", Name: "Superhero Cape", Slot: "outfit", PriceNIM: 18},
}

func cosmeticByID(id string) *models.CosmeticItem {
	for i := range CosmeticCatalog {
		if CosmeticCatalog[i].ID == id {
			return &CosmeticCatalog[i]
		}
	}
	return nil
}

func cosmeticsKey(playerID string) []byte {
	return []byte(cosmeticsKeyPrefix + playerID)
}

// GetCosmetics — bir oyuncunun sahip olduğu + o an giydiği kozmetikler.
// Kayıt yoksa boş (ama nil olmayan) bir PlayerCosmetics döner.
func (s *Store) GetCosmetics(playerID string) models.PlayerCosmetics {
	var pc models.PlayerCosmetics
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(cosmeticsKey(playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &pc)
		})
	})
	if pc.Equipped == nil {
		pc.Equipped = map[string]string{}
	}
	if pc.Owned == nil {
		pc.Owned = []string{}
	}
	return pc
}

func (s *Store) saveCosmetics(playerID string, pc models.PlayerCosmetics) error {
	data, err := json.Marshal(pc)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(cosmeticsKey(playerID), data)
	})
}

func ownsCosmetic(pc models.PlayerCosmetics, itemID string) bool {
	for _, id := range pc.Owned {
		if id == itemID {
			return true
		}
	}
	return false
}

// CosmeticMemo — exported so handlers/cosmetics.go can hand the exact memo
// string to the client in the catalog response (client must never construct
// this itself — same pattern as VS room's server-computed pay_memo).
func CosmeticMemo(itemID, playerID string) string {
	return fmt.Sprintf("cosmetic:%s:%s", itemID, playerID)
}

// ConfirmCosmeticPurchase — client'ın bildirdiği tx_hash'in gerçekten bu
// item için app cüzdanına doğru miktarda + doğru memo ile ödendiğini RPC
// üzerinden doğrular (vsroom.go'daki verifyIncomingVSPayment/
// txMatchesVSPayment tamamen jenerik — sadece memo/miktar/adres karşılaştırıyor,
// VS room'a özel bir şey yok), sonra item'ı oyuncuya kalıcı olarak açar.
// Idempotent: zaten sahipse tekrar tx doğrulamadan mevcut durumu döner.
func (s *Store) ConfirmCosmeticPurchase(playerID, itemID, txHash string) (models.PlayerCosmetics, error) {
	lock := cosmeticsLock(playerID)
	lock.Lock()
	defer lock.Unlock()

	item := cosmeticByID(itemID)
	if item == nil {
		return models.PlayerCosmetics{}, fmt.Errorf("unknown_item")
	}
	pc := s.GetCosmetics(playerID)
	if ownsCosmetic(pc, itemID) {
		return pc, nil
	}

	cfg := s.GetNimiqConfig()
	if cfg.WalletAddress == "" {
		return models.PlayerCosmetics{}, fmt.Errorf("app_wallet_not_configured")
	}
	expectedLuna := int64(item.PriceNIM * float64(NimLunaMultiplier))
	expectedMemo := CosmeticMemo(itemID, playerID)

	ok, verr := verifyIncomingVSPayment(cfg, txHash, expectedMemo, expectedLuna)
	if verr != nil {
		return models.PlayerCosmetics{}, fmt.Errorf("verify_failed: %w", verr)
	}
	if !ok {
		return models.PlayerCosmetics{}, fmt.Errorf("tx_does_not_match")
	}

	pc.Owned = append(pc.Owned, itemID)
	if err := s.saveCosmetics(playerID, pc); err != nil {
		return models.PlayerCosmetics{}, err
	}
	log.Printf("[COSMETICS] purchase confirmed player=%s item=%s tx=%s", playerID, itemID, txHash)
	return pc, nil
}

// ReconcileCosmeticPayments — safety net for cosmetics purchases, same class
// of fix as ReconcileVSPayments/StartVSPaymentReconciler in vsroom.go.
//
// BUG FIX (security audit): ConfirmCosmeticPurchase only ever runs when the
// client successfully calls the backend AFTER the wallet sends the payment —
// if that call is lost (tab closed, network drop, app crash mid-flow), the
// player has paid real NIM on-chain but the item never unlocks, and until
// now nothing — no background job, no admin tool — would ever notice or
// recover it. This mirrors exactly the "lost confirm callback" bug already
// found and fixed for VS room payments; cosmetics had no equivalent safety
// net at all. Since the memo directly encodes both the item and the payer
// (cosmetic:<item_id>:<player_id>, unique per purchase — unlike VS's
// per-room-role memo, there's no reservation/attribution ambiguity here to
// worry about), this can safely just re-derive and grant straight from the
// memo with no extra identity verification needed.
func (s *Store) ReconcileCosmeticPayments() {
	cfg := s.GetNimiqConfig()
	if cfg.WalletAddress == "" {
		return
	}
	txs, err := nimiqGetTransactionsByAddress(cfg.RPCURL, cfg.WalletAddress, 500)
	if err != nil {
		log.Printf("[COSMETICS] reconcile: tx list fetch failed: %v", err)
		return
	}
	for _, tx := range txs {
		toAddr, _ := tx["to"].(string)
		if !nimiqAddressesEqual(toAddr, cfg.WalletAddress) {
			continue
		}
		memo := decodeRecipientData(tx["recipientData"])
		if memo == "" {
			memo = decodeRecipientData(tx["data"])
		}
		if !strings.HasPrefix(memo, "cosmetic:") {
			continue
		}
		parts := strings.SplitN(memo, ":", 3)
		if len(parts) != 3 {
			continue
		}
		itemID, playerID := parts[1], parts[2]
		item := cosmeticByID(itemID)
		if item == nil || playerID == "" {
			continue
		}
		var valueLuna float64
		if v, ok := tx["value"].(float64); ok {
			valueLuna = v
		}
		expectedLuna := int64(item.PriceNIM * float64(NimLunaMultiplier))
		if int64(valueLuna) < expectedLuna {
			continue // underpaid or unrelated tx that happens to share a memo prefix
		}
		hash, _ := tx["hash"].(string)

		// Hold the same per-player lock as ConfirmCosmeticPurchase/EquipCosmetic
		// for the full read-check-write so this background pass can never race
		// (and lose an update against) a live confirm/equip call.
		func() {
			lock := cosmeticsLock(playerID)
			lock.Lock()
			defer lock.Unlock()

			pc := s.GetCosmetics(playerID)
			if ownsCosmetic(pc, itemID) {
				return // already granted — fast path already handled it, or a prior reconcile pass did
			}
			pc.Owned = append(pc.Owned, itemID)
			if serr := s.saveCosmetics(playerID, pc); serr != nil {
				log.Printf("[COSMETICS] reconcile: save failed player=%s item=%s: %v", playerID, itemID, serr)
				return
			}
			log.Printf("[COSMETICS] reconcile: granted item=%s to player=%s tx=%s (confirm call was lost)", itemID, playerID, hash)
		}()
	}
}

// StartCosmeticsReconciler — background safety net, same cadence/pattern as
// StartVSPaymentReconciler. Call once at startup.
func (s *Store) StartCosmeticsReconciler() {
	go func() {
		time.Sleep(20 * time.Second)
		for {
			SafeCall("ReconcileCosmeticPayments", s.ReconcileCosmeticPayments)
			time.Sleep(90 * time.Second)
		}
	}()
}

// EquipCosmetic — bir slotu bir item'a ayarlar, itemID == "" ise o slotu
// çıkarır (unequip). Item o slota ait olmalı ve (ücretliyse) daha önce satın
// alınmış olmalı.
func (s *Store) EquipCosmetic(playerID, slot, itemID string) (models.PlayerCosmetics, error) {
	lock := cosmeticsLock(playerID)
	lock.Lock()
	defer lock.Unlock()

	pc := s.GetCosmetics(playerID)
	if itemID != "" {
		item := cosmeticByID(itemID)
		if item == nil {
			return pc, fmt.Errorf("unknown_item")
		}
		if item.Slot != slot {
			return pc, fmt.Errorf("slot_mismatch")
		}
		if item.PriceNIM > 0 && !ownsCosmetic(pc, itemID) {
			return pc, fmt.Errorf("not_owned")
		}
	}
	if pc.Equipped == nil {
		pc.Equipped = map[string]string{}
	}
	if itemID == "" {
		delete(pc.Equipped, slot)
	} else {
		pc.Equipped[slot] = itemID
	}
	if err := s.saveCosmetics(playerID, pc); err != nil {
		return pc, err
	}
	return pc, nil
}
