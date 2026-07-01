extends Node

signal nimiq_ready(address: String, label: String, avatar: String, device_id: String)
signal auth_success(token: String, player_id: String)
signal auth_failed(reason: String)

var BACKEND_URL : String = ApiConfig.base_url()   # resolved at runtime (same origin on web)
const LS_AUTH_TOKEN := "nj_auth_token"
const LS_AUTH_PID   := "nj_auth_pid"

var nimiq_address := ""
var nimiq_label   := ""
var nimiq_avatar  := ""
var device_id     := ""
var is_ready      := false
var _poll_started := false

# Auth
var auth_token     := ""
var auth_player_id := ""
var auth_verified  := false
var _restore_network_failed := false  # true = offline restore, don't trigger re-sign
var auth_attempted := false
var auth_expires_at : int = 0   # unix timestamp


func _ready() -> void:
	if OS.has_feature("web"):
		# Check for existing token in localStorage first
		_try_restore_session()
		# _poll() is no longer called from _ready(), but from Main._build_game()
	else:
		# Editor fallback
		nimiq_address  = "TEST_ADDRESS"
		nimiq_label    = "TEST"
		nimiq_avatar   = ""
		device_id      = "dev"
		auth_token     = "dev_token"
		auth_player_id = "TEST_ADDRESS"
		auth_verified  = true
		is_ready       = true
		nimiq_ready.emit(nimiq_address, nimiq_label, nimiq_avatar, device_id)
		auth_success.emit(auth_token, auth_player_id)


func _poll() -> void:
	if _poll_started: return  # prevent double call
	_poll_started = true
	print("[NimiqBridge] _poll() START web=%s" % str(OS.has_feature("web")))
	if not OS.has_feature("web"): return

	# _nimiqAddress dolana kadar max 15 saniye bekle (0.25s × 60)
	for _w in 60:
		var _a = JavaScriptBridge.eval("window._nimiqAddress || ''", true)
		var _as := str(_a) if _a != null else ""
		if _as != "" and _as != "null":
			break
		await get_tree().create_timer(0.25).timeout

	# Adresi oku
	var addr_raw = JavaScriptBridge.eval("window._nimiqAddress || ''", true)
	nimiq_address = str(addr_raw) if addr_raw != null else ""
	print("[NimiqBridge] got addr=%s" % nimiq_address)

	var label_raw = JavaScriptBridge.eval("window._nimiqLabel || ''", true)
	nimiq_label = str(label_raw) if label_raw != null else ""

	var dev_raw = JavaScriptBridge.eval("window._nimiqDeviceId || ''", true)
	device_id = str(dev_raw) if dev_raw != null else ""

	var is_nimiq := nimiq_address != "" and nimiq_address != "null" and nimiq_address != "undefined"
	print("[NimiqBridge] poll done is_nimiq=%s addr=%s" % [str(is_nimiq), nimiq_address.left(12)])

	if not is_nimiq:
		nimiq_address = ""
		nimiq_label   = "Guest"
		nimiq_avatar  = ""
		device_id     = ""
		is_ready      = true
		nimiq_ready.emit(nimiq_address, nimiq_label, nimiq_avatar, device_id)
		return

	# Avatar data URL'yi oku
	var av_raw = JavaScriptBridge.eval("window._nimiqAvatar || ''", true)
	nimiq_avatar = str(av_raw) if av_raw != null else ""
	if nimiq_avatar.length() > 10:
		print("[NimiqBridge] avatar ready len=%d" % nimiq_avatar.length())
	else:
		print("[NimiqBridge] avatar empty")
	is_ready = true

	# _try_restore_session() is async HTTP — may not finish before poll starts.
	# If token is in localStorage, wait up to 3s for restore to finish.
	if not auth_verified:
		var has_token = JavaScriptBridge.eval("!!localStorage.getItem('nj_auth_token')", true)
		if has_token:
			print("[NimiqBridge] waiting for session restore...")
			for _sr in 20:
				await get_tree().create_timer(0.25).timeout
				if auth_verified:
					break

	# If token is valid but address differs (account changed) — re-sign
	if auth_verified and auth_player_id != "" and nimiq_address != "" and \
	   auth_player_id != nimiq_address:
		print("[NimiqBridge] address mismatch — re-auth player=%s addr=%s" % [auth_player_id.left(8), nimiq_address.left(8)])
		auth_verified = false
		auth_token = ""
		auth_player_id = ""
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_token')", true)
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_pid')", true)

	print("[NimiqBridge] emit nimiq_ready addr=%s auth_verified=%s" % [nimiq_address.left(12), str(auth_verified)])
	nimiq_ready.emit(nimiq_address, nimiq_label, nimiq_avatar, device_id)
	if not auth_verified and not _restore_network_failed:
		print("[NimiqBridge] not verified — starting sign auth...")
		_do_sign_auth()
	elif _restore_network_failed:
		print("[NimiqBridge] network was offline during restore — skipping sign, will retry when online")


## Check token in localStorage — emit auth_success if valid
func _try_restore_session() -> void:
	if not OS.has_feature("web"): return
	var token  = JavaScriptBridge.eval("localStorage.getItem('%s')" % LS_AUTH_TOKEN, true)
	var pid    = JavaScriptBridge.eval("localStorage.getItem('%s')" % LS_AUTH_PID, true)
	if token == null or str(token) == "null" or str(token) == "": return
	# Ask backend if token is valid
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		# Network error / timeout — backend unreachable, do not touch token
		if result != HTTPRequest.RESULT_SUCCESS or code == 0:
			var stored_exp : int = int(str(JavaScriptBridge.eval("parseInt(localStorage.getItem('nj_auth_exp') || '0', 10)", true)))
			var now_unix   : int = int(Time.get_unix_time_from_system())
			if stored_exp > now_unix + 60:
				# Not expired — trust token offline, mark so poll() skips _do_sign_auth
				auth_token      = str(token)
				auth_player_id  = str(pid)
				auth_expires_at = stored_exp
				auth_verified   = true
				_restore_network_failed = false  # we're fine
				print("[NimiqBridge] Offline restore — trusting local token player=%s" % auth_player_id.left(8))
				auth_success.emit(auth_token, auth_player_id)
			else:
				# Expired but offline — leave token alone, set flag so poll() won't re-sign
				_restore_network_failed = true
				print("[NimiqBridge] Offline + token expired — skipping re-sign until online")
			return
		if code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				if d.get("ok", false):
					var restored_token    : String = str(token)
					var restored_pid      : String = str(d.get("player_id", pid))
					var restored_exp      : int    = int(d.get("expires_at", 0))
					var now_unix          : int    = int(Time.get_unix_time_from_system())
					var secs_left         : int    = restored_exp - now_unix
					auth_token      = restored_token
					auth_player_id  = restored_pid
					auth_expires_at = restored_exp
					auth_verified   = true
					print("[NimiqBridge] Session restored player=%s expires=%d (%dd left)" % [auth_player_id.left(8), auth_expires_at, secs_left / 86400])
					auth_success.emit(auth_token, auth_player_id)
					return
		# Backend says token invalid (401, etc.) — clear and re-sign
		print("[NimiqBridge] Token rejected by server — clearing, re-sign will follow from poll")
		JavaScriptBridge.eval("localStorage.removeItem('%s')" % LS_AUTH_TOKEN, true)
		JavaScriptBridge.eval("localStorage.removeItem('%s')" % LS_AUTH_PID, true)
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_exp')", true)
		auth_token      = ""
		auth_player_id  = ""
		auth_verified   = false
		auth_expires_at = 0
		# poll() is waiting on auth_verified — it will call _do_sign_auth() when loop ends
	)
	http.request(BACKEND_URL + "/backend/auth/me?token=" + str(token).uri_encode())


## Sign-based auth flow: get challenge → sign → verify → store token
func _do_sign_auth() -> void:
	print("[NimiqBridge] _do_sign_auth called auth_verified=%s addr=%s" % [str(auth_verified), nimiq_address.left(12)])
	if not OS.has_feature("web"): return
	if auth_verified: return  # already logged in

	# 1. Get challenge
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("[NimiqBridge] Challenge fetch failed: %d" % code)
			auth_failed.emit("challenge_fetch_failed")
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			auth_failed.emit("challenge_parse_failed")
			return
		var d : Dictionary = j.get_data()
		var challenge : String = str(d.get("challenge", ""))
		if challenge == "":
			auth_failed.emit("empty_challenge")
			return
		# 2. Call window.nimiq.sign(challenge)
		_sign_and_verify(challenge)
	)
	http.request(BACKEND_URL + "/backend/auth/challenge")


## Calls window.nimiq.sign() and sends result to backend
func _sign_and_verify(challenge: String) -> void:
	if not OS.has_feature("web"): return

	NimiqJS.start_sign(challenge)
	print("[NimiqBridge] waiting for sign result...")
	var sd := await NimiqJS.await_sign(60.0)
	print("[NimiqBridge] sign result: %s" % str(sd))
	auth_attempted = true   # denendi, kabul ya da red fark etmez

	if not sd.get("ok", false):
		var err := str(sd.get("error", sd.get("err", "user_rejected")))
		print("[NimiqBridge] Sign not completed: %s" % err)
		auth_failed.emit(err)
		return

	var pub_key   : String = str(sd.get("publicKey", ""))
	var signature : String = str(sd.get("signature", ""))
	print("[SIG1] %s" % signature.left(64))
	print("[SIG2] %s" % signature.right(signature.length() - 64))
	print("[SIGLEN] %d" % signature.length())
	_verify_with_backend(challenge, pub_key, signature)


## Sends challenge + signature to backend, receives token
func _verify_with_backend(challenge: String, public_key: String, signature: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("[NimiqBridge] Auth verify failed: %d" % code)
			if code == 401:
				auth_verified = false
				_do_sign_auth()
				return
			auth_failed.emit("verify_failed_%d" % code)
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			auth_failed.emit("verify_parse_error")
			return
		var d : Dictionary = j.get_data()
		if not d.get("ok", false):
			auth_failed.emit(str(d.get("error", "unknown")))
			return

		auth_token      = str(d.get("token", ""))
		auth_player_id  = str(d.get("player_id", nimiq_address))
		auth_expires_at = int(d.get("expires_at", 0))
		auth_verified   = true

		# Save to localStorage
		JavaScriptBridge.eval(
			"localStorage.setItem('%s', '%s')" % [LS_AUTH_TOKEN, auth_token], true)
		JavaScriptBridge.eval(
			"localStorage.setItem('%s', '%s')" % [LS_AUTH_PID, auth_player_id], true)
		JavaScriptBridge.eval(
			"localStorage.setItem('nj_auth_exp', '%d')" % auth_expires_at, true)

		print("[NimiqBridge] Auth successful player=%s expires=%d" % [auth_player_id.left(8), auth_expires_at])

		auth_success.emit(auth_token, auth_player_id)

		# Register wallet address — after emit so Main already has the token
		_register_wallet_async(auth_player_id, nimiq_address)
	)
	var body := JSON.stringify({
		"challenge":     challenge,
		"nimiq_address": nimiq_address,
		"public_key":    public_key,
		"signature":     signature,
		"device_id":     device_id,
	})
	http.request(BACKEND_URL + "/backend/auth/verify",
		["Content-Type: application/json"], HTTPClient.METHOD_POST, body)


## Registers Nimiq address with backend (fire-and-forget)
func _register_wallet_async(player_id: String, address: String) -> void:
	if player_id == "" or address == "": return
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, _b):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			print("[NimiqBridge] Wallet registered player=%s addr=%s" % [player_id.left(8), address.left(12)])
		else:
			push_warning("[NimiqBridge] Wallet register failed: %d" % code)
	)
	var body := JSON.stringify({"player_id": player_id, "nimiq_address": address})
	var reg_headers := PackedStringArray(["Content-Type: application/json"])
	if auth_token != "":
		reg_headers.append("Authorization: Bearer " + auth_token)
	http.request(BACKEND_URL + "/backend/wallet/register",
		reg_headers, HTTPClient.METHOD_POST, body)


## Call when an avatar texture is needed.
## SVG → JS canvas → PNG → load_png_from_buffer (safe on Web)
func get_avatar_texture_async(size: int = 64) -> ImageTexture:
	if not OS.has_feature("web"):
		return ImageTexture.new()

	# Is window._nimiqAvatar available?
	var has_avatar = JavaScriptBridge.eval(
		"typeof window._nimiqAvatar === 'string' && window._nimiqAvatar.length > 10", true)
	if not has_avatar:
		return ImageTexture.new()

	var key := "myavatar_%d" % size
	var js_code := """
(function(){
  if(!window._nimiqPending) window._nimiqPending = {};
  window._nimiqPending['{KEY}'] = null;
  var svgData = window._nimiqAvatar;
  if(!svgData){ window._nimiqPending['{KEY}'] = ''; return; }
  var img = new Image();
  img.onload = function(){
	try {
	  var c = document.createElement('canvas');
	  c.width = {SIZE}; c.height = {SIZE};
	  c.getContext('2d').drawImage(img, 0, 0, {SIZE}, {SIZE});
	  window._nimiqPending['{KEY}'] = c.toDataURL('image/png');
	} catch(e){ window._nimiqPending['{KEY}'] = ''; }
  };
  var svgBlob = new Blob([svgData], {type: 'image/svg+xml'});
  img.src = URL.createObjectURL(svgBlob);
})();
"""
	js_code = js_code.replace("{KEY}", key).replace("{SIZE}", str(size))
	JavaScriptBridge.eval(js_code, true)

	# Poll for result (max ~2s)
	var result := ""
	for _i in range(40):
		await get_tree().create_timer(0.05).timeout
		var val = JavaScriptBridge.eval("window._nimiqPending['%s']" % key, true)
		if val == null:
			continue
		result = str(val)
		break
	JavaScriptBridge.eval("delete window._nimiqPending['%s']" % key, true)

	if result == "" or result == "null":
		return ImageTexture.new()

	# Strip data URL prefix
	var comma := result.find(",")
	if comma < 0:
		return ImageTexture.new()
	var b64 := result.substr(comma + 1)
	var raw := Marshalls.base64_to_raw(b64)
	var img := Image.new()
	if img.load_png_from_buffer(raw) != OK:
		return ImageTexture.new()
	return ImageTexture.create_from_image(img)
