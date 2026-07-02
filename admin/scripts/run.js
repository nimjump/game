#!/usr/bin/env node
// run.js — launches `next dev` / `next start` on the port from admin/.env
// (ADMIN_PORT), instead of a port hardcoded in package.json. Cross-platform
// (pure Node + child_process), so it works the same on Windows/macOS/Linux
// where "${VAR:-default}" shell syntax in package.json scripts would not.
const path = require("path");
const { spawnSync } = require("child_process");

require("./load-env")();

const mode = process.argv[2]; // "dev" | "start"
if (mode !== "dev" && mode !== "start") {
  console.error("usage: node scripts/run.js <dev|start>");
  process.exit(1);
}

const port = process.env.ADMIN_PORT || "3001";
const nextBin = require.resolve("next/dist/bin/next");

console.log(`[admin] ${mode} on port ${port} (ADMIN_PORT, from admin/.env) — base path ${process.env.ADMIN_BASE_PATH || "/admin"} (ADMIN_BASE_PATH)`);

const res = spawnSync(process.execPath, [nextBin, mode, "-p", port], {
  stdio: "inherit",
  env: process.env,
  cwd: path.join(__dirname, ".."),
});
process.exit(res.status === null ? 1 : res.status);
