package game

// utils.go — game paketi içi ortak yardımcı fonksiyonlar
//
// handlers paketindeki min8 ile aynı mantık;
// game paketinde min8s adıyla kullanılıyor (daily_earn_cap.go, vb.)

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
