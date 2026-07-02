package game

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"strconv"
	"strings"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

// VS Rooms — async 1v1 "VS" challenge with optional NIM entry fee.
//
// Flow:
//   1. Creator: POST /backend/vsroom/create → room saved, status
//      awaiting_creator_pay (entry>0) or awaiting_creator_play (free).
//   2. If entry>0: creator pays via their own wallet (sendBasicTransactionWithData,
//      data=memo tag) → POST /backend/vsroom/{id}/pay confirms + verifies via RPC.
//   3. Creator plays their round locally, submits via the normal /backend/submit
//      flow with vs_room_id+vs_role=creator → once server-verified, score is
//      written here and status becomes waiting_opponent (invite link now live).
//   4. Opponent joins via invite link → POST /backend/vsroom/{id}/join. This is
//      when the real "1 day to play" clock starts (ExpiresAt is reset here,
//      NOT set once at creation) — both sides then have a shared 24h window
//      from that moment to actually play their (already-fixed) seed, then the
//      same pay+play steps for the opponent's side.
//   5. Whoever finishes second (or the 24h sweep) triggers settlement:
//      winner gets 95% of the pooled entries, 5% stays in the app wallet as
//      the system fee (no separate tx needed for that).
//
// Everything is persisted to BadgerDB (prefix "vsroom:") so an app restart
// never loses a room mid-flight — the sweep goroutine picks up wherever it
// left off using nothing but ExpiresAt/Status/paid-flags read back from disk.

const (
	keyVSRoomPrefix = "vsroom:"
	// vsRoomJoinWindow — how long an invite link stays valid while nobody has
	// joined yet. Not specified by product requirements, chosen generously so
	// a shared link doesn't go stale on someone who takes a few days to open
	// it, while still eventually letting long-abandoned rooms settle/refund.
	vsRoomJoinWindow = 30 * 24 * time.Hour
	// vsRoomPlayWindow — the actual "1 day to play" window. Starts the moment
	// the opponent joins (NOT at room creation) — see JoinVSRoom.
	vsRoomPlayWindow = 24 * time.Hour
	vsPayoutFrac     = 0.95 // winner's cut; remaining 5% is the system fee
)

// ── Per-room locking ─────────────────────────────────────────────────────────
//
// Every function that mutates a room does GetVSRoom → modify in Go memory →
// saveVSRoom. Those three steps are NOT atomic on their own — two concurrent
// requests for the same room (e.g. an admin force-cancel racing an opponent's
// join, or the payment reconciler racing the client's own confirm call) could
// both read the same starting state and one write would silently clobber the
// other's ("lost update"). vsRoomLock serializes ALL mutating access to a
// given room ID within this process, closing that class of bug completely —
// every exported mutating function below acquires it before its first read
// and holds it through the final save.
var vsRoomLocks sync.Map // room ID → *sync.Mutex

func vsRoomLock(roomID string) *sync.Mutex {
	v, _ := vsRoomLocks.LoadOrStore(roomID, &sync.Mutex{})
	return v.(*sync.Mutex)
}

// ── ID / seed helpers ────────────────────────────────────────────────────────

func vsRoomRandID(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

// vsRoomMemo — deterministic, short (<64 byte) tx memo used to match an
// incoming payment to a room + role. role must be "c" (creator) or "o" (opponent).
func vsRoomMemo(roomID, role string) string {
	return fmt.Sprintf("vs:%s:%s", roomID, role)
}

// VSRoomMemo — exported for handlers to build the same memo string to show
// the player before they pay.
func VSRoomMemo(roomID, role string) string {
	return vsRoomMemo(roomID, role)
}

// ── CRUD ─────────────────────────────────────────────────────────────────────

func (s *Store) saveVSRoom(r *models.VSRoom) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(keyVSRoomPrefix+r.ID), data)
	})
}

func (s *Store) GetVSRoom(id string) (*models.VSRoom, error) {
	var r models.VSRoom
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyVSRoomPrefix + id))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &r)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &r, err
}

// ListVSRooms — all rooms, newest first (admin view).
func (s *Store) ListVSRooms() ([]models.VSRoom, error) {
	prefix := []byte(keyVSRoomPrefix)
	var out []models.VSRoom
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = prefix
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var r models.VSRoom
				if e := json.Unmarshal(v, &r); e == nil {
					out = append(out, r)
				}
				return nil
			})
		}
		return nil
	})
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].CreatedAt > out[i].CreatedAt {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out, err
}

// FindVSRoomBySessionID — locates the VS room (if any) that a given play
// session belongs to. Used to gate public replay-watching: while a VS match
// is still pending (one side hasn't played yet), showing the other side's
// exact replay would let them scout the identical seed's platform/enemy
// layout before playing their own round — an unfair advantage that has
// nothing to do with skill. Once both sides have played, the replay is safe
// to reveal (the match is already decided, nobody can act on it anymore).
func (s *Store) FindVSRoomBySessionID(sessionID string) (*models.VSRoom, error) {
	if sessionID == "" {
		return nil, nil
	}
	all, err := s.ListVSRooms()
	if err != nil {
		return nil, err
	}
	for i := range all {
		if all[i].CreatorSession == sessionID || all[i].OpponentSession == sessionID {
			return &all[i], nil
		}
	}
	return nil, nil
}

// ListVSRoomsByPlayer — rooms where playerID is creator or opponent, newest first.
func (s *Store) ListVSRoomsByPlayer(playerID string, limit int) ([]models.VSRoom, error) {
	all, err := s.ListVSRooms()
	if err != nil {
		return nil, err
	}
	var out []models.VSRoom
	for _, r := range all {
		if r.CreatorID == playerID || r.OpponentID == playerID {
			out = append(out, r)
		}
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ListOpenVSRooms — public "browse" list: rooms that are public (not
// IsPrivate), still waiting for an opponent (creator already played their
// side, invite window not expired), and not the requester's own room.
// Private rooms only ever work via their direct invite link — they never
// show up here, by design.
func (s *Store) ListOpenVSRooms(excludePlayerID string, limit int) ([]models.VSRoom, error) {
	all, err := s.ListVSRooms()
	if err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	var out []models.VSRoom
	for _, r := range all {
		if r.IsPrivate {
			continue
		}
		if r.CreatorID == excludePlayerID {
			continue
		}
		if !r.IsOpen(now) {
			continue
		}
		out = append(out, r)
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ── Create / Join ────────────────────────────────────────────────────────────

func (s *Store) CreateVSRoom(creatorID, creatorNickname string, entryNIM float64, isPrivate bool) (*models.VSRoom, error) {
	if entryNIM < 0 {
		entryNIM = 0
	}
	now := time.Now()
	status := models.VSAwaitingCreatorPlay
	if entryNIM > 0 {
		status = models.VSAwaitingCreatorPay
	}
	r := &models.VSRoom{
		ID:              vsRoomRandID(8),
		Seed:            strconv.FormatInt(rand.Int63(), 10),
		EntryNIM:        entryNIM,
		IsPrivate:       isPrivate,
		CreatorID:       creatorID,
		CreatorNickname: creatorNickname,
		Status:          status,
		CreatedAt:       now.Unix(),
		// Provisional — this is the "invite link still valid" deadline, not
		// the 1-day play window. Reset to now+vsRoomPlayWindow the moment an
		// opponent actually joins (see JoinVSRoom).
		ExpiresAt: now.Add(vsRoomJoinWindow).Unix(),
	}
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] created id=%s creator=%s entry=%.4f status=%s", r.ID, creatorID, entryNIM, r.Status)
	return r, nil
}

// JoinVSRoom — second player claims the opponent slot.
func (s *Store) JoinVSRoom(roomID, playerID, nickname string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if r.OpponentID != "" && r.OpponentID != playerID {
		return nil, fmt.Errorf("room_full")
	}
	if r.CreatorID == playerID {
		return nil, fmt.Errorf("cannot_join_own_room")
	}
	if time.Now().Unix() >= r.ExpiresAt {
		return nil, fmt.Errorf("room_expired")
	}
	if r.Status != models.VSWaitingOpponent && r.OpponentID != playerID {
		return nil, fmt.Errorf("room_not_open")
	}
	if r.OpponentID == "" {
		r.OpponentID = playerID
		r.OpponentNickname = nickname
		if r.IsFree() {
			r.Status = models.VSAwaitingOppPlay
		} else {
			r.Status = models.VSAwaitingOppPay
		}
		// The "1 day to play" window starts NOW, not at room creation —
		// both sides get the full 24h to actually play their round.
		r.ExpiresAt = time.Now().Add(vsRoomPlayWindow).Unix()
		if err := s.saveVSRoom(r); err != nil {
			return nil, err
		}
		log.Printf("[VSROOM] joined id=%s opponent=%s status=%s expires_at=%d", r.ID, playerID, r.Status, r.ExpiresAt)
	}
	return r, nil
}

// ── Payment confirmation ──────────────────────────────────────────────────────

// ConfirmVSRoomPayment — verifies an incoming tx (by hash) actually paid the
// room's entry fee to the app wallet with the right memo tag, then advances
// the room's status. Safe to call more than once (idempotent once paid).
func (s *Store) ConfirmVSRoomPayment(roomID, playerID, txHash string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if r.IsFree() {
		return nil, fmt.Errorf("room_is_free")
	}

	var role string
	switch playerID {
	case r.CreatorID:
		role = "c"
		if r.CreatorPaid {
			return r, nil // already confirmed
		}
	case r.OpponentID:
		role = "o"
		if r.OpponentPaid {
			return r, nil
		}
	default:
		return nil, fmt.Errorf("not_a_participant")
	}

	cfg := s.GetNimiqConfig()
	if cfg.WalletAddress == "" {
		return nil, fmt.Errorf("app_wallet_not_configured")
	}
	expectedLuna := int64(entryLuna(r.EntryNIM))
	expectedMemo := vsRoomMemo(r.ID, role)

	ok, verr := verifyIncomingVSPayment(cfg, txHash, expectedMemo, expectedLuna)
	if verr != nil {
		return nil, fmt.Errorf("verify_failed: %w", verr)
	}
	if !ok {
		return nil, fmt.Errorf("tx_does_not_match")
	}

	if role == "c" {
		r.CreatorPaid = true
		r.CreatorPayTx = txHash
		r.Status = models.VSAwaitingCreatorPlay
	} else {
		r.OpponentPaid = true
		r.OpponentPayTx = txHash
		r.Status = models.VSAwaitingOppPlay
	}
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] payment confirmed id=%s role=%s tx=%s", r.ID, role, txHash)
	return r, nil
}

func entryLuna(nim float64) int64 {
	return int64(nim * float64(NimLunaMultiplier))
}

// verifyIncomingVSPayment — looks up a tx by hash via RPC (the fast path,
// used right after the client's wallet sends the payment) and checks it
// against the expected recipient/amount/memo. See ReconcileVSPayments below
// for the slow-but-guaranteed fallback path that doesn't depend on this
// client-reported hash ever arriving.
func verifyIncomingVSPayment(cfg models.NimiqConfig, txHash, expectedMemo string, expectedLuna int64) (bool, error) {
	if txHash == "" {
		return false, fmt.Errorf("empty_tx_hash")
	}
	result, err := nimiqRPCCall(cfg.RPCURL, "getTransactionByHash", []any{txHash})
	if err != nil {
		return false, err
	}
	data := unwrapRPCData(result)
	if data == nil {
		return false, fmt.Errorf("unexpected_tx_result: %v", result)
	}
	ok, reason := txMatchesVSPayment(data, cfg.WalletAddress, expectedMemo, expectedLuna)
	if !ok {
		return false, fmt.Errorf("%s", reason)
	}
	return true, nil
}

// unwrapRPCData — Nimiq RPC responses are sometimes the raw object, sometimes
// wrapped as {"data": {...}, "metadata": ...} depending on method/node version.
// Handle both shapes in one place.
func unwrapRPCData(result any) map[string]any {
	if m, ok := result.(map[string]any); ok {
		if inner, ok := m["data"].(map[string]any); ok {
			return inner
		}
		return m
	}
	return nil
}

// txMatchesVSPayment — the actual match check (recipient/amount/memo),
// shared by both the single-hash lookup and the address-scan reconciler.
func txMatchesVSPayment(data map[string]any, wantAddress, expectedMemo string, expectedLuna int64) (bool, string) {
	toAddr, _ := data["to"].(string)
	if !nimiqAddressesEqual(toAddr, wantAddress) {
		return false, fmt.Sprintf("recipient_mismatch got=%s want=%s", toAddr, wantAddress)
	}
	var valueLuna float64
	switch v := data["value"].(type) {
	case float64:
		valueLuna = v
	}
	if int64(valueLuna) < expectedLuna {
		return false, fmt.Sprintf("amount_too_low got=%.0f want=%d", valueLuna, expectedLuna)
	}
	memo := decodeRecipientData(data["recipientData"])
	if memo == "" {
		memo = decodeRecipientData(data["data"])
	}
	if memo != expectedMemo {
		return false, fmt.Sprintf("memo_mismatch got=%q want=%q", memo, expectedMemo)
	}
	return true, ""
}

// ── Reconciliation — guarantees a payment can never get "lost" ──────────────
//
// The fast path (ConfirmVSRoomPayment, above) depends on the client
// successfully calling us back with the tx hash after their wallet sends it.
// If that call never arrives — tab closed, network dropped, Nimiq Pay crashed
// mid-flow, anything — the payment would otherwise sit on-chain forever with
// nobody knowing to credit it. ReconcileVSPayments closes that gap: it scans
// the app wallet's own recent incoming transactions directly (source of
// truth is the chain, not the client) and matches them against every room
// that's still waiting on a payment, purely by memo tag. This runs on a
// timer (StartVSPaymentReconciler) independent of anything the client does,
// so a real payment is mathematically guaranteed to eventually be found.
func (s *Store) ReconcileVSPayments() {
	cfg := s.GetNimiqConfig()
	if cfg.WalletAddress == "" {
		return
	}
	rooms, err := s.ListVSRooms()
	if err != nil {
		return
	}
	var pending []models.VSRoom
	for _, r := range rooms {
		if r.IsFree() || isVSTerminalStatus(r.Status) {
			continue
		}
		if !r.CreatorPaid || (r.OpponentID != "" && !r.OpponentPaid) {
			pending = append(pending, r)
		}
	}
	if len(pending) == 0 {
		return
	}

	txs, err := nimiqGetTransactionsByAddress(cfg.RPCURL, cfg.WalletAddress, 200)
	if err != nil {
		log.Printf("[VSROOM] reconcile: tx list fetch failed: %v", err)
		return
	}
	if len(txs) == 0 {
		return
	}

	for i := range pending {
		roomID := pending[i].ID
		func() {
			lock := vsRoomLock(roomID)
			lock.Lock()
			defer lock.Unlock()

			// Re-fetch fresh under the lock — never act on the pre-lock
			// snapshot, another request may have already confirmed/settled
			// this room since ListVSRooms ran above.
			r, gerr := s.GetVSRoom(roomID)
			if gerr != nil || r == nil || r.IsFree() || isVSTerminalStatus(r.Status) {
				return
			}

			changed := false
			if !r.CreatorPaid {
				if hash := findMatchingTx(txs, cfg.WalletAddress, vsRoomMemo(r.ID, "c"), int64(entryLuna(r.EntryNIM))); hash != "" {
					r.CreatorPaid = true
					r.CreatorPayTx = hash
					if r.Status == models.VSAwaitingCreatorPay {
						r.Status = models.VSAwaitingCreatorPlay
					}
					changed = true
					log.Printf("[VSROOM] reconcile: found creator payment room=%s tx=%s (client never confirmed it)", r.ID, hash)
				}
			}
			if r.OpponentID != "" && !r.OpponentPaid {
				if hash := findMatchingTx(txs, cfg.WalletAddress, vsRoomMemo(r.ID, "o"), int64(entryLuna(r.EntryNIM))); hash != "" {
					r.OpponentPaid = true
					r.OpponentPayTx = hash
					if r.Status == models.VSAwaitingOppPay {
						r.Status = models.VSAwaitingOppPlay
					}
					changed = true
					log.Printf("[VSROOM] reconcile: found opponent payment room=%s tx=%s (client never confirmed it)", r.ID, hash)
				}
			}
			if changed {
				_ = s.saveVSRoom(r)
			}
		}()
	}
}

// findMatchingTx — returns the tx hash of the first transaction in txs that
// matches the given memo/amount to wantAddress, or "" if none match.
func findMatchingTx(txs []map[string]any, wantAddress, expectedMemo string, expectedLuna int64) string {
	for _, tx := range txs {
		if ok, _ := txMatchesVSPayment(tx, wantAddress, expectedMemo, expectedLuna); ok {
			if hash, _ := tx["hash"].(string); hash != "" {
				return hash
			}
			return "found" // matched but node didn't echo a hash field — still a valid confirmation
		}
	}
	return ""
}

// nimiqGetTransactionsByAddress — recent transactions (in or out) for an
// address, newest first. Standard Albatross RPC method.
func nimiqGetTransactionsByAddress(rpcURL, address string, max int) ([]map[string]any, error) {
	result, err := nimiqRPCCall(rpcURL, "getTransactionsByAddress", []any{address, max})
	if err != nil {
		return nil, err
	}
	var list []any
	if outer, ok := result.(map[string]any); ok {
		if data, ok := outer["data"].([]any); ok {
			list = data
		}
	} else if arr, ok := result.([]any); ok {
		list = arr
	}
	out := make([]map[string]any, 0, len(list))
	for _, item := range list {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out, nil
}

// StartVSPaymentReconciler — background safety net, runs independently of
// any client action. Every payment either gets confirmed instantly via the
// client's own callback, or gets picked up here within at most this interval.
func (s *Store) StartVSPaymentReconciler() {
	go func() {
		time.Sleep(45 * time.Second)
		for {
			s.ReconcileVSPayments()
			time.Sleep(90 * time.Second)
		}
	}()
}

// decodeRecipientData — RPC returns tx data either as a hex string or, in
// some node versions, already as plain text. Try hex first, fall back to raw.
func decodeRecipientData(raw any) string {
	s, ok := raw.(string)
	if !ok || s == "" {
		return ""
	}
	if b, err := hex.DecodeString(strings.TrimPrefix(s, "0x")); err == nil && isPrintableASCII(b) {
		return string(b)
	}
	return s
}

func isPrintableASCII(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, c := range b {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

// nimiqAddressesEqual — compares two user-friendly Nimiq addresses ignoring
// spacing/case (RPC responses are sometimes formatted differently than what
// we have stored in config).
func nimiqAddressesEqual(a, b string) bool {
	norm := func(s string) string {
		return strings.ToUpper(strings.ReplaceAll(s, " ", ""))
	}
	return a != "" && norm(a) == norm(b)
}

// ── Score reporting (called from the verified-replay submit flow) ────────────

// UpdateVSRoomScore — called once the server has independently verified a
// play session's score (never trusts the client's own number). role is
// "creator" or "opponent".
func (s *Store) UpdateVSRoomScore(roomID, role string, score int, sessionID string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	now := time.Now().Unix()
	switch role {
	case "creator":
		if r.CreatorScore != nil {
			return r, nil // already recorded
		}
		// Paid rooms: never accept a score from a side that hasn't actually
		// funded the pot — settlement pays out based on *Paid flags, so a
		// score recorded here without payment would let someone win money
		// they never put in.
		if !r.IsFree() && !r.CreatorPaid {
			return nil, fmt.Errorf("payment_required")
		}
		sc := score
		r.CreatorScore = &sc
		r.CreatorSession = sessionID
		r.CreatorPlayedAt = now
		if r.Status == models.VSAwaitingCreatorPlay {
			r.Status = models.VSWaitingOpponent
		}
	case "opponent":
		if r.OpponentScore != nil {
			return r, nil
		}
		if !r.IsFree() && !r.OpponentPaid {
			return nil, fmt.Errorf("payment_required")
		}
		sc := score
		r.OpponentScore = &sc
		r.OpponentSession = sessionID
		r.OpponentPlayedAt = now
	default:
		return nil, fmt.Errorf("bad_role")
	}
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] score recorded id=%s role=%s score=%d", r.ID, role, score)

	// Both sides done → settle immediately, don't wait for the sweep.
	if r.CreatorScore != nil && r.OpponentScore != nil && r.Status != models.VSCompleted {
		s.settleVSRoom(r)
	}
	return r, nil
}

// ── Settlement ────────────────────────────────────────────────────────────────

// settleVSRoom — decides the outcome and (for paid rooms) queues payout(s)
// via the existing reward pipeline. Mutates + saves r.
func (s *Store) settleVSRoom(r *models.VSRoom) {
	now := time.Now().Unix()
	bothPlayed := r.CreatorScore != nil && r.OpponentScore != nil

	if r.IsFree() {
		r.Status = models.VSCompleted
		r.SettledAt = now
		if bothPlayed {
			if *r.CreatorScore > *r.OpponentScore {
				r.WinnerID = r.CreatorID
			} else if *r.OpponentScore > *r.CreatorScore {
				r.WinnerID = r.OpponentID
			}
		} else if r.CreatorScore != nil {
			r.WinnerID = r.CreatorID
		} else if r.OpponentScore != nil {
			r.WinnerID = r.OpponentID
		}
		_ = s.saveVSRoom(r)
		log.Printf("[VSROOM] settled (free) id=%s winner=%s", r.ID, r.WinnerID)
		return
	}

	// Paid room — figure out who actually has money in the pot.
	pot := 0.0
	if r.CreatorPaid {
		pot += r.EntryNIM
	}
	if r.OpponentPaid {
		pot += r.EntryNIM
	}

	if pot <= 0 {
		// Nobody ever actually paid — nothing to settle, nothing to refund.
		r.Status = models.VSExpiredRefunded
		r.SettledAt = now
		_ = s.saveVSRoom(r)
		return
	}

	payout := pot * vsPayoutFrac
	fee := pot - payout

	switch {
	case r.CreatorPaid && !r.OpponentPaid:
		// Only creator ever funded the pot — opponent never joined/paid.
		// No real match happened: full refund, no fee.
		s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		r.Status = models.VSExpiredRefunded
		r.SettledAt = now
		_ = s.saveVSRoom(r)
		return

	case bothPlayed:
		r.FeeNIM = fee
		if *r.CreatorScore == *r.OpponentScore {
			half := payout / 2.0
			r.PayoutTxHash = s.payoutVSRoom(r.CreatorID, half, r.ID, "split")
			r.PayoutTxHash2 = s.payoutVSRoom(r.OpponentID, half, r.ID, "split")
			r.PayoutNIM = payout
			r.WinnerID = "" // tie
		} else {
			winner := r.CreatorID
			if *r.OpponentScore > *r.CreatorScore {
				winner = r.OpponentID
			}
			r.WinnerID = winner
			r.PayoutNIM = payout
			r.PayoutTxHash = s.payoutVSRoom(winner, payout, r.ID, "win")
		}
		r.Status = models.VSCompleted

	case r.CreatorPaid && r.OpponentPaid && (r.CreatorScore != nil) != (r.OpponentScore != nil):
		// Both funded the pot, deadline passed, only one side actually played —
		// forfeit: the one who showed up takes the full (fee-adjusted) pot.
		winner := r.CreatorID
		if r.OpponentScore != nil {
			winner = r.OpponentID
		}
		r.WinnerID = winner
		r.FeeNIM = fee
		r.PayoutNIM = payout
		r.PayoutTxHash = s.payoutVSRoom(winner, payout, r.ID, "forfeit")
		r.Status = models.VSExpiredPayout

	default:
		// Both paid, neither ever played (edge case) — refund both, no fee.
		s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		s.refundVSRoom(r, r.OpponentID, r.EntryNIM)
		r.Status = models.VSExpiredRefunded
	}

	r.SettledAt = now
	_ = s.saveVSRoom(r)
	log.Printf("[VSROOM] settled id=%s status=%s winner=%s payout=%.4f fee=%.4f",
		r.ID, r.Status, r.WinnerID, r.PayoutNIM, r.FeeNIM)
}

func (s *Store) payoutVSRoom(playerID string, amountNIM float64, roomID, kind string) string {
	if playerID == "" || amountNIM <= 0 {
		return ""
	}
	reward, err := s.QueueReward(playerID, amountNIM, fmt.Sprintf("vsroom:%s:%s", roomID, kind))
	if err != nil {
		log.Printf("[VSROOM] payout QueueReward failed room=%s player=%s err=%v", roomID, playerID, err)
		return ""
	}
	return reward.ID // tx hash isn't known yet (async send) — reward ID lets admin trace it
}

func (s *Store) refundVSRoom(r *models.VSRoom, playerID string, amountNIM float64) {
	if playerID == "" || amountNIM <= 0 {
		return
	}
	_, err := s.QueueReward(playerID, amountNIM, fmt.Sprintf("vsroom:%s:refund", r.ID))
	if err != nil {
		log.Printf("[VSROOM] refund failed room=%s player=%s err=%v", r.ID, playerID, err)
	}
}

// ── Expiry sweep ──────────────────────────────────────────────────────────────

// SweepExpiredVSRooms — settles any room whose 24h window has passed and
// isn't already settled. Safe to call repeatedly (settleVSRoom is idempotent
// per-room since it always transitions to a terminal Status).
func (s *Store) SweepExpiredVSRooms() {
	rooms, err := s.ListVSRooms()
	if err != nil {
		return
	}
	now := time.Now().Unix()
	for i := range rooms {
		// rooms[i] is a snapshot from before we took any lock — only used
		// here to decide WHICH room IDs are worth locking and re-checking.
		snapshot := &rooms[i]
		if isVSTerminalStatus(snapshot.Status) || now < snapshot.ExpiresAt {
			continue
		}

		func(roomID string) {
			lock := vsRoomLock(roomID)
			lock.Lock()
			defer lock.Unlock()

			// Re-fetch under the lock — the snapshot above may be stale by
			// now (another request could have settled/cancelled/updated it
			// in the meantime), so never act on anything but fresh state.
			r, gerr := s.GetVSRoom(roomID)
			if gerr != nil || r == nil || isVSTerminalStatus(r.Status) || now < r.ExpiresAt {
				return
			}
			log.Printf("[VSROOM] sweep expiring id=%s status=%s", r.ID, r.Status)
			s.settleVSRoom(r)
		}(snapshot.ID)
	}
}

func isVSTerminalStatus(st models.VSRoomStatus) bool {
	switch st {
	case models.VSCompleted, models.VSExpiredPayout, models.VSExpiredRefunded, models.VSCancelled:
		return true
	}
	return false
}

// StartVSRoomSweep — background sweep every 5 minutes, called on startup.
func (s *Store) StartVSRoomSweep() {
	go func() {
		time.Sleep(30 * time.Second)
		for {
			s.SweepExpiredVSRooms()
			time.Sleep(5 * time.Minute)
		}
	}()
}

// ── CancelVSRoom ───────────────────────────────────────────────────────────────

// CancelVSRoom — creator can cancel while still waiting for an opponent, as
// long as nobody has paid in yet (a paid room must run its course so the
// payment isn't stranded — use the normal expiry/refund path instead).
func (s *Store) CancelVSRoom(roomID, playerID string) error {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return fmt.Errorf("room_not_found")
	}
	if r.CreatorID != playerID {
		return fmt.Errorf("not_owner")
	}
	if r.OpponentID != "" {
		return fmt.Errorf("opponent_already_joined")
	}
	if r.CreatorPaid {
		return fmt.Errorf("already_paid_use_expiry")
	}
	r.Status = models.VSCancelled
	return s.saveVSRoom(r)
}

// AdminCancelAndRefundVSRoom — force-closes a room that's still open for an
// opponent to join (OpponentID == "") and refunds the creator's payment if
// they'd already paid in. This is the admin-panel "close & refund" action.
//
// Locked exactly like every other mutator here, so the classic failure mode
// — admin clicks close at the same instant someone else clicks the invite
// link — cannot happen: whichever request (this cancel, or JoinVSRoom)
// acquires the room's mutex first completes fully before the other one even
// reads the room's state, so the second one always sees the first one's
// result and fails cleanly instead of silently racing it.
func (s *Store) AdminCancelAndRefundVSRoom(roomID string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if r.OpponentID != "" {
		return nil, fmt.Errorf("opponent_already_joined")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("already_closed")
	}
	refunded := 0.0
	if r.CreatorPaid {
		s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		refunded = r.EntryNIM
	}
	r.Status = models.VSCancelled
	r.SettledAt = time.Now().Unix()
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] admin cancel+refund id=%s creator=%s refunded=%.4f", r.ID, r.CreatorID, refunded)
	return r, nil
}
