// Server-side Nimiq identicon generator.
// Runs in Node (SSR) — no browser APIs needed.
// Uses the official @nimiq/identicons CJS bundle + dom-parser.

// eslint-disable-next-line @typescript-eslint/no-require-imports
const IdenticonsCJS = require("@nimiq/identicons/dist/identicons.bundle.cjs.js");
// eslint-disable-next-line @typescript-eslint/no-require-imports
const DOMParserLib = require("dom-parser");
const fs = require("fs");
const path = require("path");

// Inject DOMParser shim and pre-load the SVG sprite as a global
// so the library skips its own fetch() call.
if (typeof globalThis.DOMParser === "undefined") {
  (globalThis as Record<string, unknown>).DOMParser = DOMParserLib;
}
if (typeof (globalThis as Record<string, unknown>).IdenticonsAssets === "undefined") {
  try {
    const spritePath = path.join(process.cwd(), "public", "identicons.min.svg");
    (globalThis as Record<string, unknown>).IdenticonsAssets = fs.readFileSync(spritePath, "utf8");
  } catch {
    // ignore — will fall back to fetch in browser
  }
}

const Identicons = IdenticonsCJS.default ?? IdenticonsCJS;

/** Generate a Nimiq identicon SVG string for the given address. */
export async function nimiqSvg(address: string): Promise<string> {
  const raw: string = await Identicons.svg(address);
  // Remove hard-coded width/height so the SVG scales with CSS.
  return raw.replace(/\s(width|height)="[^"]*"/g, "");
}
