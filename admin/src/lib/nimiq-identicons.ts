// @nimiq/identicons and dom-parser ship no TypeScript declarations of their
// own (verified against the published package: no .d.ts in dist/, no
// "types"/"typings" field in package.json). Without this file, strict
// TypeScript builds (as used by `next build`) fail with:
//   "Could not find a declaration file for module '@nimiq/identicons/...'"
// on every import site (NimiqAvatar.tsx, nimiq-identicons.ts).

declare module "@nimiq/identicons/dist/identicons.bundle.min.js" {
  interface IdenticonsLib {
    svg(address: string): Promise<string>;
  }
  const lib: IdenticonsLib;
  export default lib;
  export const IdenticonsAssets: string;
}

declare module "@nimiq/identicons/dist/identicons.bundle.cjs.js" {
  interface IdenticonsLib {
    svg(address: string): Promise<string>;
  }
  const lib: { default?: IdenticonsLib } & IdenticonsLib;
  export default lib;
}

declare module "dom-parser" {
  class DOMParser {
    parseFromString(source: string, mimeType?: string): unknown;
  }
  export default DOMParser;
}
