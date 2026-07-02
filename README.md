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
- Know which OS you're exporting from — it determines which native
  export preset you use for the backend (see section 3.2)

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
validate replays server-side. Which preset you use depends on the OS
you're exporting from:

- Exporting on Linux → use the Linux/X11 export preset
- Exporting on Windows → use the Windows Desktop export preset

Whichever OS you build on is the build the backend will actually use —
if the backend server runs Linux but you export from Windows, the
backend won't be able to use that binary. Make sure the export platform
matches what the backend/replay-verifier host actually runs.

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
auto-restart on crash, survives reboots — see section 19.

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
  see section 14).
- **Analytics** — daily/weekly player & session counts, playtime, NIM
  distributed, Nimiq wallet balance.
- **Active / Completed / Flagged / Failed / All Sessions** — session
  browser, click into any session for the full replay analysis view.
- **Leaderboard** — read-only view of daily/weekly rankings.
- **Players / Player Search** — look up a specific player's stats, quest
  progress, reward history.
- **Logs** — aggregated client-side error/warning logs (includes
  `version_mismatch` entries — see section 13).
- **System** — leaderboard on/off switches, replay version, game update
  mode, replay verifier binary upload, "Remove All Replays" (sections
  11–13).
- **Database** — live key-count per data category in BadgerDB, with a
  clear button per category, plus the failed-replay archive (section 15).

---

## 11. Pushing a Game Update — Step by Step

This is the actual playbook for "I changed something in Godot and/or the
backend, now I need it live." Read this whole section before doing it
for the first time — the pieces (client version, replay version, update
mode) only make sense together.

### 11.1 The two builds that must move together

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
you almost always need to rebuild and redeploy *both*, or the web client
and the server's replay verifier will disagree on what the "correct"
score should have been for a given input log, and legitimate scores
start getting flagged/rejected.

### 11.2 Bumping the version number

`game/scripts/GameVersion.gd` has one constant:

    const CLIENT_VERSION := 1

The backend has a matching `REPLAY_VERSION` (env var default, changeable
live from admin → System tab). Every replay submit includes
`client_version`; the backend rejects (doesn't save, doesn't simulate)
any submit where it doesn't match `REPLAY_VERSION` exactly — see section
13 for exactly why this exists and what it does and doesn't protect
against.

**Whenever you change anything that affects gameplay simulation, bump
`CLIENT_VERSION` by 1** before exporting the web build, and set the admin
panel's replay version to the same new number once (and only once) both
the new web build and the new replay verifier binary are live. Until you
flip the admin panel's number, the *old* version stays authoritative — so
sequence matters (11.4).

If you're only changing something that doesn't affect simulation (UI
text, a sound, an admin-only feature) you don't need to touch the
version number at all — old and new clients keep working side by side.

### 11.3 Update modes: Force vs Normal

Admin panel → System tab → Game Update Mode. This exists to prevent the
awkward window where some players are on the old client (talking to the
old replay verifier) and some are on the new one, submitting scores that
don't reconcile.

- **Off** (default) — no restriction, this is normal operation.
- **Force** — new games are blocked *immediately*, for everyone, the
  moment you click it. Players mid-game can finish their current run;
  starting a *new* one shows a "Game updating" toast instead. Use this
  when you need the site down for an update right now (emergency fix,
  short maintenance window).
- **Normal** — nothing changes immediately. The backend keeps track of
  which weekly leaderboard period was current when you clicked it, and
  every minute checks whether that period has since ended (Monday
  00:00 UTC+3). The instant it rolls over, `update_active` flips on
  automatically, same effect as Force from that point on. Use this for
  a clean, non-disruptive update that lands exactly at the weekly
  leaderboard boundary — nobody's mid-week runs get cut off, and the
  next week starts entirely on the new version.

Either way, while `update_active` is true, `Main.gd` polls
`/backend/developer-mode` every 25 seconds and blocks `_do_start_game()`
with an English toast ("Game updating. Please check back shortly —
thanks for your patience!") instead of starting a session.

Click **Complete Update** once the new web export is live on Cloudflare
Pages *and* the new replay binary is uploaded — this resumes play for
everyone immediately.

### 11.4 Recommended order of operations

Doing these out of order is the most common way to end up with a pile of
falsely-rejected `version_mismatch` submits or, worse, wrongly-flagged
scores. Follow this order:

1. Finish your Godot changes.
2. Bump `game/scripts/GameVersion.gd`'s `CLIENT_VERSION`.
3. (Optional but recommended for gameplay-affecting changes) Admin panel
   → System → set update mode to **Force** or **Normal**. This stops new
   games on the *old* version from starting while you're mid-deploy.
4. Export the **native/headless** build, upload it via admin panel →
   System → Replay Verifier Binary (section 12). The worker pool restarts
   automatically and picks it up within a few seconds.
5. Export the **web** build, run `setup/build.py`, upload `export/` to
   Cloudflare Pages (section 16).
6. Admin panel → System → set **Replay version** to the same number you
   put in `CLIENT_VERSION`. From this instant, only submits from the new
   client are accepted.
7. Admin panel → System → click **Complete Update**. Players can start
   new games again, now on the new version.
8. (Optional) Admin panel → System → **Remove All Replays** if you want
   to clear out replay logs recorded against the old build (see 13.3) —
   doesn't touch scores/stats, only the raw recordings.

For small, simulation-safe changes (won't affect scoring), you can skip
steps 3, 6, 7 entirely and just redeploy — the version check only
matters when client and server would actually disagree on how to replay
something.

### 11.5 Doing all of this in one click — the Deploy tab

Steps 3–7 above can also be bundled into a single scheduled job from
admin panel → **Deploy tab**, instead of clicking through System tab
buttons one at a time. See section 18 for the full walkthrough — short
version: stage the new replay binary, tick "Deploy to Cloudflare Pages"
and "Set replay version to N", pick when it should run (right now, a
specific time, or automatically at the next daily/weekly leaderboard
boundary), and the backend does steps 3–7 itself, in order, the moment
the trigger fires — including automatically resuming play afterward.

---

## 12. Updating the Replay Verifier Binary

Admin panel → System tab → **Replay Verifier Binary** card.

- Accepts a `.zip` (Linux headless build — the backend extracts the
  binary + `.pck` from it automatically) or a `.exe` (Windows/Godot
  export, run as-is — useful if the backend host itself is Windows).
- On upload, the backend saves it into `SERVERGAMES_DIR`
  (`backend/replay-verifier` by default), clears its cached binary path,
  and restarts every persistent Godot worker process so they relaunch
  against the new binary — no backend restart needed.
- The card also shows whether the currently-active binary is healthy
  (a background monitor pings it periodically) and lists every file
  sitting in that folder with size/modified time.

This is the same folder documented in section 3.2 (native export) — the
admin upload just replaces doing it by hand over FTP/SSH.

---

## 13. Version Matching — What It Actually Protects Against

**This is not anti-cheat.** It exists purely to catch *you* forgetting to
update one half of a deploy — e.g. you push a new replay verifier binary
but forget to bump `CLIENT_VERSION` and redeploy the web build (or the
other way around). Without it, an old/new mismatch would silently
produce wrong `server_score` values or spurious flags, and you'd have no
idea why scores suddenly look broken.

### 13.1 How it works

- `game/scripts/GameVersion.gd`'s `CLIENT_VERSION` is sent as
  `client_version` on every `/backend/submit`.
- The backend compares it against `AppConfig.ReplayVersion` (env var
  `REPLAY_VERSION`, or admin panel → System → "Replay version").
- **Mismatch → the submit is silently rejected.** Nothing gets written to
  the database — no session, no score, no replay log, no simulation
  attempt. The backend responds `409 {"error":"version_mismatch"}`.
- The mismatch is logged as a client-log entry (`level: warn`,
  `message: version_mismatch`) with the player ID / IP attached — visible
  on the admin panel's Logs tab, so you can see if this is actually
  happening to real players (which would mean you deployed out of order)
  versus just being theoretical.

### 13.2 What happens on the client

`GameManager.gd`'s submit retry logic treats a `409 version_mismatch`
response as a **permanent rejection** — it's removed from the local
pending-submit queue immediately and **never retried**. It also shows a
one-time English toast: *"Your game version is out of date. Please
refresh the page to update."* This matters because without it, a stale
client would otherwise keep silently retrying a submit the server will
never accept, forever, doing nothing but wasting requests.

### 13.3 "Remove All Replays"

Admin panel → System tab → Danger Zone → **Remove All Replays**. Deletes
every stored replay log (and the whole failed-replay archive — section
15) but leaves every session's score, quest progress, and any rewards
already paid out completely untouched. Use this after a version bump if
you don't want old replay recordings (made against the previous build)
sitting around no longer meaning anything — they're just raw input logs,
not proof of anything on their own once the simulator that would replay
them has changed.

---

## 14. Leaderboards On/Off

Admin panel → System tab → Leaderboards & Versioning.

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

## 15. Database Tab & Failed Replay Archive

Admin panel → Database tab.

### 15.1 Category overview

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

### 15.2 Failed replay archive

Whenever server-side replay simulation fails outright (worker crash,
timeout, cancelled job) or a submitted score doesn't match what the
replay verifier computed (`score_mismatch`), an entry is archived here —
**in the database**, not as loose files on the server's disk. Each entry
is downloadable as a JSON file straight from the admin panel (includes
the base64 replay log + seed/char/player_seed, everything you need to
feed back into the replay binary by hand for manual debugging).

---

## 16. Deploying — the Full Picture

Putting sections 5–6 and 11–12 together, here's literally everything
that can change on a deploy and where each piece goes:

| What changed | Where it goes | How |
|---|---|---|
| Gameplay/UI (Godot project) | `export/` → Cloudflare Pages | Web export → `setup/build.py` → **admin panel Deploy tab** (or manual dashboard upload, see below) |
| Server-side replay verification (same Godot project, headless export) | `backend/replay-verifier/` | Admin panel → System (immediate) or Deploy tab (staged + scheduled) |
| Backend Go code | wherever the backend process runs | `go build .` (or `go run .` in dev), restart the process |
| Admin panel (Next.js) | wherever the admin process runs | `npm run build && npm start` (or restart if already running), restarted separately from the backend |

**There is still no `wrangler.toml` in this project** — but the backend
*can* push to Cloudflare Pages for you now (section 18), by shelling out
to `npx wrangler pages deploy` with credentials from env vars. No config
file, no `wrangler login` — just `CLOUDFLARE_API_TOKEN` /
`CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_PAGES_PROJECT` in `backend/.env`.
This needs Node/npm on the backend host (already required for the admin
app, so nothing extra to install in practice).

If you'd rather not configure that, the manual path still works exactly
as before: drag-and-drop the whole `export/` folder into the Pages
project's dashboard (Deployments → Direct upload), or push to whatever
branch the Pages project is Git-connected to.

The backend and admin app are two separate long-running processes (see
section 7) — updating one doesn't require restarting the other, except
when you specifically need the admin app to pick up new backend routes
(it doesn't — it's just a UI hitting the API, no restart needed for that
either. Only the backend Go binary itself needs restarting after a Go
code change).

---

## 17. System Resources

Admin panel → Overview tab (bottom card) shows: goroutine count, Go heap
size, uptime, CPU core count, and — on a Linux server — total/used RAM
and total/used disk space for the `DB_PATH` volume. Disk/RAM numbers
read `/proc/meminfo` and `statfs()`, which only work on Linux/macOS; on
a Windows dev machine those two numbers just don't show (nothing breaks,
the card simply doesn't render the bars).

---

## 18. The Deploy Tab — Scheduled Updates

This is the one-click version of section 11.4's manual checklist. Admin
panel → **Deploy tab**.

### 18.1 One-time setup

Set these in `backend/.env` (see `.env.example` for the same keys, blank):

    CLOUDFLARE_API_TOKEN=...       # Cloudflare dashboard → My Profile → API Tokens
    CLOUDFLARE_ACCOUNT_ID=...      # Cloudflare dashboard → any domain overview → sidebar
    CLOUDFLARE_PAGES_PROJECT=...   # Workers & Pages → your project → the slug in the URL
    CLOUDFLARE_EXPORT_DIR=../export   # default already matches this repo's layout
    CLOUDFLARE_PAGES_BRANCH=main      # whatever branch your Pages project treats as production

The Deploy tab shows a green "configured" badge once all three of
TOKEN/ACCOUNT_ID/PROJECT are set; until then the "Deploy to Cloudflare
Pages" checkbox stays disabled so you can't accidentally schedule
something that can't run.

Requires Node/npm on the backend host — the deploy runs
`npx --yes wrangler@3 pages deploy` under the hood, no global install, no
`wrangler.toml`, no interactive login (auth comes entirely from the two
env vars above, which Wrangler reads automatically in CI mode).

### 18.2 Staging a replay binary

Same file upload as System tab's Replay Verifier Binary card, but with
"Stage for later" — the file lands in a `staged/` folder and does
**nothing** until a scheduled job explicitly activates it. Check the
Deploy tab's config card to confirm it's staged before scheduling. You
can only have one staged file waiting at a time — uploading a new one
replaces it, and cancelling a pending job that would've activated it
discards it too.

### 18.3 Scheduling

Tick whichever of these three actions you want bundled together:

- **Activate staged replay binary** — swaps in whatever you staged in
  18.2, resets the cached binary path, restarts the worker pool.
- **Deploy to Cloudflare Pages** — runs Wrangler against
  `CLOUDFLARE_EXPORT_DIR`, deploying *whatever's sitting in that folder
  at the moment the job actually runs*. There's no separate "build" step
  here — export the web build and run `setup/build.py` yourself first
  (section 5), same as always; the Deploy tab only handles the upload.
- **Set replay version to N** — same as typing a number into System
  tab's "Replay version" field, just bundled into the same atomic job.

Then pick **when**:

- **Right now** — runs within ~15 seconds (the scheduler's poll interval).
- **At a specific time** — pick a date/time, runs the moment the clock
  hits it (checked every 15 seconds, so expect up to ~15s of slop).
- **When the daily leaderboard ends** — next UTC+3 midnight.
- **When the weekly leaderboard ends** — next Monday 00:00 UTC+3 (matches
  the same week boundary the weekly leaderboard itself resets on).

Only one job can be pending/running at a time — schedule a second one
and the backend tells you to cancel the first. A pending job can be
cancelled any time before it runs; a running one can't (it's already
doing the thing).

### 18.4 What actually happens when a job fires

In order:

1. New games get blocked immediately (same "Game updating" toast as
   Force update mode — section 11.3).
2. Staged replay binary activates, if you checked that box.
3. Cloudflare Pages deploy runs, if you checked that box — this is
   usually the slowest step (uploading however much the export folder
   weighs).
4. Replay version updates, if you set one.
5. If every checked step succeeded: new games are unblocked again,
   automatically — no separate "Complete Update" click needed.
6. If any step failed: the block **stays on** and the job is marked
   failed with the error in its log. Nothing after the failed step runs
   (e.g. if the binary activation fails, Cloudflare never gets touched).
   You'll need to look at the job's log (click the row to expand it),
   fix whatever's wrong, and schedule a fresh job — failed jobs aren't
   auto-retried.

### 18.5 "Close-safe" — what that actually means here

Every job is written to the database the moment you schedule it (not
held in memory) and its status is saved to the database at every step —
so restarting the backend never loses a scheduled job, and you can always
see exactly what happened by checking Deploy tab → job history.

What it deliberately does **not** do: silently resume or re-run a job
that was caught mid-execution by a backend restart. If that happens, the
job is marked `failed` with an explicit "backend restarted while this job
was running" message the next time the backend boots — a Cloudflare
deploy or binary swap isn't something that's always safe to blindly
repeat automatically, so this surfaces it for you to look at and
re-schedule manually instead of guessing.

### 18.6 The "mis gibi" scenario, end to end

Putting all of section 11 + 18 together, this is what a full update
looks like in practice:

1. You finish your Godot changes, bump `CLIENT_VERSION`, export the
   headless build.
2. Admin panel → Deploy tab → upload the new replay binary with
   "Stage for later".
3. Export the web build, run `setup/build.py`.
4. Deploy tab → tick all three checkboxes (activate binary / deploy
   Cloudflare / set replay version to the new number) → pick **"When the
   weekly leaderboard ends"** → Schedule.
5. Walk away. Players keep playing on the current version all week,
   scores keep counting toward the weekly leaderboard normally.
6. The moment the week rolls over: new games block for as long as the
   job actually takes (typically under a minute unless the Cloudflare
   upload is slow), the new binary + new web build + new replay version
   all go live together, and play resumes automatically — everyone's
   now on the new version, cleanly split at the week boundary.

---

## 19. Running Unattended — systemd (boot-start + auto-restart)

Everything so far assumes you're at a terminal running `go run .` by
hand. For a real server you want the backend (and with it, the admin
app — section 7 already made that one command) to: start automatically
when the machine boots, and restart itself automatically if it ever
crashes — without you having to SSH in and notice.

`systemd` (standard on basically every Linux server distro) does both
with one unit file. This is the "close-safe" / "kapanmama garantisi"
piece the deploy jobs (section 18) and the admin auto-start (section 7)
were already built to survive — this is what makes the survival
actually automatic instead of "works if you remember to restart it."

### 19.1 Build a real binary first

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
    # Don't let a crash-loop eat the box — after 5 restarts inside 60s,
    # systemd stops trying and the service shows as failed (check with
    # `systemctl status nimjump-backend` / `journalctl -u nimjump-backend`).
    StartLimitIntervalSec=60
    StartLimitBurst=5

    [Install]
    WantedBy=multi-user.target

What each close-safety piece is doing:

- **`Restart=always`** — the OS-level backstop. Whatever crashes the
  process (OOM kill, panic, `go build` produced a bad binary, anything)
  systemd brings it back within `RestartSec`. This is on top of, not
  instead of, the app-level auto-restart of the admin app (section 7)
  and the deploy job scheduler's own crash detection (section 18.5) —
  three independent layers, each catching a different kind of failure.
- **`WantedBy=multi-user.target`** — starts on boot, no manual step
  after a server reboot.
- **`TimeoutStopSec=10`** — gives the backend's shutdown handler (which
  cancels the admin app's child process, section 7) a moment to run
  before systemd forces it. A `systemctl stop`/`restart` is a normal
  SIGTERM, same as Ctrl+C — handled the same way either way.

### 19.3 Enable it

    sudo systemctl daemon-reload
    sudo systemctl enable --now nimjump-backend

`enable` makes it start on every future boot; `--now` also starts it
immediately. From here on:

    sudo systemctl status nimjump-backend     # is it up, how long, last exit code
    sudo journalctl -u nimjump-backend -f     # live logs — backend + [ADMIN]-prefixed admin app logs, same stream
    sudo systemctl restart nimjump-backend    # after deploying a new binary (19.1) or config change

### 19.4 What actually survives what

| Event | What happens |
|---|---|
| Admin app (Next.js) crashes | `adminproc.go` restarts it in-process within seconds (backoff, section 7) — backend itself is untouched |
| Backend process crashes/panics | systemd restarts the whole thing (`Restart=always`) within `RestartSec`; admin app comes back up with it |
| Server reboots | systemd starts the service on boot (`enable`); BadgerDB reopens from `DB_PATH` with everything intact |
| A deploy job is mid-run when any of the above happens | Marked `failed` on the next boot rather than silently resumed — see section 18.5. Nothing is lost (it's in BadgerDB), but it won't guess whether it's safe to redo automatically |
| You push new backend code | `go build -o nimjump-backend .` then `sudo systemctl restart nimjump-backend` — one restart, both backend and admin app come back |

### 19.5 If you're not on Linux

No `systemd` on Windows — use Task Scheduler (run at startup, "restart
on failure" under the task's Settings tab) or a small wrapper like
[NSSM](https://nssm.cc/) to install `nimjump-backend.exe` as a proper
Windows service with restart-on-crash. The binary and `.env` setup are
identical either way — only the "keep it running" mechanism changes.
