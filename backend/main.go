package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/dgraph-io/badger/v4"
	"github.com/fasthttp/router"
	"github.com/valyala/fasthttp"

	"nimjump-backend/game"
	"nimjump-backend/handlers"
)

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

	fmt.Println("──────────────────────────────────────────────────────")
}

func main() {
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

	addr := "0.0.0.0:" + port
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
