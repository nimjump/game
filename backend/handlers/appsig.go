package handlers

// appsig.go — app-wide request signing. Every non-admin /backend/* request
// (including the vsroom live/watch WebSocket upgrades — those still start
// as a plain HTTP GET before hijacking) must carry `app_ts` (a Unix
// timestamp) and `app_sig` (an HMAC-SHA256 over the request path + that
// timestamp, keyed by a secret shared with the game client — see
// ApiConfig.gd's APP_SIGNING_KEY and sign_url()). Enforced centrally in
// main.go's corsMiddleware, which wraps literally every route, so there is
// no endpoint that can be reached without it.
//
// Same honesty note as origin.go and vs_live_security.go: the key is baked
// into the compiled/exported game client, which is downloadable by anyone,
// so this is not "impossible to reproduce" for someone willing to pull the
// key out of the WASM/executable — no public web client can have a truly
// unextractable secret. What it DOES reliably stop: the overwhelming
// majority of scripts/bots/scanners that just hit our JSON endpoints
// directly without ever having run the real client, since a random request
// with no signature (or an expired/mismatched one) is rejected before it
// reaches any handler at all.

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strconv"
	"time"
)

// appSigningKey — MUST exactly match ApiConfig.gd's APP_SIGNING_KEY.
const appSigningKey = "nJ9x!kQ7vR2vT8pL0zC5wA1sD4fG6hJ3kM9nB7vX2cQ5wE8rT1yU4iO7pA0sD3fG"

// appSigWindow — generous clock-skew tolerance; this is re-signed fresh on
// every single request (unlike the longer-lived VS watch ticket), so it
// only needs to cover realistic client/server clock drift, not any kind of
// session length.
const appSigWindow = 5 * time.Minute

// AppSigResult — distinguishes WHY a signature check failed, so the client
// can tell a real user "your device's clock looks wrong" (an easy, fixable,
// non-scary problem) apart from a generic rejection, instead of lumping
// every failure into one indistinguishable "network error" toast.
type AppSigResult int

const (
	AppSigOK AppSigResult = iota
	AppSigClockSkew          // signature is otherwise correct — just outside the time window
	AppSigInvalid            // missing, malformed, or genuinely wrong signature
)

// VerifyAppSignature — path must be the exact request path (no query
// string, no host) that the client signed, e.g. "/backend/leaderboard".
// Deliberately checks the HMAC match FIRST, independent of the time
// window, and only reports AppSigClockSkew when the signature is otherwise
// exactly what a real client with a skewed clock would have produced —
// this keeps the distinction meaningful rather than something a crafted
// request could freely claim.
func VerifyAppSignature(path, tsStr, sigHex string) AppSigResult {
	if tsStr == "" || sigHex == "" {
		return AppSigInvalid
	}
	ts, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil {
		return AppSigInvalid
	}
	mac := hmac.New(sha256.New, []byte(appSigningKey))
	mac.Write([]byte(path))
	mac.Write([]byte(":"))
	mac.Write([]byte(tsStr))
	expected := hex.EncodeToString(mac.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(expected), []byte(sigHex)) != 1 {
		return AppSigInvalid
	}
	now := time.Now().Unix()
	skew := int64(appSigWindow.Seconds())
	if ts > now+skew || ts < now-skew {
		return AppSigClockSkew
	}
	return AppSigOK
}
