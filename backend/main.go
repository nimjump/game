package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
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

	// Load .env file (optional, real env vars take priority)
	loadEnv(".env")
	loadEnv("../.env")

	// If NIMIQ_MNEMONIC is set, derive private key + address from it automatically
	if mnemonic := os.Getenv("NIMIQ_MNEMONIC"); mnemonic != "" {
		if err := game.NimiqConfigFromMnemonic(mnemonic); err != nil {
			log.Printf("[NIMIQ] mnemonic derivation failed: %v", err)
		} else {
			log.Printf("[NIMIQ] wallet address derived from mnemonic: %s", os.Getenv("NIMIQ_WALLET_ADDRESS"))
		}
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "./data/db"
	}

	// Badger DB
	opts := badger.DefaultOptions(dbPath).
		WithLogger(nil).
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
	store.StartCleanupLoop()

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
			for {
				if err := db.RunValueLogGC(0.5); err != nil {
					break // no more GC needed
				}
			}
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

	// BIND_HOST — defaults to 127.0.0.1 (localhost-only). This server sits
	// behind a Cloudflare Tunnel (cloudflared connects out to this local
	// port — no inbound port needs to be open on this machine at all), so
	// there's no reason for the raw Go process itself to also be reachable
	// directly from the network on 0.0.0.0. Binding to loopback only means
	// nothing on this box can hit the backend (game API or admin panel)
	// except through the tunnel. Override with BIND_HOST=0.0.0.0 if this
	// ever needs to run without a tunnel/reverse proxy in front of it.
	bindHost := os.Getenv("BIND_HOST")
	if bindHost == "" {
		bindHost = "127.0.0.1"
	}
	addr := bindHost + ":" + port
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

		// COOP + COEP: required for SharedArrayBuffer / Atomics (thread support in Godot web export).
		// Must be on ALL responses including static files.
		ctx.Response.Header.Set("Cross-Origin-Opener-Policy", "same-origin")
		ctx.Response.Header.Set("Cross-Origin-Embedder-Policy", "require-corp")

		// Cross-Origin-Resource-Policy: allow Godot .wasm / .pck to be loaded cross-origin
		// (needed when COEP is active — every sub-resource must opt in)
		ctx.Response.Header.Set("Cross-Origin-Resource-Policy", "cross-origin")

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
				// same-origin and this reflection is moot.
				if origin := string(ctx.Request.Header.Peek("Origin")); origin != "" {
					ctx.Response.Header.Set("Access-Control-Allow-Origin", origin)
					ctx.Response.Header.Set("Access-Control-Allow-Credentials", "true")
				}
			} else {
				ctx.Response.Header.Set("Access-Control-Allow-Origin", "*")
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
