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
var streak : int = 0   # consecutive daily-login days including today — see backend/game/streak.go
# NOTE: no auto-paid streak_reward field anymore — the NIM reward is
# claim-based (player taps the lobby badge), see Main.gd's
# _fetch_streak_status()/_claim_streak_reward() and
# backend/handlers/streak.go.

# _do_sign_auth() can be triggered from several independent places at once —
# the PLAY button, the Settings "Connect" button, VS round start, AND
# NimiqBridge's own auto-poll flow all call it directly (see Main.gd). Each
# call fetches its OWN fresh challenge and calls NimiqJS.start_sign(), but
# the wallet extension can only handle one signing request at a time — a
# second concurrent call silently replaces/interferes with the first
# in-flight one, so the FIRST caller's captured challenge ends up being
# verified against a signature that was actually produced for the SECOND
# challenge (or vice versa). The backend's challenge is also single-use
# (deleted the instant it's looked up, success or fail — see
# consumeChallenge() in backend/game/auth.go), so this mismatch surfaces as
# a confusing, seemingly-random "challenge_not_found_or_expired" — the
# already-consumed-by-the-OTHER-call-in-flight challenge. This flag makes
# _do_sign_auth() a no-op while a sign attempt is already in progress,
# instead of letting them race.
var _signing_in_progress := false

# BUG FIX: "Failed to connect to server" toast on literally every first
# launch, before the player has touched anything. Root cause: poll()'s own
# background auto-sign flow (_wait_for_safe_moment_then_sign(), fires the
# instant the player is idle in the lobby — which is true immediately on
# first load) calls _do_sign_auth() completely silently, with no user
# gesture behind it at all. If that passive attempt's challenge-fetch or
# verify HTTP call fails for ANY reason — a cold backend still warming up,
# a transient blip, the wallet JS bridge not being fully ready yet — it hit
# the same Toast.network_error(...) calls used for a real, user-initiated
# sign attempt, scaring the player with a "connection failed" message for
# something they never asked to happen. This flag lets _do_sign_auth()
# distinguish "the player is actively trying to sign in" (show real errors)
# from "this is our own passive background attempt" (fail quietly — poll()
# / the player pressing Play later will just try again for real).
var _silent_sign_attempt := false

# Counts consecutive automatic retries triggered by a 401 from /backend/auth/
# verify (see _verify_with_backend) — capped at 1 so a structural failure
# can't silently re-prompt the wallet's native sign dialog over and over.
# Reset to 0 on any successful verify or once the retry budget is exhausted.
var _verify_401_retries := 0

# BUG FIX: NimiqBridge is a plain child node created fresh every time Main.gd
# runs (see Main._ready(), and "Play Again" -> get_tree().reload_current_scene()
# recreating Main.gd — and this bridge with it — every single round). Each
# fresh instance starts with auth_token=="" / auth_verified==false and only
# regains them once _try_restore_session()'s async HTTP call to
# /backend/auth/me resolves. Main._on_play_pressed() checks `_auth_token ==
# ""` the INSTANT Play is pressed — with no way to tell "restore is still in
# flight, this will be true in a moment" apart from "genuinely never signed
# in" apart from this flag. Without it, a fast enough Play press right after
# a round restarts (very plausible — nothing stops the player from tapping
# Play again immediately) wins the race against the restore call and
# re-triggers a full new sign challenge even though the session was already
# perfectly valid — this is exactly the intermittent (network-timing-
# dependent) "sometimes asks to sign again mid-session" bug reported.
var _restoring_session := false


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
	# If token is in localStorage, wait for restore to finish.
	#
	# BUG FIX: "asks me to sign in again every launch even though I'm
	# already signed in" — this used to be a FIXED 5s wait (20 * 0.25s),
	# after which poll() gave up and fell through to
	# _wait_for_safe_moment_then_sign() regardless of whether the restore
	# call was still genuinely in flight. On a slow connection (cold start,
	# mobile data, first request warming up a sleeping backend) the actual
	# /backend/auth/me round trip can easily take longer than 5s — poll()
	# would stop waiting and pop a REAL wallet sign prompt for a session
	# that was about to restore successfully a moment later anyway. Now
	# waits on _restoring_session (the actual live state of that HTTP call,
	# set by _try_restore_session() itself) instead of a guessed fixed
	# duration — this can never wait forever, since that HTTP request has
	# its own 5s timeout (see _try_restore_session()'s http.timeout) which
	# always resolves _restoring_session back to false one way or another.
	if not auth_verified:
		var has_token = JavaScriptBridge.eval("!!localStorage.getItem('nj_auth_token')", true)
		if has_token:
			print("[NimiqBridge] waiting for session restore...")
			# _restoring_session may not have flipped true yet if this runs
			# before _try_restore_session()'s own request() call lands —
			# give it one frame's grace before trusting "false" as final.
			await get_tree().create_timer(0.1).timeout
			while _restoring_session and not auth_verified:
				await get_tree().create_timer(0.25).timeout

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
		# BUG FIX: this used to call _do_sign_auth() the instant polling
		# finished — but polling can take up to ~18s (window._nimiqAddress
		# detection + session-restore wait), and the player is free to start
		# playing well before that resolves (game start never waits on this
		# poll). The result was the wallet's native sign prompt popping up
		# out of nowhere while the player was mid-run, taking over the
		# screen. Now it waits for a safe moment — not actively playing
		# (menu) or the game-over screen — before prompting.
		print("[NimiqBridge] not verified — waiting for a safe moment to sign...")
		_wait_for_safe_moment_then_sign()
	elif _restore_network_failed:
		print("[NimiqBridge] network was offline during restore — skipping sign, will retry when online")


## True while the player is actively mid-run (game started, not yet on the
## game-over screen) — the wrong moment to pop up a native wallet sign
## prompt over the gameplay.
func _is_mid_gameplay() -> bool:
	var main_node = get_tree().get_root().get_node_or_null("Main")
	if not main_node: return false
	var started : bool = bool(main_node.get("_started"))
	if not started: return false
	var gm = main_node.get("_gm")
	if not is_instance_valid(gm): return false
	return not bool(gm.get("_game_over"))


func _wait_for_safe_moment_then_sign() -> void:
	# Defense-in-depth alongside poll()'s own _restoring_session wait above —
	# if a restore call is STILL in flight for any reason by the time this
	# runs, wait for it too rather than popping a real sign prompt for a
	# session that might resolve itself in the next moment.
	while _is_mid_gameplay() or _restoring_session:
		await get_tree().create_timer(1.0).timeout
	if auth_verified: return  # got signed in some other way while waiting
	print("[NimiqBridge] safe moment reached — starting sign auth now (silent)")
	# silent=true: this is our own passive background attempt, not something
	# the player asked for — see _silent_sign_attempt's declaration comment.
	_do_sign_auth(true)


## Check token in localStorage — emit auth_success if valid
func _try_restore_session() -> void:
	if not OS.has_feature("web"): return
	var token  = JavaScriptBridge.eval("localStorage.getItem('%s')" % LS_AUTH_TOKEN, true)
	var pid    = JavaScriptBridge.eval("localStorage.getItem('%s')" % LS_AUTH_PID, true)
	if token == null or str(token) == "null" or str(token) == "": return
	_restoring_session = true
	# Ask backend if token is valid
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	# BUG FIX: "ERROR: Lambda capture at index 0 was freed. Passed 'null'
	# instead." / gdscript_lambda_callable.cpp:242 — seen in production on
	# multiple devices. Root cause: NimiqBridge is torn down and recreated
	# fresh every round via Main.gd's "Play Again" -> get_tree().
	# reload_current_scene() (see the class-level comment above and
	# Main.gd's own "5-6 rounds" bug-fix comment). If a round ends and
	# reloads while THIS http request is still in flight, both `http`
	# (captured index 0 — freed as soon as NimiqBridge, its parent, is
	# freed) and `self` (captured implicitly for the member access below)
	# can already be gone by the time the response arrives, and resuming
	# this Callable hits the freed capture(s). `is_instance_valid(http)`
	# catches the first; a WeakRef on self is the one capture the engine
	# can't silently null out for us, so check it ourselves before touching
	# any NimiqBridge member.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return  # freed mid-flight (scene reload) — nothing left to clean up or update
		http.queue_free()
		if _alive.get_ref() == null: return  # NimiqBridge itself freed mid-flight — nothing left to update
		_restoring_session = false  # resolved one way or another — see field comment above
		# Network error / timeout — backend unreachable, do not touch token
		if result != HTTPRequest.RESULT_SUCCESS or code == 0:
			var stored_exp : int = int(str(JavaScriptBridge.eval("parseInt(localStorage.getItem('nj_auth_exp') || '0', 10)", true)))
			var now_unix   : int = int(Time.get_unix_time_from_system())  # determinism-ok: auth token expiry check, not gameplay
			if stored_exp > now_unix + 60:
				# Not expired — trust token offline, mark so poll() skips _do_sign_auth
				auth_token      = str(token)
				auth_player_id  = str(pid)
				auth_expires_at = stored_exp
				auth_verified   = true
				_restore_network_failed = false  # we're fine
				# BUG FIX: "streak badge doesn't show on first launch" — this
				# branch fires whenever /backend/auth/me fails or times out
				# (RESULT_SUCCESS false or code==0) but the cached token isn't
				# expired yet — a flaky/cold first request is exactly the kind
				# of thing that happens on a fresh app open (sleeping backend,
				# slow mobile DNS/TLS). `streak` used to just stay at its
				# script-default 0 here, since there's no server response to
				# read it from — so auth_success still fired (the badge's
				# other gates all passed) but with a 0 count, hiding the badge
				# for a player who actually has a real streak. Read back the
				# last-known value cached in localStorage on the last
				# successful restore/sign instead of leaving it at 0.
				streak = int(str(JavaScriptBridge.eval(
					"localStorage.getItem('nj_auth_streak') || '0'", true)))
				print("[NimiqBridge] Offline restore — trusting local token player=%s streak=%d" % [auth_player_id.left(8), streak])
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
					var now_unix          : int    = int(Time.get_unix_time_from_system())  # determinism-ok: auth token expiry check, not gameplay
					var secs_left         : int    = restored_exp - now_unix
					auth_token      = restored_token
					auth_player_id  = restored_pid
					auth_expires_at = restored_exp
					auth_verified   = true
					streak          = int(d.get("streak", 0))
					print("[NimiqBridge] Session restored player=%s expires=%d (%dd left) streak=%d" % [auth_player_id.left(8), auth_expires_at, secs_left / 86400, streak])
					JavaScriptBridge.eval(
						"localStorage.setItem('nj_auth_streak', '%d')" % streak, true)
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
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/auth/me?token=" + str(token).uri_encode()))


## Releases the _signing_in_progress lock and (optionally) emits auth_failed.
## Every terminal point of the sign flow (success is handled separately in
## _verify_with_backend, since it doesn't fail) must go through this so the
## lock never gets stuck "true" after an error.
func _fail_sign_auth(reason: String) -> void:
	_signing_in_progress = false
	auth_failed.emit(reason)


## Belt-and-suspenders safety net for _signing_in_progress. Every normal exit
## path (challenge fetch failure, sign rejection, verify success/failure)
## already clears the flag directly — this exists purely to guarantee it can
## NEVER get stuck true forever if some future change (or an unexpected
## edge case, e.g. this node being freed mid-await) skips those paths. A
## permanently-stuck true here is exactly as bad as the Main.gd "_started
## never reset" bug found earlier: _do_sign_auth() would silently no-op
## forever afterwards, and the player could never sign in again without a
## full page reload. Worst-case legitimate duration is challenge fetch
## (<=8s) + wallet sign (<=60s) + verify (<=10s) — 100s gives a safe margin
## above that.
func _arm_signing_watchdog() -> void:
	var t := get_tree().create_timer(100.0)
	t.timeout.connect(func():
		if _signing_in_progress:
			push_warning("[NimiqBridge] _signing_in_progress watchdog fired — force-clearing stuck lock")
			_signing_in_progress = false
	)


## Sign-based auth flow: get challenge → sign → verify → store token
func _do_sign_auth(silent: bool = false) -> void:
	print("[NimiqBridge] _do_sign_auth called auth_verified=%s addr=%s in_progress=%s silent=%s" % [str(auth_verified), nimiq_address.left(12), str(_signing_in_progress), str(silent)])
	if not OS.has_feature("web"): return
	if auth_verified: return  # already logged in
	if _signing_in_progress:
		# A sign attempt (from ANY trigger — PLAY button, Settings Connect,
		# VS round start, or NimiqBridge's own auto-flow, see Main.gd's
		# several direct _do_sign_auth() call sites) is already in flight.
		# Letting a second one start concurrently means TWO challenges get
		# fetched but the wallet extension only handles one sign request at
		# a time — the first caller's captured challenge ends up verified
		# against a signature actually produced for the SECOND challenge,
		# which the single-use backend challenge store (already consumed by
		# whichever request got there first) then rejects as
		# "challenge_not_found_or_expired". No-op instead of racing.
		print("[NimiqBridge] sign already in progress — ignoring duplicate call")
		return
	_signing_in_progress  = true
	_silent_sign_attempt  = silent
	_arm_signing_watchdog()

	# 1. Get challenge
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	# See _try_restore_session()'s comment for why both guards are needed:
	# NimiqBridge (and this http child with it) can be freed mid-flight by
	# a "Play Again" scene reload before the response arrives.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("[NimiqBridge] Challenge fetch failed: %d" % code)
			if not _silent_sign_attempt:
				Toast.network_error("auth_challenge code=%d" % code)
			_fail_sign_auth("challenge_fetch_failed")
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			_fail_sign_auth("challenge_parse_failed")
			return
		var d : Dictionary = j.get_data()
		var challenge : String = str(d.get("challenge", ""))
		if challenge == "":
			_fail_sign_auth("empty_challenge")
			return
		# 2. Call window.nimiq.sign(challenge)
		_sign_and_verify(challenge)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/auth/challenge"))


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
		_fail_sign_auth(err)
		return

	var pub_key   : String = str(sd.get("publicKey", ""))
	var signature : String = str(sd.get("signature", ""))
	print("[SIG1] %s" % signature.left(64))
	print("[SIG2] %s" % signature.right(signature.length() - 64))
	print("[SIGLEN] %d" % signature.length())
	_verify_with_backend(challenge, pub_key, signature)


## Guards _verify_with_backend()'s response handler against acting on a
## STALE response — e.g. a slow/delayed network retry of an old request
## that finally lands minutes later (challenge TTL is 5 minutes; a response
## arriving suspiciously close to that window is almost certainly one of
## these). Two independent checks, either one is enough to call it stale:
##   1. We're already auth_verified — some OTHER attempt already succeeded
##      while this one was in flight, so this result (success OR failure)
##      no longer matters and must NOT be allowed to downgrade a perfectly
##      good session.
##   2. This response isn't for the challenge we're currently tracking as
##      "the one in flight" — a newer attempt has already superseded it.
var _active_verify_challenge := ""

## Sends challenge + signature to backend, receives token
func _verify_with_backend(challenge: String, public_key: String, signature: String) -> void:
	_active_verify_challenge = challenge
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	# See _try_restore_session()'s comment — guards against a "Play Again"
	# scene reload freeing this node (and NimiqBridge itself) before the
	# verify response arrives.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if auth_verified or _active_verify_challenge != challenge:
			print("[NimiqBridge] ignoring stale verify response for challenge=%s (already verified=%s, active=%s)" \
				% [challenge.left(24), str(auth_verified), _active_verify_challenge.left(24)])
			return
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("[NimiqBridge] Auth verify failed: %d" % code)
			# BUG FIX: this used to retry on EVERY 401 with no cap at all — if
			# something structural kept making verify fail (e.g. a stale/blank
			# nimiq_address that never gets fixed between attempts), this was
			# an unbounded loop that popped a brand new native wallet sign
			# prompt each time around. That's exactly the reported "pressed
			# Play, got asked to sign 3-4 times in a row" — the player has no
			# way to know these are silent auto-retries, it just looks like
			# the game is broken. One retry is enough to recover from a
			# genuinely transient stale-challenge race; beyond that, fail
			# cleanly so the player sees a normal error state and can press
			# Play again themselves instead of getting silently re-prompted.
			if code == 401 and _verify_401_retries < 1:
				_verify_401_retries += 1
				auth_verified = false
				# Intentional sequential retry (challenge was rejected, get a
				# fresh one), not a race — release the lock first so this
				# call isn't blocked by its own now-stale guard state.
				# Pass through the CURRENT attempt's silent-ness — this is a
				# continuation of whichever attempt (background or
				# user-initiated) triggered the original call, not a fresh
				# independent one, so it must not reset back to noisy.
				_signing_in_progress = false
				_do_sign_auth(_silent_sign_attempt)
				return
			_verify_401_retries = 0
			if not _silent_sign_attempt:
				Toast.network_error("auth_verify code=%d" % code)
			_fail_sign_auth("verify_failed_%d" % code)
			return
		_verify_401_retries = 0
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			_fail_sign_auth("verify_parse_error")
			return
		var d : Dictionary = j.get_data()
		if not d.get("ok", false):
			_fail_sign_auth(str(d.get("error", "unknown")))
			return

		_signing_in_progress = false
		auth_token      = str(d.get("token", ""))
		auth_player_id  = str(d.get("player_id", nimiq_address))
		auth_expires_at = int(d.get("expires_at", 0))
		auth_verified   = true
		streak          = int(d.get("streak", 0))

		# Save to localStorage
		JavaScriptBridge.eval(
			"localStorage.setItem('%s', '%s')" % [LS_AUTH_TOKEN, auth_token], true)
		JavaScriptBridge.eval(
			"localStorage.setItem('%s', '%s')" % [LS_AUTH_PID, auth_player_id], true)
		JavaScriptBridge.eval(
			"localStorage.setItem('nj_auth_exp', '%d')" % auth_expires_at, true)
		# Cache streak too — see _try_restore_session()'s offline-trust
		# fallback for why this matters.
		JavaScriptBridge.eval(
			"localStorage.setItem('nj_auth_streak', '%d')" % streak, true)

		print("[NimiqBridge] Auth successful player=%s expires=%d" % [auth_player_id.left(8), auth_expires_at])

		auth_success.emit(auth_token, auth_player_id)

		# Register wallet address — after emit so Main already has the token
		_register_wallet_async(auth_player_id, nimiq_address)
	)
	# Browser/OS metadata — purely informational, backs the admin panel's
	# "what devices are our players actually on" view (game.DeviceBreakdown).
	# Read the same way index.html's own _deviceMeta() does it, since this
	# is the one moment virtually every real player passes through (unlike
	# client-log entries, which only exist for players who hit an error).
	var user_agent := ""
	var platform   := ""
	var screen_str := ""
	var dpr_str    := ""
	if OS.has_feature("web"):
		var ua_raw = JavaScriptBridge.eval("navigator.userAgent || ''", true)
		user_agent = str(ua_raw) if ua_raw != null else ""
		var plat_raw = JavaScriptBridge.eval(
			"(navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ''", true)
		platform = str(plat_raw) if plat_raw != null else ""
		var scr_raw = JavaScriptBridge.eval("screen.width + 'x' + screen.height", true)
		screen_str = str(scr_raw) if scr_raw != null else ""
		var dpr_raw = JavaScriptBridge.eval("String(window.devicePixelRatio || 1)", true)
		dpr_str = str(dpr_raw) if dpr_raw != null else ""

	var body := JSON.stringify({
		"challenge":     challenge,
		"nimiq_address": nimiq_address,
		"public_key":    public_key,
		"signature":     signature,
		"device_id":     device_id,
		"user_agent":    user_agent,
		"platform":      platform,
		"screen":        screen_str,
		"dpr":           dpr_str,
	})
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/auth/verify"),
		["Content-Type: application/json"], HTTPClient.METHOD_POST, body)


## Registers Nimiq address with backend (fire-and-forget)
func _register_wallet_async(player_id: String, address: String) -> void:
	if player_id == "" or address == "": return
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	# See _try_restore_session()'s comment — this is fire-and-forget and can
	# easily outlive a "Play Again" scene reload that frees NimiqBridge (and
	# this http child with it) before the response arrives.
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, _b):
		if not is_instance_valid(http): return
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
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/wallet/register"),
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
