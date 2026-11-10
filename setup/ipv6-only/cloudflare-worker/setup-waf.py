#!/usr/bin/env python3
"""
NimJump — WAF ön kapısı kurulumu (Cloudflare).

Amaç: Worker'a **doğrudan** ulaşılamasın. İstek önce zone'un WAF'ından geçer;
imza başlıkları (`X-NJ-Sig` + `X-NJ-Ts`) yoksa veya metod POST değilse Cloudflare
isteği **Worker çalışmadan** 403 ile keser.

Neden Page Rules değil: Page Rules yalnızca URL pattern'ine bakar, header
inceleyemez. Header kontrolü WAF Custom Rules ile yapılır (Free plan 5 kural).

Yaptıkları (hepsi idempotent — tekrar çalıştırmak zarar vermez):
  1. rpc.<zone> için proxied AAAA 100:: kaydı (trafik zaten Worker'a gider)
  2. Zone route: rpc.<zone>/* → worker script
  3. WAF Custom Rule: host = rpc.<zone> ve (POST değil VEYA imza başlığı yok) → block
  4. Worker'ın workers.dev kapısını KAPATIR (yoksa WAF bypass edilir)

Kullanım:
  export CF_API_TOKEN=...            # Workers Scripts:Edit + Zone WAF + DNS edit
  export CF_ACCOUNT_ID=...
  export CF_ZONE_ID=...
  export RPC_HOST=rpc.nimiqbase.com  # istenen tam host
  export WORKER_NAME=nimjump-rpc
  python3 setup-waf.py

Kontrol:
  curl -s -o /dev/null -w '%{http_code}\\n' -X POST https://rpc.nimiqbase.com/<SECRET> \
       -H 'content-type: application/json' -d '{}'
  # 403 (Cloudflare "Attention Required!") = WAF çalışıyor, Worker'a hiç gitmedi
"""

import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"
TOKEN = os.environ.get("CF_API_TOKEN", "").strip()
ACCOUNT = os.environ.get("CF_ACCOUNT_ID", "").strip()
ZONE = os.environ.get("CF_ZONE_ID", "").strip()
HOST = os.environ.get("RPC_HOST", "").strip()
WORKER = os.environ.get("WORKER_NAME", "nimjump-rpc").strip()

RULE_DESC = "nimjump-rpc: imza basliklari yoksa worker'a hic ulasmasin"
RULE_EXPR = (
    f'(http.host eq "{HOST}" and '
    '(http.request.method ne "POST" '
    'or not any(http.request.headers["x-nj-sig"][*] ne "") '
    'or not any(http.request.headers["x-nj-ts"][*] ne "")))'
)


def call(path, method="GET", body=None):
    url = f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {TOKEN}", "content-type": "application/json"},
    )
    try:
        return json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"success": False, "errors": [{"message": str(e)}]}


def check_env():
    missing = [k for k, v in {
        "CF_API_TOKEN": TOKEN, "CF_ACCOUNT_ID": ACCOUNT,
        "CF_ZONE_ID": ZONE, "RPC_HOST": HOST,
    }.items() if not v]
    if missing:
        sys.exit(f"eksik env: {', '.join(missing)}")


def dns_record():
    """proxied AAAA 100:: — Worker route için sadece turuncu bulut gerekiyor."""
    zone_part, _, rest = HOST.partition(".")
    res = call(f"/zones/{ZONE}/dns_records?name={HOST}")
    if res.get("success") and res.get("result"):
        rec = res["result"][0]
        print(f"  ✓ DNS zaten var: {rec['type']} {rec['name']} → {rec['content']} proxied={rec['proxied']}")
        if not rec["proxied"]:
            print("  ! proxied kapalı — açılıyor")
            call(f"/zones/{ZONE}/dns_records/{rec['id']}", "PATCH", {"proxied": True})
        return
    res = call(f"/zones/{ZONE}/dns_records", "POST", {
        "type": "AAAA", "name": zone_part, "content": "100::", "proxied": True, "ttl": 1,
        "comment": "NimJump RPC worker route (WAF-protected)",
    })
    print("  ✓ DNS oluşturuldu" if res.get("success") else f"  ✗ DNS: {res.get('errors')}")


def worker_route():
    res = call(f"/zones/{ZONE}/workers/routes")
    pattern = f"{HOST}/*"
    for r in res.get("result", []) if res.get("success") else []:
        if r.get("pattern") == pattern:
            print(f"  ✓ Route zaten var: {pattern} → {r.get('script')}")
            if r.get("script") != WORKER:
                call(f"/zones/{ZONE}/workers/routes/{r['id']}", "PUT",
                     {"pattern": pattern, "script": WORKER})
                print(f"  ✓ Route script'i {WORKER} yapıldı")
            return
    res = call(f"/zones/{ZONE}/workers/routes", "POST", {"pattern": pattern, "script": WORKER})
    print("  ✓ Route oluşturuldu" if res.get("success") else f"  ✗ Route: {res.get('errors')}")


def waf_rule():
    path = f"/zones/{ZONE}/rulesets/phases/http_request_firewall_custom/entrypoint"
    cur = call(path)
    if not cur.get("success"):
        print(f"  ✗ WAF okunamadı: {cur.get('errors')} (token'da Zone WAF edit var mı?)")
        return
    rs = cur["result"]
    rules = rs.get("rules", [])
    if any(r.get("description") == RULE_DESC for r in rules):
        print("  ✓ WAF kuralı zaten var")
        return
    rules.append({"action": "block", "description": RULE_DESC, "enabled": True, "expression": RULE_EXPR})
    res = call(path, "PUT", {"description": rs.get("description", ""), "rules": rules})
    if res.get("success"):
        print(f"  ✓ WAF kuralı eklendi (toplam {len(res['result']['rules'])} kural)")
    else:
        print(f"  ✗ WAF: {res.get('errors')}")


def close_workers_dev():
    """workers.dev kapısı WAF'ı atlar — kapatılmazsa WAF anlamsız olur."""
    res = call(f"/accounts/{ACCOUNT}/workers/scripts/{WORKER}/subdomain", "POST", {"enabled": False})
    print("  ✓ workers.dev kapatıldı (tek kapı artık zone route)" if res.get("success")
          else f"  ✗ workers.dev: {res.get('errors')}")


if __name__ == "__main__":
    check_env()
    print(f"NimJump WAF ön kapısı → https://{HOST}")
    print("1) DNS"); dns_record()
    print("2) Worker route"); worker_route()
    print("3) WAF custom rule"); waf_rule()
    print("4) workers.dev kapatılıyor"); close_workers_dev()
    print("\nKural ifadesi:\n ", RULE_EXPR)
