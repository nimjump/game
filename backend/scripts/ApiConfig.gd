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
# Usage: replace `const BACKEND_URL := "..."` with
#        `var BACKEND_URL : String = ApiConfig.base_url()`

const DEFAULT_BASE := "http://127.0.0.1:8080"
const GAME_URL     := "https://nimjump.io"
const NIMIQ_DEEP   := "nimiqpay://miniapp?url=nimjump.io"

var _cached := ""

func base_url() -> String:
	if _cached != "":
		return _cached
	_cached = _resolve()
	return _cached

func _resolve() -> String:
	if OS.has_feature("web"):
		# 1a) explicit ?api=... query override
		var q : String = str(JavaScriptBridge.eval(
			"(new URLSearchParams(window.location.search)).get('api') || ''", true))
		q = q.strip_edges()
		if q != "":
			return _trim_slash(q)
		# 1b) localStorage override (nj_api_base)
		var ls : String = str(JavaScriptBridge.eval(
			"localStorage.getItem('nj_api_base') || ''", true))
		ls = ls.strip_edges()
		if ls != "":
			return _trim_slash(ls)
		# 2) same origin as the page (game + backend on one port)
		var origin : String = str(JavaScriptBridge.eval(
			"window.location.origin || ''", true))
		origin = origin.strip_edges()
		if origin != "" and origin != "null":
			return _trim_slash(origin)
	# 3) native build / fallback
	return DEFAULT_BASE

func _trim_slash(u: String) -> String:
	while u.ends_with("/"):
		u = u.substr(0, u.length() - 1)
	return u


## Share score via Web Share API (mobile native sheet) or clipboard fallback.
## text_override: custom message, leave "" for default.
func share_score(score: int, text_override: String = "") -> void:
	if not OS.has_feature("web"):
		return
	var msg := text_override
	if msg == "":
		msg = "I scored %d in NimJump! Can you beat me?" % score
	var js := """
		(function() {
			var url  = '%s';
			var text = %s;
			if (navigator.share) {
				navigator.share({ title: 'NimJump', text: text, url: url }).catch(function(){});
			} else {
				navigator.clipboard.writeText(text + '\\n' + url).catch(function(){
					prompt('Copy this link:', url);
				});
			}
		})();
	""" % [GAME_URL, JSON.stringify(msg)]
	JavaScriptBridge.eval(js, true)
