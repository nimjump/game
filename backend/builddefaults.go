package main

// ─────────────────────────────────────────────────────────────────────────────
// Build-time defaults — the four values below ARE the repo's defaults.
//
// A plain `go build ./backend` therefore produces a backend that:
//   • listens on IPv6 ONLY (tcp6, `::`)          → IPV6_ONLY=true, BIND_HOST=::
//   • already knows the game/backend public URLs  → GAME_URL / BACKEND_URL
//   • and needs no .env for any of that.
//
// Real environment variables and backend/.env ALWAYS win: applyBuildDefaults()
// only fills in what is still empty, and it runs after loadEnv().
//
// The Nimiq RPC endpoint is the one thing that is NOT baked into the source on
// purpose. This repository is public: committing the relay's path secret and
// its HMAC signing key would hand every reader a working key to the Worker and
// make the whole hardening pointless (WAF + HMAC would still "work", just for
// anyone). Those two values are injected into the release build instead, via
// -ldflags, by backend/build-release.sh:
//
//   ./build-release.sh            # reads ../release/cloudflare-worker.env
//   # or: NIMJUMP_RPC_URL=… NIMJUMP_RPC_HMAC_SECRET=… ./build-release.sh
//
// The resulting binary runs with NO .env at all (only the wallet key still
// needs to be supplied by you — it is a secret only you have).
// ─────────────────────────────────────────────────────────────────────────────

import (
	"fmt"
	"log"
	"os"
	"strings"
)

// Defaults committed to the repo. `-ldflags -X main.bdXxx=...` overrides any
// of them at build time (that is how the RPC URL + HMAC key are added).
var (
	bdGameURL    = "https://nimjump.zetashare.com"  // GAME_URL
	bdBackendURL = "https://backbone.zetashare.com" // BACKEND_URL
	bdRPCURL     string                             // NIMIQ_RPC_URL      (injected at release build)
	bdRPCHMAC    string                             // NIMIQ_RPC_HMAC_SECRET (injected at release build)
	bdBindHost   = "::"                             // BIND_HOST — IPv6 wildcard
	bdIPv6Only   = "true"                           // IPV6_ONLY — listener network = tcp6
)

// applyBuildDefaults fills missing env vars from the values above. Must run
// AFTER loadEnv() (a real .env always wins) and BEFORE handlers.InitURLs().
func applyBuildDefaults() {
	defaults := []struct {
		key   string
		value string
	}{
		{"GAME_URL", bdGameURL},
		{"BACKEND_URL", bdBackendURL},
		{"NIMIQ_RPC_URL", bdRPCURL},
		{"NIMIQ_RPC_HMAC_SECRET", bdRPCHMAC},
		{"BIND_HOST", bdBindHost},
		{"IPV6_ONLY", bdIPv6Only},
	}

	var applied []string
	for _, d := range defaults {
		if strings.TrimSpace(d.value) == "" {
			continue // nothing baked in / nothing set in this build
		}
		if strings.TrimSpace(os.Getenv(d.key)) != "" {
			continue // .env or a real env var wins
		}
		if err := os.Setenv(d.key, d.value); err != nil {
			log.Printf("[BUILTIN] could not set %s: %v", d.key, err)
			continue
		}
		// Never print secrets; show that they came from the binary, not a file.
		up := strings.ToUpper(d.key)
		if strings.Contains(up, "SECRET") || strings.Contains(up, "HMAC") || strings.Contains(up, "KEY") {
			applied = append(applied, d.key+"=<baked, hidden>")
		} else if d.key == "NIMIQ_RPC_URL" {
			// show scheme+host only, never the secret path
			shown := d.value
			if i := strings.Index(shown, "://"); i >= 0 {
				rest := shown[i+3:]
				if j := strings.Index(rest, "/"); j >= 0 {
					shown = shown[:i+3] + rest[:j] + "/<secret>"
				}
			}
			applied = append(applied, d.key+"="+shown)
		} else {
			applied = append(applied, d.key+"="+d.value)
		}
	}
	if len(applied) > 0 {
		fmt.Printf("  [BUILTIN] defaults from the binary (override with .env): %s\n", strings.Join(applied, ", "))
	}
}
