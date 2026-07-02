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

function loadFile(file) {
  if (!fs.existsSync(file)) return;
  const parsed = {};
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    parseLine(line, parsed);
  }
  for (const [key, val] of Object.entries(parsed)) {
    if (process.env[key] === undefined || process.env[key] === "") {
      process.env[key] = val;
    }
  }
}

module.exports = function loadEnv() {
  const root = path.join(__dirname, "..");
  loadFile(path.join(root, ".env"));
  if (process.env.NODE_ENV === "production") {
    loadFile(path.join(root, ".env.production"));
  }
};
