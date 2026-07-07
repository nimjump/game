"""
patch_webexport.py — export.bat tarafından her exporttan sonra calistirilir.
"""
import re, os

WEBEXPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "export")
JS_PATH   = os.path.join(WEBEXPORT, "index.js")
HTML_PATH = os.path.join(WEBEXPORT, "index.html")

# ── 1. game.js: emscripten version throw'lari ve pool_size fix ───────────────
js = open(JS_PATH, encoding="utf-8").read()
before = len(js)

js, n1 = re.subn(
    r'if\([a-zA-Z]+<\d+\)\{throw new Error\(`This emscripten[^`]+`\)\}',
    '/* version check removed */',
    js
)
js = re.sub(r'/\* version check removed \*/`\)\}', '/* version check removed */', js)
js, n2 = re.subn(r'pool_size:\s*[1-9]\d*', 'pool_size:0', js)

open(JS_PATH, "w", encoding="utf-8").write(js)
print(f"[patch] game.js: {n1} throw removed, {n2} pool_size fixed  ({before}->{len(js)} bytes)")

# ── 2. game.html: fileSizes + pool sizes + emscriptenPoolSize guncelle ────────
html = open(HTML_PATH, encoding="utf-8").read()

# fileSizes — Godot'un urettigi degerler (pck/wasm boyutlari her exportta degisir)
m = re.search(r'"fileSizes"\s*:\s*(\{[^}]+\})', html)
if m:
    print(f"[patch] game.html: fileSizes = {m.group(1)}")
else:
    print("[patch] WARNING: fileSizes bulunamadi")

# emscriptenPoolSize ve godotPoolSize 0 olmali
html, n3 = re.subn(r'"emscriptenPoolSize"\s*:\s*[1-9]\d*', '"emscriptenPoolSize":0', html)
html, n4 = re.subn(r'"godotPoolSize"\s*:\s*[1-9]\d*',      '"godotPoolSize":0',      html)

# Eski fetch+inject blogu varsa temiz <script src> ile degistir
fetch = re.search(
    r'<script[^>]*>\s*\(function\s*\(\)\s*\{[^<]*const gameUrl[^<]*</script>',
    html, re.DOTALL
)
if fetch:
    html = html[:fetch.start()] + '<script src="game.js" data-cfasync="false"></script>' + html[fetch.end():]
    print("[patch] game.html: fetch+inject blogu kaldirildi")

# Eski _godotEngineLoaded trigger varsa duzelt
old = 'window._startGodotSetup = initGodotGame;\nif (window._godotEngineLoaded) {\n  initGodotGame();\n}'
if old in html:
    html = html.replace(old, 'initGodotGame();')
    print("[patch] game.html: initGodotGame trigger duzeltildi")

open(HTML_PATH, "w", encoding="utf-8").write(html)
print(f"[patch] game.html: emscriptenPoolSize({n3}) godotPoolSize({n4}) fixed")

# ── 3. Eski brotli cache'leri sil ────────────────────────────────────────────
for name in ["game.js.fasthttp.br", "game.html.fasthttp.br"]:
    p = os.path.join(WEBEXPORT, name)
    if os.path.exists(p):
        try:
            os.remove(p)
            print(f"[patch] deleted {name}")
        except OSError:
            print(f"[patch] WARNING: {name} silinemedi — manuel sil")

print("[patch] Bitti. Backend'i yeniden baslatmayi unutma.")
