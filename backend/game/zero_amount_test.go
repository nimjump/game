package game

// Tests for the "0 NIM rewards got stuck in the RPC" bug:
//   • nothing with a 0-luna amount may ever be saved/queued/sent;
//   • legacy records that already exist must be purged, not retried.

import (
	"errors"
	"testing"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	db, err := badger.Open(badger.DefaultOptions(t.TempDir()).WithLogger(nil))
	if err != nil {
		t.Fatalf("badger open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewStore(db)
}

func TestRewardLuna(t *testing.T) {
	cases := []struct {
		nim  float64
		want int64
	}{
		{0, 0},
		{-1, 0},
		{0.000001, 0}, // below one luna → rounds to 0
		{0.000004, 0}, // still 0
		{0.00001, 1},  // exactly one luna (the VS join ping)
		{0.5, 50000},  // typical prize
		{12.34567, 1234567},
	}
	for _, c := range cases {
		if got := rewardLuna(c.nim); got != c.want {
			t.Errorf("rewardLuna(%v) = %d, want %d", c.nim, got, c.want)
		}
	}
}

func TestQueueRewardRejectsZeroAmount(t *testing.T) {
	s := testStore(t)

	for _, amt := range []float64{0, -5, 0.000001, 0.000004} {
		r, err := s.QueueReward("player-x", amt, "quest_claim:test")
		if !errors.Is(err, ErrZeroRewardAmount) {
			t.Fatalf("QueueReward(%v) err = %v, want ErrZeroRewardAmount", amt, err)
		}
		if r != nil {
			t.Fatalf("QueueReward(%v) returned a reward record; it must not be created", amt)
		}
	}

	all, _ := s.ListRewards("")
	if len(all) != 0 {
		t.Fatalf("%d reward(s) were stored for zero amounts, want 0", len(all))
	}

	// Direct-address path too.
	if _, err := s.QueueRewardToAddress("NQ07 0000 0000 0000 0000 0000 0000 0000 0000", 0.000004, "vsroom:x:refund"); !errors.Is(err, ErrZeroRewardAmount) {
		t.Fatalf("QueueRewardToAddress(0.000004) err = %v, want ErrZeroRewardAmount", err)
	}
}

// TestPurgeZeroAmountRewards — the cleanup half: records written by older
// builds must disappear from the DB, while real and already-sent ones stay.
func TestPurgeZeroAmountRewards(t *testing.T) {
	s := testStore(t)

	legacyZero := &models.PendingReward{ID: "rw_1_zero", PlayerID: "p1", AmountNIM: 0, AmountLuna: 0, Reason: "quest_claim:x", Status: models.RewardPending, Attempts: 42}
	legacyRounded := &models.PendingReward{ID: "rw_2_round", PlayerID: "p2", AmountNIM: 0.000004, AmountLuna: 0, Reason: "in_game_coins:coins=1", Status: models.RewardFailed, Attempts: 7}
	real := &models.PendingReward{ID: "rw_3_real", PlayerID: "p3", AmountNIM: 0.5, AmountLuna: 50000, Reason: "quest_claim:y", Status: models.RewardPending}
	sentZero := &models.PendingReward{ID: "rw_4_sentzero", PlayerID: "p4", AmountNIM: 0, AmountLuna: 0, Reason: "legacy", Status: models.RewardSent}
	for _, r := range []*models.PendingReward{legacyZero, legacyRounded, real, sentZero} {
		if err := s.saveReward(r); err != nil {
			t.Fatalf("save: %v", err)
		}
	}

	n, err := s.PurgeZeroAmountRewards()
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	if n != 2 {
		t.Fatalf("purged %d, want 2 (the two zero-luna pending/failed records)", n)
	}

	all, _ := s.ListRewards("")
	ids := map[string]bool{}
	for _, r := range all {
		ids[r.ID] = true
	}
	if ids["rw_1_zero"] || ids["rw_2_round"] {
		t.Error("zero-amount records were not deleted")
	}
	if !ids["rw_3_real"] {
		t.Error("a real 0.5 NIM reward was deleted — purge must never touch sendable rewards")
	}
	if !ids["rw_4_sentzero"] {
		t.Error("sent history must never be deleted")
	}

	// Idempotent: a second pass finds nothing.
	if n2, _ := s.PurgeZeroAmountRewards(); n2 != 0 {
		t.Errorf("second purge removed %d, want 0", n2)
	}
}

func TestSendTransactionRejectsZeroLuna(t *testing.T) {
	t.Setenv("NIMIQ_DEV_MODE", "1") // dev mode must NOT fake-succeed on 0 luna
	t.Setenv("NIMIQ_PRIVATE_KEY", "")
	cfg := models.NimiqConfig{WalletAddress: "NQ07 0000 0000 0000 0000 0000 0000 0000 0000"}
	if _, err := nimiqSendTransaction(cfg, cfg.WalletAddress, 0, "memo"); !errors.Is(err, ErrZeroRewardAmount) {
		t.Fatalf("nimiqSendTransaction(0 luna) err = %v, want ErrZeroRewardAmount", err)
	}
}
