package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/dgraph-io/badger/v4"
	"github.com/fasthttp/router"
	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/handlers"
)

// anchorWorkingDir forces the process's current directory to be the actual
// backend/ folder — the one containing this source file on disk — no
// matter where or how the process was actually launched from (a different
// shell, systemd with a stale WorkingDirectory=, the project folder having
// been moved/renamed, etc). Practically every relative path in this codebase
// (.env, SERVERGAMES_DIR, REPLAY_JOB_DIR, DB_PATH, ../webexport, ../admin,
// ../export) silently assumes cwd == backend/. Rather than have each of
// those guess independently across several fallback candidates, this makes
// that assumption actually true, once, before anything else runs — so
// every relative path anywhere downstream just works, on any machine.
// runtime.Caller(0) resolves to this file's real path on disk, which is
// accurate for `go run .` (this project's normal way of running it) and for
// a locally-built binary run from its own source tree; if the binary was
// copied elsewhere without its source, Chdir simply fails and is logged,
// falling back to whatever cwd the process already had.
func anchorWorkingDir() {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		return
	}
	root := filepath.Dir(thisFile)
	if err := os.Chdir(root); err != nil {
		log.Printf("[STARTUP] could not chdir to backend root %s: %v", root, err)
		return
	}
	log.Printf("[STARTUP] working directory anchored to %s", root)
}

// setupFileLogging makes ALL log.Print* output also go to backend/logs/backend.log,
// in addition to stdout. This matters specifically because this backend is
// commonly run as a Windows service (e.g. via NSSM/sc.exe) — a service has no
// attached console, so anything log.Print writes normally just vanishes into
// the void with no way to see it after the fact. Writing to a real file means
// "what happened / why isn't it working" is always answerable by opening this
// file, regardless of how the process was started. Appends across restarts
// (doesn't truncate) so a crash-and-restart doesn't erase the crash reason.
func setupFileLogging() {
	if err := os.MkdirAll("logs", 0o755); err != nil {
		log.Printf("[STARTUP] could not create logs dir, file logging disabled: %v", err)
		return
	}
	f, err := os.OpenFile(filepath.Join("logs", "backend.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("[STARTUP] could not open logs/backend.log, file logging disabled: %v", err)
		return
	}
	log.SetOutput(io.MultiWriter(os.Stdout, f))
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("[STARTUP] file logging enabled -> logs/backend.log")
}

// loadEnv loads key=value pairs from a .env file into the environment.
// Existing env vars are NOT overwritten (env takes priority over .env).
func loadEnv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return // .env is optional
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
		if os.Getenv(key) == "" { // don't overwrite real env vars
			os.Setenv(key, val)
		}
	}
}

// printStartupBanner logs Nimiq config and wallet balance at startup.
func printStartupBanner(store *game.Store) {
	cfg := store.GetNimiqConfig()

	fmt.Println("╔══════════════════════════════════════════════════════╗")
	fmt.Println("║               NimJump Backend Startup                ║")
	fmt.Println("╚══════════════════════════════════════════════════════╝")

	// Private key check
	pk := os.Getenv("NIMIQ_PRIVATE_KEY")
	if pk == "" {
		fmt.Println("  [NIMIQ] !!  NIMIQ_PRIVATE_KEY not set — rewards will NOT be sent!")
	} else {
		end := len(pk)
		var masked string
		if end > 8 {
			masked = pk[:4] + strings.Repeat("*", end-8) + pk[end-4:]
		} else {
			masked = strings.Repeat("*", end)
		}
		fmt.Printf("  [NIMIQ] Private key : %s\n", masked)
	}

	fmt.Printf("  [NIMIQ] RPC URL     : %s\n", cfg.RPCURL)
	fmt.Printf("  [NIMIQ] Wallet addr : %s\n", cfg.WalletAddress)

	// Fetch balance
	if cfg.WalletAddress != "" && pk != "" {
		balance, err := game.GetNimiqBalance(cfg)
		if err != nil {
			fmt.Printf("  [NIMIQ] Balance     : ERROR (%v)\n", err)
		} else {
			fmt.Printf("  [NIMIQ] Balance     : %.5f NIM\n", balance)
		}
	} else {
		fmt.Println("  [NIMIQ] Balance     : (skipped — key/address missing)")
	}

	// ADMIN AUTH — logs which values are ACTUALLY active at startup (never
	// the password itself). loadEnv() above only sets a var from .env if it
	// wasn't already a real env var — so if something else (a shell export,
	// a systemd Environment= line, /etc/environment, etc.) already defines
	// ADMIN_USERNAME/ADMIN_PASSWORD, THAT value silently wins over .env and
	// the login form's credentials will never match what's in the .env file
	// on disk. This line makes that mismatch visible instead of a mystery
	// "invalid_credentials" with no way to tell where the real value came from.
	adminUser := os.Getenv("ADMIN_USERNAME")
	adminPassLen := len(os.Getenv("ADMIN_PASSWORD"))
	if adminUser == "" && adminPassLen == 0 {
		fmt.Println("  [ADMIN_AUTH] !!  ADMIN_USERNAME / ADMIN_PASSWORD not set — admin panel login disabled")
	} else {
		fmt.Printf("  [ADMIN_AUTH] username=%q password_len=%d — if these don't match what you just put in .env, something else (shell export / systemd Environment= / /etc/environment) is overriding it\n", adminUser, adminPassLen)
	}

	fmt.Println("──────────────────────────────────────────────────────")
}

func main() {
	// Must run before anything else — see anchorWorkingDir() doc comment.
	anchorWorkingDir()

	// Right after anchoring cwd (so "logs/" lands in backend/, not wherever
	// the service happened to be launched from) and before anything else logs.
	setupFileLogging()

	// Load .env file (optional, real env vars take priority)
	loadEnv(".env")
	loadEnv("../.env")

	// Resolve the listen address up front and probe it BEFORE opening the
	// DB, starting the admin app supervisor, or doing anything else —
	// running `go run .` (or a second copy of the binary) while another
	// instance is already listening here (e.g. the systemd/Windows-service
	// managed one) used to fail deep inside fasthttp's ListenAndServe at
	// the very end of main(), by which point the DB was already open, the
	// admin-app child process had already been spawned, etc. That admin
	// child then raced its OWN port (see adminproc.go) and kept retrying
	// with backoff forever — the "şişiyor" (ballooning) symptom: a second
	// instance stuck looping spawn-attempts instead of just exiting.
	// Failing here, first, with a clear message, avoids all of that.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	bindHost := os.Getenv("BIND_HOST")
	if bindHost == "" {
		bindHost = "127.0.0.1"
	}
	addr := bindHost + ":" + port
	if probe, probeErr := net.Listen("tcp", addr); probeErr != nil {
		log.Fatalf("[FATAL] cannot bind %s: %v — another instance of this backend is very likely already running here (the systemd/service-managed one?). Stop it first (e.g. `sudo systemctl stop <service>` on Linux, or stop the Windows service/scheduled task), then try again. Refusing to start a second instance.", addr, probeErr)
	} else {
		probe.Close() // just a fast pre-flight check — the real listener binds this same addr again below
	}

	// If NIMIQ_MNEMONIC is set, derive private key + address from it automatically
	if mnemonic := os.Getenv("NIMIQ_MNEMONIC"); mnemonic != "" {
		if err := game.NimiqConfigFromMnemonic(mnemonic); err != nil {
			log.Printf("[NIMIQ] mnemonic derivation failed: %v", err)
		} else {
			log.Printf("[NIMIQ] wallet address derived from mnemonic: %s", os.Getenv("NIMIQ_WALLET_ADDRESS"))
		}
	}

	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "./data/db"
	}

	// Badger DB.
	//
	// SyncWrites(true): every committed transaction is fsync'd to disk BEFORE
	// Update() returns. This is the "no payment can EVER be lost" guarantee —
	// with the default (false), a committed write lingers in an OS/WAL buffer
	// and a hard crash (kill -9, power loss, OS panic) between the commit and
	// the next periodic flush would silently drop it. That's unacceptable for
	// anything touching real money: a room marked paid, a queued payout, or a
	// refund must be durably on disk the instant we consider it done. The
	// throughput cost of an fsync-per-commit is irrelevant at this game's write
	// volume, and correctness for money always wins. (Incoming VS payments are
	// additionally self-healing via the chain reconciler, but SyncWrites makes
	// EVERY write — including outgoing payouts/refunds — crash-durable too.)
	opts := badger.DefaultOptions(dbPath).
		WithLogger(nil).
		WithSyncWrites(true).
		WithValueLogFileSize(64 << 20) // 64 MB vlog files (default is 2 GB)
	db, err := badger.Open(opts)
	if err != nil {
		log.Fatalf("[FATAL] badger open: %v", err)
	}
	defer db.Close()

	store := game.NewStore(db)
	printStartupBanner(store)
	// Persistent Godot worker pool — önceden başlat, ilk submit beklemeden hazır olsun
	game.GetWorkerPool()
	srv := &handlers.Server{Store: store}
	srv.StartBackgroundServices()

	// Root context for everything that should die when the backend does —
	// right now just the admin app supervisor (adminproc.go). Cancelled in
	// the shutdown handler below.
	rootCtx, cancelRoot := context.WithCancel(context.Background())
	startAdminSupervisor(rootCtx)

	// BadgerDB GC — TTL expired key'leri diskten fiziksel olarak sil.
	// Logically silindiler (TTL'de okunmaz), ama fiziksel temizlik GC ile olur.
	go func() {
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			game.SafeCall("BadgerValueLogGC", func() {
				for {
					if err := db.RunValueLogGC(0.5); err != nil {
						break // no more GC needed
					}
				}
			})
		}
	}()

	r := router.New()
	srv.Register(r)

	// Static files — webexport folder (gzip compression enabled)
	fs := &fasthttp.FS{
		Root:               "../webexport",
		IndexNames:         []string{},
		GenerateIndexPages: true,
		Compress:           true,
		CompressBrotli:     true,
		CacheDuration:      0,
		AcceptByteRange:    false,
	}
	staticHandler := fs.NewRequestHandler()

	// adminPathPrefix — same default-fallback logic as adminBasePath() in
	// handlers/admin_proxy.go, duplicated here (unexported there) so this
	// catch-all can recognize /admin/* paths without importing internals.
	adminPathPrefix := os.Getenv("ADMIN_BASE_PATH")
	if adminPathPrefix == "" {
		adminPathPrefix = "/admin"
	}
	adminPathPrefix = strings.TrimSuffix(adminPathPrefix, "/")

	// Defensive net: /admin routes are already registered explicitly in
	// srv.Register(r) and should always take priority over this catch-all
	// for /admin/* paths — but if they ever don't (router precedence
	// surprise), route here instead of letting the static file server
	// 404 against ../webexport, which has no "admin" file to find.
	r.GET("/{filepath:*}", func(ctx *fasthttp.RequestCtx) {
		path := string(ctx.Path())
		if path == adminPathPrefix || strings.HasPrefix(path, adminPathPrefix+"/") {
			srv.AdminFallback(ctx)
			return
		}
		staticHandler(ctx)
	})

	// bindHost/port/addr were already resolved (and probe-checked) at the
	// very top of main() — see the comment there. BIND_HOST defaults to
	// 127.0.0.1 (localhost-only): this server sits behind a Cloudflare
	// Tunnel (cloudflared connects out to this local port — no inbound port
	// needs to be open on this machine at all), so there's no reason for the
	// raw Go process itself to also be reachable directly from the network
	// on 0.0.0.0. Override with BIND_HOST=0.0.0.0 if this ever needs to run
	// without a tunnel/reverse proxy in front of it.
	log.Printf("[STARTUP] listening on http://%s", addr)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-quit
		log.Println("[SHUTDOWN] stopping...")
		cancelRoot() // kills the admin app child process (adminproc.go)
		time.Sleep(300 * time.Millisecond)
		os.Exit(0)
	}()

	server := &fasthttp.Server{
		Handler:            corsMiddleware(r.Handler),
		Name:               "nimjump",
		Concurrency:        64 * 1024,          // max concurrent connections
		ReadBufferSize:     8 * 1024,           // 8KB — sufficient for small JSON requests
		WriteBufferSize:    8 * 1024,
		ReadTimeout:        10e9,               // 10s
		WriteTimeout:       30e9,               // 30s (replay submit can be large)
		// 250MB — big enough for admin replay-binary uploads (Godot .exe export
		// can be 100MB+). Public routes (submit etc.) validate their own much
		// smaller size limits after parsing, so this only raises the hard
		// connection-level ceiling, not what any given route actually accepts.
		MaxRequestBodySize: 250 * 1024 * 1024,
		ReduceMemoryUsage:  true,               // reduce GC pressure under high concurrency
		TCPKeepalive:       true,
		Logger:             log.Default(),
	}
	if err := server.ListenAndServe(addr); err != nil {
		log.Fatalf("[FATAL] listen: %v", err)
	}
}

func corsMiddleware(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		path := string(ctx.Path())

		// COOP + COEP: originally set for SharedArrayBuffer / Atomics (thread
		// support in Godot web export) — but this project's export explicitly
		// does NOT require threads (see index.html's
		// Engine.getMissingFeatures({threads:false}) check and the
		// GODOT_CONFIG['ensureCrossOriginIsolationHeaders']=false override),
		// so crossOriginIsolated was never actually load-bearing for gameplay.
		//
		// BUG FIX ("invalid request" from the Nimiq Hub API popup on the web
		// sign-in path): COOP "same-origin" (the strict value) puts any popup
		// THIS page opens into a SEPARATE browsing-context group, severing the
		// window.opener relationship — which is exactly how
		// hub.nimiq.com's signMessage() popup talks back to us. With that
		// link severed, the popup's own RPC handshake with our page fails and
		// Hub surfaces it as "Invalid Request" — a well-known real-world
		// footgun for any popup-based auth flow (Google Sign-In, OAuth, etc.)
		// under strict COOP. "same-origin-allow-popups" keeps same-origin
		// isolation from other TOP-LEVEL documents while explicitly carving
		// out an exception for popups we open ourselves — exactly this case.
		//
		// ROUND 2 FIX: relaxing COOP alone did NOT fix "Invalid Request" (user
		// confirmed it persists identically after deploy). Root cause was
		// actually the OTHER half of the pair: Cross-Origin-Embedder-Policy:
		// require-corp, which was still set below. A page that is
		// cross-origin-isolated (COOP same-origin[-allow-popups] + COEP
		// require-corp TOGETHER) cannot retain window.opener on ANY
		// cross-origin popup, no matter how COOP alone is relaxed — this is a
		// documented browser-level restriction (the same one that broke
		// Google/Firebase OAuth popups site-wide when COEP started rolling
		// out). COEP require-corp was only ever here for SharedArrayBuffer/
		// thread support, which (per the comment above) this single-threaded
		// export never needed. Removing it entirely is what actually restores
		// the popup's opener link. Cross-Origin-Resource-Policy is dropped
		// alongside it since it was only required to satisfy COEP.
		//
		// ROUND 3 FIX ("Connection was closed" / "Invalid Request" STILL
		// persisting even with a genuine synchronous click opening the popup):
		// confirmed via reading Nimiq Hub's own source (nimiq/hub RpcApi.ts +
		// @nimiq/rpc PostMessageRpcClient) that this error is thrown when the
		// popup's window.opener is NULL — Hub's 1s connect-timeout handler
		// branches specifically on `window.opener === null`, abandons the
		// postMessage handshake, and renders its "Invalid Request" page; our
		// RPC client then sees the severed window handle as closed and rejects
		// with "Connection was closed". The opener gets nulled by a COOP
		// browsing-context-group SWITCH. Crucially, `same-origin-allow-popups`
		// is only meaningful as the popup-escape-hatch for a page that is
		// otherwise cross-origin ISOLATED (i.e. paired with COEP). With COEP
		// already gone (round 2 above) this page is NOT isolated, so this COOP
		// value buys us zero security/functionality — it only remains as a
		// footgun that can still trigger a BCG switch (and thus null the
		// popup's opener) against a cross-origin popup like hub.nimiq.com.
		// `unsafe-none` (the default) is the classic, maximally-compatible
		// setting that preserves a cross-origin popup's opener relationship in
		// every browser — exactly what popup-based auth (OAuth, Google
		// Sign-In, and Nimiq Hub) needs. Set explicitly rather than omitted so
		// no upstream proxy/CDN default can silently reintroduce isolation.
		ctx.Response.Header.Set("Cross-Origin-Opener-Policy", "unsafe-none")

		// CORS for API endpoints only
		if len(path) > 8 && path[:8] == "/backend" {
			if strings.HasPrefix(path, "/backend/admin") {
				// Admin routes use a session cookie (handlers/admin_session.go)
				// instead of an Authorization header, so credentialed
				// cross-origin requests need an explicit (not wildcard)
				// Allow-Origin + Allow-Credentials — browsers refuse "*"
				// together with credentials. Only matters when the admin app
				// runs standalone in dev (ADMIN_PORT, not proxied through
				// this backend); in production the proxy makes everything
				// same-origin and this reflection is moot. Gated by the same
				// allowlist as the public API below — reflecting an
				// arbitrary Origin back with credentials enabled would
				// otherwise let ANY website ride the admin's session cookie.
				if origin := string(ctx.Request.Header.Peek("Origin")); origin != "" {
					if !handlers.IsAllowedOrigin(origin) {
						ctx.SetStatusCode(fasthttp.StatusForbidden)
						ctx.SetBodyString(`{"error":"origin_not_allowed"}`)
						return
					}
					ctx.Response.Header.Set("Access-Control-Allow-Origin", origin)
					ctx.Response.Header.Set("Access-Control-Allow-Credentials", "true")
				}
			} else {
				// Public game API — no wildcard anymore. A real browser
				// always sends a genuine Origin on cross-origin requests, so
				// this reliably blocks other websites'/apps' JS from calling
				// our API even though it can't stop a non-browser script
				// that simply forges the header (see origin.go's doc
				// comment — there's no way around that for a public client).
				if origin := string(ctx.Request.Header.Peek("Origin")); origin != "" {
					if !handlers.IsAllowedOrigin(origin) {
						ctx.SetStatusCode(fasthttp.StatusForbidden)
						ctx.SetBodyString(`{"error":"origin_not_allowed"}`)
						return
					}
					ctx.Response.Header.Set("Access-Control-Allow-Origin", origin)
				}
				// No Origin header at all (native export, some in-app
				// WebViews, server-to-server) — nothing to validate or
				// reflect; falls through to the app-signature check below,
				// which is the real, always-on gate for this class of
				// request.
				//
				// App-signature check — every real (non-preflight) request
				// to the public API must carry app_ts/app_sig, a fresh
				// HMAC computed by the actual game client (see
				// ApiConfig.gd's sign_url()). This is the one check that
				// applies uniformly regardless of Origin/WebView/native —
				// see appsig.go's doc comment for exactly what it does and
				// doesn't guarantee. Skipped for OPTIONS so CORS preflight
				// (which browsers send with no say from our own request
				// code) is never itself blocked by this.
				// /backend/client-log is exempt: it's a fire-and-forget error
				// logger called from raw JS in the page's <head> bootstrap
				// (index.html), before Godot/GDScript (and therefore
				// ApiConfig.sign_url()) is even running — including it
				// would mean the one thing meant to catch early bootstrap
				// failures could never actually be called during them.
				// Low stakes either way: it's a write-only diagnostic sink,
				// still behind the Origin check above and the rate limiter.
				if string(ctx.Method()) != "OPTIONS" && path != "/backend/client-log" {
					ts := string(ctx.QueryArgs().Peek("app_ts"))
					sig := string(ctx.QueryArgs().Peek("app_sig"))
					switch handlers.VerifyAppSignature(path, ts, sig) {
					case handlers.AppSigClockSkew:
						// A real client, correct secret, just a wrong system
						// clock — tell it exactly that (distinct error code)
						// so the game can show one clear, actionable toast
						// instead of a generic "network error" (see
						// ApiConfig.gd's wrap_completed()).
						ctx.SetStatusCode(fasthttp.StatusForbidden)
						ctx.SetBodyString(`{"error":"clock_skew"}`)
						return
					case handlers.AppSigInvalid:
						ctx.SetStatusCode(fasthttp.StatusForbidden)
						ctx.SetBodyString(`{"error":"app_signature_invalid"}`)
						return
					}
				}
			}
			ctx.Response.Header.Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
			ctx.Response.Header.Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		}

		ctx.Response.Header.Set("Cache-Control", "no-store, no-cache, must-revalidate")
		ctx.Response.Header.Set("Pragma", "no-cache")

		if string(ctx.Method()) == "OPTIONS" {
			ctx.SetStatusCode(204)
			return
		}
		next(ctx)
	}
}
