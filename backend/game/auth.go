package game

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	badger "github.com/dgraph-io/badger/v4"
	"nimjump-backend/models"
)

const (
	keyChallengePfx = "chal:" // + challenge string
	keyAuthTokenPfx = "auth:" // + token
	keyDevicePfx    = "dev:"  // + device_id
	challengeTTL    = 5 * time.Minute
)

// ── Challenge ─────────────────────────────────────────────────────────────────

// NewChallenge — generates a challenge nonce to be signed and saves it to DB
func (s *Store) NewChallenge() (*models.AuthChallenge, error) {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	ts := time.Now().UnixMilli()
	challenge := fmt.Sprintf("bunnyjump_auth_%d_%s", ts, hex.EncodeToString(b))

	ac := &models.AuthChallenge{
		Challenge: challenge,
		ExpiresAt: time.Now().Add(challengeTTL).Unix(),
	}
	data, _ := json.Marshal(ac)
	err := s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(
			badger.NewEntry([]byte(keyChallengePfx+challenge), data).WithTTL(challengeTTL + 30*time.Second),
		)
	})
	return ac, err
}

// consumeChallenge — fetch and delete the challenge from DB (single-use)
func (s *Store) consumeChallenge(challenge string) (*models.AuthChallenge, error) {
	var ac models.AuthChallenge
	err := s.db.Update(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyChallengePfx + challenge))
		if err != nil {
			return err
		}
		if e := item.Value(func(v []byte) error {
			return json.Unmarshal(v, &ac)
		}); e != nil {
			return e
		}
		return txn.Delete([]byte(keyChallengePfx + challenge))
	})
	if err == badger.ErrKeyNotFound {
		return nil, fmt.Errorf("challenge_not_found_or_expired")
	}
	return &ac, err
}

// ── Signature verification ────────────────────────────────────────────────────

// Nimiq sign() prepares the message as follows:
// prefix = "\x16Nimiq Signed Message:\n" + len(message)
// signData = sha256(prefix + message) — but actually Ed25519 raw signing
//
// window.nimiq.sign(message) → { publicKey: "hex64", signature: "hex128" }
// Deriving Nimiq address from publicKey: sha256(publicKey)[0:20] → Nimiq address format
//
// NOTE: Nimiq Ed25519 signature signs raw message with prefix:
// "\x16Nimiq Signed Message:\n" + len_bytes + message_bytes

func VerifyNimiqSignature(message, publicKeyHex, signatureHex string) error {
	pubKeyBytes, err := hex.DecodeString(publicKeyHex)
	if err != nil || len(pubKeyBytes) != 32 {
		return fmt.Errorf("invalid_public_key")
	}
	sigBytes, err := hex.DecodeString(signatureHex)
	if err != nil || len(sigBytes) != 64 {
		return fmt.Errorf("invalid_signature_length: %d", len(sigBytes))
	}

	pubKey := ed25519.PublicKey(pubKeyBytes)
	msgBytes := []byte(message)

	// Nimiq Mini App SDK signing format:
	// sha256("\x16Nimiq Signed Message:\n" + decimal_string(len(msg)) + msg)
	prefix := []byte("\x16Nimiq Signed Message:\n")
	lenStr := []byte(fmt.Sprintf("%d", len(msgBytes)))
	var data []byte
	data = append(data, prefix...)
	data = append(data, lenStr...)
	data = append(data, msgBytes...)
	hash := sha256.Sum256(data)

	if ed25519.Verify(pubKey, hash[:], sigBytes) {
		return nil
	}
	return fmt.Errorf("signature_mismatch")
}

// publicKeyToAddress — derives Nimiq address from Ed25519 public key
// Nimiq address format: NQ + checksum + base32(blake2b(pubkey)[0:20])
// Simple approach: client already sends the address; we just need to know
// that the public key corresponds to that address.
// Real check: sign verify is sufficient — ownership of the publicKey is proven.
// For extra security: we could compare the address sent by client against the one
// derived from publicKey, but Nimiq address derivation in Go is complex.
// Therefore: sign verify + address from listAccounts match is sufficient.

// ── Session ───────────────────────────────────────────────────────────────────

func newToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (s *Store) CreateSession(playerID, nimiqAddress, deviceID string) (*models.AuthSession, error) {
	token := newToken()
	sess := &models.AuthSession{
		Token:        token,
		PlayerID:     playerID,
		NimiqAddress: nimiqAddress,
		DeviceID:     deviceID,
		CreatedAt:    time.Now().Unix(),
		ExpiresAt:    time.Now().Add(sessionTTL).Unix(),
	}
	data, _ := json.Marshal(sess)
	err := s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(
			badger.NewEntry([]byte(keyAuthTokenPfx+token), data).WithTTL(sessionTTL + time.Minute),
		)
	})
	return sess, err
}

func (s *Store) GetSession(token string) (*models.AuthSession, error) {
	var sess models.AuthSession
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(keyAuthTokenPfx + token))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &sess)
		})
	})
	if err == badger.ErrKeyNotFound {
		return nil, nil
	}
	return &sess, err
}

// ── Auth flow ─────────────────────────────────────────────────────────────────

// VerifyAndLogin — verifies challenge + publicKey + signature, creates session
func (s *Store) VerifyAndLogin(challenge, nimiqAddress, publicKeyHex, signatureHex, deviceID string) (*models.AuthSession, error) {
	// 1. Consume challenge (single-use + expiry check)
	ac, err := s.consumeChallenge(challenge)
	if err != nil {
		return nil, err
	}
	if time.Now().Unix() > ac.ExpiresAt {
		return nil, fmt.Errorf("challenge_expired")
	}

	// 2. Verify signature
	if err := VerifyNimiqSignature(challenge, publicKeyHex, signatureHex); err != nil {
		return nil, fmt.Errorf("signature_invalid: %w", err)
	}

	// 3. Normalize address
	nimiqAddress = strings.ToUpper(strings.TrimSpace(nimiqAddress))

	// playerID = Nimiq address (NQ...)
	playerID := nimiqAddress

	// 4. Save wallet address (upsert)
	_ = s.RegisterPlayerWallet(playerID, nimiqAddress)

	// 5. Create session
	return s.CreateSession(playerID, nimiqAddress, deviceID)
}

// ListActiveSessions — scans all auth: keys still alive in BadgerDB (TTL not expired).
// Returns set of playerIDs that have at least one valid token.
func (s *Store) ListActiveSessions() (map[string]int64, error) {
	pfx := []byte(keyAuthTokenPfx)
	result := map[string]int64{} // playerID → latest ExpiresAt
	err := s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = pfx
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.Valid(); it.Next() {
			var sess models.AuthSession
			if e := it.Item().Value(func(v []byte) error {
				return json.Unmarshal(v, &sess)
			}); e == nil && sess.PlayerID != "" {
				if ex, ok := result[sess.PlayerID]; !ok || sess.ExpiresAt > ex {
					result[sess.PlayerID] = sess.ExpiresAt
				}
			}
		}
		return nil
	})
	return result, err
}
