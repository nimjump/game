// Loads admin/.env into process.env before next.config.js is evaluated
// (scripts/run.js does the same for the dev/start CLI port). Keeps every
// admin-panel setting — port, URL prefix — in .env instead of hardcoded here.
require("./scripts/load-env")();

/** @type {import("next").NextConfig} */
module.exports = {
  // Served behind the backend at http://<host>:<PORT>/<ADMIN_BASE_PATH> —
  // the backend reverse-proxies it (see backend/handlers/admin_proxy.go).
  // Must match ADMIN_BASE_PATH in backend/.env.
  basePath: process.env.ADMIN_BASE_PATH || "/admin",
  // Dev-only HMR/websocket origin allowlist. devtools proxies this app
  // through a fresh, randomly-named Cloudflare Quick Tunnel on every run
  // (see start-dev-tunnels.js) — e.g. gui-contents-covers-plug.trycloudflare.com
  // — so a single hardcoded hostname (leftover from an old localtunnel/
  // loclx.io setup) goes stale the moment the tunnel restarts. Wildcarding
  // the fixed *.trycloudflare.com suffix covers every future tunnel run
  // without needing to hardcode or regenerate this on each launch.
  allowedDevOrigins: ['*.trycloudflare.com', 'localhost', '127.0.0.1'],


  async headers() {
    return [
      // Replay pages — NO COEP so nimjump.io iframe can load
      {
        source: "/replay/:path*",
        headers: [
          { key: "Cross-Origin-Opener-Policy",   value: "unsafe-none" },
          { key: "Cross-Origin-Embedder-Policy",  value: "unsafe-none" },
          { key: "Access-Control-Allow-Origin",   value: "*" },
          { key: "Access-Control-Allow-Methods",  value: "GET, POST, PUT, DELETE, PATCH, OPTIONS" },
          { key: "Access-Control-Allow-Headers",  value: "*" },
          { key: "Content-Security-Policy",
            value: "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:;" },
        ],
      },
      // Everything else — keep COEP for Godot SharedArrayBuffer support
      {
        source: "/:path*",
        headers: [
          { key: "Cross-Origin-Opener-Policy",   value: "same-origin" },
          { key: "Cross-Origin-Embedder-Policy",  value: "require-corp" },
          { key: "Access-Control-Allow-Origin",   value: "*" },
          { key: "Access-Control-Allow-Methods",  value: "GET, POST, PUT, DELETE, PATCH, OPTIONS" },
          { key: "Access-Control-Allow-Headers",  value: "*" },
          { key: "Content-Security-Policy",
            value: "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:;" },
        ],
      },
    ];
  },
};