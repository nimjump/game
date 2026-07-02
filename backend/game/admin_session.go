package game

// admin_session.go — server-side sessions backing the admin panel's login
// page (replaces the old browser-native Basic Auth popup). A session is
// just a random token stored in BadgerDB with a sliding TTL; the cookie
// only ever carries the token, never the password.

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const adminSessionPrefix = "adminsession:"

// AdminSessionTTL — how long a session stays valid after its last use.
// Refreshed on every check (see ValidAdminSession), so an admin actively
// using the panel is never logged out mid-session.
const AdminSessionTTL = 7 * 24 * time.Hour

type adminSessionRecord struct {
	CreatedAt int64 `json:"created_at"`
}

func adminSessionKey(token string) []byte { return []byte(adminSessionPrefix + token) }

func generateAdminSessionToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// CreateAdminSession — call after a successful login. Returns the token to
// put in the cookie.
func (s *Store) CreateAdminSession() (string, error) {
	token, err := generateAdminSessionToken()
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(adminSessionRecord{CreatedAt: time.Now().Unix()})
	if err != nil {
		return "", err
	}
	err = s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(badger.NewEntry(adminSessionKey(token), data).WithTTL(AdminSessionTTL))
	})
	if err != nil {
		return "", err
	}
	return token, nil
}

// ValidAdminSession — does this token correspond to a live session? If so,
// its TTL is refreshed (sliding expiry).
func (s *Store) ValidAdminSession(token string) bool {
	if token == "" {
		return false
	}
	var data []byte
	err := s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(adminSessionKey(token))
		if err != nil {
			return err
		}
		return item.Value(func(v []byte) error {
			data = append([]byte(nil), v...)
			return nil
		})
	})
	if err != nil {
		return false
	}
	_ = s.db.Update(func(txn *badger.Txn) error {
		return txn.SetEntry(badger.NewEntry(adminSessionKey(token), data).WithTTL(AdminSessionTTL))
	})
	return true
}

// DeleteAdminSession — call on logout. No-op if the token is empty/unknown.
func (s *Store) DeleteAdminSession(token string) {
	if token == "" {
		return
	}
	_ = s.db.Update(func(txn *badger.Txn) error {
		return txn.Delete(adminSessionKey(token))
	})
}
