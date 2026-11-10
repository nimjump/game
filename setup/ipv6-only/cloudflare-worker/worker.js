// ─────────────────────────────────────────────────────────────────────────────
// NimJump RPC bridge — HARDENED Cloudflare Worker
//
// Purpose: let an IPv6-only game server reach the IPv4-only Nimiq RPC
// (rpc.nimiqwatch.com has an A record and no AAAA) with zero IPv4 address on
// the game server and zero inbound ports opened on it.
//
// *.workers.dev is dual-stack → the game server reaches Cloudflare over IPv6,
// the Worker then fetches the RPC from Cloudflare's IPv4-capable edge.
//
// HARDENING (assume the URL WILL leak — workers.dev names are enumerable):
//
//   1. Path secret      — only POST /<RELAY_SECRET> exists. Everything else is
//                         a plain 404 with no hint that this is a relay.
//   2. HMAC signature   — every request must carry:
//                            X-NJ-Ts : unix seconds
//                            X-NJ-Sig: hex HMAC-SHA256(HMAC_SECRET, ts + "." + body)
//                         Signature covers the timestamp AND the exact body, with
//                         a ±60 s window, so a leaked URL is useless without the
//                         key and a captured request can't be replayed later.
//                         Comparison is constant-time.
//   3. Method allowlist — only the five JSON-RPC methods this game actually
//                         calls reach the upstream. Nothing else can use the
//                         relay as a free Nimiq node.
//   4. Optional IP pin  — set ALLOWED_IP_PREFIXES to your game server's IPv6
//                         (e.g. "2a01:4f8:c0c:1234::/64" or a bare address).
//                         Anyone else gets 403 even with a valid signature.
//   5. Rate limits      — per-IP and global token buckets per isolate, plus a
//                         hard body-size cap and an upstream timeout.
//   6. No echo          — upstream 5xx/HTML bodies are never returned verbatim
//                         (an error page from a prober must not become a JSON
//                         "answer" for the backend); a short error id is logged
//                         instead.
//
// Bindings (wrangler secret put / dashboard):
//   RELAY_SECRET         required  — the secret path segment
//   HMAC_SECRET          required  — signing key shared with the backend
//   UPSTREAM             optional  — default https://rpc.nimiqwatch.com
//   ALLOWED_METHODS      optional  — comma list; default = the 5 methods below
//   ALLOWED_IP_PREFIXES  optional  — comma list of IPs/CIDR-lite prefixes
//   MAX_REQ_PER_MIN_IP   optional  — default 240
//   MAX_REQ_PER_MIN_ALL  optional  — default 3000
//
// Backend side (.env):
//   NIMIQ_RPC_URL=https://<name>.<subdomain>.workers.dev/<RELAY_SECRET>
//   NIMIQ_RPC_HMAC_SECRET=<HMAC_SECRET>
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_METHODS = [
  'getBlockNumber',
  'getAccountByAddress',
  'pushTransaction',
  'getTransactionByHash',
  'getTransactionsByAddress',
];

const TS_WINDOW_SECONDS = 60;
const MAX_BODY_BYTES = 100_000; // a signed Nimiq tx is ~a few hundred bytes

// Per-isolate, best-effort buckets (Cloudflare may run many isolates; this is
// a cheap first line of defence, the real limits belong on the account's
// rate-limiting rules).
const buckets = new Map();

function rateOk(key, perMinute) {
  if (!perMinute) return true;
  const now = Date.now();
  const cap = Math.max(10, perMinute);
  let b = buckets.get(key);
  if (!b) {
    b = { tokens: cap, last: now };
    buckets.set(key, b);
    if (buckets.size > 10_000) buckets.clear(); // isolate memory guard
  }
  b.tokens = Math.min(cap, b.tokens + ((now - b.last) / 60_000) * perMinute);
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

const enc = new TextEncoder();

async function hmacHex(secret, msg) {
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Constant-time-ish comparison (both sides are fixed-length hex).
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

// Deliberately identical for "wrong path" and "bad signature" probing: a 404
// with an empty-ish body, so scanners learn nothing.
function notFound() {
  return new Response('Not Found', { status: 404, headers: { 'cache-control': 'no-store' } });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // ── 1. path secret ──────────────────────────────────────────────────────
    const relaySecret = (env.RELAY_SECRET || '').trim();
    if (!relaySecret) return new Response('misconfigured', { status: 500 });
    const path = url.pathname.replace(/^\/+|\/+$/g, '');
    if (path !== relaySecret) return notFound();

    // ── 2. shape checks ─────────────────────────────────────────────────────
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'POST' } });
    }
    const ctype = (request.headers.get('content-type') || '').toLowerCase();
    if (!ctype.includes('application/json')) {
      return json({ error: 'content-type must be application/json' }, 415);
    }

    // ── 3. optional IP pin ──────────────────────────────────────────────────
    const ip = request.headers.get('cf-connecting-ip') || '';
    const allowedPrefixes = (env.ALLOWED_IP_PREFIXES || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    if (allowedPrefixes.length && !allowedPrefixes.some((p) => ip === p || ip.startsWith(p))) {
      console.log(`ip rejected: ${ip}`);
      return json({ error: 'forbidden' }, 403);
    }

    // ── 4. rate limits ──────────────────────────────────────────────────────
    const perIp = Number(env.MAX_REQ_PER_MIN_IP || 240);
    const perAll = Number(env.MAX_REQ_PER_MIN_ALL || 3000);
    if (!rateOk(`ip:${ip}`, perIp) || !rateOk('all', perAll)) {
      return json({ error: 'rate limited' }, 429);
    }

    // ── 5. body + signature ─────────────────────────────────────────────────
    const body = await request.text();
    if (!body) return json({ error: 'empty body' }, 400);
    if (body.length > MAX_BODY_BYTES) return json({ error: 'payload too large' }, 413);

    const hmacSecret = (env.HMAC_SECRET || '').trim();
    if (!hmacSecret) return new Response('misconfigured', { status: 500 });

    const ts = request.headers.get('x-nj-ts') || '';
    const sig = (request.headers.get('x-nj-sig') || '').toLowerCase();
    const tsNum = Number(ts);
    if (!ts || !Number.isFinite(tsNum) || Math.abs(Date.now() / 1000 - tsNum) > TS_WINDOW_SECONDS) {
      console.log(`stale/missing ts from ${ip}`);
      return json({ error: 'unauthorized' }, 401);
    }
    const expected = await hmacHex(hmacSecret, `${ts}.${body}`);
    if (!safeEqual(sig, expected)) {
      console.log(`bad signature from ${ip}`);
      return json({ error: 'unauthorized' }, 401);
    }

    // ── 6. JSON-RPC method allowlist ────────────────────────────────────────
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      return json({ error: 'invalid json' }, 400);
    }
    const allowed = (env.ALLOWED_METHODS || DEFAULT_METHODS.join(','))
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    const method = typeof payload?.method === 'string' ? payload.method : '';
    if (!allowed.includes(method)) {
      console.log(`method rejected: ${method || '(none)'} from ${ip}`);
      return json({ error: 'method not allowed' }, 403);
    }

    // ── 7. forward (with timeout) ───────────────────────────────────────────
    const upstream = (env.UPSTREAM || 'https://rpc.nimiqwatch.com').trim();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort('upstream timeout'), 15_000);
    const started = Date.now();
    let resp;
    let text = '';
    try {
      resp = await fetch(upstream, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json',
          'user-agent': 'NimJump-rpc-worker/2.0',
        },
        body,
        redirect: 'manual', // never replay the RPC body to a redirect target
        signal: ctrl.signal,
        cf: { cacheTtl: 0 },
      });
      text = await resp.text();
    } catch (e) {
      clearTimeout(timer);
      console.log(`upstream_fail ${method} ${Date.now() - started}ms ${e}`);
      return json({ error: 'upstream unavailable' }, 502);
    }
    clearTimeout(timer);

    const ms = Date.now() - started;
    if (!resp.ok) {
      // Never leak the upstream body: an HTML error page is not JSON, and
      // echoing it back would look like a successful relay response.
      console.log(`upstream_${resp.status} ${method} ${ms}ms ${text.slice(0, 120)}`);
      return json({ error: 'upstream error', status: resp.status }, 502);
    }
    if (text.length > MAX_BODY_BYTES) {
      console.log(`upstream_body_too_large ${method} ${text.length}`);
      return json({ error: 'upstream response too large' }, 502);
    }

    if (ms > 5000) console.log(`slow ${method} ${ms}ms`);
    return new Response(text, {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  },
};
