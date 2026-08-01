package game

// player_ip.go — tracks which IP(s) each player has actually connected
// from, and lazily resolves each IP to a country (with a shared, IP-keyed
// cache so the same IP is never looked up twice). Powers the admin panel's
// per-player "connection IPs" list (see handlers/admin_player.go).
//
// Recording (RecordPlayerIP) happens at auth time (handleAuthVerify /
// handleAuthMe — same touchpoints as SetPlayerDevice/RecordDailyActivity),
// fire-and-forget, never blocks or fails a login. Country resolution
// (GetIPGeo) is lazy — done on-demand when an admin actually opens a
// player's detail view, not on every login, so normal gameplay never makes
// an outbound HTTP call.

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	badger "github.com/dgraph-io/badger/v4"
)

const (
	keyPlayerIPPfx = "playerip:" // + playerID + "\x00" + ip
	keyIPGeoPfx    = "ipgeo:"    // + ip
)

type PlayerIPRecord struct {
	PlayerID  string `json:"player_id"`
	IP        string `json:"ip"`
	FirstSeen int64  `json:"first_seen"`
	LastSeen  int64  `json:"last_seen"`
	Count     int    `json:"count"` // how many successful auth events from this IP
}

func playerIPKey(playerID, ip string) []byte {
	return []byte(keyPlayerIPPfx + playerID + "\x00" + ip)
}

// RecordPlayerIP — upserts the IP a player just authenticated from. Safe to
// call on every auth verify/restore (cheap single-key read-modify-write,
// same pattern as RecordDailyActivity).
func (s *Store) RecordPlayerIP(playerID, ip string) error {
	if playerID == "" || ip == "" {
		return nil
	}
	now := time.Now().Unix()
	return s.db.Update(func(txn *badger.Txn) error {
		key := playerIPKey(playerID, ip)
		var rec PlayerIPRecord
		item, gerr := txn.Get(key)
		if gerr == nil {
			_ = item.Value(func(v []byte) error { return json.Unmarshal(v, &rec) })
		} else if gerr != badger.ErrKeyNotFound {
			return gerr
		}
		if rec.FirstSeen == 0 {
			rec.FirstSeen = now
		}
		rec.PlayerID = playerID
		rec.IP = ip
		rec.LastSeen = now
		rec.Count++
		data, merr := json.Marshal(rec)
		if merr != nil {
			return merr
		}
		return txn.Set(key, data)
	})
}

// ListPlayerIPs — every IP a player has ever authenticated from, most
// recently seen first.
func (s *Store) ListPlayerIPs(playerID string) []PlayerIPRecord {
	if playerID == "" {
		return nil
	}
	pfx := []byte(keyPlayerIPPfx + playerID + "\x00")
	var out []PlayerIPRecord
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = pfx
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.ValidForPrefix(pfx); it.Next() {
			var rec PlayerIPRecord
			_ = it.Item().Value(func(v []byte) error { return json.Unmarshal(v, &rec) })
			out = append(out, rec)
		}
		return nil
	})
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].LastSeen > out[i].LastSeen {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

// ── Geolocation (lazy, IP-keyed cache) ──────────────────────────────────

type IPGeo struct {
	IP          string `json:"ip"`
	CountryCode string `json:"country_code"` // ISO 3166-1 alpha-2, "" if unknown, "XX" for private/local
	CountryName string `json:"country_name"`
	ResolvedAt  int64  `json:"resolved_at"`
}

func ipGeoKey(ip string) []byte { return []byte(keyIPGeoPfx + ip) }

var ipGeoHTTPClient = &http.Client{Timeout: 3 * time.Second}

// GetIPGeo — country for a single IP, cached forever once resolved (a
// residential/hosting IP's country essentially never changes, and this is
// informational-only, not security-relevant, so no TTL/refresh logic).
// Private/loopback/reserved IPs (localhost dev, LAN testing) are recognized
// locally and never sent to the external lookup at all.
func (s *Store) GetIPGeo(ip string) IPGeo {
	if ip == "" {
		return IPGeo{}
	}
	if cached, ok := s.getCachedIPGeo(ip); ok {
		return cached
	}

	parsed := net.ParseIP(ip)
	if parsed != nil && (parsed.IsPrivate() || parsed.IsLoopback() || parsed.IsLinkLocalUnicast() || parsed.IsUnspecified()) {
		geo := IPGeo{IP: ip, CountryCode: "XX", CountryName: "Private/Local", ResolvedAt: time.Now().Unix()}
		s.setCachedIPGeo(geo)
		return geo
	}

	geo := s.lookupIPGeoRemote(ip)
	s.setCachedIPGeo(geo)
	return geo
}

func (s *Store) getCachedIPGeo(ip string) (IPGeo, bool) {
	var geo IPGeo
	found := false
	_ = s.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(ipGeoKey(ip))
		if err != nil {
			return err
		}
		found = true
		return item.Value(func(v []byte) error { return json.Unmarshal(v, &geo) })
	})
	return geo, found
}

func (s *Store) setCachedIPGeo(geo IPGeo) {
	data, err := json.Marshal(geo)
	if err != nil {
		return
	}
	_ = s.db.Update(func(txn *badger.Txn) error {
		return txn.Set(ipGeoKey(geo.IP), data)
	})
}

// lookupIPGeoRemote — free, no-API-key IP→country lookup (ip-api.com's
// non-commercial free tier: HTTP only, ~45 req/min). Only ever hit once per
// distinct IP thanks to the cache above (an admin re-opening the same
// player's profile costs zero extra requests). Best-effort: any failure
// (network, rate limit, malformed response) returns an "unknown" record
// that's still cached, so a broken lookup doesn't get silently retried on
// every single admin page load either.
func (s *Store) lookupIPGeoRemote(ip string) IPGeo {
	now := time.Now().Unix()
	unknown := IPGeo{IP: ip, CountryCode: "", CountryName: "Unknown", ResolvedAt: now}

	resp, err := ipGeoHTTPClient.Get("http://ip-api.com/json/" + ip + "?fields=status,countryCode,country")
	if err != nil {
		return unknown
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return unknown
	}

	var body struct {
		Status      string `json:"status"`
		CountryCode string `json:"countryCode"`
		Country     string `json:"country"`
	}
	if derr := json.NewDecoder(resp.Body).Decode(&body); derr != nil {
		return unknown
	}
	if !strings.EqualFold(body.Status, "success") || body.CountryCode == "" {
		return unknown
	}
	return IPGeo{IP: ip, CountryCode: body.CountryCode, CountryName: body.Country, ResolvedAt: now}
}

// ── Country breakdown (admin "where are our players from" view) ────────────

// CountryBreakdownEntry — one row of the admin "players by country" view.
type CountryBreakdownEntry struct {
	CountryCode string `json:"country_code"`
	CountryName string `json:"country_name"`
	Count       int    `json:"count"`
}

// countryBreakdownResolveWorkers — how many IP→country lookups run
// concurrently when this is called with a lot of never-before-seen IPs
// (fresh deploy, or right after a traffic spike of new players). Each
// individual lookup is capped at 3s (ipGeoHTTPClient's timeout) and, once
// resolved, is cached forever (GetIPGeo) — so this concurrency limit only
// ever matters for the FIRST admin page load after a batch of new IPs shows
// up; every later call is pulling from cache and is effectively instant.
const countryBreakdownResolveWorkers = 8

// CountryBreakdown — how many distinct players last connected from each
// country (by their most-recently-seen IP), sorted by count descending.
// Mirrors DeviceBreakdown's shape/pattern (see device.go) but for
// geography instead of platform. Resolves any not-yet-cached IPs
// concurrently (bounded — see countryBreakdownResolveWorkers) rather than
// one at a time, so a fresh install with many unresolved IPs doesn't make
// the admin wait one network round-trip per player, sequentially.
func (s *Store) CountryBreakdown() []CountryBreakdownEntry {
	// 1. Pick each distinct player's most-recently-seen IP.
	latestIPByPlayer := map[string]PlayerIPRecord{}
	_ = s.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = []byte(keyPlayerIPPfx)
		it := txn.NewIterator(opts)
		defer it.Close()
		for it.Rewind(); it.ValidForPrefix(opts.Prefix); it.Next() {
			_ = it.Item().Value(func(v []byte) error {
				var rec PlayerIPRecord
				if err := json.Unmarshal(v, &rec); err != nil {
					return nil
				}
				if existing, ok := latestIPByPlayer[rec.PlayerID]; !ok || rec.LastSeen > existing.LastSeen {
					latestIPByPlayer[rec.PlayerID] = rec
				}
				return nil
			})
		}
		return nil
	})

	// 2. Resolve each distinct IP to a country — concurrently, bounded.
	distinctIPs := map[string]struct{}{}
	for _, rec := range latestIPByPlayer {
		distinctIPs[rec.IP] = struct{}{}
	}
	geoByIP := make(map[string]IPGeo, len(distinctIPs))
	var geoMu sync.Mutex
	sem := make(chan struct{}, countryBreakdownResolveWorkers)
	var wg sync.WaitGroup
	for ip := range distinctIPs {
		wg.Add(1)
		sem <- struct{}{}
		go func(ip string) {
			defer wg.Done()
			defer func() { <-sem }()
			geo := s.GetIPGeo(ip)
			geoMu.Lock()
			geoByIP[ip] = geo
			geoMu.Unlock()
		}(ip)
	}
	wg.Wait()

	// 3. Aggregate distinct players by country.
	type countryKey struct{ code, name string }
	counts := map[countryKey]int{}
	for _, rec := range latestIPByPlayer {
		geo := geoByIP[rec.IP]
		code, name := geo.CountryCode, geo.CountryName
		if code == "" {
			code, name = "??", "Unknown"
		}
		counts[countryKey{code, name}]++
	}
	out := make([]CountryBreakdownEntry, 0, len(counts))
	for k, v := range counts {
		out = append(out, CountryBreakdownEntry{CountryCode: k.code, CountryName: k.name, Count: v})
	}
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].Count > out[i].Count {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}
