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
)

// VSRoom — one async 1v1 "VS" challenge room.
// Both players run the exact same seed; whoever isn't there yet just sees
// their slot as pending. Entry fee (if any) is paid by both sides in NIM
// before their own round; on settlement the winner receives 95% of the
// pooled entries (5% system fee kept in the app wallet — no separate tx).
type VSRoom struct {
	ID       string `json:"id"`
	Seed     string `json:"seed"` // decimal int64, matches game_seed format used elsewhere
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
	OpponentPaid     bool   `json:"opponent_paid"`
	OpponentPayTx    string `json:"opponent_pay_tx,omitempty"`
	OpponentScore    *int   `json:"opponent_score,omitempty"`
	OpponentSession  string `json:"opponent_session,omitempty"`
	OpponentPlayedAt int64  `json:"opponent_played_at,omitempty"`

	Status VSRoomStatus `json:"status"`

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
