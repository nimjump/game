package models

// PlayerWallet — player's registered Nimiq address
type PlayerWallet struct {
	PlayerID     string `json:"player_id"`
	NimiqAddress string `json:"nimiq_address"` // "NQ..." format
	RegisteredAt int64  `json:"registered_at"`
	// AuthSource records which sign-in channel produced the MOST RECENT
	// successful login for this player: AuthSourceNimiqPay (inside the real
	// Nimiq Pay mini-app, via the mini-app SDK) or AuthSourceWeb (a plain
	// browser tab, via the Nimiq Hub API popup). Used by QueueReward to halve
	// NIM payouts for web-sourced players (see game/nimiq.go). Empty string
	// means this wallet was registered before this field existed — treated
	// as AuthSourceNimiqPay at reward time (see QueueReward), since every
	// login before this feature shipped could only have come from inside
	// Nimiq Pay (the web sign-in path didn't exist yet).
	AuthSource string `json:"auth_source,omitempty"`
}

const (
	AuthSourceNimiqPay = "nimiq_pay"
	AuthSourceWeb      = "web"
)

// RewardStatus — status of a pending reward
type RewardStatus string

const (
	RewardPending   RewardStatus = "pending"   // saved, not yet sent
	RewardSent      RewardStatus = "sent"      // successfully sent
	RewardFailed    RewardStatus = "failed"    // send failed, awaiting retry
	RewardNoWallet  RewardStatus = "no_wallet" // player's wallet not registered
	// RewardSkipped — terminal, permanently un-sendable: the recipient address
	// equals the app's own payout wallet (sender == recipient), which the
	// Nimiq mempool rejects outright ("Sender same as recipient"). Retrying can
	// never help, so these are parked here instead of retried forever. Happens
	// e.g. when someone plays/tests using the same wallet the app pays out from
	// (notably the near-zero VS "match started" notification ping).
	RewardSkipped   RewardStatus = "skipped"
)

// PendingReward — reward record that needs to be sent
// This is saved FIRST, then sending is attempted
type PendingReward struct {
	ID          string       `json:"id"`           // unique ID: "rw_<timestamp>_<random>"
	PlayerID    string       `json:"player_id"`
	NimiqAddress string      `json:"nimiq_address"` // address at time of sending
	AmountNIM   float64      `json:"amount_nim"`
	AmountLuna  int64        `json:"amount_luna"`
	Reason      string       `json:"reason"`        // "quest_claim:q_...", "leaderboard:...:rank1"
	Status      RewardStatus `json:"status"`
	TxHash      string       `json:"tx_hash,omitempty"`
	ErrorMsg    string       `json:"error_msg,omitempty"`
	Attempts    int          `json:"attempts"`
	CreatedAt   int64        `json:"created_at"`
	LastAttempt int64        `json:"last_attempt,omitempty"`
	SentAt      int64        `json:"sent_at,omitempty"`
}

// PlayerNickname — player's chosen display name
type PlayerNickname struct {
	PlayerID    string `json:"player_id"`
	Nickname    string `json:"nickname"`     // lowercase a-z0-9, max 20 chars
	SetAt       int64  `json:"set_at"`       // unix timestamp
	CooldownEnd int64  `json:"cooldown_end"` // unix: player can't change until this
}

// NicknameLock — prevents a released nickname from being claimed for 30 days
type NicknameLock struct {
	Nickname    string `json:"nickname"`
	ReleasedBy  string `json:"released_by"` // player_id who last held it
	LockedUntil int64  `json:"locked_until"` // unix: can't be claimed until this date
}

// NimiqConfig — Nimiq RPC and Telegram settings
type NimiqConfig struct {
	RPCURL              string  `json:"rpc_url"`
	WalletAddress       string  `json:"wallet_address"`
	TelegramToken       string  `json:"telegram_token"`
	TelegramChatID      string  `json:"telegram_chat_id"`
	LowBalanceThreshold float64 `json:"low_balance_threshold"`
}
