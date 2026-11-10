# IPv6-only sunucu → IPv4-only Nimiq RPC (NimJump)

**Sorun:** Sunucun IPv6-only. `rpc.nimiqwatch.com` ise **sadece IPv4** dinliyor.
IPv4 adresi almadan (ve istemeyerek) bu RPC'ye ulaşmanın tek yolu **araya bir çevirici
koymak**. Bu klasör üç çözümü de, hazır kodla birlikte veriyor.

---

## 0. Teşhis (kanıtlı, tahmin değil)

```
$ dig +short A    rpc.nimiqwatch.com   → 49.13.63.161
$ dig +short AAAA rpc.nimiqwatch.com   → (boş — AAAA yok)
```

Doğrulandı, 2026-11-10 itibarıyla durum bu. Yani:

* `NIMIQ_RPC_URL=https://rpc.nimiqwatch.com` olan bir kutu **IPv4'ü olmadan**
  bu adrese *hiçbir zaman* bağlanamaz. Bu bir kod hatası değil, DNS/BGP gerçeği.
* `curl: (7) Failed to connect ... Network is unreachable` / `no route to host`
  mesajlarının sebebi bu.

Bu yüzden "kodu iyileştir" tek başına yetmez. **İki iş var:**

| # | İş | Nerede |
|---|----|--------|
| **A** | Backend'in RPC taşımasını sağlamlaştır (havuzlanmış bağlantı, retry/backoff, failover, IPv6/NAT64/proxy seçimi, anlaşılır hata) | `backend/game/rpc_client.go` (+ `socks5.go`) — **yapıldı** |
| **B** | IPv4-only RPC'ye ulaşmak için araya çevirici koy (3 seçenek) | bu klasör |

---

## 1. Hangi seçenek? (kısa karar tablosu)

| Seçenek | Ne gerekiyor | IPv4 adresi? | Maliyet | Üretim için? |
|---|---|---|---|---|
| **① Cloudflare Worker** | Ücretsiz CF hesabı, 5 dk | Hayır | 0 ₺ (100k req/gün) | ✅ evet |
| **② Kendi relay'in** (dual-stack kutu) | IPv6'sı olan *herhangi* bir kutu (VPS, evdeki mini PC) | O kutuda var, **oyun sunucusunda yok** | ~0–5 €/ay | ✅ en sağlamı |
| **③ NAT64 (nat64.net)** | Hiçbir şey (sadece 2 env satırı) | Hayır | 0 ₺ | ⚠️ test için evet, ödeme için riskli |

> **Önemli:** Ödeme (reward) trafiğin gerçek para. ③'te trafiğin **paylaşımlı,
> ücretsiz, rate-limitli** bir kamu servisinden geçiyor ve senin kontrolünde değil
> → orada bir kesinti = rewarD'lar bekler (retry kuyruğu halleder ama gecikir).
> Benim önerim: **②** (kendi kutun) veya **①** (Cloudflare). ③ ise "5 dakikada
> çalışsın, sonra düzgününü kuralım" çözümü.

---

## 2. Seçenek ① — Cloudflare Worker (SEÇİLEN YOL — kuruldu ve canlıda test edildi)

> ✅ **Durum:** worker `nimjump-rpc` deploy edildi, **WAF ön kapısı** kuruldu ve
> canlıda test edildi. Tek giriş noktası: **`https://rpc.nimiqbase.com/<RELAY_SECRET>`**
> (`workers.dev` kapısı **kapatıldı** — yoksa WAF bypass edilirdi).
>
> | Test | Sonuç |
> |---|---|
> | İmza başlıkları yok | **403 — Cloudflare WAF**, Worker hiç çalışmadı |
> | Sadece `X-NJ-Ts` var, imza yok | **403 WAF** |
> | `GET` (POST değil) | **403 WAF** |
> | Başlıklar var, imza yanlış | `401` (Worker'ın kendi HMAC kontrolü) |
> | Doğru imza | `{"data":66535111}` ✓ |
> | Eski `workers.dev` URL'i | `404` (kapalı) |
>
> Kimlik bilgileri: `release/cloudflare-worker.env` (repoda değil).

### Katman 0 — WAF ön kapısı (Worker'a ulaşmadan engel)

`Page Rules` başlık kontrolü **yapamaz** (sadece URL pattern). Bunun için doğru
araç **WAF Custom Rules**. Kurulum scripti: `cloudflare-worker/setup-waf.py`
(idempotent: DNS + worker route + WAF kuralı + workers.dev kapatma).

Kural (Free plan, mevcut 3 kuralın yanına eklendi, toplam 4/5):

```
(http.host eq "rpc.nimiqbase.com" and
 (http.request.method ne "POST"
  or not any(http.request.headers["x-nj-sig"][*] ne "")
  or not any(http.request.headers["x-nj-ts"][*] ne "")))
   → action: BLOCK
```

Yani: **imza başlıkları yoksa istek Worker'a hiç ulaşmıyor**, Cloudflare
"Attention Required!" 403'ü ile kesiliyor. Worker'ın kendi HMAC kontrolü de
duruyor (WAF sadece "başlık var mı" der, imzanın doğruluğunu Worker kontrol
eder) → iki katman.

```bash
export CF_API_TOKEN=...            # Workers Scripts:Edit + Zone WAF + DNS:Edit
export CF_ACCOUNT_ID=<account-id>
export CF_ZONE_ID=<zone-id>        # nimiqbase.com zone id
export RPC_HOST=rpc.nimiqbase.com
python3 setup/ipv6-only/cloudflare-worker/setup-waf.py
```

### Katman 1-6 — Worker'ın kendi sertleştirmesi (dışarıdan kullanmak imkânsız)

`workers.dev` adresleri numaralandırılabilir — bu yüzden URL'yi **sır olarak
görmüyoruz**, 6 katman var:

| Katman | Ne yapıyor |
|---|---|
| Path secret | Sadece `/<RELAY_SECRET>` var; diğer her şey düz `404` (ipucu sızdırmaz) |
| **HMAC imza** | `X-NJ-Ts` + `X-NJ-Sig = HMAC-SHA256(HMAC_SECRET, ts + "." + gövde)`, ±60 sn pencere, sabit zamanlı karşılaştırma → URL sızdıysa bile anahtar olmadan kullanılamaz, yakalanan istek 60 sn sonra replay edilemez |
| Metod allowlist | Sadece 5 metod: `getBlockNumber,getAccountByAddress,pushTransaction,getTransactionByHash,getTransactionsByAddress` → relay "bedava Nimiq node" olarak kullanılamaz |
| IP pin (opsiyonel) | `ALLOWED_IP_PREFIXES` = oyun sunucunun IPv6'si → başkası imza bassa bile `403` |
| Rate limit + boyut | IP başına/dakika ve global token bucket, 100 KB gövde sınırı, 15 sn upstream timeout |
| Sızıntısız hata | Upstream 5xx/HTML gövdesi asla geri yansıtılmaz (HTML "JSON cevabı" gibi görünmesin diye) |

### Kurulum (API ile, wrangler gerekmez)

```bash
# repo kökünde
A=f5ef2e8e424c635fa1461fc139e084f6          # account id
CF=<cloudflare api token>                     # Workers Scripts:Edit yetkili
RELAY_SECRET=$(openssl rand -hex 24)
HMAC_SECRET=$(openssl rand -hex 32)

curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$A/workers/scripts/nimjump-rpc" \
  -H "Authorization: Bearer $CF" \
  -F "metadata={\"main_module\":\"worker.js\",\"compatibility_date\":\"2025-01-01\",\"bindings\":[
        {\"type\":\"secret_text\",\"name\":\"RELAY_SECRET\",\"text\":\"$RELAY_SECRET\"},
        {\"type\":\"secret_text\",\"name\":\"HMAC_SECRET\",\"text\":\"$HMAC_SECRET\"},
        {\"type\":\"plain_text\",\"name\":\"UPSTREAM\",\"text\":\"https://rpc.nimiqwatch.com\"}]};type=application/json" \
  -F "worker.js=@setup/ipv6-only/cloudflare-worker/worker.js;type=application/javascript+module"

# workers.dev'i AÇMA — WAF'ı atlayan bir kapı olur. Bunun yerine
# setup-waf.py çalıştır (zone route + WAF kuralı kurar, workers.dev'i kapatır).
```

### Backend `.env`

```ini
NIMIQ_RPC_URL=https://rpc.nimiqbase.com/<RELAY_SECRET>
NIMIQ_RPC_HMAC_SECRET=<HMAC_SECRET>
NIMIQ_RPC_NETWORK=auto
```

İmza, `game/rpc_client.go` içinde her istek için otomatik üretiliyor; başka bir
ayar gerekmiyor. Secret'ları değiştirmek istersen: aynı `PUT`'u yeni değerlerle
tekrar çalıştır, sonra `.env`'i güncelle.

---

## 2b. Seçenek ① (eski/alternatif: wrangler ile deploy)

`*.workers.dev` **hem IPv4 hem IPv6** yayınlar. Yani IPv6-only sunucun Cloudflare'in
edge'ine IPv6 ile gider, Worker da RPC'yi kendi IPv4 çıkışından çeker.

```bash
cd setup/ipv6-only/cloudflare-worker
npm i -g wrangler
wrangler login
wrangler secret put RELAY_SECRET      # openssl rand -hex 24
wrangler secret put HMAC_SECRET       # openssl rand -hex 32
wrangler deploy
# → https://nimjump-rpc.<senin-subdomain>.workers.dev
```

Test:

```bash
curl -s -X POST https://nimjump-rpc.<sub>.workers.dev/<RELAY_SECRET> \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"getBlockNumber","params":[],"id":1}'
# {"jsonrpc":"2.0","result":{"data":66534142,...},"id":1}
```

Sonra sunucuda `backend/.env`:

```ini
NIMIQ_RPC_URL=https://nimjump-rpc.<sub>.workers.dev/<RELAY_SECRET>
NIMIQ_RPC_NETWORK=auto
```

Bitti. `worker.js` içinde secret URL **path**'inde (header değil) — backend'e yeni
bir ayar eklemeden çalışsın diye; yanlış path 404 alır, upstream'e hiç dokunmaz.
Ayrıca `ALLOWED_METHODS` ile sadece backend'in kullandığı 5 metod geçer.

> Not: Cloudflare içeriği okuyabilir (plaintext JSON-RPC). İşlem imzalama
> **senin sunucunda** oluyor, private key asla dışarı çıkmıyor — ama Worker'ın
> döndürdüğü cevaba güvenmen gerekir (bakiye/block yüksekliği). Paranoyaksan ②.

---

## 3. Seçenek ② — Kendi IPv6→IPv4 relay'in (üretim için önerilen)

IPv6'sı olan **herhangi** bir kutuya (VPS / evdeki Raspberry Pi / eski laptop —
IPv4'ü olan ama IPv6'sı da olan bir şey) küçük bir Go relay kur. Oyun sunucunun
IPv4 adresi olmaz, sadece relay'e IPv6 ile bağlanır.

```bash
# relay kutusunda
cd setup/ipv6-only/relay
go build -o rpc-relay .
./rpc-relay -listen [::]:8848 -target https://rpc.nimiqwatch.com -secret "$(openssl rand -hex 24)"
```

Kalıcı servis: `relay/nimjump-rpc-relay.service` (secret'ı düzenle, sonra
`systemctl enable --now nimjump-rpc-relay`).

Oyun sunucusunda:

```ini
NIMIQ_RPC_URL=http://[RELAY_IPv6]:8848/<SECRET>
```

Relay'in özellikleri: tek paylaşımlı keep-alive upstream bağlantı havuzu, IP başına
token-bucket rate limit (retry fırtınasında upstream'i korur), `/healthz` (upstream
blok yüksekliğini de döner), upstream 4xx/5xx'te gövde snippet'i loglar, secret
path dışındaki her şey 404.

Caddy'yi tercih edersen: `Caddyfile.example` — püf noktası `reverse_proxy
https://rpc.nimiqwatch.com` + `tls_server_name rpc.nimiqwatch.com`, böylece TLS SNI
doğru gider (çıplak IP'ye proxy'lersen sertifika patlar).

Doğrulama (relay kutusunda **ve** oyun sunucusunda):

```bash
./../../setup/ipv6-only/check-rpc.sh
curl -s http://[RELAY_IPv6]:8848/healthz    # {"relay":"ok","upstream":{...,"block":66534142}}
```

---

## 4. Seçenek ③ — NAT64 (sunucuda hiçbir şey kurmadan, sadece env)

NAT64, `64:ff9b::/96` (veya sağlayıcının `/96`'sı) içindeki bir IPv6 adresini
IPv4'e çevirir. Yani `49.13.63.161` → `2a00:1098:2b::310d:3fa1` gibi bir adres.
Kodumuz bunu **kendisi** yapıyor (`NIMIQ_RPC_NETWORK=nat64`), DNS64'e bile gerek yok.

`backend/.env`:

```ini
NIMIQ_RPC_NETWORK=nat64
NIMIQ_NAT64_PREFIX=2a00:1098:2b::/96,2a00:1098:2c:1::/96,2a01:4f8:c2c:123f:64::/96,2a01:4f9:c010:3f02:64::/96
```

Bunlar [nat64.net](https://nat64.net/)'in ücretsiz kamu NAT64 gateway'leri —
sırayla denenir, biri çökerse diğerine geçer. Host tarafında **hiçbir route/DNS
değişikliği gerekmez** (prefix'ler zaten o gateway'lere yönlendirilmiş).

Kendi NAT64'ünü işletiyorsan sadece prefix'i yaz; `/96` olmak zorunda (kodun
IPv4'ü son 32 bite koyması buna bağlı):

```ini
NIMIQ_RPC_NETWORK=nat64
NIMIQ_NAT64_PREFIX=64:ff9b::/96
```

Yerel test:

```bash
ip -6 route get 2a00:1098:2b::310d:3fa1     # route var mı?
./setup/ipv6-only/check-rpc.sh -network nat64
```

> ⚠️ nat64.net **rate limitli** ve gönüllü bir servis. Ayrıca bağlantı tablosu
> paylaşımlı. Aylık ciddi ödeme trafiği için ① veya ②'ye geç.

**Neden `clatd`/`tayga` önermiyorum:** `tayga` çalışması için host'un kendi IPv4
çıkışına ihtiyaç duyar (sende yok), `clatd` ise yerel kernel'de 464XLAT kurar —
sadece RPC için gereğinden fazla, üstelik kernel/netfilter değişikliği ister.
Tek servis için env iki satır yeterken sistemi kurcalamaya değmez.

---

## 5. Kodda ne değişti? (`backend/game/rpc_client.go`, `socks5.go`, `main.go`)

Eski hâli her RPC çağrısında **yeni bir `http.Client`** yaratıp `client.Post(...)`
yapıyordu. Bunun bedeli: her çağrıda yeni TCP+TLS el sıkışması, keep-alive yok,
**HTTP status kontrolü yok** (proxy'nin döndürdüğü 502 HTML'i "JSON parse hatası"
olarak görünüyordu), retry yok, failover yok, rate-limit yönetimi yok, adres ailesi
kontrolü yok. IPv6-only bir host + IPv4-only endpoint kombinasyonunda bu tam olarak
"anlaşılmaz hatalar + rate-limit banı" üretir.

Yeni taşıma katmanı:

| Özellik | Kazanç |
|---|---|
| Paylaşımlı `http.Transport` (keep-alive, HTTP/2, idle limitleri) | her çağrıda TLS el sıkışması yok → gecikme ve CPU düşer |
| `NIMIQ_RPC_NETWORK=auto\|ipv6\|ipv4\|nat64` | adres ailesini **sen** belirlersin; `ipv6` seçiliyken v4-only endpoint net bir hata verir |
| NAT64 dialer (çoklu prefix) | IPv4 adresi almadan IPv4-only RPC; SNI/Host korunur → sertifika doğrulanır |
| `NIMIQ_RPC_PROXY=socks5://user:pass@[v6]:1080` (RFC1928/1929, remote DNS) | var olan bir tünelden geçirebilirsin (harici bağımlılık yok) |
| `NIMIQ_RPC_URLS=a,b,c` + endpoint cooldown | sağlayıcı çökerse otomatik diğerine geçer, ölü endpoint dövülmez |
| Sadece **geçici** hatalarda retry (backoff+jitter, en fazla `NIMIQ_RPC_MAX_RETRIES`) | "Transaction already in mempool" gibi mantık hataları retry edilmez → rate-limit'e girmez |
| HTTP status kontrolü + 8 MB gövde limiti + redirect yasağı + JSON-RPC id kontrolü | 502/HTML/kaptif portal "başarılı cevap" sanılmaz |
| `getBlockNumber` için 2 sn TTL cache (`NIMIQ_RPC_BLOCK_CACHE_MS`) | reward döngüsü saniyede bir blok sormaz — eski "Rate limit exceeded" sorununun kaynağı buydu |
| `RPCDiagnostics()` + açılışta tek seferlik probe | "neden bağlanamıyor" sorusunun cevabı logda: AAAA yok / NAT64 route yok / proxy reddetti |
| `cmd/rpccheck` CLI | tek komutla teşhis, `.env`'i aynen kullanır |

Ayrıca (**istenen "sadece IPv6" kısmı**, sunucu tarafı):

```ini
BIND_HOST=::          # :: üzerinden dinle
IPV6_ONLY=true        # listener "tcp6" olur → IPv4 ile erişim imkânsız
```

Doğrulandı (bu repoda): `IPV6_ONLY=true` ile

```
LISTEN 0 4096 [::]:18099        # ss -ltn
curl 127.0.0.1:18099  → bağlantı kurulamadı (000)   ← IPv4 imkânsız
curl [::1]:18099      → sunucu cevap verdi (404)    ← IPv6 çalışıyor
```

(`main.go`: probe + `server.Serve(tcp6 listener)`; `net.JoinHostPort` ile
`[::]:PORT` biçimlendirmesi.)

---

## 6. Uygulama sırası (önerdiğim)

```bash
# 1) Repo'yu IPv4'ü olan bir yerden al (github.com da IPv4-only! IPv6-only sunucuda
#    git clone/npm install patlar — aşağıdaki uyarıya bak) ve sunucuya kopyala.
git clone https://github.com/nimjump/game.git

# 2) Backend'i derle (Go 1.21+)
cd game/backend && go build ./...

# 3) RPC yolunu seç (① / ② / ③) ve .env'i düzenle (.env.example'da hazır bloklar var)

# 4) Doğrula
./../setup/ipv6-only/check-rpc.sh          # veya: go run ./cmd/rpccheck

# 5) Başlat — açılış logunda şunu görmelisin:
#    [NIMIQ-RPC] mode=nat64 endpoints=1 ... [NIMIQ-RPC] reachable ✓ block=66534142 in 480ms
```

---

## 7. Uyarılar (bunlar başına dert olabilir)

1. **`github.com` da IPv4-only.** Tam IPv6-only bir sunucuda `git clone`,
   `go mod download` (kısmen), `npm install` (bazı paketler) patlayabilir.
   Çözüm: kodu başka makinede `git clone` + `go mod vendor` yapıp `rsync`/`scp` ile
   taşı (en temizi), ya da relay kutusuna bir `ssh -D` SOCKS açıp
   `ALL_PROXY=socks5h://…` ver. `registry.npmjs.org`, `api.telegram.org` ve R2
   endpoint'i IPv6 destekliyor — asıl sıkıntı GitHub.
2. **Admin paneli `npm install` yapıyor** (`ADMIN_AUTOSTART=true`, ilk açılışta).
   IPv6-only sunucuda bunu **IPv4'ü olan bir yerde** bir kez çalıştırıp
   `admin/node_modules` + `admin/.next` klasörlerini sunucuya kopyala; ya da
   `ADMIN_AUTOSTART=false` yapıp paneli ayrı bir kutuda çalıştır.
3. **Cloudflare Tunnel (`cloudflared`)**: `BIND_HOST=127.0.0.1` varsayılanı bunun
   için. Tunnel kullanıyorsan dışarıya IPv6 açman gerekmez; `IPV6_ONLY` sadece
   doğrudan IPv6 ile servis vermek istiyorsan gerekli.
4. **Private key'i hiçbir proxy'e koyma.** Relay/Worker sadece JSON-RPC metni taşır;
   imzalama sunucuda kalır. Yine de ②/① cevabına güven meselesi var (bakiye, blok).
5. **Sırlar:** relay secret / Worker secret = `openssl rand -hex 24`. Bunları
   `.env`'e koy, repoya commit etme. Relay portunu mümkünse sadece oyun
   sunucunun IPv6 /128'inden kabul edecek şekilde firewall'la.

---

## 8. Dosyalar

```
setup/ipv6-only/
├── README.md                      ← bu dosya
├── check-rpc.sh                   ← tek komutluk teşhis (aile/route/DNS/TCP/JSON-RPC)
├── Caddyfile.example              ← Caddy ile relay (② alternatifi)
├── relay/
│   ├── main.go                    ← IPv6→IPv4 relay (stdlib, ~250 satır)
│   ├── go.mod
│   └── nimjump-rpc-relay.service  ← systemd unit
└── cloudflare-worker/
    ├── worker.js                  ← Cloudflare Worker (①)
    └── wrangler.toml
```
