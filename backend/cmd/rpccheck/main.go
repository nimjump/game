// Command rpccheck diagnoses Nimiq JSON-RPC reachability from THIS host.
//
// It is the tool you run on the server when payouts stop working:
//
//	# default: use whatever the backend env would use
//	go run ./cmd/rpccheck
//
//	# "why can't my IPv6-only box reach the RPC?"
//	go run ./cmd/rpccheck -network nat64
//
//	# is my SOCKS tunnel / proxy the problem?
//	go run ./cmd/rpccheck -proxy socks5://127.0.0.1:1080
//
//	# pure reachability test of any endpoint
//	go run ./cmd/rpccheck -url https://rpc.nimiqwatch.com -method getBlockNumber
//
// It prints DNS records, the exact address family used, the block height and
// the full transport diagnostics (endpoint health, last error per endpoint).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"time"

	"nimjump-backend/game"
)

func main() {
	rpcURL := flag.String("url", envOr("NIMIQ_RPC_URL", "https://rpc.nimiqwatch.com"), "RPC endpoint to test")
	network := flag.String("network", envOr("NIMIQ_RPC_NETWORK", ""), "auto | ipv6 | ipv4 | nat64 (overrides NIMIQ_RPC_NETWORK)")
	nat64 := flag.String("nat64-prefix", envOr("NIMIQ_NAT64_PREFIX", ""), "NAT64 prefix, default 64:ff9b::/96")
	proxy := flag.String("proxy", envOr("NIMIQ_RPC_PROXY", ""), "socks5://host:port or http://host:port")
	method := flag.String("method", "getBlockNumber", "JSON-RPC method to call")
	flag.Parse()

	// Apply flags as env so the backend's own config reader sees them —
	// this tests exactly the code path the backend uses.
	if *network != "" {
		os.Setenv("NIMIQ_RPC_NETWORK", *network)
	}
	if *nat64 != "" {
		os.Setenv("NIMIQ_NAT64_PREFIX", *nat64)
	}
	if *proxy != "" {
		os.Setenv("NIMIQ_RPC_PROXY", *proxy)
	}
	os.Setenv("NIMIQ_RPC_URL", *rpcURL)
	os.Setenv("NIMIQ_RPC_MAX_RETRIES", "0") // fast, honest single attempt
	os.Setenv("NIMIQ_RPC_BLOCK_CACHE_MS", "0")

	fmt.Println("── host connectivity ────────────────────────────────────────────")
	printLocalFamilies()

	fmt.Println("\n── DNS ─────────────────────────────────────────────────────────")
	host := hostOf(*rpcURL)
	printDNS(host)

	fmt.Printf("\n── JSON-RPC %s via %s ────────────────────────────\n", *method, *rpcURL)
	start := time.Now()
	res, err := game.NimiqRPCCallForDiagnostics(*rpcURL, *method)
	elapsed := time.Since(start).Round(time.Millisecond)
	if err != nil {
		fmt.Printf("✗ FAILED in %s\n  %v\n", elapsed, err)
	} else {
		b, _ := json.Marshal(res)
		fmt.Printf("✓ OK in %s\n  result: %s\n", elapsed, truncate(string(b), 300))
	}

	fmt.Println("\n── transport diagnostics ───────────────────────────────────────")
	diag := game.RPCDiagnostics(*rpcURL)
	b, _ := json.MarshalIndent(diag, "", "  ")
	fmt.Println(string(b))

	if err != nil {
		fmt.Println("\n── what to do ──────────────────────────────────────────────────")
		hint(strings.ToLower(err.Error()))
		os.Exit(1)
	}
}

func hint(errText string) {
	switch {
	case strings.Contains(errText, "no aaaa record"):
		fmt.Println("The endpoint is IPv4-only and this host looks IPv6-only.")
		fmt.Println("Options (see setup/ipv6-only/README.md):")
		fmt.Println("  1) NAT64:  set NIMIQ_RPC_NETWORK=nat64 and make sure a NAT64 route exists")
		fmt.Println("             (clatd / tayga / jool — script: setup/ipv6-only/setup-clat.sh)")
		fmt.Println("  2) Proxy:  NIMIQ_RPC_PROXY=socks5://127.0.0.1:1080 via a dual-stack box")
		fmt.Println("  3) Relay:  your own IPv6→IPv4 reverse proxy (setup/ipv6-only/relay/)")
	case strings.Contains(errText, "nat64"):
		fmt.Println("DNS resolves, but the translated address is not reachable.")
		fmt.Println("Check: ip -6 route get 64:ff9b::<ipv4>   (needs a /96 route to your NAT64)")
		fmt.Println("Or use the proxy/relay options instead.")
	case strings.Contains(errText, "socks5"):
		fmt.Println("The SOCKS tunnel is the problem, not the RPC. Verify the tunnel process,")
		fmt.Println("credentials in NIMIQ_RPC_PROXY, and that the proxy itself has IPv4.")
	case strings.Contains(errText, "network is unreachable"):
		fmt.Println("This host has no route for the address family being used.")
		fmt.Println("For IPv6-only hosts use NIMIQ_RPC_NETWORK=nat64 or a proxy.")
	default:
		fmt.Println("Run with -network auto/ipv6/nat64 to see which layer fails.")
	}
}

func printLocalFamilies() {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		fmt.Println("  (could not list interfaces:", err, ")")
		return
	}
	var v4, v6 []string
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() {
			continue
		}
		if ipnet.IP.To4() != nil {
			v4 = append(v4, ipnet.String())
		} else {
			v6 = append(v6, ipnet.String())
		}
	}
	sort.Strings(v4)
	sort.Strings(v6)
	if len(v4) == 0 {
		fmt.Println("  IPv4: none (IPv6-only host — expected)")
	} else {
		fmt.Println("  IPv4:", strings.Join(v4, ", "))
	}
	if len(v6) == 0 {
		fmt.Println("  IPv6: none (!)")
	} else {
		fmt.Println("  IPv6:", strings.Join(v6, ", "))
	}
	fmt.Println("  64:ff9b::/96 route:", nat64Route())
}

func nat64Route() string {
	c, err := net.Dial("udp", "[64:ff9b::808:808]:80")
	if err != nil {
		return "no (" + err.Error() + ")"
	}
	c.Close()
	return "yes"
}

func printDNS(host string) {
	if net.ParseIP(host) != nil {
		fmt.Printf("  %s is a literal IP\n", host)
		return
	}
	a, errA := net.LookupIP(host)
	_ = errA
	var v4, v6 []string
	for _, ip := range a {
		if ip.To4() != nil {
			v4 = append(v4, ip.String())
		} else {
			v6 = append(v6, ip.String())
		}
	}
	if len(v4) == 0 {
		fmt.Println("  A:    none")
	} else {
		fmt.Println("  A:   ", strings.Join(v4, ", "))
	}
	if len(v6) == 0 {
		fmt.Println("  AAAA: none  ← IPv4-only endpoint; an IPv6-only host needs NAT64/proxy")
	} else {
		fmt.Println("  AAAA:", strings.Join(v6, ", "))
	}
}

func hostOf(raw string) string {
	s := raw
	for _, p := range []string{"https://", "http://"} {
		s = strings.TrimPrefix(s, p)
	}
	if i := strings.IndexAny(s, "/"); i >= 0 {
		s = s[:i]
	}
	if h, _, err := net.SplitHostPort(s); err == nil {
		return h
	}
	return s
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
