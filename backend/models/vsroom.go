package models

// VSRoomStatus — lifecycle of an async VS challenge room.
type VSRoomStatus string

const (
	VSAwaitingCreatorPay VSRoomStatus = "awaiting_creator_pay" // entry_nim>0, creator hasn't paid yet
	VSAwaitingCreatorPlay VSRoomStatus = "awaiting_creator_play" // creator paid (or free), hasn't played yet
	VSWaitingOpponent    VSRoomStatus = "waiting_opponent"    // creator played, open for invite link (up to 24h)
	VSAwaitingOppPay     VSRoomStatus = "awaiting_opponent_pay" // opponent joined, entry_nim>0, hasn't paid yet
	VSAwaitingOppPlay    VSRoomStatus = "awaiting_opponent_play" // opponent paid (or free), hasn't played yet
	VSCompleted          VSRoomStatus = "completed"            // both played, payout done (or free — just settled)
	VSExpiredPayout      VSRoomStatus = "expired_payout"       // 24h passed, only one side played+paid, forfeit payout done
	VSExpiredRefunded    VSRoomStatus = "expired_refunded"     // 24h passed, no real match happened — refunded
	VSCancelled          VSRoomStatus = "cancelled"            // creator cancelled before opponent joined (only if unpaid/free)
	// VSManualReview — a HELD state: one side's replay was flagged (possible
	// cheat) or failed server re-simulation, so the match must NOT auto-settle
	// or pay anyone out. It waits for an admin to investigate and resolve
	// (declare a winner or refund both). NOT terminal — admin still acts on it.
	VSManualReview       VSRoomStatus = "manual_review"
)

// VSRoom — one async 1v1 "VS" challenge room.
// Both players run the exact same seed; whoever isn't there yet just sees
// their slot as pending. Entry fee (if any) is paid by both sides in NIM
// before their own round; on settlement the winner receives 95% of the
// pooled entries (5% system fee kept in the app wallet — no separate tx).
type VSRoom struct {
	ID string `json:"id"`
	// ShortCode — a short, friendly, purely-numeric PUBLIC handle (4 digits for
	// public rooms, 8 for private) used in the shareable invite link (?vs=1903)
	// and shown to players. Unlike ID it is NOT globally unique forever: it's
	// only unique among currently-active rooms and is recycled once a room ends
	// (so "1903" can belong to a different room tomorrow). All security-relevant
	// and internal operations — payment memo, storage key, etc. — use the long
	// unguessable ID instead; ShortCode is purely a nicer public alias that the
	// backend resolves back to a room (see GetVSRoomByShortCode).
	ShortCode string `json:"short_code"`
	Seed      string `json:"seed"` // decimal int64, matches game_seed format used elsewhere
	EntryNIM float64 `json:"entry_nim"` // 0 = free room
	// IsPrivate — if true, this room never appears in the public "open rooms"
	// browse list; it only works via its direct invite link (still fully
	// joinable/playable, just not discoverable). The creator always sees it
	// in their own "My VS Matches" list regardless.
	IsPrivate bool `json:"is_private"`

	CreatorID       string `json:"creator_id"`
	CreatorNickname string `json:"creator_nickname"`
	CreatorPaid     bool   `json:"creator_paid"`
	CreatorPayTx    string `json:"creator_pay_tx,omitempty"`
	CreatorScore    *int   `json:"creator_score,omitempty"`
	CreatorSession  string `json:"creator_session,omitempty"`
	CreatorPlayedAt int64  `json:"creator_played_at,omitempty"`

	OpponentID       string `json:"opponent_id,omitempty"`
	OpponentNickname string `json:"opponent_nickname,omitempty"`

	// ── Opponent slot reservation (INTERNAL — never exposed to clients) ──────
	// Paying IS joining: a paid room's opponent slot (OpponentID above) is only
	// ever set once the entry payment is confirmed. Until then the would-be
	// opponent is merely "pending": they've tapped Accept and are paying, but
	// they do NOT count as joined and appear nowhere as a participant. These
	// fields exist only so (a) the reconciler can credit a genuinely-paid but
	// never-confirmed opponent, and (b) the server can tell the pending payer
	// themselves "here's your Pay button" on a re-fetch. json:"-" keeps them
	// out of every API response, so no one ever sees an unpaid opponent.
	PendingOpponentID       string `json:"-"`
	PendingOpponentNickname string `json:"-"`
	PendingOpponentSince    int64  `json:"-"`
	OpponentPaid     bool   `json:"opponent_paid"`
	OpponentPayTx    string `json:"opponent_pay_tx,omitempty"`
	OpponentScore    *int   `json:"opponent_score,omitempty"`
	OpponentSession  string `json:"opponent_session,omitempty"`
	OpponentPlayedAt int64  `json:"opponent_played_at,omitempty"`

	Status VSRoomStatus `json:"status"`

	// Mutual forfeit — once matched (OpponentID set), either side can request
	// to bail out. Nothing happens until BOTH sides have requested it: at
	// that point the room is cancelled and whoever paid in gets a full
	// refund (no fee — no real match happened). A one-sided request alone
	// never ends the room; it just records intent until the other side
	// agrees (or the normal 24h expiry/settlement takes over regardless).
	CreatorForfeitRequested  bool `json:"creator_forfeit_requested,omitempty"`
	OpponentForfeitRequested bool `json:"opponent_forfeit_requested,omitempty"`

	// NeedsReview — set true the moment EITHER side's VS submission is flagged
	// by anti-cheat or fails server replay re-simulation. While set, the match
	// can never auto-settle/pay out — settleVSRoom parks it in VSManualReview
	// for an admin to resolve. ReviewReason records why (which side + reason).
	NeedsReview  bool   `json:"needs_review,omitempty"`
	ReviewReason string `json:"review_reason,omitempty"`

	// RefundedDupTxs — hashes of DUPLICATE/extra entry payments already refunded.
	// A player whose wallet (or Nimiq Pay) is slow can send the same entry twice;
	// the room only ever keeps ONE payment per side, and the reconciler refunds
	// every extra matching tx to its sender. Recording the refunded hashes here
	// keeps that refund strictly once-only across reconcile cycles. Internal.
	RefundedDupTxs []string `json:"-"`

	WinnerID     string  `json:"winner_id,omitempty"`     // "" if tie-split or refunded
	PayoutNIM    float64 `json:"payout_nim,omitempty"`     // total amount actually paid out (post-fee)
	FeeNIM       float64 `json:"fee_nim,omitempty"`
	PayoutTxHash string  `json:"payout_tx_hash,omitempty"` // creator's payout tx (if any)
	PayoutTxHash2 string `json:"payout_tx_hash_2,omitempty"` // opponent's payout tx (if any, tie-split)
	SettledAt    int64   `json:"settled_at,omitempty"`

	CreatedAt int64 `json:"created_at"`
	ExpiresAt int64 `json:"expires_at"` // CreatedAt + 24h
}

// IsFree — true if this room has no entry fee (pure friendly match).
func (r *VSRoom) IsFree() bool {
	return r.EntryNIM <= 0
}

// IsOpen — true if a second player can still join (creator has played,
// opponent slot empty, not expired, not full).
func (r *VSRoom) IsOpen(nowUnix int64) bool {
	return r.OpponentID == "" && r.Status == VSWaitingOpponent && nowUnix < r.ExpiresAt
}
