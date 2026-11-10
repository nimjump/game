package game

// Regression tests for the "why is it still dialling rpc.nimiqwatch.com?" class
// of bug: a value saved from the admin panel (Badger key "nimcfg") must never
// beat NIMIQ_RPC_URL, and the lock must make it impossible.

import (
	"testing"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	db, err := badger.Open(badger.DefaultOptions(t.TempDir()).WithLogger(nil))
	if err != nil {
		t.Fatalf("badger: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewStore(db)
}

const (
	oldPublicRPC = "https://rpc.nimiqwatch.com"
	workerRPC    = "https://rpc.nimiqbase.com/secretpath"
)

func TestEnvWinsOverStoredDBValue(t *testing.T) {
	s := newTestStore(t)
	if err := s.SaveNimiqConfig(models.NimiqConfig{RPCURL: oldPublicRPC}); err != nil {
		t.Fatalf("save: %v", err)
	}

	t.Setenv("NIMIQ_RPC_URL", workerRPC)
	t.Setenv("NIMIQ_RPC_URL_LOCK", "")

	cfg, src := s.GetNimiqConfigEx()
	if cfg.RPCURL != workerRPC {
		t.Fatalf("effective RPC = %q, want the .env/baked value %q (DB must not win)", cfg.RPCURL, workerRPC)
	}
	if src != RPCSourceEnv {
		t.Fatalf("source = %q, want %q", src, RPCSourceEnv)
	}
}

func TestLockIgnoresStoredValueCompletely(t *testing.T) {
	s := newTestStore(t)
	if err := s.SaveNimiqConfig(models.NimiqConfig{RPCURL: oldPublicRPC}); err != nil {
		t.Fatalf("save: %v", err)
	}
	t.Setenv("NIMIQ_RPC_URL", workerRPC)
	t.Setenv("NIMIQ_RPC_URL_LOCK", "true")

	cfg, src := s.GetNimiqConfigEx()
	if cfg.RPCURL != workerRPC || src != RPCSourceEnv {
		t.Fatalf("locked config = %q (%s), want %q (%s)", cfg.RPCURL, src, workerRPC, RPCSourceEnv)
	}
}

func TestDBValueStillWorksWhenNothingElseConfigured(t *testing.T) {
	s := newTestStore(t)
	if err := s.SaveNimiqConfig(models.NimiqConfig{RPCURL: "https://relay.example/rpc"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	t.Setenv("NIMIQ_RPC_URL", "")
	t.Setenv("NIMIQ_RPC_URL_LOCK", "")

	cfg, src := s.GetNimiqConfigEx()
	if cfg.RPCURL != "https://relay.example/rpc" || src != RPCSourceDB {
		t.Fatalf("config = %q (%s), want the DB value (%s)", cfg.RPCURL, src, RPCSourceDB)
	}
}

func TestClearStoredRPCURL(t *testing.T) {
	s := newTestStore(t)
	if err := s.SaveNimiqConfig(models.NimiqConfig{RPCURL: oldPublicRPC, WalletAddress: "NQ07 KEEP"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	removed, err := s.ClearStoredRPCURL()
	if err != nil {
		t.Fatalf("clear: %v", err)
	}
	if removed != oldPublicRPC {
		t.Fatalf("removed = %q, want %q", removed, oldPublicRPC)
	}
	// Other fields must survive: only the URL is cleared.
	cfg := s.GetNimiqConfig()
	if cfg.WalletAddress != "NQ07 KEEP" {
		t.Fatalf("wallet address was damaged by the reset: %q", cfg.WalletAddress)
	}
	// Idempotent.
	if again, _ := s.ClearStoredRPCURL(); again != "" {
		t.Fatalf("second clear returned %q, want empty", again)
	}
}
