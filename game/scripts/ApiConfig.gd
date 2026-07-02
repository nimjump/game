extends Node
# ── ApiConfig (autoload singleton) ───────────────────────────────────────────
# Single source of truth for the backend base URL, resolved at runtime so the
# game works no matter where it's hosted or deployed. Nothing below is baked
# into the binary as "the" backend — every value is an overridable fallback.
#
# Resolution order for the API base URL:
#   1. An explicit override (highest priority), useful for testing:
#        • Web: URL query param  ?api=http://host:port
#        • Web: localStorage key  nj_api_base
#        • Native: command-line arg  --api=http://host:port
#        • Native: environment variable  NIMJUMP_API_BASE
#   2. On the web, the page's own origin (window.location.origin) — so when the
#      game is served from the SAME port as the backend, the API "just works"
#      from whatever IP/domain it was opened on (localhost, LAN IP, etc.).
#   3. Native: a local config file (config.cfg next to the executable, or
#      user://config.cfg) — lets ops change the backend post-build with no
#      recompile and no editing of this script. Format:
#        [api]
#        base="https://api.example.com"
#        game_url="https://example.com"
#   4. _FALLBACK_BASE below — only used if nothing above resolved anything.
#      This is a local-dev convenience, never a production value.
#
# Public game URL (share links, replay deep links, VS invites) follows the
# same pattern:
#   1. ?game_url=... query param / localStorage nj_game_url (web)
#      or --game-url=... / NIMJUMP_GAME_URL env var (native)
#   2. Server-provided game_url (stats/submit responses) via set_game_url()
#   3. Web: window.location.origin
#   4. Native config file entry (game_url key)
#   5. _FALLBACK_GAME_URL — local-dev-only last resort

const CONFIG_FILE_NAME := "config.cfg"

# ════════════════════════════════════════════════════════════════════════
#  BURAYA KENDİ BACKEND URL'İNİ YAZ (deploy ettiğin domain/IP)
#  Örnek:  const PROD_BASE := "https://api.nimjump.io"
#  Örnek:  const PROD_BASE := "http://1.2.3.4:8080"
# ════════════════════════════════════════════════════════════════════════
const PROD_BASE     := "https://backbone.zetashare.com"   # <-- backend API URL'i
const PROD_GAME_URL := "https://game.zetashare.com"        # <-- oyunun public URL'i (share/replay/VS invite linkleri)

# Local-dev-only last-resort values. These are intentionally NOT "the"
# production backend — real deployments must set NIMJUMP_API_BASE / --api=
# or ship a config.cfg next to the executable. Kept here only so the game
# still boots on a bare checkout with zero configuration.
const _FALLBACK_BASE     := "http://127.0.0.1:8080"
const _FALLBACK_GAME_URL := "http://127.0.0.1:8080"
# Scheme used to silently try to open the Nimiq Pay app on every visit.
# %s gets replaced with game_url()'s host — keep adjustable here.
const NIMIQ_DEEP_SCHEME := "nimiqpay://miniapp?url=%s"

var _cached     := ""
var _game_cached := ""

## Outgoing links (share, replay, VS invite, etc) are passed through as-is.
func tag_url(url: String) -> String:
	return url

## Runtime public game URL for share/replay links.
func game_url() -> String:
	if _game_cached != "":
		return _game_cached
	_game_cached = _resolve_game_url()
	return _game_cached

## Called when backend returns game_url (stats, config, etc).
func set_game_url(url: String) -> void:
	url = _trim_slash(url.strip_edges())
	if url != "":
		_game_cached = url

func replay_url(session_id: String) -> String:
	if session_id.strip_edges() == "":
		return tag_url(game_url())
	return tag_url(game_url() + "?replay=" + session_id.uri_encode())

func _resolve_game_url() -> String:
	var prod := PROD_GAME_URL.strip_edges()
	if prod == "":
		prod = PROD_BASE.strip_edges()

	if OS.has_feature("web"):
		var q : String = str(JavaScriptBridge.eval(
			"(new URLSearchParams(window.location.search)).get('game_url') || ''", true))
		q = q.strip_edges()
		if q != "":
			return _trim_slash(q)
		var ls : String = str(JavaScriptBridge.eval(
			"localStorage.getItem('nj_game_url') || ''", true))
		ls = ls.strip_edges()
		if ls != "":
			return _trim_slash(ls)
		if prod != "":
			return _trim_slash(prod)
		var origin : String = str(JavaScriptBridge.eval(
			"window.location.origin || ''", true))
		origin = origin.strip_edges()
		if origin != "" and origin != "null":
			return _trim_slash(origin)
		return _FALLBACK_GAME_URL

	# Native: cmdline arg > env var > PROD_GAME_URL/PROD_BASE > config file > local-dev fallback.
	var cli := _cmdline_value("--game-url=")
	if cli != "":
		return _trim_slash(cli)
	var env := OS.get_environment("NIMJUMP_GAME_URL").strip_edges()
	if env != "":
		return _trim_slash(env)
	if prod != "":
		return _trim_slash(prod)
	var cfg := _config_value("game_url")
	if cfg != "":
		return _trim_slash(cfg)
	return _FALLBACK_GAME_URL


## Reads --key=value from the command line, e.g. _cmdline_value("--api=").
func _cmdline_value(prefix: String) -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""


## Reads an [api] key from a config.cfg checked in two locations, in order:
##   1. user://config.cfg — per-user override dir, no rebuild needed
##   2. config.cfg placed next to the exported executable
## Example file:
##   [api]
##   base="https://api.example.com"
##   game_url="https://example.com"
func _config_value(key: String) -> String:
	var cfg := ConfigFile.new()
	var user_path := "user://" + CONFIG_FILE_NAME
	if cfg.load(user_path) == OK:
		var v : String = str(cfg.get_value("api", key, ""))
		if v.strip_edges() != "":
			return v.strip_edges()

	var exe_dir := OS.get_executable_path().get_base_dir()
	var side_path := exe_dir.path_join(CONFIG_FILE_NAME)
	var cfg2 := ConfigFile.new()
	if cfg2.load(side_path) == OK:
		var v2 : String = str(cfg2.get_value("api", key, ""))
		if v2.strip_edges() != "":
			return v2.strip_edges()
	return ""

## Builds the nimiqpay:// deep link from game_url().
func nimiq_deep_link() -> String:
	var host := game_url().replace("https://", "").replace("http://", "")
	return NIMIQ_DEEP_SCHEME % host

func base_url() -> String:
	if _cached != "":
		return _cached
	_cached = _resolve()
	return _cached

func _resolve() -> String:
	if OS.has_feature("web"):
		var q : String = str(JavaScriptBridge.eval(
			"(new URLSearchParams(window.location.search)).get('api') || ''", true))
		q = q.strip_edges()
		if q != "":
			return _trim_slash(q)
		var ls : String = str(JavaScriptBridge.eval(
			"localStorage.getItem('nj_api_base') || ''", true))
		ls = ls.strip_edges()
		if ls != "":
			return _trim_slash(ls)
		if PROD_BASE.strip_edges() != "":
			return _trim_slash(PROD_BASE)
		var origin : String = str(JavaScriptBridge.eval(
			"window.location.origin || ''", true))
		origin = origin.strip_edges()
		if origin != "" and origin != "null":
			return _trim_slash(origin)
		return _FALLBACK_BASE

	# Native: cmdline arg > env var > PROD_BASE > config file > local-dev fallback.
	var cli := _cmdline_value("--api=")
	if cli != "":
		return _trim_slash(cli)
	var env := OS.get_environment("NIMJUMP_API_BASE").strip_edges()
	if env != "":
		return _trim_slash(env)
	if PROD_BASE.strip_edges() != "":
		return _trim_slash(PROD_BASE)
	var cfg := _config_value("base")
	if cfg != "":
		return _trim_slash(cfg)
	return _FALLBACK_BASE

func _trim_slash(u: String) -> String:
	while u.ends_with("/"):
		u = u.substr(0, u.length() - 1)
	return u


## Share score via Web Share API (mobile native sheet) or clipboard fallback.
## text_override: custom message. share_url: link opened by Nimiq Pay / browser.
## Call synchronously inside button pressed handler (user activation window).
func share_score(score: int, text_override: String = "", share_url: String = "") -> void:
	var url := share_url.strip_edges()
	if url == "":
		url = tag_url(game_url())
	var msg := text_override
	if msg == "":
		if url.find("?replay=") >= 0:
			msg = "I scored %d in NimJump! Can you beat me? Watch my replay: %s" % [score, url]
		else:
			msg = "I scored %d in NimJump! Can you beat me? %s" % [score, url]
	# Avoid duplicating the URL when the message already contains it.
	var full := msg if url != "" and url in msg else msg + "\n" + url
	if OS.has_feature("web"):
		var toast_cb := JavaScriptBridge.create_callback(_on_share_toast)
		var banner_cb := JavaScriptBridge.create_callback(_on_share_banner)
		JavaScriptBridge.get_interface("window")._nj_toast_cb = toast_cb
		JavaScriptBridge.get_interface("window")._nj_banner_cb = banner_cb
		var js := """
			(function() {
				console.log('[Share] share_score() invoked');
				var url  = %s;
				var text = %s;
				var full = %s;
				console.log('[Share] url=', url, 'text=', text);

				// If the toast bridge itself fails for some reason, fall through to
				// the banner bridge as a second attempt — belt and suspenders so
				// there's truly no dead-silent outcome.
				function showToast(msg) {
					try { window._nj_toast_cb(msg); }
					catch(e) {
						console.warn('[Share] toast bridge failed, trying banner', e);
						try { window._nj_banner_cb(msg, 'toast-bridge-failed'); } catch(e2) { console.error('[Share] banner bridge also failed', e2); }
					}
				}
				function showFallbackBanner(why) { try { window._nj_banner_cb(full, why); } catch(e) { console.warn('[Share] banner bridge failed', why, e); } }

				// BUG FIX: inside embedded WebViews (e.g. Nimiq Pay's in-app browser),
				// navigator.clipboard.writeText() commonly rejects — WebViews often
				// don't grant the async Clipboard permission at all — and the old
				// fallback here was window.prompt(), which most Android WebViews
				// never implement (no WebChromeClient.onJsPrompt override), so it
				// either does nothing or throws immediately. Net effect: total
				// silence, no toast, nothing copied — exactly what was reported.
				// Fix: try the legacy execCommand('copy') trick FIRST — it works
				// through a hidden textarea + a real selection/copy, which is far
				// more widely supported inside restrictive WebViews than the async
				// Clipboard API since it doesn't need a permissions grant. Only if
				// that ALSO fails do we fall through to the async API, and finally
				// to the in-game banner (with prompt() dropped entirely).
				function execCommandCopy() {
					var ta = null;
					try {
						ta = document.createElement('textarea');
						ta.value = full;
						ta.setAttribute('readonly', '');
						// Off-screen but still a real, focusable/selectable element —
						// execCommand('copy') requires an actual selection to exist,
						// display:none or zero-size elements can't be selected in
						// some WebViews so this stays fully laid out, just off-screen.
						ta.style.position = 'fixed';
						ta.style.top = '-9999px';
						ta.style.left = '-9999px';
						ta.style.fontSize = '16px';   // avoid iOS Safari auto-zoom on focus
						document.body.appendChild(ta);

						// iOS Safari/WebView: textarea.select() alone is unreliable —
						// needs an explicit Range+Selection, plus setSelectionRange as
						// a belt-and-suspenders second pass.
						var isIOS = /ipad|iphone|ipod/i.test(navigator.userAgent);
						if (isIOS) {
							var range = document.createRange();
							range.selectNodeContents(ta);
							var sel = window.getSelection();
							sel.removeAllRanges();
							sel.addRange(range);
							ta.setSelectionRange(0, 999999);
						} else {
							ta.focus();
							ta.select();
						}
						return document.execCommand('copy');
					} catch (e) {
						console.warn('[Share] execCommand copy failed', e);
						return false;
					} finally {
						// Always clean up, even if execCommand itself threw.
						if (ta && ta.parentNode) ta.parentNode.removeChild(ta);
					}
				}

				function tryClipboard() {
					console.log('[Share] tryClipboard()');
					if (execCommandCopy()) {
						console.log('[Share] execCommand copy succeeded');
						showToast('Score copied to clipboard!');
						return;
					}
					if (navigator.clipboard && navigator.clipboard.writeText) {
						navigator.clipboard.writeText(full).then(function(){
							console.log('[Share] clipboard.writeText succeeded');
							showToast('Score copied to clipboard!');
						}).catch(function(e){
							console.warn('[Share] clipboard write rejected', e);
							showFallbackBanner('clipboard-blocked');
						});
					} else {
						showFallbackBanner('no-clipboard-support');
					}
				}

				// Every path below must end in a showToast/showFallbackBanner call —
				// no silent "nothing happened" outcome, per explicit request. That
				// includes the user dismissing the native share sheet (AbortError)
				// and the stale/late-resolve case, which used to just `return`.
				try {
					if (navigator.share) {
						var _shareStartedAt = Date.now();
						var SHARE_STALE_MS = 10000;
						navigator.share({ title: 'NimJump', text: text, url: url }).then(function(){
							console.log('[Share] navigator.share resolved (user shared)');
							showToast('Shared!');
						}).catch(function(e){
							console.warn('[Share] navigator.share rejected/cancelled', e);
							var elapsed = Date.now() - _shareStartedAt;
							if (e && e.name === 'AbortError') {
								showToast('Share cancelled');
								return;
							}
							if (elapsed > SHARE_STALE_MS) {
								showToast('Share timed out — copying instead');
							}
							tryClipboard();
						});
					} else {
						tryClipboard();
					}
				} catch (syncErr) {
					console.error('[Share] unexpected error:', syncErr);
					// Last-resort catch-all — even if something above threw in a way
					// none of the inner try/catches anticipated, still surface it
					// in-game instead of failing completely silently.
					tryClipboard();
				}
			})();
		""" % [JSON.stringify(url), JSON.stringify(msg), JSON.stringify(full)]
		JavaScriptBridge.eval(js, true)
	else:
		DisplayServer.clipboard_set(full)
		Toast.get_instance().show_toast("Copied to clipboard!", Toast.Kind.SUCCESS)


func _on_share_toast(args: Array) -> void:
	var msg: String = str(args[0]) if args.size() > 0 else ""
	Toast.get_instance().show_toast(msg, Toast.Kind.SUCCESS)


func _on_share_banner(args: Array) -> void:
	var full_text: String = str(args[0]) if args.size() > 0 else ""
	Toast.get_instance().show_toast("Couldn't share automatically — copy your score: " + full_text, Toast.Kind.WARN)
