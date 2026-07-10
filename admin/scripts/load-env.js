// load-env.js — tiny dependency-free .env loader.
//
// Reads admin/.env (and admin/.env.production when NODE_ENV=production)
// into process.env, without overwriting variables that are already set
// (real env vars always win — same rule the backend's loadEnv() in
// backend/main.go follows). Used by next.config.js and scripts/run.js so
// ADMIN_PORT / ADMIN_BASE_PATH live only in .env, never hardcoded in code.
const fs = require("fs");
const path = require("path");

function parseLine(line, out) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) return;
  const eq = trimmed.indexOf("=");
  if (eq === -1) return;
  const key = trimmed.slice(0, eq).trim();
  let val = trimmed.slice(eq + 1).trim();
  val = val.replace(/^["']|["']$/g, "");
  out[key] = val;
}

function loadFile(file, skip) {
  if (!fs.existsSync(file)) return;
  const parsed = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    parseLine(line, parsed);
  }
  for (const [key, val] of Object.entries(parsed)) {
    // BUG FIX: this used to check `process.env[key] === undefined ||
    // process.env[key] === ""` — treating a deliberately-BLANK real env
    // var the same as "not set" and overwriting it anyway. That broke two
    // things at once: (1) admin/.env.production's own
    // NEXT_PUBLIC_BACKEND_URL="" (meant to make production's same-origin
    // build use a relative URL) never actually took effect, because .env
    // was loaded first and always filled in its own non-blank
    // (production-backend) value before .env.production ever got a
    // chance — see the ordering fix below; (2) devtools passing
    // NEXT_PUBLIC_BACKEND_URL: '' as a real spawn env var (to mean "same-
    // origin, relative — see start-dev-tunnels.js's buildAdminApp") got
    // silently clobbered right back to the real production backend URL
    // by this very loadFile("./.env") call, which is exactly why the
    // built admin app kept calling https://backbone.zetashare.com instead
    // of a relative path even after that override was added. `skip`
    // tracks every key that's already meaningfully set (real env vars
    // present before this module ever ran, PLUS anything already filled
    // in by a higher-precedence file below) — an intentionally-blank
    // value counts as "set" and is never overwritten again.
    if (skip.has(key)) continue;
    process.env[key] = val;
    skip.add(key);
  }
}

module.exports = function loadEnv() {
  const root = path.join(__dirname, "..");
  // Real env vars — including ones deliberately set to "" by whatever
  // spawned this process — always win over anything in a file. Snapshot
  // which keys already exist BEFORE loading any file.
  const skip = new Set(Object.keys(process.env));
  // .env.production overrides .env in production (standard dotenv
  // layering: the more specific file wins) — load it FIRST so the keys it
  // sets get added to `skip` before plain .env is loaded, instead of the
  // previous order where .env always loaded first and .env.production's
  // overrides could never actually apply.
  if (process.env.NODE_ENV === "production") {
    loadFile(path.join(root, ".env.production"), skip);
  }
  loadFile(path.join(root, ".env"), skip);
};
