# NimJump — Full Export & Deploy Guide

This is not just a web export guide — it covers the full setup: the web
build for the browser, the native build the backend needs for replay
verification, compression, and deployment to Cloudflare Pages.

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
    ├── index.wasm.gz
    ├── index.wasm.br
    ├── index.pck
    └── _headers
```

---

## 1. Prerequisites

- Godot 4.7 exactly (check via Help → About Godot)
- Web export templates installed (Editor → Manage Export Templates)
- Python 3.9+ with pip install brotli
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
├── index.wasm        (uncompressed, ~30 MB)
├── index.pck
└── index.audio.worklet.js   (if using AudioWorklet)

backend/replay-verifier/
└── replay.exe (or replay.zip) + its .pck
```

Do not upload the export/ folder to Cloudflare yet — the .wasm still
needs compressing.

---

## 5. Compress the WASM Output

Run (from inside the setup folder):

    cd setup
    python build.py

This script does the rest of the export folder prep, not just
compression:

1. Compresses index.wasm into index.wasm.gz and index.wasm.br
2. Deletes the original uncompressed index.wasm (the ~30 MB one) — it's
   not needed once the compressed versions exist
3. Copies _headers and the assets/ folder from game/template into
   export/, overwriting whatever was there

So after running it, export/ has index.wasm.gz, index.wasm.br,
_headers, and assets/ — no plain index.wasm left behind, and no manual
copying needed on your end.

If you edit _headers or add something to assets/, do it in
game/template — that's the source. Editing the copies inside export/
directly will just get overwritten next time you run build.py.

---

## 6. Deploy to Cloudflare Pages

1. Cloudflare dashboard → Workers & Pages → the NimJump Pages project
2. Deployments → Direct upload (drag the whole export folder, including
   the generated _headers) or push via your Git-connected branch
3. Once live, open the site → DevTools → Network → reload
4. Check the index.wasm request:
   - Content-Encoding header should be br or gzip depending on what
     Cloudflare served
   - Transferred size should be a fraction of the original 30 MB
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
| index.wasm still transfers at full ~30 MB | build.py wasn't run before deploying, or the original index.wasm got re-added some other way |
| Backend replay-verifier fails to run the export | Native export platform doesn't match the OS the backend host runs on (see 3.2) |
| Game hangs on the loading bar | index.wasm and index.pck are from different export runs — always redo export → compress → deploy together, never mix files from different runs |
| Custom HTML Shell reset to blank | Some Godot version upgrades reset export preset fields — recheck section 3.1 after upgrading the editor |

---

## Checklist Before Uploading

- [ ] export/index.html — the custom shell, not Godot's default
- [ ] export/index.wasm.gz and export/index.wasm.br generated by build.py
- [ ] backend/replay-verifier/replay.exe (or replay.zip) — native build present and matching the backend host's OS
