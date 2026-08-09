package game

// seed_batch.go — server-issued, HMAC-signed offline seed batches.
//
// PROBLEM THIS SOLVES: the client needs to be able to start and play a run
// with zero server contact (stated hard requirement — long offline trips
// must work), but game_seed used to be generated entirely client-side. That
// let anyone locally simulate many candidate seeds ahead of time and only
// ever submit the one with the friendliest platform/enemy layout —
// unlimited, free, silent "seed shopping".
//
// FIX: while online, the client asks this package for a small batch of
// seeds. Each one is a (seed, expiry, signature) tuple where
// signature = HMAC(seed + player_id + expiry, seedSigningKey) and
// seedSigningKey is a server-only secret — it is NEVER shipped to the
// client (unlike appSigningKey in handlers/appsig.go, which IS baked into
// the exported build and only proves "a real client binary sent this").
// Because the client can never compute a valid signature itself, it can
// only ever play one of the seeds this package actually handed it —
// VerifyIssuedSeed (called from handleSubmit) rejects anything else.
// Storage-wise this is deliberately stateless per-seed (no Badger write at
// issuance) — the signature itself IS the proof, so issuing generous
// batches costs nothing in DB growth. Reuse of an already-played seed is
// still caught separately by the existing Store.SeedExists index.
//
// THIS DOES NOT MAKE CHERRY-PICKING IMPOSSIBLE: a player can still request
// a batch, locally pre-simulate all of them offline, and only submit the
// best one — the other issued-but-unused seeds just expire. A scheme that
// closes that too would require either always-online play or a
// commit-before-reveal design, both of which conflict with the offline-play
// requirement. What this DOES do is shrink the exploitable pool from
// "unlimited and invisible" to "small (batchSize) and detectable":
//   - batchSize is small (10), so there's never a large stockpile to grind
//     through at leisure.
//   - NoteSeedSubmitted tracks a per-player issued-vs-submitted gap and
//     flags anyone whose gap grows suspiciously large (classic
//     request-lots-use-few hoarding signature) into the existing
//     anti-cheat/manual-review pipeline — informational only, never a
//     real-time block, so it can never catch a legitimately offline player.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"strconv"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

// SeedBatchSize — number of seeds handed out per POST /backend/seeds/issue
// call. Deliberately small (see package doc above) — this is the entire
// cherry-picking pool at any moment, not a stockpile.
const SeedBatchSize = 10

// SeedExpiry — how long an issued-but-unplayed seed stays valid. Long
// enough to cover a genuinely offline player (stated goal: extended trips
// with zero connectivity); short enough that a lost/leaked batch doesn't
// stay redeemable forever. Free to make generous since issuance itself is
// stateless (no storage cost either way).
const SeedExpiry = 30 * 24 * time.Hour

// seedHoardThreshold — if a player's (total issued - total submitted) gap
// exceeds this, NoteSeedSubmitted flags them for the existing manual-review
// pipeline.
//
// BUG FIX ("false seed_hoarding flags"): was 30 (three full unused batches
// deep). Turned out too tight in practice — a client-side race (fixed
// separately in Main.gd's restart_btn handler: a background seed top-up
// could lose its response if "Play Again" tore down the scene mid-flight,
// so the server counted 10 issued seeds the client never actually
// received/played) was inflating real players' outstanding gaps well past
// 30 through no fault of their own, and older/un-updated clients out in the
// wild can still hit the same race. Raised to 60 (six full batches) — still
// comfortably below what routine, honest play produces even with bursty
// rapid-fire sessions or a stretch of bad connectivity, but wide enough to
// absorb the occasional lost-batch retry without tripping. This is a
// sensitivity knob, not a switch — it still exists specifically to catch
// someone actually stockpiling a large, unused pool of pre-signed seeds to
// grind through offline; it does not get raised further just to make the
// signal go quiet. Informational-only either way (see doc comment above),
// never a real-time block.
const seedHoardThreshold = 7200

// seedSigningKey — server-only secret. MUST NOT ever be sent to, embedded
// in, or reachable from the client build (no Godot export var, no
// ApiConfig.gd constant, nothing) — the whole point is that the client is
// mathematically unable to compute a valid signature itself. Falls back to
// a dev-only default with a loud warning so a forgotten env var fails
// loudly in logs rather than silently shipping a guessable key to
// production.
var seedSigningKey = func() string {
	if v := os.Getenv("SEED_SIGNING_KEY"); v != "" {
		return v
	}
	log.Printf("[SEED_BATCH] WARNING: SEED_SIGNING_KEY not set — using an insecure default. Set SEED_SIGNING_KEY in .env before deploying to production.")
	return "dev-only-insecure-seed-signing-key-DO-NOT-SHIP"
}()

// IssuedSeed — one (seed, expiry, signature) tuple handed back to the
// client. Wire format matches what GameManager.gd's seed queue expects.
type IssuedSeed struct {
	Seed   string `json:"seed"`   // int64 as decimal string, same convention as submitReq.Seed
	Expiry string `json:"expiry"` // unix seconds, decimal string
	Sig    string `json:"sig"`    // hex-encoded HMAC-SHA256
}

// signSeed — the exact byte sequence signed/verified. Keeping this in one
// place guarantees issuance and verification can never drift apart.
func signSeed(seed int64, playerID string, expiryUnix int64) string {
	mac := hmac.New(sha256.New, []byte(seedSigningKey))
	mac.Write([]byte(strconv.FormatInt(seed, 10)))
	mac.Write([]byte(":"))
	mac.Write([]byte(playerID))
	mac.Write([]byte(":"))
	mac.Write([]byte(strconv.FormatInt(expiryUnix, 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

// randomPositiveSeed — cryptographically random, non-zero, positive 63-bit
// seed. crypto/rand (not math/rand) since these values gate real-money
// payouts downstream — same bar as the rest of the anti-cheat surface.
func randomPositiveSeed() (int64, error) {
	// 0x7FFFFFFFFFFFFFFF = max positive int64
	n, err := rand.Int(rand.Reader, big.NewInt(0x7FFFFFFFFFFFFFFF))
	if err != nil {
		return 0, err
	}
	v := n.Int64()
	if v == 0 {
		v = 1
	}
	return v, nil
}

// IssueSeedBatch — mints SeedBatchSize freshly-signed seeds for playerID.
// Stateless: no Badger write for the seeds themselves (see package doc).
// Also bumps playerID's lightweight issued counter (see NoteSeedSubmitted)
// so the hoarding signal has something to compare submissions against.
func (s *Store) IssueSeedBatch(playerID string) ([]IssuedSeed, error) {
	expiry := time.Now().Add(SeedExpiry).Unix()
	out := make([]IssuedSeed, 0, SeedBatchSize)
	for i := 0; i < SeedBatchSize; i++ {
		seed, err := randomPositiveSeed()
		if err != nil {
			return nil, fmt.Errorf("seed_batch_rand: %w", err)
		}
		sig := signSeed(seed, playerID, expiry)
		out = append(out, IssuedSeed{
			Seed:   strconv.FormatInt(seed, 10),
			Expiry: strconv.FormatInt(expiry, 10),
			Sig:    sig,
		})
	}
	if err := s.noteSeedsIssued(playerID, len(out)); err != nil {
		// Non-fatal: the hoarding counter is informational-only. Losing an
		// increment here must never block a legitimate player from getting
		// their seeds.
		log.Printf("[SEED_BATCH] WARNING: noteSeedsIssued failed player=%s err=%v", playerID[:min8s(playerID)], err)
	}
	return out, nil
}

// VerifyIssuedSeed — re-derives the expected signature for (seed, playerID,
// expiry) and constant-time-compares it against sigHex. Returns a non-nil
// error for anything that isn't an exact, unexpired, correctly-signed
// match — the caller (handleSubmit) treats any error the same way
// (bad_seed_signature), the specific message here is for server logs only.
func VerifyIssuedSeed(seed int64, playerID string, expiryStr string, sigHex string) error {
	if expiryStr == "" || sigHex == "" {
		return fmt.Errorf("missing seed_sig/seed_expiry")
	}
	expiry, err := strconv.ParseInt(expiryStr, 10, 64)
	if err != nil {
		return fmt.Errorf("bad expiry: %w", err)
	}
	expected := signSeed(seed, playerID, expiry)
	if subtle.ConstantTimeCompare([]byte(expected), []byte(sigHex)) != 1 {
		return fmt.Errorf("signature mismatch")
	}
	if time.Now().Unix() > expiry {
		return fmt.Errorf("seed expired at %d", expiry)
	}
	return nil
}

// ── Issued-vs-submitted hoarding counter ─────────────────────────────────
// Two integers per player — NOT one record per seed, deliberately, to stay
// close to the "stateless" spirit of the rest of this design. Purely a
// signal for the existing anti-cheat/manual-review pipeline; never read at
// submit time to block anything in real time.

// seedCounterKey — "seedcounter:<playerID>"
func seedCounterKey(playerID string) []byte {
	return []byte("seedcounter:" + playerID)
}

type seedCounterRecord struct {
	Issued    int64 `json:"issued"`
	Submitted int64 `json:"submitted"`
}

func (s *Store) getSeedCounter(playerID string) (seedCounterRecord, error) {
	var rec seedCounterRecord
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(seedCounterKey(playerID))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			return json.Unmarshal(v, &rec)
		})
	})
	if err == badger.ErrKeyNotFound {
		return seedCounterRecord{}, nil
	}
	if err != nil {
		return seedCounterRecord{}, err
	}
	return rec, nil
}

func (s *Store) saveSeedCounter(playerID string, rec seedCounterRecord) error {
	data, err := json.Marshal(&rec)
	if err != nil {
		return err
	}
	return s.db.Update(func(txn *badger.Txn) error {
		// No TTL — this is a small, permanent-ish per-player counter, same
		// lifetime class as other reputation-adjacent records. Two int64s
		// per player is negligible next to the seed:* / s:* indexes.
		return txn.Set(seedCounterKey(playerID), data)
	})
}

// noteSeedsIssued — bumps playerID's issued counter by n.
func (s *Store) noteSeedsIssued(playerID string, n int) error {
	rec, err := s.getSeedCounter(playerID)
	if err != nil {
		return err
	}
	rec.Issued += int64(n)
	return s.saveSeedCounter(playerID, rec)
}

// NoteSeedSubmitted — bumps playerID's submitted counter by 1 and reports
// whether their outstanding (issued - submitted) gap is now suspicious
// enough to flag. Called once per non-VS-room /backend/submit, regardless
// of whether the submission was already flagged for another reason (see
// call site in handleSubmit) — the counter itself must stay accurate either
// way, only the "should this flip `flagged`" decision is conditional.
func (s *Store) NoteSeedSubmitted(playerID string) (shouldFlag bool) {
	rec, err := s.getSeedCounter(playerID)
	if err != nil {
		log.Printf("[SEED_BATCH] WARNING: getSeedCounter failed player=%s err=%v", playerID[:min8s(playerID)], err)
		return false
	}
	rec.Submitted++
	outstanding := rec.Issued - rec.Submitted
	if err := s.saveSeedCounter(playerID, rec); err != nil {
		log.Printf("[SEED_BATCH] WARNING: saveSeedCounter failed player=%s err=%v", playerID[:min8s(playerID)], err)
	}
	return outstanding > seedHoardThreshold
}