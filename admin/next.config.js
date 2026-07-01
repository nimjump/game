/** @type {import("next").NextConfig} */
module.exports = {
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