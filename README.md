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

## 7. Running the Admin Panel (Local Dev)

The admin folder at NimJump/admin is a separate app, not part of the
Godot export pipeline. To run it locally:

    cd admin
    npm install
    npm run dev

It serves on localhost — check the terminal output for the exact port.
This is independent of whether you've exported the web build or the
native build; it's a separate local dev server.

---

## 8. Running the Backend (Local Dev)

The backend folder at NimJump/backend is started directly from that
folder:

    cd backend
    go mod tidy
    go run .

This is separate from the admin dev server and from the export/build
pipeline — it just needs the replay.exe (or replay.zip) in
backend/replay-verifier/ to already be in place if you want replay
verification to actually work while it's running.

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
