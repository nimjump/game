#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NimJump — "zero-env" release build.
#
# Produces binaries that need NO .env at all: the Cloudflare Worker RPC endpoint
# (URL + HMAC signing key), the public GAME_URL/BACKEND_URL and IPv6-only
# listening are compiled in. Everything can still be overridden at runtime by a
# .env or real env vars.
#
# Usage:
#   ./build-release.sh                              # reads ../release/cloudflare-worker.env
#   NIMJUMP_RPC_URL=... NIMJUMP_RPC_HMAC_SECRET=... ./build-release.sh
#
# Output: ../release/nimjump-backend-linux-{amd64,arm64}
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="${NIMJUMP_OUT_DIR:-../../release}"   # outside the repo by default
SECRETS_FILE="${NIMJUMP_SECRETS_FILE:-}"
if [ -z "$SECRETS_FILE" ]; then
  for cand in ../../release/cloudflare-worker.env ../release/cloudflare-worker.env; do
    [ -f "$cand" ] && SECRETS_FILE="$cand" && break
  done
fi
if [ -z "${NIMJUMP_RPC_URL:-}" ] && [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$SECRETS_FILE"; set +a
  NIMJUMP_RPC_URL="${NIMIQ_RPC_URL:-}"
  NIMJUMP_RPC_HMAC_SECRET="${NIMIQ_RPC_HMAC_SECRET:-}"
fi

if [ -z "${NIMJUMP_RPC_URL:-}" ] || [ -z "${NIMJUMP_RPC_HMAC_SECRET:-}" ]; then
  echo "✗ NIMJUMP_RPC_URL / NIMJUMP_RPC_HMAC_SECRET bulunamadı." >&2
  echo "  ${SECRETS_FILE:-cloudflare-worker.env} bulunamadı — env olarak ver ya da:" >&2
  echo "  NIMJUMP_RPC_URL=https://rpc.nimiqbase.com/<SECRET> NIMJUMP_RPC_HMAC_SECRET=<HMAC> $0" >&2
  exit 1
fi

LDF="-s -w"
LDF="$LDF -X main.bdRPCURL=$NIMJUMP_RPC_URL"
LDF="$LDF -X main.bdRPCHMAC=$NIMJUMP_RPC_HMAC_SECRET"
LDF="$LDF -X main.bdRPCLock=true"   # stale admin-panel RPC URL can never win
[ -n "${NIMJUMP_GAME_URL:-}" ]    && LDF="$LDF -X main.bdGameURL=$NIMJUMP_GAME_URL"
[ -n "${NIMJUMP_BACKEND_URL:-}" ] && LDF="$LDF -X main.bdBackendURL=$NIMJUMP_BACKEND_URL"

mkdir -p "$OUT_DIR"
for arch in amd64 arm64; do
  echo "→ linux/$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "$LDF" \
    -o "$OUT_DIR/nimjump-backend-linux-$arch" .
done
chmod +x "$OUT_DIR"/nimjump-backend-linux-*

echo
echo "✓ hazır:"
ls -lh "$OUT_DIR"/nimjump-backend-linux-*
echo
echo "Binary içinde gömülü RPC host'u doğrula:"
echo "  strings $OUT_DIR/nimjump-backend-linux-amd64 | grep -o 'rpc\\.[a-z0-9.]*' | sort -u"
