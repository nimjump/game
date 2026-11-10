#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NimJump — verify that THIS host can reach the Nimiq RPC, and tell you exactly
# which layer is broken if it can't.
#
# Run it on the game server, after every change to .env / NAT64 / proxy:
#
#   ./check-rpc.sh                    # use .env / NIMIQ_RPC_* as-is
#   ./check-rpc.sh -network nat64     # test the NAT64 path
#   ./check-rpc.sh -url http://[2001:db8::5]:8848/SECRET
#
# Exit code 0 = the RPC answered. 1 = it didn't (the output says why).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="${BACKEND_DIR:-$HERE/../../backend}"

echo "══ 1. address families on this host ═══════════════════════════════════"
ip -brief addr show scope global 2>/dev/null | sed 's/^/   /' || true
if ip -4 route show default 2>/dev/null | grep -q .; then
  echo "   default IPv4 route: yes"
else
  echo "   default IPv4 route: NONE  → this is an IPv6-only host (as intended)"
fi
if ip -6 route show default 2>/dev/null | grep -q .; then
  echo "   default IPv6 route: yes"
else
  echo "   default IPv6 route: NONE  ⚠ no IPv6 either — nothing will work"
fi

echo
echo "══ 2. DNS for the RPC host ═════════════════════════════════════════════"
HOSTNAME_=$(echo "${NIMIQ_RPC_URL:-https://rpc.nimiqwatch.com}" | sed -e 's|^https\{0,1\}://||' -e 's|/.*||' -e 's|^\[||' -e 's|\].*||' -e 's|:.*||')
echo "   host: $HOSTNAME_"
getent ahostsv4 "$HOSTNAME_" 2>/dev/null | awk '{print "   A:    "$1}' | sort -u
getent ahostsv6 "$HOSTNAME_" 2>/dev/null | awk '{print "   AAAA: "$1}' | sort -u
if ! getent ahostsv6 "$HOSTNAME_" >/dev/null 2>&1; then
  echo "   AAAA: none  → IPv4-only endpoint: needs NAT64, a proxy, or a relay"
fi
echo "   (resolver: $( (resolvectl status 2>/dev/null | awk '/Current DNS Server/{print $4; exit}') || grep -m1 nameserver /etc/resolv.conf | awk '{print $2}' ))"

echo
echo "══ 3. raw TCP probes ═══════════════════════════════════════════════════"
tcp_probe() { # host port label
  if timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
    echo "   ✓ $3 ($1:$2)"
  else
    echo "   ✗ $3 ($1:$2)"
  fi
}
V4=$(getent ahostsv4 "$HOSTNAME_" 2>/dev/null | awk 'NR==1{print $1}')
[ -n "${V4:-}" ] && tcp_probe "$V4" 443 "direct IPv4 to the RPC (works only if this host has IPv4)"
[ -n "${V4:-}" ] && tcp_probe "64:ff9b::$V4" 443 "NAT64 via the well-known prefix 64:ff9b::/96"
# IPv4 → hex groups for the nat64.net prefix (10.20.30.40 → a14:1e28)
if [ -n "${V4:-}" ]; then
  IFS=. read -r a b c d <<<"$V4"
  EMB=$(printf '%x:%x' $((a*256+b)) $((c*256+d)))
  tcp_probe "2a00:1098:2b::${EMB}" 443 "NAT64 via nat64.net (2a00:1098:2b::/96)"
  tcp_probe "2a00:1098:2c:1::${EMB}" 443 "NAT64 via nat64.net (2a00:1098:2c:1::/96)"
fi
if [ -n "${NIMIQ_RPC_PROXY:-}" ]; then
  PX=$(echo "$NIMIQ_RPC_PROXY" | sed -e 's|^socks5h\{0,1\}://||' -e 's|^http\{0,1\}://||' -e 's|.*@||')
  PH=${PX%%:*}; PP=${PX##*:}
  tcp_probe "$PH" "$PP" "proxy from NIMIQ_RPC_PROXY"
fi

echo
echo "══ 4. real JSON-RPC call through the backend's own client ══════════════"
cd "$BACKEND" 2>/dev/null || { echo "   ⚠ backend dir not found ($BACKEND) — skipping"; exit 1; }
if [ -f .env ]; then
  echo "   (loading .env)"
  set -a; . ./.env 2>/dev/null; set +a
fi
GO=${GO:-go}
command -v "$GO" >/dev/null || { echo "   ⚠ go not installed — install Go 1.21+ or run the compiled binary"; exit 1; }
"$GO" run ./cmd/rpccheck "$@"
