# NimJump — Full Export & Deploy Guide

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
│       └── assets/              (copied into export/ by build.py)
├── backend/
│   └── replay-verifier/
│       └── replay.exe           (or replay.zip — native export goes here)
├── admin/                       (run with npm install && npm run dev, serves on localhost)
├── setup/
│   └── build.py
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

---

## 2. Open the Project

1. Launch Godot 4.7
2. Project Manager → Import → select project.godot inside NimJump/game
3. Edit → wait for asset import to finish before touching export

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

For each preset:

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

## 5. Split the WASM Output

Run (from inside the setup folder):

    cd setup
    python build.py

Cloudflare Pages has a hard 25 MiB per-file limit. Instead of
compressing index.wasm to fit under it, build.py splits it:

1. Scans export/ for any .wasm file over 24 MiB (a little headroom
   under Cloudflare's 25 MiB cap).
2. For each oversized file, cuts it into two roughly-equal halves —
   index.wasm.part1 and index.wasm.part2 — and deletes the original
   index.wasm. It never exists as one file on disk after this, so it
   can never be uploaded (and rejected) as a single blob.
3. Writes wasm-loader.js into export/. This patches window.fetch so
   that when Godot's own loader requests "index.wasm", it instead
   fetches both .part1 and .part2, stitches the bytes back together,
   and hands Godot a normal-looking Response. Godot never knows the
   file was split.
4. Injects `<script src="wasm-loader.js"></script>` as the very first
   script in index.html's `<head>` — it has to run before Godot's own
   loader script, or the patch happens too late. Safe to re-run
   (won't duplicate the tag).
5. Copies _headers and the assets/ folder from game/template into
   export/, overwriting whatever was there.

If a .wasm file happens to be under 24 MiB, it's left alone as a
single file and no wasm-loader.js is generated at all — the split
step only kicks in when it's actually needed.

If you edit _headers or add something to assets/, do it in
game/template — that's the source. Editing the copies inside export/
directly will just get overwritten next time you run build.py.

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

The admin folder at NimJump/admin is a separate Next.js app, but you
never touch it directly — **the Go backend fully bootstraps and runs it
for you.** `go run .` (or the compiled binary) is the *only* command you
ever need:

- If `admin/node_modules` doesn't exist yet → the backend runs
  `npm install` for you.
- If there's no production build yet (`admin/.next/BUILD_ID` missing) →
  the backend runs `npm run build` for you.
- Only then does it start the admin app, and it supervises it from
  there — restarts it automatically (with backoff) if it ever crashes,
  and kills it cleanly when the backend shuts down.

This all lives in `backend/adminproc.go`. A completely fresh checkout —
`git clone`, fill in `backend/.env`, `go run .` — brings up the whole
stack with nothing run inside `admin/` by hand, ever. This is exactly
what fixes the "Could not find a production build" error from forgetting
to run `npm run build`: now the backend never lets that happen.

The backend reverse-proxies `http://<host>:PORT/admin` (default
`PORT=8080`) to the admin app on `ADMIN_PORT` (default 3001), and locks
both the admin UI and every `/backend/admin/*` API route behind a login
page + session cookie — required because the backend is exposed to the
public internet.

**One-time setup — just the two things Go can't infer for you:**

1. In `backend/.env`, set `ADMIN_USERNAME` and `ADMIN_PASSWORD` (see
   `backend/.env.example`). If either is missing, all admin routes stay
   locked (503) rather than being left open.
2. `admin/next.config.js` sets `basePath: "/admin"` — this applies in
   both dev and production, so the app is always reached at `/admin`,
   never at the root path.

**Then just run the backend:**

    cd backend
    go mod tidy
    go run .

First run will be slower (`npm install` + `npm run build` happening in
the background — watch for `[ADMIN_BUILD]`-prefixed log lines, can take
a minute or two depending on the machine). Every run after that is fast,
since those steps are skipped once already done.

Open `http://localhost:8080/admin` — that's it, no second terminal, no
manual `npm` anything. You're redirected to
`http://localhost:8080/admin/login` if you're not signed in yet. Only
port 8080 needs to be reachable from the internet; port 3001 can stay
bound to localhost. Everything the admin app itself prints shows up
prefixed `[ADMIN]` (or `[ADMIN_BUILD]` during setup), so you can watch
both processes from the one terminal.

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

---

## Checklist Before Uploading

- [ ] export/index.html — the custom shell, not Godot's default
- [ ] export/index.wasm.part1 and .part2 present (or plain index.wasm if it was under 24 MiB) — generated by build.py, no single oversized index.wasm left behind
- [ ] export/wasm-loader.js present and referenced as the first `<script>` in index.html's `<head>` (only applies if a split happened)
- [ ] backend/replay-verifier/replay.exe (or replay.zip) — native build present and matching the backend host's OS

---

## 10. Admin Panel — What's On Each Tab

Open `http://<host>:PORT/admin` (e.g. `http://localhost:8080/admin` in
dev). You'll land on a login page (not a browser popup) asking for a
username/password — credentials come from `ADMIN_USERNAME` /
`ADMIN_PASSWORD` in `backend/.env`. There is no separate admin account
system, no database table of admin users — it's exactly those two env
values, checked once at login. Change them any time by editing `.env`
and restarting the backend; there's nothing to migrate. A successful
login sets an HttpOnly session cookie good for 7 days (refreshed on
every request, so an admin actively using the panel is never logged out
mid-session) — "Log out" in the top-right of the panel clears it early.

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

1. Finish your Godot changes.
2. (Optional, recommended for gameplay-affecting changes) Admin panel →
   System → **Activate** the update lock so new games stop starting on
   the old build while you deploy.
3. Export the **native/headless** build, upload it via admin panel →
   System → Replay Verifier Binary (section 12). The worker pool restarts
   automatically and picks it up within a few seconds.
4. Export the **web** build, run `setup/build.py`, upload `export/` to
   Cloudflare Pages (section 15 — manual upload only).
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
- Backed by `DAILY_LEADERBOARD_ENABLED` / `WEEKLY_LEADERBOARD_ENABLED` in
  `backend/.env` (these are just the *initial* values — once you flip a
  switch from the admin panel, the saved DB value always wins over the
  env var from then on).
- `GET /backend/leaderboard` includes an `"enabled"` field in its
  response reflecting the current switch state for whichever period type
  was requested — the client can use this to hide a tab instead of
  showing an empty/stale list.
- **Weekly leaderboard ships disabled by default** (intentional, not a
  bug) — flip it on from the System tab whenever you're ready.

---

## 14. Database Tab & Failed Replay Archive

Admin panel → Database tab.

### 14.1 Category overview

Every meaningful key-prefix in BadgerDB is listed with a live count:
sessions, seed dedup index, auth tokens, nicknames, wallet registrations,
pending NIM reward queue, daily earn caps, player quests/progress,
client logs, failed-replay archive, leaderboard winner snapshots, and app
config. Each has a **Clear** button that deletes every key under that
category's prefix.

Categories marked **sensitive** (auth tokens, wallets, pending rewards,
app config, sessions, leaderboard winners) show a stronger double
confirmation before deleting — these either touch real money bookkeeping,
log everyone out, or reset settings back to `.env` defaults. The rest
(seed index, daily caps, quests, client logs, failed-replay archive) are
safe to clear any time; they regenerate/reset on their own.

### 14.2 Failed replay archive

Whenever server-side replay simulation fails outright (worker crash,
timeout, cancelled job) or a submitted score doesn't match what the
replay verifier computed (`score_mismatch`), an entry is archived here —
**in the database**, not as loose files on the server's disk. Each entry
is downloadable as a JSON file straight from the admin panel (includes
the base64 replay log + seed/char/player_seed, everything you need to
feed back into the replay binary by hand for manual debugging).

---

## 15. Deploying — the Full Picture

Putting sections 5–6 and 11–12 together, here's literally everything
that can change on a deploy and where each piece goes:

| What changed | Where it goes | How |
|---|---|---|
| Gameplay/UI (Godot project) | `export/` → Cloudflare Pages | Web export → `setup/build.py` → manual dashboard upload (Deployments → Direct upload), or push to whatever branch the Pages project is Git-connected to |
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

Admin panel → Overview tab (bottom card) shows: goroutine count, Go heap
size, uptime, CPU core count, and — on a Linux server — total/used RAM
and total/used disk space for the `DB_PATH` volume. Disk/RAM numbers
read `/proc/meminfo` and `statfs()`, which only work on Linux/macOS; on
a Windows dev machine those two numbers just don't show (nothing breaks,
the card simply doesn't render the bars).

---

## 17. Running Unattended — systemd (boot-start + auto-restart)

Everything so far assumes you're at a terminal running `go run .` by
hand. For a real server you want the backend (and with it, the admin
app — section 7 already made that one command) to: start automatically
when the machine boots, and restart itself automatically if it ever
crashes — without you having to SSH in and notice.

`systemd` (standard on basically every Linux server distro) does both
with one unit file. This is the "close-safe" / "kapanmama garantisi"
piece the admin auto-start (section 7) was already built to survive —
this is what makes the survival actually automatic instead of "works if
you remember to restart it."

### 17.1 Build a real binary first

Don't run `go run .` in production — it recompiles on every start and
leaves a build cache around. Compile once:

    cd backend
    go build -o nimjump-backend .

This produces a single `nimjump-backend` executable in `backend/`.
Rebuild it (`go build -o nimjump-backend .`) every time you change Go
code and want the change live — the systemd unit below just runs
whatever binary is sitting at that path.

### 19.2 The unit file

Create `/etc/systemd/system/nimjump-backend.service` (adjust `User` and
the two `/opt/nimjump/...` paths to match where you actually deployed
the repo):

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
    # Give the backend time to close BadgerDB / kill the admin child
    # process cleanly (see main.go's shutdown handler) before systemd
    # sends SIGKILL.
    TimeoutStopSec=10
    # Crash-loop cap: if the service fails to stay up 5 times within 60s,
    # something is seriously wrong (not just a one-off blip that
    # RestartSec=3 will quietly fix) — a corrupt binary, a stuck port
    # conflict, disk full, whatever. Rather than the old failure mode
    # (systemd just gives up and marks the unit `failed` PERMANENTLY,
    # never coming back on its own — the "sistemd'de kuruluydu ama geri
    # açmadı" symptom this project hit once), StartLimitAction below
    # escalates instead of giving up: it reboots the whole machine. A
    # reboot clears almost anything a repeated crash loop could be stuck
    # on (stale port bindings, wedged child processes, etc.), and unlike
    # "just retry forever" it doesn't burn CPU/log space failing in a
    # tight loop indefinitely if something is truly broken.
    StartLimitIntervalSec=60
    StartLimitBurst=5
    # Fires when the above burst limit is hit. `reboot` = a normal
    # `systemctl reboot` (other services get a clean shutdown first). Use
    # `reboot-force` instead if you want it to skip that and reboot
    # immediately — faster recovery, less graceful.
    StartLimitAction=reboot

    [Install]
    WantedBy=multi-user.target

What each close-safety piece is doing:

- **`Restart=always`** — the OS-level backstop. Whatever crashes the
  process (OOM kill, panic, `go build` produced a bad binary, anything)
  systemd brings it back within `RestartSec`. This is on top of, not
  instead of, the app-level auto-restart of the admin app (section 7)
  — two independent layers, each catching a different kind of failure.
- **`WantedBy=multi-user.target`** — starts on boot, no manual step
  after a server reboot.
- **`TimeoutStopSec=10`** — gives the backend's shutdown handler (which
  cancels the admin app's child process, section 7) a moment to run
  before systemd forces it. A `systemctl stop`/`restart` is a normal
  SIGTERM, same as Ctrl+C — handled the same way either way.
- **`StartLimitIntervalSec=60` / `StartLimitBurst=5` / `StartLimitAction=reboot`**
  — the three work together as one escalation ladder: individual crashes
  just get `Restart=always`'d back within `RestartSec` like normal, with
  no cap, no matter how many happen — as long as they're not bunched up
  fast. Only if 5 of them land inside the same 60-second window does it
  escalate to a full system reboot instead of the old behavior (marking
  the unit permanently `failed` and just sitting there dead until
  someone runs `systemctl reset-failed` by hand). A reboot is a much
  stronger recovery action than a bare service restart, and — unlike the
  permanently-`failed` trap — it's still fully automatic; nobody has to
  notice and intervene.
  Since main.go now fails fast and clearly on a port conflict (see its
  startup port probe) instead of silently limping through a slow
  partial-boot loop, hitting this burst limit at all should now be rare
  — but if it ever does happen, the reboot escalation makes sure it
  doesn't get stuck down waiting for someone to notice.

If you already have this unit installed with the old settings, editing
`/etc/systemd/system/nimjump-backend.service` on the server and running
`sudo systemctl daemon-reload` picks up the change (no reinstall needed).

### 17.2b Make sure logs actually survive a crash/reboot (do this once)

The reboot escalation above is only useful if the *logs explaining why*
survive the reboot too — otherwise you're back to "it happened, no way to
tell why," same as the incident that started this whole section. By
default, many distros only keep the systemd journal in a small
in-memory/volatile buffer that's wiped on every reboot. Make it
persistent and generously sized, once, on the server:

    sudo mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nStorage=persistent\nSystemMaxUse=500M\n' | sudo tee /etc/systemd/journald.conf.d/nimjump.conf
    sudo systemctl restart systemd-journald

- **`Storage=persistent`** — writes to `/var/log/journal/` on disk
  instead of a volatile in-memory ring buffer, so logs survive reboots
  (and the `StartLimitAction=reboot` above can't erase its own evidence).
- **`SystemMaxUse=500M`** — caps how much disk it's allowed to use so
  persistent logging can't slowly fill the disk; old entries get
  rotated out once the cap is hit, but 500MB at this project's log
  volume is weeks, not hours.

After this, `journalctl -u nimjump.service` (or `--list-boots` to see
every past boot) keeps working across reboots instead of only covering
whatever's happened since the box last came up.

### 17.3 Enable it

    sudo systemctl daemon-reload
    sudo systemctl enable --now nimjump-backend

`enable` makes it start on every future boot; `--now` also starts it
immediately. From here on:

    sudo systemctl status nimjump-backend     # is it up, how long, last exit code
    sudo journalctl -u nimjump-backend -f     # live logs — backend + [ADMIN]-prefixed admin app logs, same stream
    sudo systemctl restart nimjump-backend    # after deploying a new binary (17.1) or config change

### 17.4 What actually survives what

| Event | What happens |
|---|---|
| Admin app (Next.js) crashes | `adminproc.go` restarts it in-process within seconds (backoff, section 7) — backend itself is untouched |
| Backend process crashes/panics | systemd restarts the whole thing (`Restart=always`) within `RestartSec`; admin app comes back up with it |
| Server reboots | systemd starts the service on boot (`enable`); BadgerDB reopens from `DB_PATH` with everything intact |
| You push new backend code | `go build -o nimjump-backend .` then `sudo systemctl restart nimjump-backend` — one restart, both backend and admin app come back |

### 17.5 If you're not on Linux

No `systemd` on Windows — use Task Scheduler (run at startup, "restart
on failure" under the task's Settings tab) or a small wrapper like
[NSSM](https://nssm.cc/) to install `nimjump-backend.exe` as a proper
Windows service with restart-on-crash. The binary and `.env` setup are
identical either way — only the "keep it running" mechanism changes.

