package game

import "log"

// utils.go — game paketi içi ortak yardımcı fonksiyonlar
//
// handlers paketindeki min8 ile aynı mantık;
// game paketinde min8s adıyla kullanılıyor (daily_earn_cap.go, vb.)

// SafeGo runs fn in its own goroutine with panic recovery. Without this,
// a panic in ANY background goroutine (bad replay payload, unexpected RPC
// response shape, nil deref, etc.) takes down the entire process — there
// was no recover() anywhere in the codebase before this. name is just a
// label for the log line so a crash-and-recover shows up as
// "[PANIC_RECOVERED] name=... err=..." instead of silently vanishing or
// (worse) killing the server. Use this for any `go func(){...}()` /
// `go s.Method(...)` spawn that isn't already wrapped — it's a drop-in
// replacement for a bare `go`.
func SafeGo(name string, fn func()) {
	go func() {
		SafeCall(name, fn)
	}()
}

// SafeCall runs fn() with panic recovery, WITHOUT spawning a goroutine.
// Use this inside a `for { ...; time.Sleep(...) }` background loop (retry
// loop, VS payment reconciler, balance monitor, etc.) around just the
// per-iteration work — wrapping the whole loop in SafeGo instead would only
// protect against the FIRST panic and then the loop is simply gone forever
// (recover stops the panic but doesn't resume the for-loop it interrupted).
// Calling SafeCall once per iteration means a single bad cycle logs and
// moves on; the loop keeps ticking.
func SafeCall(name string, fn func()) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[PANIC_RECOVERED] name=%s err=%v", name, r)
		}
	}()
	fn()
}

// min8s — string'in ilk 8 karakterini güvenli döner (log için kısaltma).
// Slice panic'ini önler: len(s) < 8 ise tüm uzunluğu döner.
func min8s(s string) int {
	if len(s) < 8 {
		return len(s)
	}
	return 8
}

// clampF64 — float64 değeri [lo, hi] aralığına sıkıştırır.
func clampF64(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// minInt — iki int'in küçüğünü döner.
func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// maxInt — iki int'in büyüğünü döner.
func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
