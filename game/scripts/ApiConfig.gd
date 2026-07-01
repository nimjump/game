extends Node
# ── ApiConfig (autoload singleton) ───────────────────────────────────────────
# Single source of truth for the backend base URL, resolved at runtime so the
# game works no matter where it's hosted:
#
#   1. An explicit override (highest priority), useful for testing:
#        • URL query param  ?api=http://host:port
#        • localStorage key  nj_api_base
#   2. On the web, the page's own origin (window.location.origin) — so when the
#      game is served from the SAME port as the backend, the API "just works"
#      from whatever IP/domain it was opened on (localhost, LAN IP, etc.).
#   3. Native / fallback: DEFAULT_BASE below (change this one line for prod)
#
# Public game URL (share links, replay deep links, VS invites):
#   1. ?game_url=... query param or localStorage nj_game_url
#   2. Server-provided game_url (stats/submit responses) via set_game_url()
#   3. Web: window.location.origin
#   4. DEFAULT_GAME_URL fallback

const DEFAULT_BASE     := "http://127.0.0.1:8080"
const DEFAULT_GAME_URL := "https://nimjump.io"
# Scheme used to silently try to open the Nimiq Pay app on every visit.
# %s gets replaced with game_url()'s host — keep adjustable here.
const NIMIQ_DEEP_SCHEME := "nimiqpay://miniapp?url=%s"

var _cached     := ""
var _game_cached := ""

## Legacy alias — prefer game_url() which resolves at runtime.
const GAME_URL := DEFAULT_GAME_URL

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
		var origin : String = str(JavaScriptBridge.eval(
			"window.location.origin || ''", true))
		origin = origin.strip_edges()
		if origin != "" and origin != "null":
			return _trim_slash(origin)
	return DEFAULT_GAME_URL

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
		var origin : String = str(JavaScriptBridge.eval(
			"window.location.origin || ''", true))
		origin = origin.strip_edges()
		if origin != "" and origin != "null":
			return _trim_slash(origin)
	return DEFAULT_BASE

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

				function showToast(msg) { try { window._nj_toast_cb(msg); } catch(e) { console.warn('[Share] toast bridge failed', e); } }
				function showFallbackBanner(why) { try { window._nj_banner_cb(full, why); } catch(e) { console.warn('[Share] banner bridge failed', why, e); } }

				function tryClipboard() {
					console.log('[Share] tryClipboard()');
					if (navigator.clipboard && navigator.clipboard.writeText) {
						navigator.clipboard.writeText(full).then(function(){
							console.log('[Share] clipboard write succeeded');
							showToast('Score copied to clipboard!');
						}).catch(function(e){
							console.warn('[Share] clipboard write rejected', e);
							try {
								var ok = window.prompt('Copy this:', full);
								if (ok === null) showFallbackBanner('prompt-dismissed');
							} catch(e2) {
								showFallbackBanner('prompt-blocked');
							}
						});
					} else {
						try {
							var ok = window.prompt('Copy this:', full);
							if (ok === null) showFallbackBanner('no-clipboard-api');
						} catch(e3) {
							showFallbackBanner('no-prompt');
						}
					}
				}

				try {
					if (navigator.share) {
						var _shareStartedAt = Date.now();
						var SHARE_STALE_MS = 10000;
						navigator.share({ title: 'NimJump', text: text, url: url }).then(function(){
							console.log('[Share] navigator.share resolved (user shared)');
						}).catch(function(e){
							var elapsed = Date.now() - _shareStartedAt;
							if (e && e.name === 'AbortError') return;
							if (elapsed > SHARE_STALE_MS) return;
							tryClipboard();
						});
					} else {
						tryClipboard();
					}
				} catch (syncErr) {
					console.error('[Share] navigator.share threw:', syncErr);
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
