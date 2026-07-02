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
  allowedDevOrigins: ['n3zydebg87.loclx.io'],


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