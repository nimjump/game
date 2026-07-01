"use client";

import { useEffect, useState } from "react";

const cache = new Map<string, string>();
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _lib: any = null;
const _pending: Array<() => void> = [];

function getLib() {
  if (_lib) return Promise.resolve(_lib);
  return new Promise<any>(resolve => { // eslint-disable-line @typescript-eslint/no-explicit-any
    _pending.push(() => resolve(_lib));
  });
}

let _loaded = false;
function ensureLib() {
  if (_loaded) return;
  _loaded = true;
  // Direkt bundle dosyasını import et — IdenticonsAssets sprite'ı içinde taşıyor
  import("@nimiq/identicons/dist/identicons.bundle.min.js").then((mod: any) => { // eslint-disable-line @typescript-eslint/no-explicit-any
    // Sprite'ı global'e ver
    if (mod.IdenticonsAssets) {
      (globalThis as any).IdenticonsAssets = mod.IdenticonsAssets; // eslint-disable-line @typescript-eslint/no-explicit-any
    }
    _lib = mod.default ?? mod;
    _pending.forEach(fn => fn());
    _pending.length = 0;
  }).catch(() => { _loaded = false; });
}

interface Props {
  address: string;
  size?: number;
  style?: React.CSSProperties;
  className?: string;
}

export default function NimiqAvatar({ address, size = 36, style, className }: Props) {
  const [svg, setSvg] = useState<string>(cache.get(address) ?? "");

  useEffect(() => {
    ensureLib();
    if (!address) return;
    if (cache.has(address)) { setSvg(cache.get(address)!); return; }
    let dead = false;
    getLib().then(lib => {
      lib.svg(address).then((raw: string) => {
        cache.set(address, raw);
        if (!dead) setSvg(raw);
      }).catch(() => {});
    });
    return () => { dead = true; };
  }, [address]);

  const wrap: React.CSSProperties = {
    width: size,
    height: size,
    borderRadius: "50%",
    overflow: "hidden",
    flexShrink: 0,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    background: "#21262d",
    lineHeight: 0,
    ...style,
  };

  if (!svg) return <div style={wrap} className={className} />;

  return (
    <div
      className={className}
      style={wrap}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}