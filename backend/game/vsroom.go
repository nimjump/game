package game

import (
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"sort"
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
	// vsOpponentPayWindow — how long an opponent's slot reservation is held
	// while they pay. Paying IS joining: an opponent who reserves the slot but
	// doesn't pay within this window is treated as never having joined — the
	// reservation is released and the room reopens for anyone else (see the
	// reservation sweep in SweepExpiredVSRooms). Kept short so an abandoned
	// "join" frees the room quickly instead of stranding the creator. The
	// reconciler runs before this sweep, so a player who genuinely DID pay is
	// always credited first and never wrongly bumped.
	vsOpponentPayWindow = 10 * time.Minute
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

// vsRoomRandID generates a room ID. This ID doubles as a de-facto bearer
// token: the unauthenticated GET /backend/vsroom/{id} route (needed so a
// shared invite link works before the recipient has signed in) trusts
// "knows the ID" as "was actually given the invite link". math/rand is
// predictable (seeded, reproducible) and unsuitable for anything acting as
// a secret — crypto/rand is required here. (The per-run game *seed* stored
// on the room is a different thing and stays math/rand — it only needs to
// be unpredictable pre-match, not cryptographically secure, and always
// requires knowing/holding a valid room ID to ever read in the first
// place.)
func vsRoomRandID(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	buf := make([]byte, n)
	if _, err := crand.Read(buf); err != nil {
		// crypto/rand failing means the OS entropy source is broken — extremely
		// unlikely, but fall back rather than panic so room creation still works.
		log.Printf("[VSROOM] crypto/rand read failed, falling back to math/rand: %v", err)
		for i := range buf {
			buf[i] = byte(rand.Intn(256))
		}
	}
	b := make([]byte, n)
	for i, v := range buf {
		b[i] = chars[int(v)%len(chars)]
	}
	return string(b)
}

// randNumericCode — a width-digit numeric string (crypto/rand). Includes
// leading zeros, e.g. width 4 => "0000".."9999".
func randNumericCode(width int) string {
	buf := make([]byte, width)
	if _, err := crand.Read(buf); err != nil {
		for i := range buf {
			buf[i] = byte(rand.Intn(256))
		}
	}
	b := make([]byte, width)
	for i, v := range buf {
		b[i] = '0' + byte(int(v)%10)
	}
	return string(b)
}

// vsRoomUniqueID — the long internal room key, GUARANTEED unique: it's a
// 36^12 (~4.7e18) random string AND collision-checked against every existing
// room, so no two rooms can ever share an internal ID. (Unlike the short
// public code, this is never recycled — a finished room keeps its ID forever
// so old payment memos / records never point at a different room.)
func (s *Store) vsRoomUniqueID() string {
	for i := 0; i < 50; i++ {
		id := vsRoomRandID(12)
		if existing, _ := s.GetVSRoom(id); existing == nil {
			return id
		}
		log.Printf("[VSROOM] internal-id collision (astronomically unlikely) — retrying")
	}
	// 50 straight collisions on a 4.7e18 space is effectively impossible unless
	// something is badly wrong — widen so a repeat is truly unreachable.
	return vsRoomRandID(20)
}

// vsRoomShortCode — a short, purely-numeric PUBLIC code (see VSRoom.ShortCode):
// unique only among currently-ACTIVE rooms, recycled once a room finishes (a
// terminal or past-expiry room's code is free to reuse). Width by visibility:
//   - PUBLIC rooms: 4 digits (10,000 live codes). Public rooms are already
//     listed in the browse list, so a guessable public code leaks nothing —
//     short, shareable codes are the whole point. Widens to 5+ only if 10k
//     rooms are somehow live at once.
//   - PRIVATE rooms: 8 digits (100,000,000). A private room's only protection
//     is that its code is hard to guess, so it gets a far bigger space; with
//     the per-IP rate limiter, scanning it is impractical.
// The long unguessable ID (vsRoomRandID) stays the real key for storage,
// payment memo and every internal op — this is only the friendly alias.
func (s *Store) vsRoomShortCode(private bool) string {
	startWidth := 4
	if private {
		startWidth = 8
	}
	// Codes of finished rooms are free to recycle — only ACTIVE rooms reserve
	// one. Build the in-use set once.
	inUse := map[string]bool{}
	if all, err := s.ListVSRooms(); err == nil {
		now := time.Now().Unix()
		for _, r := range all {
			if r.ShortCode == "" || isVSTerminalStatus(r.Status) {
				continue
			}
			if r.ExpiresAt > 0 && now >= r.ExpiresAt {
				continue // past its deadline — treat as free to recycle
			}
			inUse[r.ShortCode] = true
		}
	}
	for width := startWidth; width <= startWidth+5; width++ {
		for i := 0; i < 40; i++ {
			code := randNumericCode(width)
			if !inUse[code] {
				return code
			}
		}
		log.Printf("[VSROOM] short-code width=%d looks saturated, widening", width)
	}
	// Astronomically unlikely fallback.
	return randNumericCode(startWidth + 6)
}

// GetVSRoomByShortCode resolves a public ShortCode (see VSRoom.ShortCode) back
// to its room. Only ACTIVE rooms are considered (a recycled code's old,
// finished room must never shadow the live one); the most recently created
// match wins if two somehow share a code across the active/terminal boundary.
func (s *Store) GetVSRoomByShortCode(code string) (*models.VSRoom, error) {
	if code == "" {
		return nil, fmt.Errorf("room_not_found")
	}
	all, err := s.ListVSRooms()
	if err != nil {
		return nil, err
	}
	var best *models.VSRoom
	for i := range all {
		r := &all[i]
		if r.ShortCode != code || isVSTerminalStatus(r.Status) {
			continue
		}
		if best == nil || r.CreatedAt > best.CreatedAt {
			best = r
		}
	}
	if best == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	return best, nil
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

// StripVSSeed returns a copy of r with the game Seed cleared unless viewerID
// is allowed to see it (see canSeeVSSeed). Both sides play the exact same
// fixed seed asynchronously, so leaking it early would let someone scout the
// level's platform/enemy layout ahead of their own attempt. Call this on
// every room (or list of rooms) returned by an endpoint that isn't
// exclusively gated to that room's own participants (admin routes, which
// are already behind requireAdminSession, are exempt).
func StripVSSeed(r models.VSRoom, viewerID string) models.VSRoom {
	if !canSeeVSSeed(&r, viewerID) {
		r.Seed = ""
	}
	return r
}

// canSeeVSSeed — a participant may see the room's seed ONLY once the match is
// FULLY committed: the opponent has joined AND (for paid rooms) both sides
// have paid. Before that, neither the creator nor the opponent can see it.
// This is what makes "you can't scout the level before your opponent is in"
// airtight, and it exactly matches when play becomes possible (see
// UpdateVSRoomScore's readiness gate) — so it never blocks legitimate play,
// which only ever starts after both sides are locked in. It also closes the
// old free seed-grinding exploit (create -> peek-seed -> cancel -> repeat):
// the seed simply isn't in any response until a real, committed opponent
// exists, by which point neither side can back out.
func canSeeVSSeed(r *models.VSRoom, viewerID string) bool {
	if viewerID != r.CreatorID && viewerID != r.OpponentID {
		return false
	}
	if r.OpponentID == "" {
		return false // no opponent locked in yet — nobody sees the seed
	}
	if r.IsFree() {
		return true // both present, no fee to commit
	}
	return r.CreatorPaid && r.OpponentPaid
}

// PaginateVSRooms slices an already-filtered/sorted room list into a page,
// returning the page plus the pre-pagination total count (so a caller can
// show "X of Y" or decide whether to offer a "load more" control). limit<=0
// means "no limit" (return everything from offset onward).
func PaginateVSRooms(all []models.VSRoom, limit, offset int) ([]models.VSRoom, int) {
	total := len(all)
	if offset < 0 {
		offset = 0
	}
	if offset >= total {
		return []models.VSRoom{}, total
	}
	end := total
	if limit > 0 && offset+limit < total {
		end = offset + limit
	}
	return all[offset:end], total
}

// ListVSRoomsByPlayer — rooms where playerID is creator or opponent, newest
// first, paginated. Returns the page plus the total matching-room count.
func (s *Store) ListVSRoomsByPlayer(playerID string, limit, offset int) ([]models.VSRoom, int, error) {
	all, err := s.ListVSRooms()
	if err != nil {
		return nil, 0, err
	}
	var filtered []models.VSRoom
	for _, r := range all {
		if r.CreatorID != playerID && r.OpponentID != playerID {
			continue
		}
		// Paying IS creating: a paid room whose creator hasn't paid yet doesn't
		// really exist — hide it even from the creator's own "My Matches" (it's
		// not open, not joinable, nobody sees it) until the entry payment lands.
		// The creator is dropped straight into the pay flow at create time, and
		// an abandoned unpaid room is cleaned up by the sweep.
		if r.CreatorID == playerID && !r.IsFree() && !r.CreatorPaid && r.OpponentID == "" {
			continue
		}
		filtered = append(filtered, r)
	}
	// Ordering for the "My Matches" tab: live matches where the opponent has
	// ALREADY joined float to the very top (these need attention — you may have
	// created a room, not played yet, and someone's now waiting on you), then
	// rooms still open for an opponent to join, then finished/expired/cancelled
	// ones at the bottom. Sorting happens BEFORE pagination so the order is
	// global across pages, not just within one page.
	isTerminal := func(st models.VSRoomStatus) bool {
		switch st {
		case models.VSCompleted, models.VSExpiredPayout, models.VSExpiredRefunded, models.VSCancelled:
			return true
		}
		return false
	}
	priority := func(r models.VSRoom) int {
		if isTerminal(r.Status) {
			return 2 // done — bottom
		}
		if r.OpponentID != "" {
			return 0 // opponent locked in — live match, top
		}
		return 1 // still waiting for someone to join
	}
	sort.Slice(filtered, func(i, j int) bool {
		pi, pj := priority(filtered[i]), priority(filtered[j])
		if pi != pj {
			return pi < pj
		}
		return filtered[i].CreatedAt > filtered[j].CreatedAt // newer first within a tier
	})
	page, total := PaginateVSRooms(filtered, limit, offset)
	return page, total, nil
}

// CountVSRoomsNeedingAction — how many of this player's rooms are waiting on
// THEM right now: the opponent has already joined, the match isn't finished,
// and this player hasn't locked in their own score yet (whether they still
// owe the entry payment or just need to play their round). This is exactly
// the "it's your turn" set — it drives the red badge on the VS tab. Rooms
// with no opponent yet don't count (nothing can be played until someone
// joins), and finished/expired/cancelled rooms don't count either.
func (s *Store) CountVSRoomsNeedingAction(playerID string) (int, error) {
	if playerID == "" {
		return 0, nil
	}
	all, err := s.ListVSRooms()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, r := range all {
		if r.CreatorID != playerID && r.OpponentID != playerID {
			continue
		}
		if r.OpponentID == "" {
			continue // no opponent yet — nothing to play
		}
		switch r.Status {
		case models.VSCompleted, models.VSExpiredPayout, models.VSExpiredRefunded, models.VSCancelled, models.VSManualReview:
			continue // already settled
		}
		var myScore *int
		if r.CreatorID == playerID {
			myScore = r.CreatorScore
		} else {
			myScore = r.OpponentScore
		}
		if myScore == nil {
			n++
		}
	}
	return n, nil
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
	// Highest entry fee (biggest pot) first — the browse list leads with the
	// juiciest challenges. Newer rooms break ties so equal-stake rooms don't
	// freeze in a stale order.
	sort.Slice(out, func(i, j int) bool {
		if out[i].EntryNIM != out[j].EntryNIM {
			return out[i].EntryNIM > out[j].EntryNIM
		}
		return out[i].CreatedAt > out[j].CreatedAt
	})
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
	// NEW FLOW ("nobody plays until the opponent has joined"): a free room goes
	// straight to waiting_opponent — the creator does NOT play first anymore.
	// A paid room still needs the creator's payment before it opens (that pay
	// step also gates the seed reveal). Both sides only play once BOTH are in
	// (see ConfirmVSRoomPayment + UpdateVSRoomScore's readiness gate).
	status := models.VSWaitingOpponent
	if entryNIM > 0 {
		status = models.VSAwaitingCreatorPay
	}
	r := &models.VSRoom{
		// Long unguessable internal key (storage, payment memo, all internal
		// ops), collision-checked so it's GUARANTEED unique. The short friendly
		// ?vs= code is a SEPARATE public alias below.
		ID:              s.vsRoomUniqueID(),
		ShortCode:       s.vsRoomShortCode(isPrivate),
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
		now := time.Now().Unix()
		if r.IsFree() {
			// Free room: nothing to pay, so joining commits immediately.
			r.OpponentID = playerID
			r.OpponentNickname = nickname
			r.Status = models.VSAwaitingOppPlay
			r.ExpiresAt = time.Now().Add(vsRoomPlayWindow).Unix()
			if err := s.saveVSRoom(r); err != nil {
				return nil, err
			}
			log.Printf("[VSROOM] joined (free) id=%s opponent=%s", r.ID, playerID)
			SafeGo("sendVSJoinPing", func() { s.sendVSJoinPing(r.CreatorID, r.ID) })
			SafeGo("sendVSJoinPing", func() { s.sendVSJoinPing(playerID, r.ID) })
			return r, nil
		}
		// PAID room: paying IS joining. Do NOT commit the opponent slot here —
		// only reserve this player as the pending payer (used by the reconciler
		// and to show them their own Pay button). OpponentID stays empty and the
		// room stays "waiting_opponent" for everyone until the payment confirms
		// (see ConfirmVSRoomPayment). Concurrent joiners are allowed; whoever
		// pays first wins the slot and any later payer is auto-refunded.
		r.PendingOpponentID = playerID
		r.PendingOpponentNickname = nickname
		r.PendingOpponentSince = now
		if err := s.saveVSRoom(r); err != nil {
			return nil, err
		}
		log.Printf("[VSROOM] opponent pending (unpaid, reserved to pay) id=%s player=%s", r.ID, playerID)
	}
	return r, nil
}

// sendVSJoinPing sends a player the smallest possible NIM amount the moment
// their room actually gets a real opponent (both the creator AND the
// opponent get one) — the only practical way this WebView mini-app has to
// reach a player who's since closed the tab and isn't actively polling the
// room. It rides on Nimiq Pay's own built-in "payment received" notification
// (there is no other push channel available here); the memo carries the
// actual message (see buildMemo's "notify_join" case) — the amount itself is
// irrelevant, which is why it's kept at the true minimum (vsNotifyPingNIM).
// Uses the exact same reward queue/retry machinery as every other payout, so
// it's visible in the same admin panel queue and costs nothing extra to
// operate — it's just another QueueReward call with a near-zero amount.
func (s *Store) sendVSJoinPing(playerID, roomID string) {
	if _, err := s.QueueRewardRaw(playerID, vsNotifyPingNIM, fmt.Sprintf("vsroom:%s:notify_join", roomID)); err != nil {
		log.Printf("[VSROOM] join-ping failed room=%s player=%s err=%v (non-fatal, purely cosmetic)", roomID, playerID, err)
	}
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

	// role: creator, or (everyone else) the opponent side. The opponent slot is
	// claimed BY the act of paying — playerID need not already be OpponentID.
	role := "o"
	if playerID == r.CreatorID {
		role = "c"
		if r.CreatorPaid {
			return r, nil // already confirmed
		}
	} else {
		if r.OpponentID == playerID && r.OpponentPaid {
			return r, nil // this player already holds the paid slot
		}
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
		// Creator paying OPENS the room for an opponent — it does not let the
		// creator play yet. Both play only once the opponent has also paid.
		r.Status = models.VSWaitingOpponent
		if err := s.saveVSRoom(r); err != nil {
			return nil, err
		}
	} else {
		// Opponent side. Paying IS joining, so the payment is what claims the
		// slot. If someone ELSE already paid and grabbed it first, this payer
		// lost the race — their (verified, real) payment is immediately refunded
		// and they're told the slot is taken. Otherwise this payment claims it.
		if r.OpponentID != "" && r.OpponentID != playerID {
			log.Printf("[VSROOM] opponent slot already taken id=%s by=%s — refunding late payer=%s tx=%s",
				r.ID, r.OpponentID, playerID, txHash)
			s.refundVSRoom(r, playerID, r.EntryNIM)
			return nil, fmt.Errorf("slot_taken_refunded")
		}
		nickname := r.PendingOpponentNickname
		if r.PendingOpponentID != playerID || nickname == "" {
			if pn, gerr := s.GetNickname(playerID); gerr == nil && pn != nil && pn.Nickname != "" {
				nickname = pn.Nickname
			} else {
				nickname = "Player"
			}
		}
		r.OpponentID = playerID
		r.OpponentNickname = nickname
		r.OpponentPaid = true
		r.OpponentPayTx = txHash
		r.PendingOpponentID = ""
		r.PendingOpponentNickname = ""
		r.PendingOpponentSince = 0
		// Both sides funded now → match is live, both can play (any order).
		r.Status = models.VSAwaitingOppPlay
		// The play window starts when the opponent actually commits (pays).
		r.ExpiresAt = time.Now().Add(vsRoomPlayWindow).Unix()
		if err := s.saveVSRoom(r); err != nil {
			return nil, err
		}
		// Now that a real opponent is locked in, ping both sides (see JoinVSRoom
		// for why this moved here from join — join no longer commits anyone).
		SafeGo("sendVSJoinPing", func() { s.sendVSJoinPing(r.CreatorID, r.ID) })
		SafeGo("sendVSJoinPing", func() { s.sendVSJoinPing(playerID, r.ID) })
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
		// Every non-terminal paid room is scanned — not only ones still missing a
		// payment. A fully-paid room still needs a pass so a DUPLICATE entry (slow
		// wallet re-send) landing after it was paid gets refunded, not pocketed.
		pending = append(pending, r)
	}
	if len(pending) == 0 {
		return
	}

	// Scan a generous window of recent incoming txs. 500 (vs. a tighter 200)
	// gives headroom so that even after a lengthy server outage — during which
	// many unrelated payments could have landed — an unconfirmed VS payment is
	// still within the fetched history when we come back up and reconcile.
	txs, err := nimiqGetTransactionsByAddress(cfg.RPCURL, cfg.WalletAddress, 500)
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
			// Opponent side. In the pay-to-join model the slot is empty until a
			// payment claims it, so recovery here means: a pending payer's entry
			// tx is on-chain but their confirm call was lost — commit them as the
			// opponent now. (If the slot is already filled, nothing to do; a
			// losing racer's refund is handled at confirm time.)
			if r.OpponentID == "" && r.PendingOpponentID != "" && !r.OpponentPaid {
				if hash := findMatchingTx(txs, cfg.WalletAddress, vsRoomMemo(r.ID, "o"), int64(entryLuna(r.EntryNIM))); hash != "" {
					nickname := r.PendingOpponentNickname
					if nickname == "" {
						if pn, gerr := s.GetNickname(r.PendingOpponentID); gerr == nil && pn != nil && pn.Nickname != "" {
							nickname = pn.Nickname
						} else {
							nickname = "Player"
						}
					}
					r.OpponentID = r.PendingOpponentID
					r.OpponentNickname = nickname
					r.OpponentPaid = true
					r.OpponentPayTx = hash
					r.PendingOpponentID = ""
					r.PendingOpponentNickname = ""
					r.PendingOpponentSince = 0
					r.Status = models.VSAwaitingOppPlay
					r.ExpiresAt = time.Now().Add(vsRoomPlayWindow).Unix()
					changed = true
					log.Printf("[VSROOM] reconcile: committed pending opponent room=%s player=%s tx=%s (confirm was lost)", r.ID, r.OpponentID, hash)
				}
			}
			// Refund any DUPLICATE entry payments (same memo, extra tx) for either
			// paid side back to whoever sent them — the "player double-paid because
			// the wallet was slow" case. Idempotent (RefundedDupTxs).
			if r.CreatorPaid {
				if s.refundDuplicateVSSide(r, txs, cfg.WalletAddress, "c", r.CreatorPayTx) {
					changed = true
				}
			}
			if r.OpponentPaid {
				if s.refundDuplicateVSSide(r, txs, cfg.WalletAddress, "o", r.OpponentPayTx) {
					changed = true
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

// findAllMatchingVSTxs — every transaction matching the given memo/amount to
// wantAddress (not just the first). Used to spot DUPLICATE entry payments for a
// side that is already paid, so the extras can be refunded.
func findAllMatchingVSTxs(txs []map[string]any, wantAddress, expectedMemo string, expectedLuna int64) []map[string]any {
	var out []map[string]any
	for _, tx := range txs {
		if ok, _ := txMatchesVSPayment(tx, wantAddress, expectedMemo, expectedLuna); ok {
			out = append(out, tx)
		}
	}
	return out
}

func sliceContainsStr(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

// refundDuplicateVSSide — for one already-paid side (role "c"/"o" with its
// committed entry tx keptHash), refunds every OTHER on-chain tx carrying the
// same room+role memo back to whoever sent it. This is what makes double-paying
// safe: a slow wallet / Nimiq-Pay delay that makes a player re-send their entry
// leaves the room keeping exactly one payment and the extra returned to them.
// Idempotent via r.RefundedDupTxs. Returns true if it changed r. MUST be called
// under the room lock; caller saves r.
func (s *Store) refundDuplicateVSSide(r *models.VSRoom, txs []map[string]any, wantAddress, role, keptHash string) bool {
	// Can't safely tell the kept entry apart from a duplicate unless we have a
	// real, specific hash for it — skip (never risk refunding the real entry).
	if keptHash == "" || keptHash == "found" {
		return false
	}
	memo := vsRoomMemo(r.ID, role)
	expectedLuna := int64(entryLuna(r.EntryNIM))
	changed := false
	for _, tx := range findAllMatchingVSTxs(txs, wantAddress, memo, expectedLuna) {
		hash, _ := tx["hash"].(string)
		if hash == "" || hash == keptHash {
			continue // no hash, or this IS the committed entry — keep it
		}
		if sliceContainsStr(r.RefundedDupTxs, hash) {
			continue // already refunded this duplicate on an earlier pass
		}
		sender, _ := tx["from"].(string)
		if sender == "" {
			continue // can't refund what we can't attribute
		}
		s.refundVSRoom(r, sender, r.EntryNIM)
		r.RefundedDupTxs = append(r.RefundedDupTxs, hash)
		changed = true
		log.Printf("[VSROOM] duplicate %s payment refunded room=%s to=%s tx=%s", role, r.ID, sender, hash)
	}
	return changed
}

// nimiqGetTransactionsByAddress — recent transactions (in or out) for an
// address, newest first. Standard Albatross RPC method.
func nimiqGetTransactionsByAddress(rpcURL, address string, max int) ([]map[string]any, error) {
	// Albatross' get_transactions_by_address takes THREE positional params:
	// (address, max, start_at). The third — start_at, an optional tx hash to
	// page from — is nullable but still POSITIONALLY REQUIRED: sending only
	// [address, max] fails with rpc_err -32602 "invalid length 2, expected
	// struct ... with 3 elements" (exactly the reconciler spam this fixes).
	// nil == null == "start from the newest transaction".
	result, err := nimiqRPCCall(rpcURL, "getTransactionsByAddress", []any{address, max, nil})
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
		// Short boot delay (just enough for networking/RPC to be reachable),
		// then a first pass immediately — so any payment that landed while we
		// were DOWN gets credited within seconds of coming back up, not after a
		// full cycle. Then settle into the steady 90s cadence.
		time.Sleep(10 * time.Second)
		for {
			SafeCall("ReconcileVSPayments", s.ReconcileVSPayments)
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
	// NEW FLOW readiness gate: NOBODY may play until the opponent has joined
	// AND (for paid rooms) BOTH sides have paid. This is what enforces "you
	// can't play before your opponent is in" server-side — the creator can no
	// longer lock in an early score alone, which also means no seed-scouting
	// advantage. Applies symmetrically to both roles.
	if r.OpponentID == "" {
		return nil, fmt.Errorf("opponent_not_joined")
	}
	if !r.IsFree() && (!r.CreatorPaid || !r.OpponentPaid) {
		return nil, fmt.Errorf("both_must_pay_first")
	}
	switch role {
	case "creator":
		if r.CreatorScore != nil {
			return r, nil // already recorded
		}
		sc := score
		r.CreatorScore = &sc
		r.CreatorSession = sessionID
		r.CreatorPlayedAt = now
	case "opponent":
		if r.OpponentScore != nil {
			return r, nil
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

// MarkVSRoomPlayed records that a side has SUBMITTED its run (played) the moment
// the submission arrives — independent of the async replay simulation that only
// verifies + records the actual score later. Without this, a room whose replay
// is still being simulated (or one flagged into manual review, where the score
// is never recorded at all) keeps showing the player a "Play" button because
// CreatorScore/OpponentScore is still nil — letting them replay the same match.
// Sets ONLY the played-at timestamp (+ session id); never touches scores or
// triggers settlement. Idempotent.
func (s *Store) MarkVSRoomPlayed(roomID, role, sessionID string) {
	if roomID == "" {
		return
	}
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()
	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return
	}
	switch role {
	case "creator":
		if r.CreatorPlayedAt > 0 || r.CreatorScore != nil {
			return
		}
		r.CreatorPlayedAt = time.Now().Unix()
		if r.CreatorSession == "" {
			r.CreatorSession = sessionID
		}
	case "opponent":
		if r.OpponentPlayedAt > 0 || r.OpponentScore != nil {
			return
		}
		r.OpponentPlayedAt = time.Now().Unix()
		if r.OpponentSession == "" {
			r.OpponentSession = sessionID
		}
	default:
		return
	}
	_ = s.saveVSRoom(r)
	log.Printf("[VSROOM] marked played id=%s role=%s session=%s", r.ID, role, sessionID)
}

// ClaimVSRoomPlay atomically claims a participant's SINGLE play attempt at the
// START of their run — the network-safe lock that makes replaying a VS match
// impossible. It marks the caller's side as played RIGHT NOW (before they
// actually play), so that even if their later score submission never reaches the
// server (connection dropped mid-submit, app killed, tab closed…) the match can
// NEVER offer them a fresh attempt: the played lock was already committed here,
// under the room lock, before the round even began. A second claim for a side
// that has already played (or already scored) is refused with "already_played".
// Enforces the same readiness gate as scoring. Returns the room (seed included
// for this participant) so the client starts the round from the authoritative
// server seed, not a locally-held one.
func (s *Store) ClaimVSRoomPlay(roomID, playerID string) (*models.VSRoom, error) {
	if roomID == "" || playerID == "" {
		return nil, fmt.Errorf("bad_request")
	}
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()
	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("match_over")
	}
	var role string
	switch playerID {
	case r.CreatorID:
		role = "creator"
	case r.OpponentID:
		role = "opponent"
	default:
		return nil, fmt.Errorf("not_a_participant")
	}
	// Same readiness gate as UpdateVSRoomScore: nobody plays before the opponent
	// has joined AND (paid rooms) both sides have paid.
	if r.OpponentID == "" {
		return nil, fmt.Errorf("opponent_not_joined")
	}
	if !r.IsFree() && (!r.CreatorPaid || !r.OpponentPaid) {
		return nil, fmt.Errorf("both_must_pay_first")
	}
	now := time.Now().Unix()
	switch role {
	case "creator":
		if r.CreatorPlayedAt > 0 || r.CreatorScore != nil {
			return nil, fmt.Errorf("already_played")
		}
		r.CreatorPlayedAt = now
	case "opponent":
		if r.OpponentPlayedAt > 0 || r.OpponentScore != nil {
			return nil, fmt.Errorf("already_played")
		}
		r.OpponentPlayedAt = now
	}
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] play claimed id=%s role=%s player=%s", r.ID, role, playerID)
	return r, nil
}

// ── Settlement ────────────────────────────────────────────────────────────────

// VSFeeFraction — the winner's share of the pot (0..1), i.e. 1 minus the
// admin-configured system fee percent. Defaults to vsPayoutFrac (5% fee → 0.95)
// when unset. Clamped so a bad/out-of-range value can never pay out more than
// the pot or go negative.
func (s *Store) VSFeeFraction() float64 {
	pct := s.GetAppConfig().VSFeePercent
	if pct == nil {
		return vsPayoutFrac
	}
	p := *pct
	if p < 0 {
		p = 0
	}
	if p > 100 {
		p = 100
	}
	return 1.0 - p/100.0
}

// FlagVSRoomForReview — mark a room as needing manual admin review because one
// side's play was flagged (possible cheat) or its replay failed to re-simulate.
// Once set, the room can never auto-settle/pay out (see settleVSRoom's guard).
// Safe to call more than once; a room already reviewed/terminal is left alone.
func (s *Store) FlagVSRoomForReview(roomID, role, reason string) {
	if roomID == "" {
		return
	}
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()
	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil || isVSTerminalStatus(r.Status) {
		return
	}
	if r.NeedsReview {
		return
	}
	r.NeedsReview = true
	r.ReviewReason = fmt.Sprintf("%s: %s", role, reason)
	// Park it in the held state right away so it stops looking "live" (no play
	// prompts) and the sweep won't try to auto-settle it. Money never moves.
	r.Status = models.VSManualReview
	_ = s.saveVSRoom(r)
	log.Printf("[VSROOM] flagged for manual review id=%s reason=%q", r.ID, r.ReviewReason)
}

// settleVSRoom — decides the outcome and (for paid rooms) queues payout(s)
// via the existing reward pipeline. Mutates + saves r.
func (s *Store) settleVSRoom(r *models.VSRoom) {
	now := time.Now().Unix()

	// HARD STOP: if either side was flagged / failed replay verification, this
	// match must NOT auto-settle or pay anyone out — hold it for an admin to
	// investigate (declare a winner or refund both). No money moves here.
	if r.NeedsReview {
		if r.Status != models.VSManualReview {
			r.Status = models.VSManualReview
			_ = s.saveVSRoom(r)
			log.Printf("[VSROOM] settle held for MANUAL REVIEW id=%s reason=%q — no auto-payout", r.ID, r.ReviewReason)
		}
		return
	}

	bothPlayed := r.CreatorScore != nil && r.OpponentScore != nil

	// FAIRNESS HOLD: a side that CLAIMED its attempt (PlayedAt>0) but has no
	// recorded score started a run whose result never made it back — a dropped
	// score-submit, a crash mid-run, or a replay that failed/never verified. That
	// must NEVER auto-forfeit against them (the other side can't win a pot off a
	// run we simply failed to receive). Hold the whole match for an admin to sort
	// out (let them resubmit, replay, or refund both). A side that never even
	// claimed (PlayedAt==0) is a genuine no-show and still forfeits normally.
	if !bothPlayed {
		creatorStartedNoScore := r.CreatorPlayedAt > 0 && r.CreatorScore == nil
		opponentStartedNoScore := r.OpponentPlayedAt > 0 && r.OpponentScore == nil
		if creatorStartedNoScore || opponentStartedNoScore {
			r.NeedsReview = true
			if r.ReviewReason == "" {
				r.ReviewReason = "played_no_score: a side started a run whose result never arrived"
			}
			if r.Status != models.VSManualReview {
				r.Status = models.VSManualReview
				_ = s.saveVSRoom(r)
				log.Printf("[VSROOM] settle held for MANUAL REVIEW id=%s — claimed-but-no-score", r.ID)
			}
			return
		}
	}

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

	payout := pot * s.VSFeeFraction()
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
	_, err := s.QueueRewardRaw(playerID, amountNIM, fmt.Sprintf("vsroom:%s:refund", r.ID))
	if err != nil {
		log.Printf("[VSROOM] refund failed room=%s player=%s err=%v", r.ID, playerID, err)
	}
}

// ── Expiry sweep ──────────────────────────────────────────────────────────────

// SweepExpiredVSRooms — settles any room whose 24h window has passed and
// isn't already settled. Safe to call repeatedly (settleVSRoom is idempotent
// per-room since it always transitions to a terminal Status).
func (s *Store) SweepExpiredVSRooms() {
	// SAFETY (payments must never be lost, even across a server crash): credit
	// any on-chain payment that the client never confirmed BEFORE we settle
	// anything. Otherwise a room that was genuinely paid — but whose confirm
	// call was lost / happened while we were down — could be swept as
	// "nobody paid → expired" and the player's real money would be orphaned.
	// Reconciling first means a settling room always sees the true paid state,
	// so the payer is correctly refunded (or the match settled) instead. The
	// reconciler reads the chain directly (source of truth), independent of any
	// client callback, and each takes/releases its per-room lock individually,
	// so this can't deadlock with the sweep loop below.
	s.ReconcileVSPayments()

	rooms, err := s.ListVSRooms()
	if err != nil {
		return
	}
	now := time.Now().Unix()
	payWindowSecs := int64(vsOpponentPayWindow.Seconds())
	for i := range rooms {
		// rooms[i] is a snapshot from before we took any lock — only used
		// here to decide WHICH room IDs are worth locking and re-checking.
		snapshot := &rooms[i]
		if isVSTerminalStatus(snapshot.Status) {
			continue
		}
		// Held for manual review → never auto-settle; leave it for the admin.
		if snapshot.Status == models.VSManualReview || snapshot.NeedsReview {
			continue
		}

		// Pending-reservation release (paying IS joining): a would-be opponent
		// who tapped Accept but never paid within vsOpponentPayWindow is dropped —
		// their pending reservation is cleared so the reconciler/next joiner isn't
		// held to a stale payer. The slot itself was never taken (OpponentID stays
		// empty), so the room was open the whole time anyway. ReconcileVSPayments
		// ran above, so a pending payer who actually DID pay is already committed
		// (OpponentID set) and skipped here.
		if snapshot.OpponentID == "" && snapshot.PendingOpponentID != "" &&
			!snapshot.OpponentPaid && snapshot.PendingOpponentSince > 0 &&
			now-snapshot.PendingOpponentSince > payWindowSecs {
			func(roomID string) {
				lock := vsRoomLock(roomID)
				lock.Lock()
				defer lock.Unlock()
				r, gerr := s.GetVSRoom(roomID)
				if gerr != nil || r == nil {
					return
				}
				// Re-verify under the lock — reconcile/confirm may have committed
				// this player in the meantime, in which case leave it alone.
				if r.OpponentID != "" || r.PendingOpponentID == "" || r.OpponentPaid ||
					r.PendingOpponentSince == 0 || now-r.PendingOpponentSince <= payWindowSecs {
					return
				}
				log.Printf("[VSROOM] dropping stale unpaid pending opponent id=%s player=%s (%ds unpaid)",
					r.ID, r.PendingOpponentID, now-r.PendingOpponentSince)
				r.PendingOpponentID = ""
				r.PendingOpponentNickname = ""
				r.PendingOpponentSince = 0
				_ = s.saveVSRoom(r)
			}(snapshot.ID)
			// Don't `continue` — the room may ALSO be past ExpiresAt and need
			// settling; fall through to the expiry check below.
		}

		// Abandoned unpaid CREATOR room (paying IS creating): a paid room whose
		// creator never paid within the pay window doesn't really exist — cancel
		// it so it can't linger. ReconcileVSPayments ran above, so a creator who
		// genuinely paid (but whose confirm was lost) is already marked paid and
		// skipped here. No refund needed — by definition nobody paid in.
		if snapshot.Status == models.VSAwaitingCreatorPay && !snapshot.CreatorPaid &&
			snapshot.OpponentID == "" && snapshot.PendingOpponentID == "" &&
			now-snapshot.CreatedAt > payWindowSecs {
			func(roomID string) {
				lock := vsRoomLock(roomID)
				lock.Lock()
				defer lock.Unlock()
				r, gerr := s.GetVSRoom(roomID)
				if gerr != nil || r == nil {
					return
				}
				if r.Status != models.VSAwaitingCreatorPay || r.CreatorPaid ||
					r.OpponentID != "" || r.PendingOpponentID != "" ||
					now-r.CreatedAt <= payWindowSecs {
					return
				}
				log.Printf("[VSROOM] cancelling abandoned unpaid creator room id=%s (%ds unpaid)", r.ID, now-r.CreatedAt)
				r.Status = models.VSCancelled
				r.SettledAt = now
				_ = s.saveVSRoom(r)
			}(snapshot.ID)
			continue
		}

		if now < snapshot.ExpiresAt {
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
			SafeCall("SweepExpiredVSRooms", s.SweepExpiredVSRooms)
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
	if isVSTerminalStatus(r.Status) {
		return fmt.Errorf("already_settled")
	}
	if r.OpponentID != "" {
		return fmt.Errorf("opponent_already_joined")
	}
	// Someone is mid-payment to join right now — don't yank the room out from
	// under them (their in-flight entry payment could otherwise orphan).
	if r.PendingOpponentID != "" && time.Now().Unix()-r.PendingOpponentSince < int64(vsOpponentPayWindow.Seconds()) {
		return fmt.Errorf("someone_is_joining")
	}

	// Fund-safety: before cancelling a PAID room, confirm the true paid state
	// from the chain — a creator whose payment confirm was lost must still be
	// refunded, never cancelled away. Cheap targeted check by the creator memo.
	if !r.IsFree() && !r.CreatorPaid {
		cfg := s.GetNimiqConfig()
		if cfg.WalletAddress != "" {
			if txs, terr := nimiqGetTransactionsByAddress(cfg.RPCURL, cfg.WalletAddress, 500); terr == nil {
				if hash := findMatchingTx(txs, cfg.WalletAddress, vsRoomMemo(r.ID, "c"), int64(entryLuna(r.EntryNIM))); hash != "" {
					r.CreatorPaid = true
					r.CreatorPayTx = hash
					log.Printf("[VSROOM] cancel: found unconfirmed creator payment room=%s tx=%s — will refund", r.ID, hash)
				}
			}
		}
	}

	// No committed opponent → safe to cancel. Refund the creator's entry if
	// they'd actually paid in (no fee — no match happened).
	if !r.IsFree() && r.CreatorPaid {
		s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		log.Printf("[VSROOM] cancelled + refunded creator room=%s", r.ID)
	} else {
		log.Printf("[VSROOM] cancelled (unpaid) room=%s", r.ID)
	}
	r.PendingOpponentID = ""
	r.PendingOpponentNickname = ""
	r.PendingOpponentSince = 0
	r.Status = models.VSCancelled
	r.SettledAt = time.Now().Unix()
	return s.saveVSRoom(r)
}

// AdminCancelAndRefundVSRoom — force-closes ANY non-terminal room and
// refunds whichever side(s) actually paid in, no fee taken. This is the
// admin-panel "close & refund" / dispute-resolution action.
//
// Originally this only worked pre-match (OpponentID == ""); once two players
// were matched and paid in, admins had zero intervention capability short of
// hand-editing the database — a real operational risk for a feature moving
// real money. It now works at any point before the room reaches a terminal
// status: if only the creator ever paid, only the creator is refunded (same
// as before); if both paid, both get refunded. There's no partial/manual
// settlement option here by design — a full refund-both is the one outcome
// that's always fair regardless of what actually happened in a disputed
// match, so it's the safe generic answer rather than admin having to pick a
// winner.
//
// Locked exactly like every other mutator here, so the classic failure mode
// — admin clicks close at the same instant someone else clicks the invite
// link, or the score-submit flow is mid-settlement — cannot happen:
// whichever request acquires the room's mutex first completes fully before
// the other one even reads the room's state.
func (s *Store) AdminCancelAndRefundVSRoom(roomID string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("already_closed")
	}
	creatorRefund := 0.0
	opponentRefund := 0.0
	if r.CreatorPaid {
		s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		creatorRefund = r.EntryNIM
	}
	if r.OpponentID != "" && r.OpponentPaid {
		s.refundVSRoom(r, r.OpponentID, r.EntryNIM)
		opponentRefund = r.EntryNIM
	}
	r.Status = models.VSCancelled
	r.SettledAt = time.Now().Unix()
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] admin cancel+refund id=%s matched=%v creator_refund=%.4f opponent_refund=%.4f",
		r.ID, r.OpponentID != "", creatorRefund, opponentRefund)
	return r, nil
}

// AdminResolveVSRoomWinner — admin dispute resolution: declare the outcome of a
// (typically flagged / under-review) match and pay it out accordingly. outcome:
// "creator" | "opponent" | "tie". The pot is whatever both sides actually paid
// in; the winner gets the fee-adjusted payout (tie splits it). Clears the review
// flag and settles the room as completed. Locked like every other mutator.
func (s *Store) AdminResolveVSRoomWinner(roomID, outcome string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("already_closed")
	}
	if r.OpponentID == "" {
		return nil, fmt.Errorf("no_opponent")
	}
	pot := 0.0
	if r.CreatorPaid {
		pot += r.EntryNIM
	}
	if r.OpponentPaid {
		pot += r.EntryNIM
	}
	payout := pot * s.VSFeeFraction()
	r.FeeNIM = pot - payout
	r.PayoutNIM = payout
	switch outcome {
	case "creator":
		r.WinnerID = r.CreatorID
		r.PayoutTxHash = s.payoutVSRoom(r.CreatorID, payout, r.ID, "win")
	case "opponent":
		r.WinnerID = r.OpponentID
		r.PayoutTxHash = s.payoutVSRoom(r.OpponentID, payout, r.ID, "win")
	case "tie":
		half := payout / 2.0
		r.WinnerID = ""
		r.PayoutTxHash = s.payoutVSRoom(r.CreatorID, half, r.ID, "split")
		r.PayoutTxHash2 = s.payoutVSRoom(r.OpponentID, half, r.ID, "split")
	default:
		return nil, fmt.Errorf("bad_outcome")
	}
	r.NeedsReview = false
	r.Status = models.VSCompleted
	r.SettledAt = time.Now().Unix()
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] admin resolved id=%s outcome=%s winner=%s payout=%.4f", r.ID, outcome, r.WinnerID, payout)
	return r, nil
}

// AdminReopenVSRoom — admin "let them play it again" resolution: wipe both
// sides' scores/sessions, clear the review flag, hand out a FRESH seed (so a
// prior seed-scouting/cheat attempt is worthless), and reset the play window.
// Nobody is paid; both keep their existing entry payment and simply replay.
// Use for genuine technical failures where the fair fix is a clean rematch.
func (s *Store) AdminReopenVSRoom(roomID string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("already_closed")
	}
	if r.OpponentID == "" || !r.CreatorPaid || !r.OpponentPaid {
		return nil, fmt.Errorf("not_a_funded_match")
	}
	r.Seed = strconv.FormatInt(rand.Int63(), 10) // fresh level for the rematch
	r.CreatorScore = nil
	r.OpponentScore = nil
	r.CreatorSession = ""
	r.OpponentSession = ""
	r.CreatorPlayedAt = 0
	r.OpponentPlayedAt = 0
	r.NeedsReview = false
	r.ReviewReason = ""
	r.Status = models.VSAwaitingOppPlay // both funded → both may play again
	r.ExpiresAt = time.Now().Add(vsRoomPlayWindow).Unix()
	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	log.Printf("[VSROOM] admin reopened id=%s — fresh seed, scores cleared, play window reset", r.ID)
	return r, nil
}

// RequestVSForfeit — a matched player's request to bail out of a room they
// no longer want to play. Nothing happens on a one-sided request except
// recording it; only once BOTH the creator and the opponent have requested
// it does the room actually get cancelled and refunded (full refund to
// whoever paid, no fee — this is a mutual "let's just call it off", not a
// competitive outcome). This is separate from CancelVSRoom (creator-only,
// pre-match) and AdminCancelAndRefundVSRoom (admin-only, any time) — this
// one requires no admin, but requires consent from both sides, so neither
// player can unilaterally deny the other a fair shot at a match they
// already paid into.
func (s *Store) RequestVSForfeit(roomID, playerID string) (*models.VSRoom, error) {
	lock := vsRoomLock(roomID)
	lock.Lock()
	defer lock.Unlock()

	r, err := s.GetVSRoom(roomID)
	if err != nil || r == nil {
		return nil, fmt.Errorf("room_not_found")
	}
	if isVSTerminalStatus(r.Status) {
		return nil, fmt.Errorf("already_closed")
	}
	if r.OpponentID == "" {
		return nil, fmt.Errorf("no_opponent_yet") // use /cancel instead
	}
	switch playerID {
	case r.CreatorID:
		if r.CreatorForfeitRequested {
			return r, nil // already requested — idempotent
		}
		r.CreatorForfeitRequested = true
	case r.OpponentID:
		if r.OpponentForfeitRequested {
			return r, nil
		}
		r.OpponentForfeitRequested = true
	default:
		return nil, fmt.Errorf("not_a_participant")
	}

	if r.CreatorForfeitRequested && r.OpponentForfeitRequested {
		if r.CreatorPaid {
			s.refundVSRoom(r, r.CreatorID, r.EntryNIM)
		}
		if r.OpponentPaid {
			s.refundVSRoom(r, r.OpponentID, r.EntryNIM)
		}
		r.Status = models.VSCancelled
		r.SettledAt = time.Now().Unix()
		log.Printf("[VSROOM] mutual forfeit id=%s — both sides agreed, refunded and cancelled", r.ID)
	} else {
		log.Printf("[VSROOM] forfeit requested id=%s by=%s (waiting on the other side)", r.ID, playerID)
	}

	if err := s.saveVSRoom(r); err != nil {
		return nil, err
	}
	return r, nil
}
