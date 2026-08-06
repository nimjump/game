# NimJump — Full Export & Deploy Guide

> **⚠️ QA Disclaimer — Anti-Cheat Testing**
> the council can stress-test the anti-cheat system. They should try
> every possible method of cheating, — including
> in-game/memory cheats (code injection, memory editing, value
> manipulation), network cheats (intercepting or modifying packet data),
> and any other method they can find.
> This game was built to bring a gaming audience into the Nimiq ecosystem,
> and to give Nimiq a way to distribute rewards safely —
> without having to worry about cheaters stealing them.


> ### Known Limitations

>NimJump is complete and fully functional. A significant portion of the development effort was dedicated to designing a minimal client-authority architecture, centered around deterministic map generation and server-side replay verification.

> There are currently two known cheating vectors:

>

> 1. **Gameplay automation (bot).** While technically possible, developing a competitive bot is expected to require significant effort for relatively little practical benefit. The game is primarily skill-based, making this attack economically unattractive.

>

> 2. **Arbitrary seed generation.** To support offline play, the current implementation generates the game seed on the client. A malicious user could repeatedly generate seeds until finding one that produces a favorable game. This limitation is currently accepted because offline play is considered a core feature of the game. Given the complexity of this attack and the importance of offline play, this tradeoff was considered acceptable by me for the current release.

>

> ### Planned Solution

>

> The planned solution is to replace arbitrary client-generated seeds with **server-issued seed batches**. While the player is online, the server will issue a batch of signed seeds (for example, 100). These seeds can then be consumed during offline gameplay. When the player reconnects and claims rewards, the server will verify that every submitted seed is authentic, unused, and was originally issued by the server.

>

> This approach preserves offline play while preventing players from generating arbitrary seeds in search of favorable outcomes.



This is not just a web export guide — it covers the full setup: the web
build for the browser, the native build the backend needs for replay
verification, wasm splitting, and deployment to Cloudflare Pages.

All paths below are relative to the NimJump root folder.

---

## 0. Folder Layout

```
NimJump/
├── game/
│   ├── project.godot           (the actual Godot project)
│   └── template/
│       ├── index.html          (custom HTML shell for the web export)
│       ├── _headers             (copied into export/ by build.py)
│       ├── manifest.json        (copied into export/ by build.py)
│       ├── robots.txt           (copied into export/ by build.py — SEO)
│       ├── sitemap.xml          (copied into export/ by build.py — SEO)
│       └── assets/              (copied into export/ by build.py)
├── backend/
│   └── replay-verifier/
│       └── replay.exe           (or replay.zip — native export goes here)
├── admin/                       (run with npm install && npm run dev, serves on localhost)
├── setup/
│   ├── urls.ini               (the client's two URLs — see section 2b)
│   ├── apply_urls.py          (run BEFORE export — writes urls.ini into ApiConfig.gd)
│   ├── urls_config.py         (shared urls.ini parser)
│   └── build.py
├── patch_safari.py              (run after every web export, before build.py — see section 4b)
└── export/                      (web export output folder)
    ├── index.html
    ├── index.js
    ├── index.wasm.part1         (or plain index.wasm if under 24 MiB)
    ├── index.wasm.part2
    ├── wasm-loader.js            (only generated if a split happened)
    ├── index.pck
    └── _headers
```

---

## 1. Prerequisites

- Godot 4.7 exactly (check via Help → About Godot)
- Web export templates installed (Editor → Manage Export Templates)
- Python 3.9+ (no extra pip packages needed — build.py only uses the
  standard library)
- A Cloudflare Pages project already connected (initial Pages setup is
  not covered here)
- Know which OS the backend/replay-verifier host runs — it determines
  which native export preset you use (see section 3.2)


## 2. Open the Project

1. Launch Godot 4.7
2. Project Manager → Import → select project.godot inside NimJump/game
3. Edit → wait for asset import to finish before touching export

---

## 2b. Configure Your URLs (do this BEFORE exporting)

No domain is hardcoded anywhere in this project. Two URLs, three places
to set them:

| Where | What |
|---|---|
| `setup/urls.ini` | the game client |
| `backend/.env` | `GAME_URL`, `BACKEND_URL` |
| `admin/.env` | `NEXT_PUBLIC_GAME_URL`, `NEXT_PUBLIC_BACKEND_URL` |

The two URLs are different things: **api_base** is where the Go backend
runs, **game_url** is the public URL players open (share/replay/VS invite
links, SEO tags). They can be the same host. No trailing slashes.

### 2b.1 Client — `setup/urls.ini`

```ini
[urls]
api_base = https://api.example.com
game_url = https://game.example.com
```

Then, **before** exporting from Godot:

    python setup/apply_urls.py            # writes them into ApiConfig.gd
    python setup/apply_urls.py --check    # verify only, exit 1 if drifted


Runtime overrides for testing: `?api=` / `?game_url=` query params, or
`nj_api_base` / `nj_game_url` in localStorage.

### 2b.2 Backend and admin — their own `.env` files

`GAME_URL` and `BACKEND_URL` in `backend/.env` are **required** — no
defaults. The backend exits at startup with a clear message if either is
missing, rather than quietly running against the wrong domain. They feed
the CORS allowlist and the `game_url` the backend hands the client.

`admin/.env` gets `NEXT_PUBLIC_GAME_URL` / `NEXT_PUBLIC_BACKEND_URL`,
inlined at build time — rebuild the admin app after changing them.

### 2b.3 The app signing key (what it is, where it lives)

**The API is not open to the public** — every request has to be signed by
the real game client or the backend refuses it. Nothing to set up, it's
already on.

The game and the backend share one secret string. Every client request to
`/backend/*` carries `app_ts` (a timestamp) and `app_sig` (an HMAC-SHA256
of the request path + that timestamp, keyed by the secret). The backend
recomputes it and rejects anything that doesn't match or is more than 5
minutes off. This runs in `corsMiddleware`, so an unsigned request never
reaches a handler.

The key is **not in a database or an `.env` file** — it's a constant
compiled into both sides:

| Side | File | Name |
|---|---|---|
| Game client | `game/scripts/ApiConfig.gd` | `const APP_SIGNING_KEY` |
| Backend | `backend/handlers/appsig.go` | `const appSigningKey` |

The two must be byte-for-byte identical. The shipped values already
match, so if you're just changing domains, skip this. To use your own
secret: change both constants, rebuild the backend, re-export the game.
Changing one without the other means every API call 403s.

Note the limit: the key is baked into the downloadable client, so a
determined person can extract it. It stops bots and casual scripts, not a
dedicated attacker.

---

## 3. Export Presets

You need two presets: one for the web build, one for the backend's
native build. They serve different purposes and go to different
locations.

### 3.1 Web preset

Project → Export... → select (or create) the Web preset.

In the Options tab:

- HTML → Custom HTML Shell: set to game/template/index.html
  If this is left blank, Godot silently falls back to its own default
  HTML template and any custom markup in our shell (favicon, SDK
  scripts, etc.) is discarded on every export.

Export Path (top of dialog): export/index.html

### 3.2 Native preset (for the backend)

The backend's replay-verifier needs a native build of the game to
validate replays server-side. Pick the export preset to match the OS the
backend/replay-verifier host actually runs — not the OS your own machine
happens to be on:

- Backend host runs Linux → use the Linux/X11 export preset
- Backend host runs Windows → use the Windows Desktop export preset

Godot can export either target from either OS (as long as the matching
export templates are installed) — the only thing that matters is the
export preset you pick, not which machine you're clicking Export on.

Export Path for this preset: backend/replay-verifier/replay.exe
(or replay.zip if that's the packaged format replay-verifier expects —
the important part is the name replay, not the game's own name)

---

## 4. Export the Builds

First, if you haven't already (section 2b) — the URLs are compiled in, so
this has to come before the export, not after:

    python setup/apply_urls.py

Then, for each preset:

1. Project → Export...
2. Select the preset (Web, then separately the native one)
3. Export Project → confirm the path matches section 3 → Save
4. Wait for it to finish (the .wasm write for the web build alone can
   take a minute or two on a 30 MB+ file) — don't close the editor
   mid-export

After both exports, you should have:

```
export/
├── index.html
├── index.js
├── index.wasm        (single file at this point, typically ~30 MB)
├── index.pck
└── index.audio.worklet.js   (if using AudioWorklet)

backend/replay-verifier/
└── replay.exe (or replay.zip) + its .pck
```

Do not upload the export/ folder to Cloudflare yet — Cloudflare Pages
rejects any single file over 25 MiB, and Godot's wasm export is
routinely bigger than that. That's what build.py handles next.

---

## 4b. Patch for Safari (run after every web export)

Safari/iOS chokes on the pthread pool size Godot bakes into its web
export and can hang or throw on load, while Chrome/Firefox are fine.
`patch_safari.py` forces `pool_size` to `0` in the exported
`index.js`/`index.html` (plus a few smaller export-time fixes) and clears
stale brotli-cache files.

Run it from the **repo root**, after the web export and before
`setup/build.py`:

    cd /path/to/nimjump
    python patch_safari.py

Safe to re-run — it only matches unpatched patterns. Skip it and
Should run mandatorily or game can fail to load.

---

## 5. Split the WASM Output + Fill In the URLs

Run (from inside the setup folder):

    cd setup
    python build.py

Cloudflare Pages rejects any file over 25 MiB and Godot's .wasm is
usually bigger, so build.py:

1. Splits any .wasm over 24 MiB into `.part1` / `.part2` and deletes the
   original, then writes `wasm-loader.js` (patches `window.fetch` to
   stitch the halves back together) and injects it as the first script in
   index.html's `<head>`. Skipped entirely if the .wasm is small enough.
2. Copies `_headers`, `manifest.json`, `robots.txt`, `sitemap.xml` and
   `assets/` from game/template into export/.
3. Fills in the `__GAME_URL__` / `__API_BASE__` placeholders from
   setup/urls.ini, and exits with an error if any are left over.

Safe to re-run. Edit `_headers`/`assets/` in game/template — the copies
in export/ get overwritten every run.

---

## 6. Deploy to Cloudflare Pages

1. Cloudflare dashboard → Workers & Pages → the NimJump Pages project
2. Deployments → Direct upload (drag the whole export folder, including
   the generated _headers and wasm-loader.js if present) or push via
   your Git-connected branch
3. Once live, open the site → DevTools → Network → reload
4. Confirm the wasm loading worked:
   - You should see two requests, index.wasm.part1 and
     index.wasm.part2, each returning 200 — not a single index.wasm
     request
   - wasm-loader.js should load and execute before index.js
   - No "wasm-loader: failed to fetch parts" error in the console
5. Confirm the game actually loads and plays

---

## 7. Running the Admin Panel

`admin/` is a separate Next.js app, but you never run it yourself — the
Go backend installs, builds, starts and supervises it (`adminproc.go`).
`go run .` is the only command you need.

**One-time setup:** set `ADMIN_USERNAME` and `ADMIN_PASSWORD` in
`backend/.env`. If either is missing, all admin routes stay locked (503).

**Then:**

    cd backend
    go mod tidy
    go run .

First run is slower (`npm install` + `npm run build` in the background —
watch for `[ADMIN_BUILD]` log lines); later runs skip those.

Open `http://localhost:8080/admin` and log in. The backend reverse-proxies
`/admin` to the admin app on `ADMIN_PORT` (default 3001), so only port
8080 needs to be internet-reachable. Admin logs appear in the same
terminal, prefixed `[ADMIN]`.

**Controls** (all in `backend/.env`, see `.env.example`):

- `ADMIN_AUTOSTART` (default `true`) — set `false` if you'd rather run
  the admin app yourself (separate terminal, separate host, your own
  process manager, whatever).
- `ADMIN_DIR` (default `../admin`) — where the admin app's source lives,
  relative to `backend/`.
- `ADMIN_START_CMD` (default `npm start`) — the command run once setup
  is done. Change to `npm run dev` for local development with hot reload
  instead of a production build (dev mode skips the build step entirely
  — Next.js compiles on the fly).
- `ADMIN_REBUILD_ON_START` (default `false`) — set `true` to force a
  fresh `npm run build` on every single backend start, even if one
  already exists. Handy right after pulling new admin code so you never
  have a stale build running; costs you a slower startup every time, so
  leave it `false` day-to-day and flip it on only when you know you just
  changed something in `admin/`.

**If you'd rather run it separately anyway** (`ADMIN_AUTOSTART=false`):

    cd admin
    npm install
    npm run build && npm start     # or: npm run dev

    cd ../backend
    go run .

If backend and admin end up on different machines/ports, set
`ADMIN_PROXY_URL` in `backend/.env` accordingly either way.

---

## 8. Running the Backend (Local Dev)

The backend folder at NimJump/backend is started directly from that
folder:

    cd backend
    go mod tidy
    go run .

This single command also brings up the admin app (section 7) unless
`ADMIN_AUTOSTART=false`. It just needs the replay.exe (or replay.zip) in
backend/replay-verifier/ to already be in place if you want replay
verification to actually work while it's running.

For running this unattended on a real server — auto-start on boot,
auto-restart on crash, survives reboots — see section 17.

---

## 9. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Default Godot robot favicon shows up instead of ours | Custom HTML Shell wasn't set to game/template/index.html in the Web preset |
| Upload to Cloudflare fails / "file too large" | build.py wasn't run before deploying, so index.wasm is still one file over the 25 MiB limit |
| Game hangs on the loading bar, console shows a fetch error for .part1/.part2 | wasm-loader.js didn't get uploaded, or the `<script>` tag wasn't injected into index.html — rerun build.py and re-check index.html's `<head>` |
| Game hangs on the loading bar (no fetch errors) | index.wasm(.part1/.part2) and index.pck are from different export runs — always redo export → build.py → deploy together, never mix files from different runs |
| Backend replay-verifier fails to run the export | Native export platform doesn't match the OS the backend host runs on (see 3.2) |
| Custom HTML Shell reset to blank | Some Godot version upgrades reset export preset fields — recheck section 3.1 after upgrading the editor |
| Game loads but every API call fails / talks to the old domain | `apply_urls.py` wasn't run before the export — run `python setup/apply_urls.py --check` to confirm, then re-export (the URLs are compiled in, re-uploading won't fix it) |
| Backend won't start: `[CONFIG] GAME_URL is not set` | `GAME_URL` / `BACKEND_URL` missing from `backend/.env` — required, no defaults (see `.env.example`) |
| Backend rejects requests with `origin_not_allowed` (403) | `GAME_URL`/`BACKEND_URL` in `backend/.env` don't match the domain the browser is actually on. For temporary origins use `EXTRA_ALLOWED_ORIGINS` instead of editing Go code |
| Deployed site shows a literal `__GAME_URL__` in a link/meta tag | `export/` was uploaded without running `setup/build.py` — it's what substitutes the placeholders, and it hard-fails if any are left |
| Share / replay / VS invite links point at the wrong domain | `game_url` in `setup/urls.ini` is wrong, or the export predates the last `apply_urls.py` run — the compiled value deliberately overrides whatever the backend sends |
| Every backend request 403s right after changing a key | `APP_SIGNING_KEY` in `ApiConfig.gd` and `backend/handlers/appsig.go` are out of sync (section 2b.3) |
| Game fails to load / hangs specifically on Safari or iOS, works fine on Chrome/Firefox | patch_safari.py (section 4b) wasn't run on this export — the pthread pool_size Safari chokes on is still baked into index.js/index.html |

---

## Checklist Before Uploading

- [ ] `setup/urls.ini` holds the right domains, and `python setup/apply_urls.py --check` passes — i.e. this export was made *after* the URLs were applied (section 2b)
- [ ] `GAME_URL` / `BACKEND_URL` set in `backend/.env`, `NEXT_PUBLIC_*` set in `admin/.env`
- [ ] `setup/build.py` reported no leftover URL placeholders
- [ ] export/index.html — the custom shell, not Godot's default
- [ ] patch_safari.py already run against this export (before build.py) — otherwise Safari/iOS players can fail to load the game
- [ ] export/index.wasm.part1 and .part2 present (or plain index.wasm if it was under 24 MiB) — generated by build.py, no single oversized index.wasm left behind
- [ ] export/wasm-loader.js present and referenced as the first `<script>` in index.html's `<head>` (only applies if a split happened)
- [ ] backend/replay-verifier/replay.exe (or replay.zip) — native build present and matching the backend host's OS
- [ ] export/robots.txt and export/sitemap.xml present, with the real domain filled in — build.py generates both from game/template and substitutes `__GAME_URL__` from setup/urls.ini (section 2b)

---

## 10. Admin Panel — What's On Each Tab

Open `http://<host>:PORT/admin` and log in with `ADMIN_USERNAME` /
`ADMIN_PASSWORD` from `backend/.env` — there's no admin account system
beyond those two values, so changing them is just an `.env` edit plus a
restart. The session cookie lasts 7 days.

- **Overview** — currently-playing sessions, recent sessions, replay
  worker queue health, and a server resources card (RAM / disk usage —
  see section 16).
- **Analytics** — daily/weekly player & session counts, playtime, NIM
  distributed, Nimiq wallet balance.
- **Completed / Flagged / Failed / All Sessions** — session browser,
  click into any session for the full replay analysis view (including
  whether that match was played with tap or gyro control). A session
  only shows up here once it's actually finished.
- **Leaderboard** — read-only view of daily/weekly rankings.
- **Players** — look up a specific player's stats, quest progress, reward
  history, connection-IP history.
- **Streaks** — every player's daily login-streak status (current day,
  longest run), aggregate NIM distributed via streak claims, and the
  reward formula's three knobs (base/extra-per-day/max NIM) plus the
  per-IP multi-account claim cap — all admin-editable here.
- **Logs** — aggregated client-side error/warning logs.
- **System** — leaderboard on/off switches, game update lock (Activate/
  Deactivate — section 11), replay verifier binary upload, "Remove All
  Replays" (section 12).
- **Database** — live key-count per data category in BadgerDB, with a
  clear button per category, plus the failed-replay archive (section 14).

---

## 11. Pushing a Game Update — Step by Step

This is the actual playbook for "I changed something in Godot and/or the
backend, now I need it live." Updating is just: build, deploy, and
optionally use the update lock to keep players off the site for a moment
while you do it.

### 11.1 The two builds that still move together

Every deploy touches up to two separate binaries, built from the same
Godot project, for two different purposes:

1. **Web export** (`export/` folder) — what players' browsers actually
   run. Built via Godot's Web export preset, then processed by
   `setup/build.py` (WASM splitting), then uploaded to Cloudflare Pages.
2. **Native / headless export** (`backend/replay-verifier/replay.exe` or
   `replay.zip`) — what the backend runs server-side to re-simulate every
   submitted replay and verify the score wasn't tampered with. Built via
   Godot's Windows/Linux export preset with the `--server-worker` /
   `--server-replay` headless entry points (see `Main.gd`'s `_ready()`).

**Both come from the same Godot project** — if you change gameplay logic
(movement, scoring, enemy behavior, anything that affects simulation),
rebuild and redeploy *both* together, or the web client and the server's
replay verifier will disagree on what the "correct" score should have
been for a given input log, and legitimate scores can end up flagged.

The backend doesn't check version-matching between client and server —
keeping these two builds in sync is a matter of discipline, not something
enforced for you.

### 11.2 Game Update Lock: Activate / Deactivate

Admin panel → System tab → **Game Update Lock**. One switch, two states:

- **Deactivate** (default) — no restriction, this is normal operation.
  Status shows "new games open."
- **Activate** — new games are blocked *immediately*, for everyone.
  Players mid-game can finish their current run; starting a *new* one
  shows a "Game updating" toast instead. Status shows "new games
  locked." Use this while you swap in a new build so nobody starts a
  session against a half-updated deploy.

While active, `Main.gd` polls `/backend/developer-mode` every 25 seconds
and blocks `_do_start_game()` with an English toast ("Game updating.
Please check back shortly — thanks for your patience!") instead of
starting a session. Click **Deactivate** once your new build is fully
live to resume play for everyone immediately.

### 11.3 Recommended order of operations

1. Finish your Godot changes. If any URL changed, edit `setup/urls.ini`
   and run `python setup/apply_urls.py` now — before any export
   (section 2b).
2. (Optional, recommended for gameplay-affecting changes) Admin panel →
   System → **Activate** the update lock so new games stop starting on
   the old build while you deploy.
3. Export the **native/headless** build, upload it via admin panel →
   System → Replay Verifier Binary (section 12). The worker pool restarts
   automatically and picks it up within a few seconds.
4. Export the **web** build, run `python patch_safari.py` (section 4b —
   Safari/iOS pool_size fix, must run before build.py), then
   `setup/build.py`, then upload `export/` to Cloudflare Pages (section
   15 — manual upload only).
5. Admin panel → System → **Deactivate** the update lock. Players can
   start new games again, now on the new version.
6. (Optional) Admin panel → System → **Remove All Replays** if you want
   to clear out replay logs recorded against the old build — doesn't
   touch scores/stats, only the raw recordings.

For small changes that don't affect scoring, you can skip steps 2 and 5
entirely and just redeploy — the lock is a courtesy to avoid confusing
mid-deploy behavior, not something enforced by the backend.

---

## 12. Updating the Replay Verifier Binary

This is how you get a newly exported native/headless build (section 3.2)
onto a live server without touching FTP/SSH — the admin panel uploads it
straight into place and hot-swaps it in.

**Step by step:**

1. Export the **native/headless** preset in Godot first (section 3.2/4) —
   you're uploading the output of that export, not the web build.
2. Log into the admin panel → **System** tab.
3. Find the **Replay Verifier Binary** card.
4. Click the file picker and choose the exported file:
   - `.zip` if the backend host runs Linux — the backend unpacks the
     binary + its `.pck` out of the zip automatically, you don't extract
     anything yourself first.
   - `.exe` if the backend host runs Windows — uploaded and run as-is,
     no unpacking needed.
5. Click **Upload & Replace**. A confirm dialog appears (it tells you the
   worker pool is about to restart) — confirm it.
6. That's it. The backend saves the file into `SERVERGAMES_DIR`
   (`backend/replay-verifier` by default), then restarts every persistent
   Godot worker process so they all relaunch against the new binary —
   this takes a few seconds, no backend restart and no downtime beyond
   that brief worker-pool restart. It goes live the instant the upload
   finishes; there's no separate "activate" step and nothing to schedule.

**Confirming it worked:** the same card shows a health indicator for the
currently-active binary (a background check pings it periodically) plus a
list of every file in that folder with its size and modified time — after
uploading, check that the modified time on your new file is recent and
the health indicator is still green.

This is the same folder documented in section 3.2 — the admin upload is
just a faster way to put a file there than doing it by hand on the server.

---

## 13. Leaderboards On/Off

Admin panel → System tab → Leaderboards.

- Two independent switches: **Daily leaderboard enabled** and **Weekly
  leaderboard enabled**.
- Both default to **on**.
- Backed by `DAILY_LEADERBOARD_ENABLED` / `WEEKLY_LEADERBOARD_ENABLED` in
  `backend/.env` (these are just the *initial* values — once you flip a
  switch from the admin panel, the saved DB value always wins over the
  env var from then on).
- `GET /backend/leaderboard` includes an `"enabled"` field in its
  response reflecting the current switch state for whichever period type
  was requested — the client can use this to hide a tab instead of
  showing an empty/stale list.

---

## 14. Database Tab & Failed Replay Archive

Admin panel → Database tab.

Every BadgerDB key-prefix is listed with a live count and a **Clear**
button. Categories marked **sensitive** (auth tokens, wallets, pending
rewards, app config, sessions, leaderboard winners) ask for a second
confirmation — they touch money, log everyone out, or reset settings.
The rest regenerate on their own and are safe to clear any time.

The **failed replay archive** is also here: every replay that crashed,
timed out, or came back as a `score_mismatch`, downloadable as JSON
(replay log + seed/char/player_seed) for manual debugging.

---

## 15. Deploying — the Full Picture

Putting sections 5–6 and 11–12 together, here's literally everything
that can change on a deploy and where each piece goes:

| What changed | Where it goes | How |
|---|---|---|
| Gameplay/UI (Godot project) | `export/` → Cloudflare Pages | Web export → `python patch_safari.py` (section 4b) → `setup/build.py` → manual dashboard upload (Deployments → Direct upload), or push to whatever branch the Pages project is Git-connected to |
| A domain | `setup/urls.ini` + both `.env`s | `apply_urls.py` → re-export → `patch_safari.py` → `build.py` → upload; update `backend/.env` and `admin/.env` and restart both processes (section 2b) |
| Server-side replay verification (same Godot project, headless export) | `backend/replay-verifier/` | Admin panel → System → Replay Verifier Binary upload (section 12) |
| Backend Go code | wherever the backend process runs | `go build .` (or `go run .` in dev), restart the process |
| Admin panel (Next.js) | wherever the admin process runs | `npm run build && npm start` (or restart if already running), restarted separately from the backend |

Deploying to Cloudflare Pages is always a manual step: drag-and-drop the
whole `export/` folder into the Pages project's dashboard (Deployments →
Direct upload), or push to whatever branch the Pages project is
Git-connected to.

The backend and admin app are two separate long-running processes (see
section 7) — updating one doesn't require restarting the other, except
when you specifically need the admin app to pick up new backend routes
(it doesn't — it's just a UI hitting the API, no restart needed for that
either. Only the backend Go binary itself needs restarting after a Go
code change).

---

## 16. System Resources

Admin panel → Overview tab (bottom card) shows goroutine count, Go heap
size, uptime and CPU core count, plus RAM and disk usage on Linux/macOS.
The RAM/disk bars simply don't render on Windows.

---

## 17. Running Unattended — systemd (boot-start + auto-restart)

On a real server you want the backend to start on boot and restart itself
on crash. One systemd unit does both. (The admin app comes along with it —
section 7.)

**1. Build a binary** — don't run `go run .` in production:

    cd backend
    go build -o nimjump-backend .

**2. Create `/etc/systemd/system/nimjump-backend.service`** (adjust `User`
and the paths):

    [Unit]
    Description=NimJump backend (also auto-starts the admin app)
    After=network.target

    [Service]
    Type=simple
    User=nimjump
    WorkingDirectory=/opt/nimjump/backend
    ExecStart=/opt/nimjump/backend/nimjump-backend
    Restart=always
    RestartSec=3
    # Time for the shutdown handler to close BadgerDB and kill the admin
    # child process before SIGKILL.
    TimeoutStopSec=10
    # If it crashes 5 times in 60s, something is actually broken — reboot
    # instead of systemd's default of marking the unit permanently `failed`
    # and sitting there dead until someone SSHes in.
    StartLimitIntervalSec=60
    StartLimitBurst=5
    StartLimitAction=reboot

    [Install]
    WantedBy=multi-user.target

**3. Enable it:**

    sudo systemctl daemon-reload
    sudo systemctl enable --now nimjump-backend

Day to day:

    sudo systemctl status nimjump-backend     # up? how long? last exit code
    sudo journalctl -u nimjump-backend -f     # backend + [ADMIN] logs, one stream
    sudo systemctl restart nimjump-backend    # after a new binary or config change

Two independent layers of recovery: `adminproc.go` restarts the admin app
if it crashes, systemd restarts the backend if *it* crashes. BadgerDB
reopens from `DB_PATH` intact across reboots.

**Not on Linux?** Use Task Scheduler (run at startup + "restart on
failure") or [NSSM](https://nssm.cc/) to install the binary as a Windows
service. Same binary and `.env`, different keep-alive mechanism.

