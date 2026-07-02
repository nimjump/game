extends Node

# ═══════════════════════════════════════════════════════
#  Main.gd  —  Fully responsive UI  (Bubble v1.0 assets)
#  No hardcoded pixels — all sizes derived from get_viewport().size
#  Godot Project Settings → Display → Window:
#    Stretch Mode: canvas_items   Stretch Aspect: expand
# ═══════════════════════════════════════════════════════

const UITheme := preload("res://scripts/UITheme.gd")

# Resolved once at runtime via the ApiConfig autoload (same-origin on web,
# query/localStorage override for testing, DEFAULT_BASE fallback natively).
var BACKEND_URL : String = ApiConfig.base_url()

var _started    := false

# ── Server update-mode status (polled) ──────────────────────────────
# When the admin panel puts the game into update mode, the server flips
# update_active on (either immediately — "force" — or automatically once
# the current weekly leaderboard period ends — "normal"). While active,
# starting a NEW game is blocked and a toast is shown instead; anyone
# already mid-run is left alone. See backend/handlers/server.go
# handleDeveloperModeGet + backend/game/appconfig.go.
var _update_active  := false
var _update_message := "Game updating. Please check back shortly — thanks for your patience!"
var _status_poll_timer : Timer = null
const _STATUS_POLL_SEC := 25.0

var _muted      := false
var _volume     := 1.0
# iOS never supports the Vibration API (Safari/WKWebView have no navigator.vibrate,
# and it's never coming — Apple has no plans to implement it). Detected once at
# startup so the settings toggle can be shown-but-disabled instead of a toggle
# that silently does nothing when tapped.
var _is_ios     := false
var _char_index := 0
var _vibration  := true
var _save_timer : SceneTreeTimer = null  # debounce: coalesce rapid _save_settings calls
var _landscape_overlay : CanvasLayer = null   # shown when device is landscape

# ── Per-sound settings ─────────────────────────────────────────────
var _bgm_enabled    := true
var _bgm_volume     := 0.55   # quieter than sfx by default
var _jump_enabled   := true
var _jump_volume    := 0.85
var _damage_enabled := true
var _damage_volume  := 0.90

# ── Audio — tüm ses JS tarafında (_gdSound / _gdSetBus) ──────────

# ── Vibration tracking ─────────────────────────────────────────────
var _prev_lives : int = 3   # detect damage by lives decrease

var _hud        : CanvasLayer
var _go_panel   : PanelContainer
var _replay_bar : CanvasLayer
var _bg_rect    : TextureRect
var _bg_rect2   : TextureRect   # second layer for background transitions
var _bg_index   : int = -1
var _bg_fading  : bool = false
var _bg_selected : int = 0      # user-selected fixed background
var _bg_auto     : bool = true  # true → oyun biome'a göre otomatik değiştirir

var _score_display : _DigitDisplay
var _nimiq_display : _DigitDisplay
var _final_display  : _DigitDisplay
var _go_score_label : Label
var _height_display : _DigitDisplay
var _srv_score_display : _DigitDisplay
var _go_stats_lbl      : Label = null

var _gm         : Node2D
var _cam        : Camera2D
var _player     : CharacterBody2D
var _life_icons : Array[TextureRect] = []

var _claim_lbl    : Label
var _claim_btn    : Button
var _claim_status : Label
var _session_id   : String = ""
var _claim_flagged := false
var _claim_done    := false

var _ui_layer : CanvasLayer
var _ui_root  : Control
var _char_lbl : Label

var _settings_popup    : Control
var _settings_rebuilding := false  # re-entrancy guard for _rebuild_settings_if_open()
var _nick_overlay      : Control   # tam ekran nickname düzenleme overlay'i
var _sound_toggle      : CheckButton
var _volume_slider     : HSlider
var _sound_icon        : TextureRect
var _settings_char_lbl : Label

const CHAR_NAMES := ["Bunny 1", "Bunny 2", "Bunny 3", "Bunny 4", "Bunny 5"]
const CHAR_DESCS := ["Fast + Light", "Heavy + Strong", "Balanced", "Strong + Slow", "Light + Bouncy"]

var _powerup_slots : Array[Dictionary] = []
var _powerup_row   : HBoxContainer
# Cached powerup state — rebuild only when structure changes
var _pw_prev_key   : String = ""

# MN-04: per-field HUD cache (avoids string key allocation every tick)
var _last_hud_main_active : bool   = false
var _last_hud_main_type   : String = ""
var _last_hud_main_tmax   : int    = 0   # stored as int(*10) to match old key
var _last_hud_shield_on   : bool   = false
var _last_hud_mirror_on   : bool   = false
var _last_hud_eq_on       : bool   = false
var _last_hud_drunk_on    : bool   = false

# MN-05: preloaded powerup textures (avoids runtime load() inside update_powerup_hud)
const _TEX_POWERUP_JETPACK  := preload("res://assets/items/powerup_jetpack.png")
const _TEX_POWERUP_WINGS    := preload("res://assets/items/powerup_wings.png")
const _TEX_POWERUP_BUBBLE   := preload("res://assets/items/powerup_bubble.png")
const _TEX_DEBUFF_MIRROR    := preload("res://assets/items/debuff_mirror.png")
const _TEX_DEBUFF_EARTHQUAKE:= preload("res://assets/items/debuff_earthquake.png")
const _TEX_DEBUFF_DRUNK     := preload("res://assets/items/debuff_drunk.png")

# MN-11: preloaded torch textures
const _TEX_TORCH_OFF  := preload("res://assets/pack/torch_off.png")
const _TEX_TORCH_ON_A := preload("res://assets/pack/torch_on_a.png")
const _TEX_TORCH_ON_B := preload("res://assets/pack/torch_on_b.png")

# ── Backend state ──────────────────────────────────────────────────
var _play_btn      : Button = null   # PLAY button reference
var _vs_panel      : CanvasLayer = null
var _backend_ok    : bool   = true   # no longer used for ping — always true
var _ping_retry_timer: SceneTreeTimer = null  # auto-retry handle
var _torch_rects   : Array  = []     # [left_torch, right_torch] TextureRect nodes
var _torch_tween   : Tween  = null   # torch flicker animation



# ── Nimiq ─────────────────────────────────────────────────────────
# NimiqBridge is the single source of truth.
# These computed properties read directly from the bridge so there is
# never a stale copy.  A write still works (GDScript assigns to the
# backing _* variable), but every READ goes through the bridge first.
var _nimiq_bridge   : Node   = null

var _nimiq_address_local   : String = ""
var nimiq_address   : String:
	get: return _nimiq_bridge.nimiq_address if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.nimiq_address != "" else _nimiq_address_local
	set(v): _nimiq_address_local = v

var _nimiq_label_local     : String = ""
var nimiq_label     : String:
	get: return _nimiq_bridge.nimiq_label if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.nimiq_label != "" else _nimiq_label_local
	set(v): _nimiq_label_local = v

var _nimiq_avatar_local    : String = ""
var nimiq_avatar    : String:
	get: return _nimiq_bridge.nimiq_avatar if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.nimiq_avatar != "" else _nimiq_avatar_local
	set(v): _nimiq_avatar_local = v

var _nimiq_device_id_local : String = ""
var nimiq_device_id : String:
	get: return _nimiq_bridge.device_id if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.device_id != "" else _nimiq_device_id_local
	set(v): _nimiq_device_id_local = v

var _nimiq_expires_at_local: int = 0
var nimiq_expires_at: int:
	get: return _nimiq_bridge.auth_expires_at if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.auth_expires_at > 0 else _nimiq_expires_at_local
	set(v): _nimiq_expires_at_local = v

var _auth_token_local      : String = ""
var _auth_token     : String:
	get: return _nimiq_bridge.auth_token if is_instance_valid(_nimiq_bridge) and _nimiq_bridge.auth_token != "" else _auth_token_local
	set(v): _auth_token_local = v

var _player_nickname: String = ""  # chosen display name (from /backend/nickname)
var _nickname_cooldown_end: int = 0 # unix: can't change nickname until this
var _avatar_tex     : ImageTexture = null
var _avatar_card    : Control = null  # reference to keep/clean avatar card node
var _js_window      = null            # JavaScriptBridge.get_interface("window") — zero-latency gyro reads

var _vw  : float = GameConstants.VW
var _vh  : float = GameConstants.VH
var _ref : float = GameConstants.VW

# ── Mobile control mode ────────────────────────────────────────────
# "tap"  = tap left/right half of screen
# "gyro" = tilt device to control
var _control_mode       : String  = "tap"   # default: tap
var _gyro_sensitivity   : float   = 1.5     # gyro sensitivity (0.5–3.0)
var _gyro_auto_calib    : bool    = true    # auto-zero on start
var _gyro_dead_zone     : float   = 0.08    # threshold — below this is treated as 0
var _gyro_baseline      : float   = 0.0     # manual calibration reference
var _native_touch_x     : float   = -1.0    # native mobile: active touch X position (-1 = none)


func _ready() -> void:
	# ── Server-side replay mode (headless) ──────────────────────────────────
	var args := OS.get_cmdline_user_args()
	if "--server-worker" in args:
		_run_server_worker()
		return
	if "--server-replay" in args:
		_run_server_replay(args)
		return

	# ── [CRASH DEBUG] in-editor repro ────────────────────────────────────────
	# F6 (Play Scene) on Main.tscn doesn't let you pass real CLI args easily,
	# so this hardcodes them instead. Fill in YOUR actual crashing seed/log/out
	# below, set _DEBUG_REPRO_ENABLED = true, then press F6 on Main.tscn.
	# Turn this back to false when done so it doesn't run on every play.
	const _DEBUG_REPRO_ENABLED := false
	if _DEBUG_REPRO_ENABLED:
		_run_server_replay(PackedStringArray([
			"--server-replay",
			"--seed", "PUT_YOUR_REAL_SEED_HERE",
			"--char", "1",
			"--player-seed", "PUT_YOUR_REAL_PLAYER_SEED_HERE",
			"--log", "C:/path/to/your/real/debug_replay.log",
			"--out", "C:/path/to/your/temp/debug_result_editor.json",
		]))
		return

	var vp := get_viewport()
	_vw  = vp.get_visible_rect().size.x
	_vh  = vp.get_visible_rect().size.y
	# Klavye açılınca yanlış resize engellemek için başlangıç değerleri
	_last_vw_real = _vw
	_last_vh_real = _vh
	_ref = minf(minf(_vw, _vh), GameConstants.VW)  # cap: design ref is 600x800, don't scale UI past it on big screens
	vp.size_changed.connect(_on_viewport_resized)

	_check_landscape()

	_setup_audio()

	# iOS detection (web only) — Safari/WKWebView never implement navigator.vibrate(),
	# and Godot's own Input.vibrate_handheld() is a no-op on the HTML5/web export
	# regardless of OS (engine limitation, not fixable from project code). So on iOS
	# the vibration toggle is shown but permanently disabled instead of silently
	# doing nothing when the player taps it.
	if OS.has_feature("web"):
		_is_ios = bool(JavaScriptBridge.eval(
			"/iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream", true))
		if _is_ios:
			_vibration = false

	# Web: JS listener for touch tracking (always set up for tap mode)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("""
			if (!window._touchListenerSet) {
				window._touchListenerSet = true;
				window._activeTouches = [];
				document.addEventListener('touchstart', function(e) {
					window._activeTouches = [];
					for (var i = 0; i < e.touches.length; i++)
						window._activeTouches.push(e.touches[i].clientX);
				}, {passive: true});
				document.addEventListener('touchmove', function(e) {
					window._activeTouches = [];
					for (var i = 0; i < e.touches.length; i++)
						window._activeTouches.push(e.touches[i].clientX);
				}, {passive: true});
				document.addEventListener('touchend', function(e) {
					window._activeTouches = [];
					for (var i = 0; i < e.touches.length; i++)
						window._activeTouches.push(e.touches[i].clientX);
				}, {passive: true});
			}
			// Gyro listener — all logic in JS so direction is ready the instant the event fires
			window._gyroRaw      = 0;
			window._gyroDir      = 0;
			window._gyroBase     = 0;
			window._gyroCalibN   = 0;
			window._gyroPermDenied = false;
			window._startGyroListener = function() {
				if (window._gyroListenerSet) return;
				window._gyroListenerSet = true;
				window.addEventListener('deviceorientation', function(e) {
					var g = e.gamma || 0;
					window._gyroRaw = g;
					// Fast calibration: first 15 events
					if (window._gyroCalibN < 15) {
						var a = window._gyroCalibN < 5 ? 0.6 : 0.3;
						window._gyroBase = g * a + window._gyroBase * (1 - a);
						window._gyroCalibN++;
					}
					var tilted = g - window._gyroBase;
					var thr    = window._gyroThreshold || 3.5;
					var nthr   = thr * 0.5;
					if (window._gyroDir !== 0 && Math.abs(tilted) < nthr)
						window._gyroDir = 0;
					else if (tilted >  thr) window._gyroDir =  1;
					else if (tilted < -thr) window._gyroDir = -1;
				}, {capture: true, passive: true});
			};
			// Non-iOS: start immediately
			if (!(typeof DeviceOrientationEvent !== 'undefined' &&
				  typeof DeviceOrientationEvent.requestPermission === 'function')) {
				window._startGyroListener();
			}
		""", true)
		# Pre-compile getter functions — called per frame with zero string parsing
		JavaScriptBridge.eval("""
			window._getGyroDir = function(){ return window._gyroPermDenied ? 0 : (window._gyroDir|0); };
			window._getGyroRaw = function(){ return +(window._gyroRaw||0); };
			window._getTapDir  = function(){
				var t = window._activeTouches;
				if (!t || t.length === 0) return 0;
				var sum = 0;
				for (var i = 0; i < t.length; i++) sum += t[i];
				return (sum / t.length) > window.innerWidth * 0.5 ? 1 : -1;
			};
		""", true)
		_js_window = JavaScriptBridge.get_interface("window")

	# Nimiq bridge — connect BEFORE add_child
	# (in editor mode, _ready may emit synchronously)
	_nimiq_bridge = Node.new()
	_nimiq_bridge.set_script(load("res://scripts/NimiqBridge.gd"))
	_nimiq_bridge.connect("nimiq_ready", _on_nimiq_ready)
	_nimiq_bridge.connect("auth_success", _on_auth_success)
	_nimiq_bridge.connect("auth_failed",  _on_auth_failed)
	add_child(_nimiq_bridge)

	# Don't wait for Nimiq — start game immediately, Nimiq loads in background
	_load_settings()
	_build_game()
	_start_status_poll()
	_build_start_ui()
	_init_game()
	_apply_audio_settings()
	# Every web visit: silently try to open the Nimiq Pay app via deep link.
	# If the app isn't installed this just does nothing — the page stays put
	# and the player keeps playing in the browser as normal.
	if OS.has_feature("web"):
		var deep_link := ApiConfig.nimiq_deep_link()
		JavaScriptBridge.eval("""
			(function() {
				try {
					console.log('[NimiqDeep] trying to open app:', '%s');
					var iframe = document.createElement('iframe');
					iframe.style.display = 'none';
					iframe.src = '%s';
					document.body.appendChild(iframe);
					setTimeout(function() {
						if (iframe && iframe.parentNode) iframe.remove();
					}, 2000);
				} catch (e) {
					console.warn('[NimiqDeep] attempt failed (app probably not installed)', e);
				}
			})();
		""" % [deep_link, deep_link], true)
	# Web replay mode: ?replay=SESSION_ID in URL → fetch and auto-start replay
	if OS.has_feature("web"):
		var session_id : String = str(JavaScriptBridge.eval(
			"(function(){ var m = location.search.match(/[?&]replay=([^&]+)/); return m ? decodeURIComponent(m[1]) : ''; })()", true))
		if session_id != "" and session_id != "null":
			_web_fetch_and_start_replay(session_id)

		# VS invite link: ?vs=ROOM_ID → auto-open VS popup with invite
		var vs_invite : String = str(JavaScriptBridge.eval(
			"(function(){ var m = location.search.match(/[?&]vs=([^&]+)/); return m ? decodeURIComponent(m[1]) : ''; })()", true))
		if vs_invite != "" and vs_invite != "null":
			await get_tree().create_timer(0.5).timeout   # let UI settle first
			_on_vs_pressed_with_invite(vs_invite)


func _web_fetch_and_start_replay(session_id: String) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	var url := ApiConfig.base_url() + "/backend/replay/" + session_id
	http.request_completed.connect(func(result, code, _headers, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("[WEB_REPLAY] fetch failed: result=%d code=%d" % [result, code])
			Toast.network_error("web_replay code=%d" % code)
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			return
		var d : Dictionary = j.get_data()
		var seed_val : int = int(str(d.get("seed", "0")))
		var char_idx : int = int(d.get("char", 0))
		var log_b64  : String = str(d.get("replay_log", ""))
		if log_b64 == "":
			push_warning("[WEB_REPLAY] no replay_log in response")
			return
		var raw : PackedByteArray = Marshalls.base64_to_raw(log_b64)
		if raw.is_empty():
			push_warning("[WEB_REPLAY] base64 decode failed")
			return
		print("[WEB_REPLAY] starting replay seed=%d char=%d bytes=%d" % [seed_val, char_idx, raw.size()])
		await _start_replay(seed_val, raw, char_idx, "web")
	)
	http.request(url)


## Headless server replay: parse args, simulate, write JSON result file, quit.
func _run_server_replay(args: PackedStringArray) -> void:
	var seed        : int    = 0
	var char_idx    : int    = 0
	var player_seed : int    = 0
	var log_path    : String = ""
	var out_path    : String = ""
	var max_tick    : int    = -1   # [CRASH BISECT] -1 = no cap, run full replay

	var replay_speed : float = 16.0  # default: 16x for fast server validation

	for i in range(args.size() - 1):
		match args[i]:
			"--seed":        seed         = int(args[i + 1])
			"--char":        char_idx     = int(args[i + 1])
			"--log":         log_path     = args[i + 1]
			"--out":         out_path     = args[i + 1]
			"--speed":       replay_speed = float(args[i + 1])
			"--max-tick":    max_tick     = int(args[i + 1])
			"--player-seed": player_seed  = int(args[i + 1])

	if log_path == "" or out_path == "" or seed == 0:
		printerr("[SERVER_REPLAY] Missing arguments: --seed --log --out required")
		_write_replay_result(out_path, 0, 0, "missing_args", null)
		get_tree().quit(1)
		return

	# Read log file
	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		printerr("[SERVER_REPLAY] Failed to open log file: ", log_path)
		_write_replay_result(out_path, 0, 0, "log_file_error", null)
		get_tree().quit(1)
		return
	var raw_bytes := file.get_buffer(file.get_length())
	file.close()

	# Main.tscn already loaded the scene — find GameManager and Camera2D inside it
	var gm_node  = get_node_or_null("GameManager")
	var dummy_cam = get_node_or_null("Camera2D")

	if gm_node == null:
		gm_node = Node2D.new()
		gm_node.set_script(load("res://scripts/GameManager.gd"))
		add_child(gm_node)

	if dummy_cam == null:
		dummy_cam = Camera2D.new()
		add_child(dummy_cam)

	# Player — must be CharacterBody2D (not Node2D)
	var dummy_player := CharacterBody2D.new()
	dummy_player.set_script(load("res://scripts/Player.gd"))
	add_child(dummy_player)
	# let _ready() run
	await get_tree().process_frame

	# In headless mode, kill the idle tween immediately.
	# Player._ready() starts a physics-mode tween (_run_idle_loop).
	# During simulation this tween ticks and fires callbacks;
	# if _run_idle_loop is called again while _initialized=false, tweens pile up
	# — activate() cleans this, but if fired inside simulate_tick state can corrupt.
	# start_replay() already calls activate(); this just closes the window before that.
	var idle_tw = dummy_player.get("_idle_tween")
	if idle_tw != null and idle_tw is Tween:
		idle_tw.kill()
		dummy_player.set("_idle_tween", null)

	gm_node.call("init", dummy_cam, dummy_player, null, null, null, self, seed, true)

	# Connect signal BEFORE starting replay
	var _result_written := false  # prevent double-write

	# Calculate: RLE decoded total tick count (needed by fast-sim path)
	var _total_ticks : int = 0
	var _ri : int = 0
	while _ri < raw_bytes.size():
		var b : int = raw_bytes[_ri]
		if b == 0xFF:  # delta marker: 0xFF + lo + hi
			if _ri + 2 < raw_bytes.size():
				_ri += 3
			else:
				break  # truncated marker at end of buffer — stop cleanly
			continue
		_total_ticks += max(1, (b >> 2) & 0x3F)
		_ri += 1
	print("[SERVER_REPLAY] raw_bytes=%d decoded_ticks=%d" % [raw_bytes.size(), _total_ticks])

	# Seed + log + char doğrudan set et, start_replay_external çağırma.
	# start_replay_external → start_replay() → _replay_mode=PLAYING set eder.
	# Sonraki await process_frame'de _physics_process araya girerek bazı tick'leri
	# tüketir ve _game_over flag'ini bozabilir — seek_to_tick bunu düzeltemez.
	# Bunun yerine seek_to_tick'in ihtiyacı olan state'i elle set ediyoruz.
	gm_node.set("_replay_seed",        seed)
	gm_node.set("_replay_log",         raw_bytes)
	gm_node.set("_replay_char",        char_idx)
	gm_node.set("_replay_player_seed", player_seed)
	gm_node.set("_replay_nickname",    "server")
	# _replay_total_ticks'i de set et (seek_to_tick clamp için kullanır)
	gm_node.set("_replay_total_ticks", _total_ticks)

	await get_tree().process_frame
	if not _result_written:
		# [CRASH BISECT] If --max-tick was given, stop the synchronous sim early
		# instead of running all _total_ticks in one shot. Run with different
		# values to binary-search the exact tick where it crashes:
		#   reaches "[BISECT] survived" print -> crash is AFTER this tick
		#   process dies with no print at all -> crash is AT or BEFORE this tick
		var _seek_target : int = _total_ticks
		if max_tick >= 0:
			_seek_target = mini(max_tick, _total_ticks)
		print("[BISECT] seeking to tick=%d / %d" % [_seek_target, _total_ticks])
		gm_node.call("seek_to_tick", _seek_target)
		print("[BISECT] survived tick=%d" % _seek_target)
		if not _result_written:
			_result_written = true
			var server_score : int = int(gm_node.get("score"))
			var ticks        : int = int(gm_node.get("_replay_tick_count"))
			# Print QUEST_RESULT so Go parseQuestResult() can pick it up from stdout
			var gm_kills     : int = int(gm_node.get("_quest_kills"))
			var gm_platforms : int = int(gm_node.get("_quest_platforms"))
			print("[QUEST_RESULT] " + JSON.stringify({
				"score": server_score, "ticks": ticks,
				"kills": gm_kills, "platforms": gm_platforms,
				"flying_kills": int(gm_node.get("_quest_flying_kills")),
				"mosquito_kills": int(gm_node.get("_quest_mosquito_kills")),
				"coins": int(gm_node.get("_quest_coins")),
				"golden_carrots": int(gm_node.get("_quest_golden_carrots")),
				"powerups": int(gm_node.get("_quest_powerups")),
				"took_damage":    bool(gm_node.get("_quest_took_damage")),
				"item_types":     (gm_node.get("_quest_item_types") as Dictionary).size() if gm_node.get("_quest_item_types") is Dictionary else 0,
				"lives_left":     int(gm_node.get("lives")) if gm_node.get("lives") != null else 0,
				"used_mirror":    bool(gm_node.get("_quest_used_mirror")),
				"used_powerup":   bool(gm_node.get("_quest_used_powerup")),
				"no_coins":       int(gm_node.get("_quest_coins")) == 0,
				"enemy_types":    (gm_node.get("_quest_enemy_types") as Dictionary).size() if gm_node.get("_quest_enemy_types") is Dictionary else 0,
				"combo_max":      int(gm_node.get("_quest_combo_max")),
				"nohit_max":      int(gm_node.get("_quest_noHit_max")),
				"kills_no_dmg":   int(gm_node.get("_quest_kills_no_dmg")),
				"highest_y":      int(gm_node.get("_quest_highest_y"))
			}))
			print("[SERVER_REPLAY] fast-sim done score=%d ticks=%d kills=%d plat=%d" % [server_score, ticks, gm_kills, gm_platforms])
			_write_replay_result(out_path, server_score, ticks, "", gm_node)
			get_tree().quit(0)

	# Timeout: 2 minutes (should never fire with fast-sim, safety net only)
	get_tree().create_timer(120.0).timeout.connect(func():
		if _result_written: return
		_result_written = true
		printerr("[SERVER_REPLAY] timeout")
		_write_replay_result(out_path, 0, 0, "timeout")
		get_tree().quit(2)
	)


## Persistent worker mode — job dosyası polling.
## Go tarafı: wrk_job_<id>.json yazar → Godot işler → wrk_result_<id>.json yazar → job siler.
## Env var WORKER_JOB_DIR ile job/result dizini belirlenir (default: /tmp).
## Env var WORKER_ID ile bu worker'ın ID'si belirlenir (sadece kendi job'larını okur).
func _run_server_worker() -> void:
	var job_dir  : String = OS.get_environment("WORKER_JOB_DIR")
	var worker_id: String = OS.get_environment("WORKER_ID")
	if job_dir == "":
		job_dir = "/tmp"
	if worker_id == "":
		worker_id = "1"

	print("[WORKER#%s] Persistent worker starting, job_dir=%s" % [worker_id, job_dir])

	# GM + Player + Camera bir kez oluştur, tüm işlerde yeniden kullan
	var gm_node = get_node_or_null("GameManager")
	var dummy_cam = get_node_or_null("Camera2D")
	if gm_node == null:
		gm_node = Node2D.new()
		gm_node.set_script(load("res://scripts/GameManager.gd"))
		add_child(gm_node)
	if dummy_cam == null:
		dummy_cam = Camera2D.new()
		add_child(dummy_cam)

	var dummy_player := CharacterBody2D.new()
	dummy_player.set_script(load("res://scripts/Player.gd"))
	add_child(dummy_player)
	await get_tree().process_frame

	var idle_tw = dummy_player.get("_idle_tween")
	if idle_tw != null and idle_tw is Tween:
		idle_tw.kill()
		dummy_player.set("_idle_tween", null)

	# Worker hazır — Go bunu stdout'ta görünce iş gönderebilir
	print("[WORKER#%s] READY" % worker_id)

	var _job_count    : int  = 0
	var _gm_inited    : bool = false
	# Job dosya adı deseni: wrk_job_<worker_id>_<anything>.json
	var job_prefix    : String = "wrk_job_%s_" % worker_id

	# ── Ana polling döngüsü ──────────────────────────────────────────────────
	while true:
		# Job dosyasını ara
		var da := DirAccess.open(job_dir)
		var job_file_name : String = ""
		if da:
			da.list_dir_begin()
			var fname := da.get_next()
			while fname != "":
				if fname.begins_with(job_prefix) and fname.ends_with(".json"):
					job_file_name = fname
					break
				fname = da.get_next()
			da.list_dir_end()

		if job_file_name == "":
			# İş yok — bir frame bekle (CPU'yu meşgul etmemek için)
			await get_tree().process_frame
			continue

		var job_path := job_dir.path_join(job_file_name)

		# Dosyayı oku (atomik olmayabilir — içi dolana kadar kısa bekle)
		var raw_text : String = ""
		for _try in range(10):
			var jf := FileAccess.open(job_path, FileAccess.READ)
			if jf:
				raw_text = jf.get_as_text()
				jf.close()
				if raw_text.strip_edges() != "":
					break
			await get_tree().process_frame

		if raw_text.strip_edges() == "":
			printerr("[WORKER#%s] Empty job file: %s — skipping" % [worker_id, job_file_name])
			DirAccess.remove_absolute(job_path)
			continue

		# QUIT komutu
		if raw_text.strip_edges() == "QUIT":
			print("[WORKER#%s] QUIT received" % worker_id)
			DirAccess.remove_absolute(job_path)
			break

		# JSON parse
		var json := JSON.new()
		if json.parse(raw_text.strip_edges()) != OK:
			printerr("[WORKER#%s] JSON parse error in %s" % [worker_id, job_file_name])
			DirAccess.remove_absolute(job_path)
			continue

		var job         : Dictionary = json.get_data()
		var seed        : int        = int(str(job.get("seed",        "0")))
		var char_idx    : int        = int(job.get("char",        0))
		var player_seed : int        = int(str(job.get("player_seed", "0")))
		var log_hex     : String     = str(job.get("log",         ""))
		var out_path    : String     = str(job.get("out",         ""))

		# Job dosyasını hemen sil (tekrar işlenmesin)
		DirAccess.remove_absolute(job_path)

		if seed == 0 or log_hex == "" or out_path == "":
			printerr("[WORKER#%s] Invalid job seed=%d log=%d out=%s" % [worker_id, seed, log_hex.length(), out_path])
			_write_replay_result(out_path, 0, 0, "invalid_job", null)
			continue

		_job_count += 1
		print("[WORKER#%s] JOB#%d seed=%d char=%d" % [worker_id, _job_count, seed, char_idx])

		# Hex → bytes
		var raw_bytes := PackedByteArray()
		var _hex_i := 0
		while _hex_i + 1 < log_hex.length():
			raw_bytes.append(log_hex.substr(_hex_i, 2).hex_to_int())
			_hex_i += 2

		# RLE tick sayısı
		var _total_ticks : int = 0
		var _ri : int = 0
		while _ri < raw_bytes.size():
			var b : int = raw_bytes[_ri]
			if b == 0xFF:
				if _ri + 2 < raw_bytes.size():
					_ri += 3
				else:
					break  # truncated marker at end of buffer — stop cleanly
				continue
			_total_ticks += max(1, (b >> 2) & 0x3F)
			_ri += 1

		# İlk işte GM'i init et
		if not _gm_inited:
			gm_node.call("init", dummy_cam, dummy_player, null, null, null, self, seed, true)
			await get_tree().process_frame
			_gm_inited = true

		# Replay state'i set et.
		# ÖNEMLİ: _game_over = true → await penceresi boyunca _physics_process'in
		# yanlış state'te tick çalıştırmasını engeller (RNG desync düzeltmesi).
		# seek_to_tick zaten _game_over = false yapıyor, bu set geçici bir kapı.
		gm_node.set("_game_over",          true)
		gm_node.set("_replay_mode",        0)   # ReplayMode.OFF
		gm_node.set("_replay_seed",        seed)
		gm_node.set("_replay_log",         raw_bytes)
		gm_node.set("_replay_char",        char_idx)
		gm_node.set("_replay_player_seed", player_seed)
		gm_node.set("_replay_nickname",    "server")
		gm_node.set("_replay_total_ticks", _total_ticks)

		await get_tree().process_frame
		gm_node.call("seek_to_tick", _total_ticks)

		var server_score : int = int(gm_node.get("score"))
		var ticks        : int = int(gm_node.get("_replay_tick_count"))

		print("[WORKER#%s] DONE#%d score=%d ticks=%d" % [worker_id, _job_count, server_score, ticks])
		_write_replay_result(out_path, server_score, ticks, "", gm_node)

		# Clean slate before next job — leftover PLAYING state caused hangs/desync
		if gm_node.has_method("prep_worker_job"):
			gm_node.call("prep_worker_job")
		await get_tree().process_frame

	get_tree().quit(0)


func _write_replay_result(path: String, score: int, ticks: int, error: String, gm = null) -> void:
	if path == "":
		return
	var out := {
		"server_score": score,
		"ticks":        ticks,
		"error":        error,
		"kills":        0,
		"platforms":    0,
		"flying_kills":   0,
		"mosquito_kills": 0,
		"coins":          0,
		"golden_carrots": 0,
		"powerups":       0,
		"took_damage":    false,
		"item_types":     0,
		"lives_left":     0,
		"used_mirror":    false,
		"used_powerup":   false,
		"no_coins":       true,
		"enemy_types":    0,
		"combo_max":      0,
		"nohit_max":      0,
		"kills_no_dmg":   0,
		"highest_y":      0,
	}
	if is_instance_valid(gm):
		out["kills"]          = int(gm.get("_quest_kills"))
		out["platforms"]      = int(gm.get("_quest_platforms"))
		out["flying_kills"]   = int(gm.get("_quest_flying_kills"))
		out["mosquito_kills"] = int(gm.get("_quest_mosquito_kills"))
		out["coins"]          = int(gm.get("_quest_coins"))
		out["golden_carrots"] = int(gm.get("_quest_golden_carrots"))
		out["powerups"]       = int(gm.get("_quest_powerups"))
		out["took_damage"]    = bool(gm.get("_quest_took_damage"))
		out["item_types"]     = (gm.get("_quest_item_types") as Dictionary).size() if gm.get("_quest_item_types") is Dictionary else 0
		out["lives_left"]     = int(gm.get("lives")) if gm.get("lives") != null else 0
		out["used_mirror"]    = bool(gm.get("_quest_used_mirror"))
		out["used_powerup"]   = bool(gm.get("_quest_used_powerup"))
		out["no_coins"]       = int(gm.get("_quest_coins")) == 0
		out["enemy_types"]    = (gm.get("_quest_enemy_types") as Dictionary).size() if gm.get("_quest_enemy_types") is Dictionary else 0
		out["combo_max"]      = int(gm.get("_quest_combo_max"))
		out["nohit_max"]      = int(gm.get("_quest_noHit_max"))
		out["kills_no_dmg"]    = int(gm.get("_quest_kills_no_dmg"))
		out["highest_y"]       = int(gm.get("_quest_highest_y"))
		out["quest_has_result"] = true
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(out))
		file.close()


## Single source of truth — call on every auth/address change
func _sync_panels() -> void:
	# Bridge varsa her zaman bridge'den oku
	if is_instance_valid(_nimiq_bridge):
		if _nimiq_bridge.nimiq_address != "": nimiq_address    = _nimiq_bridge.nimiq_address
		if _nimiq_bridge.nimiq_label   != "": nimiq_label      = _nimiq_bridge.nimiq_label
		if _nimiq_bridge.auth_token    != "": _auth_token      = _nimiq_bridge.auth_token
		if _nimiq_bridge.auth_expires_at > 0: nimiq_expires_at = _nimiq_bridge.auth_expires_at

	var pid : String = nimiq_address if nimiq_address != "" else \
		(_nimiq_bridge.auth_player_id if is_instance_valid(_nimiq_bridge) else "")
	var token      : String = _auth_token
	var has_wallet : bool   = nimiq_address != ""
	var authed     : bool   = token != ""

	for panel in [_leaderboard_panel, _quest_panel, _stats_panel, _vs_panel]:
		if not is_instance_valid(panel): continue
		if panel.has_method("set_has_wallet"):     panel.call("set_has_wallet", has_wallet)
		if panel.has_method("set_player_id"):      panel.call("set_player_id", pid)
		if panel.has_method("set_auth_token"):     panel.call("set_auth_token", token)
		if panel.has_method("set_auth_attempted"): panel.call("set_auth_attempted", authed)

	_rebuild_settings_if_open()


func _on_nimiq_ready(address: String, label: String, avatar_data_url: String, device_id: String) -> void:
	nimiq_address   = address
	nimiq_label     = label if label != "" else (address.left(9) + "..." + address.right(4) if address.length() > 13 else address)
	nimiq_avatar    = avatar_data_url
	nimiq_device_id = device_id
	print("[MAIN] Nimiq ready address=%s label=%s avatar=%s" % [
		nimiq_address.left(12), nimiq_label,
		"present" if avatar_data_url.length() > 10 else "none"
	])
	if avatar_data_url.begins_with("data:image/"):
		_avatar_tex = _data_url_to_texture(avatar_data_url)
	_sync_panels()


func _on_auth_success(token: String, player_id: String) -> void:
	print("[MAIN] Auth successful player=%s" % player_id.left(8))
	_auth_token = token
	_fetch_nickname(player_id, token)
	_sync_panels()
	_rebuild_settings_if_open()
	# Flush any pending score submits now that we're authed
	if is_instance_valid(_gm) and _gm.has_method("flush_pending"):
		_gm.call("flush_pending")
	# If session not started yet (auth came late), trigger it now
	if is_instance_valid(_gm) and not _started:
		var sid : String = str(_gm.get("session_id")) if _gm.get("session_id") != null else ""
		if sid == "":
			print("[MAIN] Auth arrived late — triggering _start_session")
			_gm.call("_start_session")


func _on_auth_failed(reason: String) -> void:
	print("[MAIN] Auth not completed: %s" % reason)
	_auth_token = ""
	if is_instance_valid(_nimiq_bridge):
		_nimiq_bridge.auth_token     = ""
		_nimiq_bridge.auth_verified  = false
		_nimiq_bridge.auth_attempted = true
	_sync_panels()
	# Any auth failure — including offline/network errors (challenge_fetch_failed,
	# verify_failed_*, challenge_parse_failed, etc.) — must still let the player
	# play. Previously only "no_provider"/"user_rejected" started the game, so
	# a player with no internet connection got stuck waiting forever on the
	# challenge request instead of playing offline. Auth just stays unverified;
	# leaderboard/replay submission stays blocked (server needs a valid token
	# for those), but the game itself always opens.
	if not _started:
		print("[MAIN] auth failed (%s) — starting game without wallet" % reason)
		_started = true
		_block_lb_replay = true
		if is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
		if is_instance_valid(_stats_panel):       _stats_panel.hide_panel()
		if is_instance_valid(_quest_panel):       _quest_panel.hide_panel()
		_do_start_game()


## Called when server returns 401 — token invalid, clear it
func _on_auth_expired() -> void:
	print("[MAIN] 401 from server — clearing auth token")
	_auth_token      = ""
	nimiq_expires_at = 0
	if is_instance_valid(_nimiq_bridge):
		_nimiq_bridge.auth_token      = ""
		_nimiq_bridge.auth_verified   = false
		_nimiq_bridge.auth_expires_at = 0
	if OS.has_feature("web"):
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_token')", true)
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_pid')", true)
		JavaScriptBridge.eval("localStorage.removeItem('nj_auth_exp')", true)
	_sync_panels()
	_rebuild_settings_if_open()


## Fetch nickname from backend and cache locally
func _fetch_nickname(player_id: String, token: String) -> void:
	if player_id == "" or token == "": return
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if code == 401: _on_auth_expired(); return
		if result != HTTPRequest.RESULT_SUCCESS or code != 200: return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK: return
		var d : Dictionary = j.get_data()
		_player_nickname = str(d.get("nickname", ""))
		_nickname_cooldown_end = int(d.get("cooldown_end", 0))
		print("[MAIN] Nickname fetched: '%s' cooldown=%d" % [_player_nickname, _nickname_cooldown_end])
		_rebuild_settings_if_open()
	)
	var url := ApiConfig.base_url() + "/backend/nickname?player_id=" + player_id.uri_encode()
	http.request(url, ["Authorization: Bearer " + token])


## Send nickname to backend
func _set_nickname_async(nickname: String, token: String, on_done: Callable) -> void:
	if token == "": on_done.call(false, "not_authenticated"); return
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			var msg := "error_%d" % code
			if body.size() > 0:
				var j2 := JSON.new()
				if j2.parse(body.get_string_from_utf8()) == OK:
					msg = str(j2.get_data().get("error", msg))
			on_done.call(false, msg)
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			on_done.call(false, "parse_error"); return
		var d : Dictionary = j.get_data()
		_player_nickname = str(d.get("nickname", nickname))
		_nickname_cooldown_end = int(d.get("cooldown_end", 0))
		on_done.call(true, "")
	)
	var body := JSON.stringify({"nickname": nickname})
	http.request(ApiConfig.base_url() + "/backend/nickname",
		["Content-Type: application/json", "Authorization: Bearer " + token],
		HTTPClient.METHOD_POST, body)


var _resize_timer   : SceneTreeTimer = null
var _last_vw_real   : float = 0.0   # klavye olmadan son gerçek genişlik
var _last_vh_real   : float = 0.0   # klavye olmadan son gerçek yükseklik

func _on_viewport_resized() -> void:
	var vp    := get_viewport()

	# ── KLAVYE AÇILIP KAPANMA DÖNGÜSÜ (flicker) FIX ──────────────────
	# Bir LineEdit'e yazarken mobil klavye açılır → viewport küçülür →
	# bu fonksiyon tetiklenir → _vw/_vh güncellenir → bağlı anchor'lar
	# yeniden yerleşir → bazı tarayıcılarda bu yeniden-yerleşim, focus'taki
	# input'un "görünür alandan çıktığını/taşındığını" sanıp klavyeyi
	# KAPATIR → viewport büyür → bu fonksiyon TEKRAR tetiklenir → tekrar
	# yeniden yerleşim → bazı durumlarda klavye TEKRAR açılır → sonsuz
	# açılıp-kapanma döngüsü. Kesin çözüm: bir LineEdit gerçekten focus'ta
	# iken hiçbir viewport-resize tepkisi VERME (ne _vw/_vh güncelle ne
	# rebuild) — döngüyü tetikleyecek hiçbir tepki yoksa döngü oluşamaz.
	# Focus bittiğinde (klavye kapanıp input'tan çıkıldığında) normal
	# akış devam eder ve son gerçek boyuta tek seferde senkronize olur.
	var focused := vp.gui_get_focus_owner()
	if is_instance_valid(focused) and focused is LineEdit:
		return

	var new_w := vp.get_visible_rect().size.x
	var new_h := vp.get_visible_rect().size.y

	# ── KLAVYE AÇILINCA VIEWPORT KÜÇÜLME SORUNU ──────────────────────
	# Mobilde sanal klavye açıldığında viewport yüksekliği azalır.
	# Bu bir UI rebuild tetiklemez — sadece _vw/_vh güncellenir.
	# Eşik: yükseklik %35'ten fazla küçüldüyse klavye açılmış demektir,
	# rebuild'i tamamen atla (hem oyun sırasında hem lobby'de).
	if _last_vh_real > 0.0:
		var shrink_ratio := (_last_vh_real - new_h) / _last_vh_real
		if shrink_ratio > 0.25:
			# Klavye kaynaklı küçülme — sadece _vw/_vh güncelle, rebuild YOK
			_vw  = new_w
			_vh  = new_h
			_ref = minf(minf(_vw, _vh), GameConstants.VW)
			return
		elif shrink_ratio < -0.05:
			# Klavye kapandı, boyut büyüdü — gerçek boyutu güncelle
			_last_vw_real = new_w
			_last_vh_real = new_h
	else:
		_last_vw_real = new_w
		_last_vh_real = new_h

	_check_landscape()
	_vw  = new_w
	_vh  = new_h
	_ref = minf(minf(_vw, _vh), GameConstants.VW)  # cap: design ref is 600x800, don't scale UI past it on big screens

	# Oyun aktifken rebuild etme — sadece main menu / game-over ekranında yenile
	if _started:
		return

	# Küçük boyut değişikliklerini yoksay (klavye, status bar vs.)
	# Sadece gerçek yönelim değişikliği (genişlik/yükseklik yer değiştirdi) rebuild yap
	var w_changed := absf(new_w - _last_vw_real) > 80.0
	var h_changed := absf(new_h - _last_vh_real) > 80.0
	# Sadece W değişti ama H değişmediyse (portrait→landscape veya tersi)
	# İkisi de değiştiyse gerçek resize sayılır
	var is_real_resize := (w_changed and h_changed) or (w_changed and not h_changed)

	# Bir panel (VS, Quest, Stats, Leaderboard) tüm ekranı kaplayarak açıkken
	# alttaki ana menüyü yıkıp yeniden kurmak riskli (task #64'ün crash'i) —
	# o yüzden hâlâ yapmıyoruz. AMA panelin kendi İÇİ (ikon/font/margin
	# boyutları) sadece panel ilk açıldığında hesaplanan sabit `ref` değerini
	# kullanıyor — döndürme gerçek bir yön değişikliğiyse (klavye değil) o
	# `ref` artık yanlış, ve panel HİÇ yeniden kurulmadığı için bazı öğeler
	# (anchor'lı pozisyonlar) doğru yerleşirken bazıları (sabit piksel boyut/
	# font) eski haliyle takılı kalıyor — "bazıları güncelleniyor bazıları
	# olmuyor" hatası tam bu. Güvenli çözüm: gerçek yön değişikliğinde açık
	# paneli kapat (içeriği bozmadan) — kullanıcı sekmeye tekrar dokunduğunda
	# panel sıfırdan, doğru ref ile kurulur. Küçük/klavye kaynaklı
	# değişikliklerde panel açık kalır, sadece _vw/_vh güncellenir.
	for panel in [_vs_panel, _quest_panel, _stats_panel, _leaderboard_panel]:
		if is_instance_valid(panel) and panel.visible:
			_vw  = new_w
			_vh  = new_h
			_ref = minf(minf(_vw, _vh), GameConstants.VW)
			if is_real_resize and panel.has_method("hide_panel"):
				panel.call("hide_panel")
				_last_vw_real = new_w
				_last_vh_real = new_h
			return

	if not is_real_resize:
		return

	_last_vw_real = new_w
	_last_vh_real = new_h

	# Debounce: 300ms içinde tekrar resize gelirse öncekini iptal et
	if is_instance_valid(_resize_timer):
		_resize_timer = null
	_resize_timer = get_tree().create_timer(0.3)
	await _resize_timer.timeout
	if not is_instance_valid(_resize_timer):
		return
	_resize_timer = null
	# UI'ı teardown + rebuild
	# determinism-ok (whole block): viewport-resize UI rebuild — only reachable via
	# vp.size_changed, which is never connected/fired during --server-replay/--server-worker.
	if is_instance_valid(_ui_layer):
		_ui_layer.free()  # determinism-ok: viewport-resize rebuild, never fires headless
		_ui_layer = null
	_ui_root        = null
	_settings_popup = null
	_bottom_bar     = null
	_play_btn       = null
	if is_instance_valid(_quest_panel):      _quest_panel.free();      _quest_panel = null  # determinism-ok: viewport-resize rebuild, never fires headless
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.free(); _leaderboard_panel = null  # determinism-ok: viewport-resize rebuild, never fires headless
	if is_instance_valid(_stats_panel):      _stats_panel.free();      _stats_panel = null  # determinism-ok: viewport-resize rebuild, never fires headless
	# BUG FIX: _vs_panel was missing from this list entirely. VSPanel is the
	# ONLY one of the four panels with actual text-input fields (NIM amount,
	# invite link) — so it's the only one that ever has a LineEdit focused
	# when a keyboard-triggered resize slips past the shrink_ratio>0.25 guard
	# above (e.g. a device where the virtual keyboard takes up less than 25%
	# of the screen). When that happened, this block tore down and rebuilt
	# the ENTIRE main menu underneath a VS panel that was left dangling —
	# never freed, never nulled, still holding an active HTTPRequest/Timer
	# from mid-typing — which is what was actually crashing the game.
	if is_instance_valid(_vs_panel):         _vs_panel.free();         _vs_panel = null  # determinism-ok: viewport-resize rebuild, never fires headless
	_build_start_ui()


func _check_landscape() -> void:
	_hide_landscape_overlay()  # landscape kısıtlaması kaldırıldı

func _show_landscape_overlay() -> void:
	pass  # devre dışı

func _hide_landscape_overlay() -> void:
	if not is_instance_valid(_landscape_overlay): return
	_landscape_overlay.queue_free()
	_landscape_overlay = null

func _process(_delta: float) -> void:
	# If calibration screen is open, update the angle label
	if is_instance_valid(_calib_layer):
		_calib_tick()


## Native mobile (Android/iOS) touch tracking
func _input(event: InputEvent) -> void:
	# Audio unlock — canvas inputları gui_input'a gelmiyor olabilir
	if not _audio_unlocked:
		if event is InputEventScreenTouch or event is InputEventMouseButton or event is InputEventKey:
			_start_bgm_if_needed()
	if event is InputEventScreenTouch:
		if event.pressed:
			_native_touch_x = event.position.x
			# 4 parmak = debug panel aç/kapat
			if event.index == 3:
				if is_instance_valid(_dbg_layer):
					_dbg_layer.queue_free(); _dbg_layer = null
				else:
					_open_overlay_debug()
		else:
			_native_touch_x = -1.0
	elif event is InputEventScreenDrag:
		_native_touch_x = event.position.x
	# PC'de test için: F9
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F9:
		if is_instance_valid(_dbg_layer):
			_dbg_layer.queue_free(); _dbg_layer = null
		else:
			_open_overlay_debug()


# ─────────────────────────────────────────────────────
#  GYRO CALIBRATION SCREEN
# ─────────────────────────────────────────────────────

var _calib_layer     : CanvasLayer = null
var _calib_angle_lbl : Label       = null
var _calib_ok_lbl    : Label       = null

# Saved state for calibration mode
var _calib_saved_gm      : Node         = null
var _calib_saved_player  : Node         = null
var _calib_saved_started : bool         = false
var _calib_saved_hud_vis : bool         = false
var _replay_source       : String       = ""  # "game_over" | "leaderboard" | "stats" | "web"
var _block_lb_replay     : bool         = false  # block late LB HTTP responses when play is pressed
var _calib_gm            : Node2D       = null
var _calib_real_player   : CharacterBody2D = null

## Calibration: opens a simulation of the real game without enemies/flat platforms.
## Restores previous state (lobby or game) on exit.
func _open_gyro_calib_screen() -> void:
	if is_instance_valid(_calib_layer):
		return

	_ensure_gyro_js()

	# ── Save current state ──────────────────────────────────────────
	_calib_saved_gm      = _gm
	_calib_saved_player  = _player
	_calib_saved_started = _started
	_calib_saved_hud_vis = is_instance_valid(_hud) and _hud.visible

	# Pause / hide current GM+player
	if is_instance_valid(_gm):
		_gm.set_process(false)
		_gm.set_physics_process(false)
		_gm.visible = false
	if is_instance_valid(_player):
		_player.visible = false
	if is_instance_valid(_hud):
		_hud.visible = false
	if is_instance_valid(_ui_layer):
		_ui_layer.visible = false

	# ── Create calibration GM ────────────────────────────────────────
	_calib_gm = Node2D.new()
	_calib_gm.name = "CalibGM"
	_calib_gm.set_script(load("res://scripts/GameManager.gd"))
	add_child(_calib_gm)

	# Calib player
	_calib_real_player = CharacterBody2D.new()
	_calib_real_player.set_script(load("res://scripts/Player.gd"))
	_calib_gm.add_child(_calib_real_player)

	# Calib kamera
	var calib_cam := Camera2D.new()
	calib_cam.enabled = true
	_calib_gm.add_child(calib_cam)

	# calib_mode flag — enemies/items/score/camera movement disabled
	_calib_gm.set("calib_mode", true)

	_calib_gm.call("init", calib_cam, _calib_real_player, null, null, null, self, -1, true)
	_calib_real_player.activate()

	# ── Overlay CanvasLayer — angle display + buttons ────────────────
	var vw  := _vw
	var vh  := _vh
	var ref := _ref

	_calib_layer = CanvasLayer.new()
	_calib_layer.layer = 30
	add_child(_calib_layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_calib_layer.add_child(root)

	# Angle pill — top center
	var angle_pill := PanelContainer.new()
	angle_pill.set_anchors_preset(Control.PRESET_TOP_WIDE)
	angle_pill.offset_top    = int(vh * 0.03)
	angle_pill.offset_bottom = int(vh * 0.03) + int(ref * 0.072)
	angle_pill.offset_left   = int(vw * 0.22)
	angle_pill.offset_right  = -int(vw * 0.22)
	var pill_st := StyleBoxFlat.new()
	pill_st.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	for s in ["corner_radius_top_left","corner_radius_top_right","corner_radius_bottom_left","corner_radius_bottom_right"]:
		pill_st.set(s, 20)
	angle_pill.add_theme_stylebox_override("panel", pill_st)
	root.add_child(angle_pill)

	var pill_mc := _make_margin_container(int(ref * 0.018))
	angle_pill.add_child(pill_mc)
	var pill_hbox := HBoxContainer.new()
	pill_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	pill_hbox.add_theme_constant_override("separation", int(ref * 0.010))
	pill_mc.add_child(pill_hbox)
	var angle_desc := Label.new()
	angle_desc.text = "Tilt:"
	UITheme.apply_label(angle_desc, Color(0.75, 0.75, 0.75), int(ref * 0.028))
	pill_hbox.add_child(angle_desc)
	_calib_angle_lbl = Label.new()
	_calib_angle_lbl.text = "0.0 deg"
	UITheme.apply_label(_calib_angle_lbl, UITheme.COL_GOLD, int(ref * 0.034))
	pill_hbox.add_child(_calib_angle_lbl)

	# "Calibrated!" label
	_calib_ok_lbl = Label.new()
	_calib_ok_lbl.text = "OK. Zero point set!"
	UITheme.apply_label(_calib_ok_lbl, Color(0.3, 0.9, 0.4), int(ref * 0.038))
	_calib_ok_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_calib_ok_lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_calib_ok_lbl.offset_top    = int(vh * 0.12)
	_calib_ok_lbl.offset_bottom = int(vh * 0.12) + int(ref * 0.055)
	_calib_ok_lbl.modulate.a    = 0.0
	root.add_child(_calib_ok_lbl)

	# Buttons
	var btn_w   := vw * 0.72
	var btn_h   := int(ref * 0.095)
	var btn_gap := int(ref * 0.016)

	var zero_btn := Button.new()
	zero_btn.text = "Set Zero Now"
	zero_btn.add_theme_font_size_override("font_size", int(ref * 0.044))
	zero_btn.custom_minimum_size = Vector2(btn_w, btn_h)
	zero_btn.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	zero_btn.offset_bottom = -int(vh * 0.05) - btn_h - btn_gap
	zero_btn.offset_top    = -int(vh * 0.05) - btn_h * 2 - btn_gap
	zero_btn.offset_left   = (vw - btn_w) * 0.5
	zero_btn.offset_right  = -(vw - btn_w) * 0.5
	UITheme.apply_play_button(zero_btn)
	root.add_child(zero_btn)
	zero_btn.pressed.connect(func():
		if OS.has_feature("web"):
			_gyro_baseline = (_js_window._getGyroRaw() if _js_window != null else 0.0)
		else:
			_gyro_baseline = Input.get_gravity().x / 9.8 * 90.0
		if is_instance_valid(_calib_ok_lbl):
			var tw := create_tween()
			if tw:
				tw.tween_property(_calib_ok_lbl, "modulate:a", 1.0, 0.12)
				tw.tween_interval(0.7)
				tw.tween_property(_calib_ok_lbl, "modulate:a", 0.0, 0.20)
				tw.tween_callback(func(): _close_gyro_calib_screen())
	)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.add_theme_font_size_override("font_size", int(ref * 0.038))
	back_btn.custom_minimum_size = Vector2(btn_w, btn_h)
	back_btn.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	back_btn.offset_bottom = -int(vh * 0.05)
	back_btn.offset_top    = -int(vh * 0.05) - btn_h
	back_btn.offset_left   = (vw - btn_w) * 0.5
	back_btn.offset_right  = -(vw - btn_w) * 0.5
	UITheme.apply_ghost_button(back_btn)
	root.add_child(back_btn)
	back_btn.pressed.connect(func(): _close_gyro_calib_screen())

	set_process(true)


## Called every frame — updates the angle label
func _calib_tick() -> void:
	if not is_instance_valid(_calib_angle_lbl): return

	var raw := 0.0
	if OS.has_feature("web"):
		raw = (_js_window._getGyroRaw() if _js_window != null else 0.0)
	else:
		raw = Input.get_gravity().x / 9.8 * 90.0

	var relative := raw - _gyro_baseline
	_calib_angle_lbl.text = "%+.1f deg" % relative
	if abs(relative) < 5.0:
		_calib_angle_lbl.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	elif abs(relative) < 20.0:
		_calib_angle_lbl.add_theme_color_override("font_color", UITheme.COL_GOLD)
	else:
		_calib_angle_lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))


## Close calibration screen — destroy calib GM, restore previous state
func _close_gyro_calib_screen() -> void:
	if not is_instance_valid(_calib_layer): return

	var tw := create_tween()
	if tw:
		tw.tween_property(_calib_layer, "modulate:a", 0.0, 0.18)
		tw.tween_callback(func(): _calib_cleanup())
	else:
		_calib_cleanup()


func _calib_cleanup() -> void:
	# Remove overlay
	if is_instance_valid(_calib_layer):
		_calib_layer.queue_free()
	_calib_layer     = null
	_calib_angle_lbl = null
	_calib_ok_lbl    = null

	# Destroy calib GM + player
	if is_instance_valid(_calib_real_player):
		_calib_real_player.queue_free()
	_calib_real_player = null
	if is_instance_valid(_calib_gm):
		_calib_gm.queue_free()
	_calib_gm = null

	# Restore previous state
	_gm      = _calib_saved_gm
	_player  = _calib_saved_player
	_started = _calib_saved_started

	if is_instance_valid(_gm):
		_gm.set_process(true)
		_gm.set_physics_process(true)
		_gm.visible = true
	if is_instance_valid(_player):
		_player.visible = true
	if is_instance_valid(_hud):
		_hud.visible = _calib_saved_hud_vis
	if is_instance_valid(_ui_layer) and not _started:
		_ui_layer.visible = true

	_calib_saved_gm      = null
	_calib_saved_player  = null


## Sets up DeviceOrientation event listener and touch tracker once for web.
func _ensure_gyro_js() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("window._gyroThreshold = %f;" % (3.5 / maxf(_gyro_sensitivity, 0.1)), true)
	JavaScriptBridge.eval("""
		// iOS: request permission (non-iOS already started in _ready)
		if (typeof DeviceOrientationEvent !== 'undefined' &&
			typeof DeviceOrientationEvent.requestPermission === 'function') {
			if (!window._gyroPermAsked) {
				window._gyroPermAsked = true;
				DeviceOrientationEvent.requestPermission().then(function(state) {
					if (state === 'granted') window._startGyroListener();
					else window._gyroPermDenied = true;
				}).catch(function() {
					window._gyroPermDenied = true;
				});
			}
		} else {
			window._startGyroListener();
		}
	""", true)

## Returns -1 / 0 / 1 direction; GameManager uses this value.
func get_control_dir() -> int:
	if _control_mode == "tap":
		return _get_tap_dir()
	else:
		return _get_gyro_dir()

## Tap left/right half of screen — touch or left mouse click
func _get_tap_dir() -> int:
	# Keyboard support (desktop / editor)
	var l_key := Input.is_action_pressed("ui_left")  or Input.is_action_pressed("move_left")
	var r_key := Input.is_action_pressed("ui_right") or Input.is_action_pressed("move_right")
	if r_key and not l_key: return 1
	if l_key and not r_key: return -1

	# Native mobile (Android/iOS) — touch from _input
	if not OS.has_feature("web") and _native_touch_x >= 0.0:
		return 1 if _native_touch_x > _vw * 0.5 else -1

	# Web / mobile touch — pre-compiled JS getter, zero string parsing per frame
	if OS.has_feature("web"):
		if _js_window == null:
			return 0
		var result = _js_window._getTapDir()
		return int(result) if result != null else 0

	# Native touch (Godot 4 — touch events come via _input,
	# no instant query available; fall through to keyboard)
	return 0

## Gyro (device tilt) — web: pre-compiled JS getter, no per-frame string parsing
var _gyro_calib_frames := 0  # used for native fallback only
func _get_gyro_dir() -> int:
	if OS.has_feature("web"):
		if _js_window == null:
			return 0
		var d = _js_window._getGyroDir()
		return int(d) if d != null else 0
	else:
		# Native: GDScript reads gravity directly
		var raw_gamma := Input.get_gravity().x / 9.8 * 90.0
		if _gyro_calib_frames < 15:
			if abs(raw_gamma) < 60.0:
				var alpha := 0.6 if _gyro_calib_frames < 5 else 0.3
				_gyro_baseline = raw_gamma * alpha + _gyro_baseline * (1.0 - alpha)
				_gyro_calib_frames += 1
		var tilted    := raw_gamma - _gyro_baseline
		var threshold := 3.5 / maxf(_gyro_sensitivity, 0.1)
		if abs(tilted) < threshold * 0.5: return 0
		return 1 if tilted > 0 else -1


func _save_settings() -> void:
	# Debounce: coalesce rapid calls (slider drag) into one write 300ms later
	if _save_timer != null: return
	if not get_tree(): return
	_save_timer = get_tree().create_timer(0.3)
	_save_timer.timeout.connect(func():
		_save_timer = null
		_save_settings_flush()
	)

func _save_settings_flush() -> void:
	if not OS.has_feature("web"): return
	var d := {
		"control_mode":    _control_mode,
		"gyro_sensitivity": _gyro_sensitivity,
		"vibration":       _vibration,
		"muted":           _muted,
		"bgm_enabled":     _bgm_enabled,
		"bgm_volume":      _bgm_volume,
		"jump_enabled":    _jump_enabled,
		"jump_volume":     _jump_volume,
		"damage_enabled":  _damage_enabled,
		"damage_volume":   _damage_volume,
		"char_index":      _char_index,
		"bg_selected":     _bg_selected,
		"bg_auto":         _bg_auto,
	}
	JavaScriptBridge.eval("localStorage.setItem('nimjump_settings', '%s')" % JSON.stringify(d).replace("'", "\\'"), true)


func _load_settings() -> void:
	if not OS.has_feature("web"): return
	var raw_js : String = str(JavaScriptBridge.eval("localStorage.getItem('nimjump_settings') ?? ''", true))
	if raw_js == "" or raw_js == "null": return
	var result : Variant = JSON.parse_string(raw_js)
	if not result is Dictionary: return
	var d : Dictionary = result
	if d.has("control_mode"):     _control_mode     = str(d["control_mode"])
	if d.has("gyro_sensitivity"): _gyro_sensitivity = float(d["gyro_sensitivity"])
	if d.has("vibration"):        _vibration        = bool(d["vibration"])
	if d.has("muted"):            _muted            = bool(d["muted"])
	if d.has("bgm_enabled"):      _bgm_enabled      = bool(d["bgm_enabled"])
	if d.has("bgm_volume"):       _bgm_volume       = float(d["bgm_volume"])
	if d.has("jump_enabled"):     _jump_enabled     = bool(d["jump_enabled"])
	if d.has("jump_volume"):      _jump_volume      = float(d["jump_volume"])
	if d.has("damage_enabled"):   _damage_enabled   = bool(d["damage_enabled"])
	if d.has("damage_volume"):    _damage_volume    = float(d["damage_volume"])
	if d.has("char_index"):       _char_index       = int(d["char_index"])
	if d.has("bg_selected"):      _bg_selected      = int(d["bg_selected"])
	if d.has("bg_auto"):          _bg_auto          = bool(d["bg_auto"])


func _anchored(node: Control, preset: int) -> Control:
	node.set_anchors_and_offsets_preset(preset)
	return node


func _p(pct: float) -> float:
	return _ref * pct

func _ph(pct: float) -> float:
	return _vh * pct

func _pw(pct: float) -> float:
	return _vw * pct


# ─────────────────────────────────────────────────────
#  GAME INFRASTRUCTURE
# ─────────────────────────────────────────────────────
# Recursively searches the scene tree for an existing Camera2D
func _find_camera_in_tree(node: Node) -> Camera2D:
	if node is Camera2D:
		return node as Camera2D
	for child in node.get_children():
		var result := _find_camera_in_tree(child)
		if result:
			return result
	return null


func _build_game() -> void:
	print("[Main] _build_game() called — setting up background")
	# ── Teardown previous build — free all game nodes before rebuilding ──────
	# Use free() not queue_free() — new nodes are added in the same frame
	var _nodes_to_free := [_hud, _ui_layer, _gm, _player, _replay_bar,
		_quest_panel, _leaderboard_panel, _stats_panel]
	for node in _nodes_to_free:
		if is_instance_valid(node): node.free()  # determinism-ok: client-only UI teardown, never runs in --server-replay/--server-worker (those return before _build_game() is ever called)
	_hud = null; _ui_layer = null; _gm = null; _player = null
	_replay_bar = null; _quest_panel = null; _leaderboard_panel = null; _stats_panel = null
	_powerup_row = null
	# Free all CanvasLayers except landscape/calib overlays
	for child in get_children().duplicate():
		if child is CanvasLayer:
			if child != _landscape_overlay and child != _calib_layer:
				child.free()  # determinism-ok: same _build_game() UI teardown, client-only
	# ─────────────────────────────────────────────────────────────────────────
	# Start Nimiq poll only on first call (_poll_started flag blocks second call)
	if _nimiq_bridge and not _nimiq_bridge._poll_started:
		_nimiq_bridge._poll()
	# TextureRect is a Control node; anchor/preset doesn't work inside Node2D.
	# Solution: wrap in a CanvasLayer (layer=-10) — always fills the viewport.
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -10
	add_child(bg_layer)

	var bg_root := Control.new()
	bg_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_layer.add_child(bg_root)

	# Bottom layer: current background (always visible)
	_bg_rect = TextureRect.new()
	_bg_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_root.add_child(_bg_rect)

	# Top layer: new background (fades in)
	_bg_rect2 = TextureRect.new()
	_bg_rect2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg_rect2.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_bg_rect2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_rect2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_rect2.modulate.a   = 0.0
	bg_root.add_child(_bg_rect2)

	apply_selected_background()

	_gm = Node2D.new()
	_gm.name = "GameManager"
	_gm.set_script(load("res://scripts/GameManager.gd"))
	add_child(_gm)
	# On app open: flush any pending submits
	_gm.call("flush_pending")

	# Use existing Camera2D if present, otherwise create a new one
	_cam = get_viewport().get_camera_2d()
	if not is_instance_valid(_cam):
		_cam = _find_camera_in_tree(get_tree().root)
	if is_instance_valid(_cam) and _cam.get_parent() != _gm:
		# Move existing camera under _gm
		var old_parent := _cam.get_parent()
		if old_parent:
			old_parent.remove_child(_cam)
		_gm.add_child(_cam)
	elif not is_instance_valid(_cam):
		_cam = Camera2D.new()
		_cam.name = "Camera2D"
		_gm.add_child(_cam)
	_cam.position_smoothing_enabled = false
	_cam.make_current()

	# ── HUD CanvasLayer ─────────────────────────────
	_hud = CanvasLayer.new()
	_hud.name    = "HUD"
	_hud.visible = false
	add_child(_hud)

	var hud_root := Control.new()
	_anchored(hud_root, Control.PRESET_FULL_RECT)
	_hud.add_child(hud_root)

	var a := UITheme.get_theme_assets()
	# All sizes via _p() = ref*pct. ref = min(w,h) ≈ 600 → consistent scale.
	# _pw/_ph only for anchor offsets.
	var M  := int(_p(0.020))  # margin
	var IC := int(_p(0.065))  # icon size (~1.5x larger)
	var DH := int(_p(0.065))  # digit height (score)
	var DH2:= int(_p(0.050))  # digit height (altitude)
	var FS := int(_p(0.028))  # label font size

	# ══ TOP LEFT: Score (no panel, directly on hud_root) ═══
	var score_anchor := Control.new()
	score_anchor.anchor_left   = 0.0; score_anchor.anchor_top    = 0.0
	score_anchor.anchor_right  = 0.0; score_anchor.anchor_bottom = 0.0
	score_anchor.offset_left   = M;   score_anchor.offset_top    = M
	score_anchor.offset_right  = M + int(_p(0.42))
	score_anchor.offset_bottom = M + int(DH * 2 + int(_p(0.010)) + int(_p(0.010)) * 2)
	hud_root.add_child(score_anchor)

	var score_vbox := VBoxContainer.new()
	score_vbox.add_theme_constant_override("separation", int(_p(0.010)))
	_anchored(score_vbox, Control.PRESET_FULL_RECT)
	score_anchor.add_child(score_vbox)

	_score_display = _make_icon_row(score_vbox, "res://assets/hud/coin_gold.png",      DH,          DH)
	_nimiq_display = _make_icon_row(score_vbox, "res://assets/items/nimiq_hexagon_item.png", int(_p(0.065)), int(_p(0.065)))

	# ══ TOP RIGHT: Pause button ══════════════════════
	var btn_sz := int(_p(0.088))

	# Pause button removed per request — not a real feature in this game.
	# _powerup_row used to reserve space to the LEFT of it (offset_right
	# stopped short by btn_sz+margin); now it can use the full row width.
	_powerup_row = HBoxContainer.new()
	_powerup_row.add_theme_constant_override("separation", int(_p(0.026)))
	_powerup_row.anchor_left   = 0.0; _powerup_row.anchor_right  = 1.0
	_powerup_row.anchor_top    = 0.0; _powerup_row.anchor_bottom = 0.0
	_powerup_row.offset_left   = M
	_powerup_row.offset_right  = -M
	_powerup_row.offset_top    = M
	_powerup_row.offset_bottom = M + btn_sz
	_powerup_row.alignment     = BoxContainer.ALIGNMENT_END
	hud_root.add_child(_powerup_row)

	# ══ BOTTOM LEFT: Life icons ══════════════════════
	# PanelContainer auto-sizes to content — no manual calculation needed
	var heart_sz  := int(_p(0.088))
	var heart_sep := int(_p(0.003))
	var heart_mg  := int(_p(0.004))

	var life_pc := PanelContainer.new()
	life_pc.anchor_left   = 0.0; life_pc.anchor_top    = 1.0
	life_pc.anchor_right  = 0.0; life_pc.anchor_bottom = 1.0
	life_pc.offset_left   = M;   life_pc.offset_top    = -M
	life_pc.offset_right  = M;   life_pc.offset_bottom = -M
	life_pc.grow_horizontal = Control.GROW_DIRECTION_END
	life_pc.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	UITheme.apply_panel(life_pc)
	hud_root.add_child(life_pc)

	var life_mc := MarginContainer.new()
	life_mc.add_theme_constant_override("margin_left",   heart_mg)
	life_mc.add_theme_constant_override("margin_right",  heart_mg)
	life_mc.add_theme_constant_override("margin_top",    heart_mg)
	life_mc.add_theme_constant_override("margin_bottom", heart_mg)
	life_pc.add_child(life_mc)

	var life_row := HBoxContainer.new()
	life_row.add_theme_constant_override("separation", heart_sep)
	life_mc.add_child(life_row)

	var heart_full_tex  : Texture2D = null
	var heart_empty_tex : Texture2D = null
	if ResourceLoader.exists("res://assets/hud/hudHeart_full.png"):
		heart_full_tex  = load("res://assets/hud/hudHeart_full.png")
	if ResourceLoader.exists("res://assets/hud/hudHeart_empty.png"):
		heart_empty_tex = load("res://assets/hud/hudHeart_empty.png")
	for _i in 3:
		var ico := TextureRect.new()
		ico.texture             = heart_full_tex
		ico.custom_minimum_size = Vector2(heart_sz, heart_sz)
		ico.size                = Vector2(heart_sz, heart_sz)
		ico.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		ico.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ico.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
		ico.set_meta("heart_full",  heart_full_tex)
		ico.set_meta("heart_empty", heart_empty_tex)
		life_row.add_child(ico)
		_life_icons.append(ico)

	# ══ GAME OVER PANEL ════════════════════════════
	var go_dim := ColorRect.new()
	go_dim.color   = Color(0.0, 0.0, 0.0, 0.62)
	go_dim.visible = false
	_anchored(go_dim, Control.PRESET_FULL_RECT)
	hud_root.add_child(go_dim)

	var go_center := CenterContainer.new()
	go_center.visible = false
	_anchored(go_center, Control.PRESET_FULL_RECT)
	hud_root.add_child(go_center)

	_go_panel = PanelContainer.new()
	# Width: 86% of screen — PanelContainer auto-sizes to content height
	_go_panel.custom_minimum_size = Vector2(_p(0.86), 0.0)
	_go_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var _go_panel_st := StyleBoxFlat.new()
	_go_panel_st.bg_color     = Color(0.957, 0.898, 0.800)   # QuestPanel _COL_CARD_BG ile aynı
	_go_panel_st.border_color = Color(0.580, 0.380, 0.220)   # _COL_CARD_BORDER
	_go_panel_st.set_border_width_all(3)
	_go_panel_st.set_corner_radius_all(14)
	_go_panel_st.shadow_color = Color(0.0, 0.0, 0.0, 0.20)
	_go_panel_st.shadow_size  = 8
	_go_panel.add_theme_stylebox_override("panel", _go_panel_st)
	go_center.add_child(_go_panel)

	var go_mc := _make_margin_container(int(_p(0.032)))
	_go_panel.add_child(go_mc)

	var go_vbox := VBoxContainer.new()
	go_vbox.add_theme_constant_override("separation", int(_p(0.015)))
	go_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	go_mc.add_child(go_vbox)

	# "GAME OVER" title row — title centered, share btn right
	var go_title_row := HBoxContainer.new()
	go_title_row.alignment = BoxContainer.ALIGNMENT_CENTER
	go_vbox.add_child(go_title_row)

	var go_title := Label.new()
	go_title.text = "GAME OVER"
	go_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(go_title, Color(0.180, 0.100, 0.040), int(_p(0.072)))
	go_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_title_row.add_child(go_title)

	# Score box
	var go_score_box := PanelContainer.new()
	go_score_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _score_box_st := StyleBoxFlat.new()
	_score_box_st.bg_color     = Color(0.910, 0.850, 0.750)
	_score_box_st.border_color = Color(0.580, 0.380, 0.220)
	_score_box_st.set_border_width_all(2)
	_score_box_st.set_corner_radius_all(10)
	go_score_box.add_theme_stylebox_override("panel", _score_box_st)
	go_vbox.add_child(go_score_box)

	var go_score_mc := _make_margin_container(int(_p(0.020)))
	go_score_box.add_child(go_score_mc)

	var go_score_vbox := VBoxContainer.new()
	go_score_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	go_score_vbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go_score_vbox.add_theme_constant_override("separation", int(_p(0.006)))
	go_score_mc.add_child(go_score_vbox)

	# ── Final score: icon + digits, centered ──
	var _fs_sz := int(_p(0.054))


	_final_display = _DigitDisplay.new(int(_p(0.096)))

	var _fs_hbox := HBoxContainer.new()
	_fs_hbox.add_theme_constant_override("separation", int(_p(0.010)))
	_fs_hbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_fs_hbox.add_child(_final_display)
	go_score_vbox.add_child(_fs_hbox)

	var go_final_lbl := Label.new()
	go_final_lbl.text = "FINAL SCORE"
	UITheme.apply_label(go_final_lbl, Color(0.480, 0.340, 0.200), int(_p(0.026)))
	go_final_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_final_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go_score_vbox.add_child(go_final_lbl)

	# ── Match stats box — 4-ikonlu grid (referans UI gibi) ──────────
	var stats_box := PanelContainer.new()
	stats_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _stats_box_st := StyleBoxFlat.new()
	_stats_box_st.bg_color     = Color(0.910, 0.850, 0.750)
	_stats_box_st.border_color = Color(0.580, 0.380, 0.220)
	_stats_box_st.set_border_width_all(2)
	_stats_box_st.set_corner_radius_all(10)
	stats_box.add_theme_stylebox_override("panel", _stats_box_st)
	go_vbox.add_child(stats_box)

	var stats_mc := _make_margin_container(int(_p(0.014)))
	stats_box.add_child(stats_mc)

	var stats_grid := HBoxContainer.new()
	stats_grid.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_grid.add_theme_constant_override("separation", 0)
	stats_mc.add_child(stats_grid)

	var stat_defs : Array = [
		["res://assets/hud/platform_icon.png",  "P",  "0",  "PLATFORMS"],
		["res://assets/hud/skull_icon.png",     "K",  "0",  "KILLS"    ],
		["res://assets/items/nimiq_hexagon_item.png", "C", "0",  "COINS"    ],
	]

	var _stat_val_nodes : Array[Label] = []
	for i in stat_defs.size():
		var d : Array = stat_defs[i]
		var item := VBoxContainer.new()
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.alignment = BoxContainer.ALIGNMENT_CENTER
		item.add_theme_constant_override("separation", int(_p(0.003)))

		# CenterContainer garantees the inner HBox stays centered
		var cc := CenterContainer.new()
		cc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.add_child(cc)

		var icon_row := HBoxContainer.new()
		icon_row.add_theme_constant_override("separation", int(_p(0.008)))
		cc.add_child(icon_row)

		var ico_sz := int(_p(0.046))
		if ResourceLoader.exists(d[0] as String):
			var tr := TextureRect.new()
			tr.texture = load(d[0] as String)
			tr.custom_minimum_size = Vector2(ico_sz, ico_sz)
			tr.size               = Vector2(ico_sz, ico_sz)
			tr.stretch_mode       = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.expand_mode        = TextureRect.EXPAND_IGNORE_SIZE
			tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			tr.texture_filter     = Control.TEXTURE_FILTER_LINEAR
			icon_row.add_child(tr)
		else:
			var el := Label.new()
			el.text = d[1] as String
			UITheme.apply_label(el, Color(0.480, 0.340, 0.200), int(_p(0.038)))
			el.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			icon_row.add_child(el)

		var vl := Label.new()
		vl.text = d[2] as String
		UITheme.apply_label(vl, Color(0.180, 0.100, 0.040), int(_p(0.044)))
		vl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon_row.add_child(vl)
		_stat_val_nodes.append(vl)

		var cl := Label.new()
		cl.text = d[3] as String
		UITheme.apply_label(cl, Color(0.480, 0.340, 0.200), int(_p(0.022)))
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.add_child(cl)

		stats_grid.add_child(item)
		# Vertical separator (except after last)
		if i < stat_defs.size() - 1:
			var vsep := VSeparator.new()
			vsep.add_theme_color_override("color", Color(0.700, 0.500, 0.300, 0.5))
			vsep.custom_minimum_size = Vector2(1, int(_p(0.050)))
			vsep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			stats_grid.add_child(vsep)

	# _go_stats_lbl kept as dummy so existing show_game_over code doesn't crash
	_go_stats_lbl = Label.new()
	_go_stats_lbl.visible = false
	stats_box.add_child(_go_stats_lbl)
	_go_panel.set_meta("stat_vals", _stat_val_nodes)

	# Server score box — gizli, claim logic için tutuldu
	var srv_box := PanelContainer.new()
	srv_box.visible = false
	go_vbox.add_child(srv_box)
	var srv_mc := _make_margin_container(0)
	srv_box.add_child(srv_mc)
	var srv_vbox := VBoxContainer.new()
	srv_mc.add_child(srv_vbox)
	_claim_lbl = Label.new()
	srv_vbox.add_child(_claim_lbl)
	_srv_score_display = _DigitDisplay.new(int(_p(0.065)))
	_srv_score_display.visible = false
	srv_vbox.add_child(_srv_score_display)
	_claim_status = Label.new()
	srv_vbox.add_child(_claim_status)

	# CLAIM butonu — gizli kalır, arka planda çalışır
	_claim_btn = Button.new()
	_claim_btn.visible = false
	_claim_btn.pressed.connect(_do_claim)
	go_vbox.add_child(_claim_btn)

	# Button row — referans UI gibi: PLAY AGAIN (büyük turuncu) | WATCH REPLAY (ghost)
	var go_btn_row := HBoxContainer.new()
	go_btn_row.add_theme_constant_override("separation", int(_p(0.012)))
	go_btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go_vbox.add_child(go_btn_row)

	var restart_btn := Button.new()
	restart_btn.text = "PLAY AGAIN"
	restart_btn.add_theme_font_size_override("font_size", int(_p(0.034)))
	restart_btn.custom_minimum_size = Vector2(0, int(_p(0.088)))
	restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restart_btn.pressed.connect(func():
		if OS.has_feature("web"):
			JavaScriptBridge.eval("history.replaceState(null,'',location.pathname)", true)
		get_tree().reload_current_scene()
	)
	UITheme.apply_play_button(restart_btn)
	go_btn_row.add_child(restart_btn)

	# ── REPLAY button ────────────────────────────────────────────────
	var replay_btn := Button.new()
	replay_btn.text = "WATCH REPLAY"
	replay_btn.add_theme_font_size_override("font_size", int(_p(0.034)))
	replay_btn.custom_minimum_size = Vector2(0, int(_p(0.088)))
	replay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	replay_btn.visible = false   # hidden when no replay available
	UITheme.apply_ghost_button(replay_btn)
	replay_btn.pressed.connect(_on_replay_pressed)
	go_btn_row.add_child(replay_btn)
	_go_panel.set_meta("replay_btn", replay_btn)

	# ── SHARE button — full width, turuncu, StatsPanel ile aynı stil ──
	var share_btn := Button.new()
	share_btn.text = "Share Score"
	share_btn.add_theme_font_size_override("font_size", int(_p(0.030)))
	share_btn.custom_minimum_size = Vector2(0, int(_p(0.072)))
	share_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _shs_n := StyleBoxFlat.new(); var _shs_h := StyleBoxFlat.new(); var _shs_p := StyleBoxFlat.new()
	_shs_n.bg_color = Color(0.780, 0.380, 0.120); _shs_n.set_corner_radius_all(10)
	_shs_h.bg_color = Color(0.820, 0.450, 0.160); _shs_h.set_corner_radius_all(10)
	_shs_p.bg_color = Color(0.640, 0.300, 0.080); _shs_p.set_corner_radius_all(10)
	share_btn.add_theme_stylebox_override("normal",  _shs_n)
	share_btn.add_theme_stylebox_override("hover",   _shs_h)
	share_btn.add_theme_stylebox_override("pressed", _shs_p)
	share_btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
	share_btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
	share_btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
	share_btn.pressed.connect(func():
		var sc : int = int(_gm.get("score")) if _gm else 0
		var sid : String = str(_gm.get("session_id")) if _gm and _gm.get("session_id") != null else ""
		var share_url : String = ApiConfig.replay_url(sid) if sid != "" else ApiConfig.game_url()
		var msg : String
		if sid != "":
			msg = "My score %d — can you beat me? Watch my replay: %s" % [sc, share_url]
		else:
			msg = "My score %d — can you beat me? %s" % [sc, share_url]
		ApiConfig.share_score(sc, msg, share_url)
	)
	go_vbox.add_child(share_btn)

	_go_panel.set_meta("container", go_center)
	_go_panel.set_meta("dim", go_dim)

	# Player
	_player = CharacterBody2D.new()
	_player.name = "Player"
	_player.set_script(load("res://scripts/Player.gd"))
	_gm.add_child(_player)

func _init_game() -> void:
	# Connect signal BEFORE init — if pool is full, init may emit synchronously
	if _gm.has_signal("ready_to_play") and not _gm.is_connected("ready_to_play", _on_gm_ready):
		_gm.connect("ready_to_play", _on_gm_ready)

	_gm.call("init", _cam, _player, null, null, null, self, -1)

	_player.lives_changed.connect(_on_lives_changed)
	_prev_lives = _player.lives
	_on_lives_changed(_player.lives)

	# Hook jump sound — Player calls play_jump_sound on main_node
	# (main_node is set by GameManager.init; we use the same pattern)
	if _player.has_signal("jumped"):
		if not _player.is_connected("jumped", play_jump_sound):
			_player.connect("jumped", play_jump_sound)


func _on_gm_ready() -> void:
	var used_seed : int = _gm.get("game_seed")
	print("[MAIN] _on_gm_ready seed=%d _started=%s _initialized=%s" % [
		used_seed, str(_started), str(_player.get("_initialized") if _player else "no_player")])
	if used_seed != 0:
		_update_torch_state()
	# ready_to_play geldiğinde platformlar zaten spawn edilmiş durumda —
	# 0.8s bekleme kaldırıldı (blocking); PLAY butonu hemen açılır.
	if is_instance_valid(_play_btn):
		_play_btn.disabled = false
		_play_btn.text = "PLAY"
	if _started and _player and _player.has_method("activate"):
		if not _player.get("_initialized"):
			print("[MAIN] calling activate()")
			_player.activate()


# ─────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────
## Create a MarginContainer with equal margins on all sides
func _make_margin_container(margin: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   margin)
	mc.add_theme_constant_override("margin_right",  margin)
	mc.add_theme_constant_override("margin_top",    margin)
	mc.add_theme_constant_override("margin_bottom", margin)
	return mc

## Create an HBoxContainer row with an icon and a _DigitDisplay
func _make_icon_row(parent: VBoxContainer, icon_path: String, icon_sz: int, digit_h: int) -> _DigitDisplay:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_p(0.008)))
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(row)
	if ResourceLoader.exists(icon_path):
		var ico := TextureRect.new()
		ico.texture = load(icon_path)
		ico.custom_minimum_size = Vector2(icon_sz, icon_sz)
		ico.size                = Vector2(icon_sz, icon_sz)
		ico.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
		ico.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ico.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
		ico.texture_filter      = Control.TEXTURE_FILTER_LINEAR
		row.add_child(ico)
	var disp := _DigitDisplay.new(digit_h)
	row.add_child(disp)
	return disp


# ─────────────────────────────────────────────────────
#  POWERUP HUD
# ─────────────────────────────────────────────────────
func _make_powerup_slot(tex: Texture2D, t_max: float, t_cur: float, is_debuff: bool = false) -> Dictionary:
	var slot_size := _p(0.090)

	var slot_ctrl := Control.new()
	slot_ctrl.custom_minimum_size = Vector2(slot_size, slot_size)

	var icon := TextureRect.new()
	icon.texture = tex
	icon.anchor_left   = 0.0; icon.anchor_top    = 0.0
	icon.anchor_right  = 1.0; icon.anchor_bottom = 1.0
	icon.offset_left   = 0.0; icon.offset_top    = 0.0
	icon.offset_right  = 0.0; icon.offset_bottom = 0.0
	icon.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode   = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	slot_ctrl.add_child(icon)

	var arc := _ArcBar.new()
	arc.anchor_left   = 0.0; arc.anchor_top    = 0.0
	arc.anchor_right  = 1.0; arc.anchor_bottom = 1.0
	arc.offset_left  = -_p(0.010); arc.offset_top    = -_p(0.010)
	arc.offset_right  = _p(0.010); arc.offset_bottom =  _p(0.010)
	arc.radius = slot_size * 0.5 - 2.0
	arc.t_max     = t_max
	arc.t_cur     = t_cur
	arc.is_debuff = is_debuff
	slot_ctrl.add_child(arc)

	_powerup_row.add_child(slot_ctrl)
	return { "ctrl": slot_ctrl, "arc": arc, "t_max": t_max }


func update_powerup_hud(
		main_active: bool, main_type: String, main_timer: float, main_tmax: float,
		shield_active: bool, shield_timer: float, shield_tmax: float,
		mirror_on: bool = false, mirror_t: float = 0.0,
		eq_on: bool = false, eq_t: float = 0.0,
		drunk_on: bool = false, drunk_t: float = 0.0) -> void:
	if DisplayServer.get_name() == "headless": return

	# MN-04: compare each field directly — zero String/Array allocations per tick
	var _new_tmax_int := int(main_tmax * 10)
	var _eff_type     := main_type if main_active else ""
	var _structure_same := (
		_last_hud_main_active == main_active and
		_last_hud_main_type   == _eff_type   and
		_last_hud_main_tmax   == _new_tmax_int and
		_last_hud_shield_on   == shield_active and
		_last_hud_mirror_on   == mirror_on     and
		_last_hud_eq_on       == eq_on         and
		_last_hud_drunk_on    == drunk_on
	)

	if _structure_same:
		# Structure unchanged — just update arc timers (no alloc)
		# MN-01: unrolled — no Array literal per tick
		var idx := 0
		if main_active and idx < _powerup_slots.size():
			_powerup_slots[idx]["arc"].t_cur = main_timer; idx += 1
		if shield_active and idx < _powerup_slots.size():
			_powerup_slots[idx]["arc"].t_cur = shield_timer; idx += 1
		if mirror_on and idx < _powerup_slots.size():
			_powerup_slots[idx]["arc"].t_cur = mirror_t; idx += 1
		if eq_on and idx < _powerup_slots.size():
			_powerup_slots[idx]["arc"].t_cur = eq_t; idx += 1
		if drunk_on and idx < _powerup_slots.size():
			_powerup_slots[idx]["arc"].t_cur = drunk_t; idx += 1
		return

	# Update cached fields
	_last_hud_main_active = main_active
	_last_hud_main_type   = _eff_type
	_last_hud_main_tmax   = _new_tmax_int
	_last_hud_shield_on   = shield_active
	_last_hud_mirror_on   = mirror_on
	_last_hud_eq_on       = eq_on
	_last_hud_drunk_on    = drunk_on

	# Structure changed — rebuild
	for slot in _powerup_slots:
		if is_instance_valid(slot.get("ctrl")):
			slot["ctrl"].queue_free()
	_powerup_slots.clear()

	# MN-05: use preloaded textures — no runtime load() in hot path
	if main_active:
		var tex : Texture2D = null
		match main_type:
			"jetpack": tex = _TEX_POWERUP_JETPACK
			"wings":   tex = _TEX_POWERUP_WINGS
		_powerup_slots.append(_make_powerup_slot(tex, main_tmax, main_timer))

	if shield_active:
		_powerup_slots.append(_make_powerup_slot(_TEX_POWERUP_BUBBLE, shield_tmax, shield_timer))

	# MN-01: unrolled debuff loop — no Array literal allocation
	if mirror_on and mirror_t > 0.0:
		_powerup_slots.append(_make_powerup_slot(_TEX_DEBUFF_MIRROR, 5.0, mirror_t, true))
	if eq_on and eq_t > 0.0:
		_powerup_slots.append(_make_powerup_slot(_TEX_DEBUFF_EARTHQUAKE, 5.0, eq_t, true))
	if drunk_on and drunk_t > 0.0:
		_powerup_slots.append(_make_powerup_slot(_TEX_DEBUFF_DRUNK, 5.0, drunk_t, true))



# ─────────────────────────────────────────────────────
#  START UI
# ─────────────────────────────────────────────────────
func _build_start_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 10
	add_child(_ui_layer)

	_ui_root = Control.new()
	_anchored(_ui_root, Control.PRESET_FULL_RECT)
	_ui_layer.add_child(_ui_root)

	# Browser autoplay policy: ilk gerçek dokunmada BGM başlat
	# gui_input: UI elementlerine gelen dokunma/tıklamalar
	_ui_root.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventScreenTouch or ev is InputEventMouseButton:
			_start_bgm_if_needed()
	)
	# set_process_input: canvas'a (oyun alanına) gelen inputları da yakala
	# Böylece PLAY butonuna basmadan önce canvas'a dokunan da sesi açar
	set_process_input(true)

	var at := UITheme.get_theme_assets()

	# All elements invisible initially — will enter with fade+slide
	_ui_root.modulate.a = 0.0

	# ── Title ────────────────────────────────────────
	# Wrap in a CenterContainer anchored to the top strip so the label
	# is always horizontally centred regardless of viewport width.
	# The CenterContainer also ensures pivot_offset is the visual centre
	# of the label, making the idle scale-breathe animate from the middle.
	var title_anchor := Control.new()
	title_anchor.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title_anchor.offset_top    = 0
	title_anchor.offset_bottom = int(_ph(0.18))
	title_anchor.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_ui_root.add_child(title_anchor)

	var title_center := CenterContainer.new()
	title_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_anchor.add_child(title_center)

	var title_lbl := Label.new()
	title_lbl.text = "NimJump"
	UITheme.apply_label(title_lbl, Color.WHITE, int(_p(0.108)))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_center.add_child(title_lbl)

	# After one frame the label has a size; set pivot to its centre so
	# scale animations (breathe) expand/contract around the middle.
	await get_tree().create_timer(0.05).timeout
	title_lbl.pivot_offset = title_lbl.size * 0.5

	# Avatar card removed from main menu — shown only in Settings

	# ── Character selector — screen center (no panel) ────
	var nav_sz := int(_p(0.060))
	var sel_pc := HBoxContainer.new()
	sel_pc.alignment = BoxContainer.ALIGNMENT_CENTER
	sel_pc.add_theme_constant_override("separation", int(_p(0.018)))
	sel_pc.anchor_left   = 0.5; sel_pc.anchor_right  = 0.5
	sel_pc.anchor_top    = 0.5; sel_pc.anchor_bottom = 0.5
	sel_pc.offset_left   = -int(_p(0.40))
	sel_pc.offset_right  =  int(_p(0.40))
	sel_pc.offset_top    =  int(_p(0.06))
	sel_pc.offset_bottom =  int(_p(0.06)) + nav_sz
	sel_pc.grow_horizontal = Control.GROW_DIRECTION_BOTH
	sel_pc.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_ui_root.add_child(sel_pc)

	var left_btn := UITheme.make_selector_button(true, nav_sz)
	left_btn.pressed.connect(func(): _change_char(-1))
	sel_pc.add_child(left_btn)

	_char_lbl = Label.new()
	_char_lbl.text = CHAR_NAMES[_char_index]
	UITheme.apply_label(_char_lbl, Color.WHITE, int(_p(0.047)))
	_char_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	_char_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_pc.add_child(_char_lbl)

	var right_btn := UITheme.make_selector_button(false, nav_sz)
	right_btn.pressed.connect(func(): _change_char(1))
	sel_pc.add_child(right_btn)

	# ── PLAY and Settings buttons ────────────────────
	# (VS button removed from the menu per request — system kept intact)
	var btn_w       := _p(0.72)
	var play_h      := int(_p(0.105))
	var set_h       := int(_p(0.080))
	var gap         := int(_p(0.034))   # slightly bigger than the old inter-button gap so there's still visible breathing room, without the full VS-row gap

	# Centre the PLAY/Settings block in the space between the character
	# selector's bottom edge (the arrow row above) and the bottom nav bar's
	# top edge, so the gap above the block equals the gap below it —
	# instead of a fixed offset from the screen edge that left them uneven.
	var sel_bottom_abs     : float = _vh * 0.5 + sel_pc.offset_bottom
	var bottom_bar_h       : float = _vh * 0.09  # must match _build_bottom_bar()'s bar_h formula
	var bottom_bar_top_abs : float = _vh - bottom_bar_h
	# VS button removed — no longer reserving vs_h+gap of blank space here.
	var block_h            : float = play_h + gap + set_h
	var avail_h             : float = bottom_bar_top_abs - sel_bottom_abs
	var equal_margin        : float = maxf((avail_h - block_h) * 0.5, 0.0)
	var block_top_abs       : float = sel_bottom_abs + equal_margin
	var base_bottom := int(block_top_abs + block_h - _vh)

	# Settings — bottom
	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.add_theme_font_size_override("font_size", int(_p(0.055)))
	settings_btn.custom_minimum_size = Vector2(btn_w, set_h)
	settings_btn.anchor_left   = 0.5; settings_btn.anchor_right  = 0.5
	settings_btn.anchor_top    = 1.0; settings_btn.anchor_bottom = 1.0
	settings_btn.offset_left   = -btn_w * 0.5
	settings_btn.offset_right  =  btn_w * 0.5
	settings_btn.offset_bottom = base_bottom
	settings_btn.offset_top    = base_bottom - set_h
	settings_btn.pressed.connect(_open_settings)
	UITheme.apply_ghost_button(settings_btn)
	_ui_root.add_child(settings_btn)

	# VS button removed from the main menu per request — the whole VS system
	# (VSManager, VSPanel, _open_vs_panel/_build_vs_panel/_start_vs_game, deep
	# links via _open_vs_room, etc.) stays fully intact, there's just no
	# button here to open it anymore.

	# PLAY — above Settings
	_play_btn = Button.new()
	_play_btn.disabled = false
	_play_btn.text = "PLAY"
	_play_btn.add_theme_font_size_override("font_size", int(_p(0.080)))
	_play_btn.custom_minimum_size = Vector2(btn_w, play_h)
	_play_btn.anchor_left   = 0.5; _play_btn.anchor_right  = 0.5
	_play_btn.anchor_top    = 1.0; _play_btn.anchor_bottom = 1.0
	_play_btn.offset_left   = -btn_w * 0.5
	_play_btn.offset_right  =  btn_w * 0.5
	_play_btn.offset_bottom = base_bottom - set_h - gap
	_play_btn.offset_top    = base_bottom - set_h - gap - play_h
	_play_btn.pressed.connect(_on_play_pressed)
	UITheme.apply_play_button(_play_btn)
	_ui_root.add_child(_play_btn)


	# Error/connection banners now go through the global Toast singleton
	# (see Toast.gd) — call Toast.show_banner("...") wherever needed.



	# ── Entrance animation — fade in + title from top, buttons from bottom ──
	var intro := create_tween()
	if intro:
		intro.set_parallel(true)
		# Overall fade in
		intro.tween_property(_ui_root, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		# Title slides down from above — animate the anchor container
		var t_orig_top    := title_anchor.offset_top
		var t_orig_bottom := title_anchor.offset_bottom
		title_anchor.offset_top    -= int(_p(0.06))
		title_anchor.offset_bottom -= int(_p(0.06))
		intro.tween_property(title_anchor, "offset_top",    t_orig_top,    0.40).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		intro.tween_property(title_anchor, "offset_bottom", t_orig_bottom, 0.40).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		# Character selector slides in from the left
		sel_pc.offset_left  -= int(_p(0.08))
		sel_pc.offset_right -= int(_p(0.08))
		intro.tween_property(sel_pc, "offset_left",  -int(_p(0.40)), 0.38).set_delay(0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		intro.tween_property(sel_pc, "offset_right",  int(_p(0.40)), 0.38).set_delay(0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		# Buttons come up from below
		_play_btn.offset_top    += int(_p(0.06))
		_play_btn.offset_bottom += int(_p(0.06))
		var _base := base_bottom  # same equal-margin position computed above, not a fixed screen offset
		var _set_h2 := int(_p(0.080))
		var _play_h2 := int(_p(0.105))
		var _gap2 := int(_p(0.034))   # must match `gap` above
		intro.tween_property(settings_btn, "offset_top",    _base - _set_h2,              0.36).set_delay(0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		intro.tween_property(settings_btn, "offset_bottom", _base,                         0.36).set_delay(0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		intro.tween_property(_play_btn, "offset_top",    _base - _set_h2 - _gap2 - _play_h2, 0.38).set_delay(0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		intro.tween_property(_play_btn, "offset_bottom", _base - _set_h2 - _gap2,            0.38).set_delay(0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# ── Idle animations (start after intro) ──────────────────
	await get_tree().create_timer(0.25).timeout

	# Title breathes — scale on label with pivot at centre
	# pivot_offset was set above after the first process frame
	var title_tw := create_tween()
	if title_tw:
		title_tw.set_loops()
		title_tw.tween_property(title_lbl, "scale", Vector2(1.05, 1.05), 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		title_tw.tween_property(title_lbl, "scale", Vector2(0.95, 0.95), 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Keep pivot centred if window resizes
	title_lbl.resized.connect(func(): title_lbl.pivot_offset = title_lbl.size * 0.5)

	# PLAY button glows
	var play_tw := create_tween()
	if play_tw:
		play_tw.set_loops()
		play_tw.tween_property(_play_btn, "modulate", Color(1.0, 1.0, 0.75, 1.0), 0.55).set_trans(Tween.TRANS_SINE)
		play_tw.tween_property(_play_btn, "modulate", Color(1.0, 1.0, 1.0,  1.0), 0.55).set_trans(Tween.TRANS_SINE)

	# Character selector bobs up and down slightly
	var sel_tw := create_tween()
	if sel_tw:
		sel_tw.set_loops()
		sel_tw.tween_property(sel_pc, "offset_top",    sel_pc.offset_top    - int(_p(0.012)), 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		sel_tw.tween_property(sel_pc, "offset_bottom", sel_pc.offset_bottom - int(_p(0.012)), 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		sel_tw.tween_property(sel_pc, "offset_top",    sel_pc.offset_top,                     0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		sel_tw.tween_property(sel_pc, "offset_bottom", sel_pc.offset_bottom,                  0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	_build_settings_popup()
	_build_bottom_bar()
	_build_quest_panel()
	_check_vsroom_deeplink()


# ─────────────────────────────────────────────────────
#  BOTTOM NAVIGATION BAR
# ─────────────────────────────────────────────────────

var _bottom_bar        : Control
var _quest_panel       : CanvasLayer
var _leaderboard_panel : CanvasLayer
var _stats_panel       : CanvasLayer
var _active_tab        : String = ""
var _tab_btns          : Dictionary = {}

func _build_bottom_bar() -> void:
	var bar_h := int(_vh * 0.09)

	_bottom_bar = PanelContainer.new()
	# Warm bej bottom bar — NinePatch yerine StyleBoxFlat
	var bb_st := StyleBoxFlat.new()
	bb_st.bg_color                   = Color(0.957, 0.898, 0.800)
	bb_st.border_color               = Color(0.700, 0.520, 0.340)
	bb_st.border_width_top           = 2
	bb_st.corner_radius_top_left     = int(_vh * 0.018)
	bb_st.corner_radius_top_right    = int(_vh * 0.018)
	bb_st.corner_radius_bottom_left  = 0
	bb_st.corner_radius_bottom_right = 0
	_bottom_bar.add_theme_stylebox_override("panel", bb_st)
	_bottom_bar.set_anchor_and_offset(SIDE_LEFT,   0, 0)
	_bottom_bar.set_anchor_and_offset(SIDE_RIGHT,  1, 0)
	_bottom_bar.set_anchor_and_offset(SIDE_BOTTOM, 1, 0)
	_bottom_bar.set_anchor_and_offset(SIDE_TOP,    1, -bar_h)
	_bottom_bar.z_index = 20
	_ui_root.add_child(_bottom_bar)

	var row := HBoxContainer.new()
	row.alignment             = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 0)
	_bottom_bar.add_child(row)

	var tabs := [
		{"id": "quests",      "lucide": "zap",        "label": "Quests"},
		{"id": "stats",       "lucide": "bar-chart-2", "label": "Statistics"},
		{"id": "leaderboard", "lucide": "trophy",      "label": "Leaderboard"},
	]
	for t in tabs:
		var btn := _make_tab_button(t.lucide, t.label, t.id)
		_tab_btns[t.id] = btn
		row.add_child(btn)


func _make_tab_button(lucide_name: String, label: String, tab_id: String) -> Button:
	# Return button directly (for dict compatibility),
	# but use CenterContainer for visual content.
	var ic_size := int(_vh * 0.034)
	var fs      := int(_vh * 0.016)

	var btn := Button.new()
	btn.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	btn.text                   = ""
	btn.flat                   = true
	btn.clip_contents          = false
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Warm hover / pressed — saydam arka plan, köşesiz
	var bb_hover := StyleBoxFlat.new()
	bb_hover.bg_color = Color(0.700, 0.520, 0.340, 0.18)
	var bb_pressed := StyleBoxFlat.new()
	bb_pressed.bg_color = Color(0.700, 0.520, 0.340, 0.30)
	var bb_normal := StyleBoxEmpty.new()
	btn.add_theme_stylebox_override("normal",  bb_normal)
	btn.add_theme_stylebox_override("hover",   bb_hover)
	btn.add_theme_stylebox_override("pressed", bb_pressed)
	btn.add_theme_stylebox_override("focus",   bb_normal)

	# CenterContainer: takes Button's size, centers content.
	# mouse_filter=IGNORE → clicks pass through to Button.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment            = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	vbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", int(_vh * 0.004))
	center.add_child(vbox)

	# Başlangıç rengi pasif (orta kahve) — _set_active_tab ile güncellenir
	var ic := UITheme.lucide_icon(lucide_name, ic_size, Color(0.480, 0.340, 0.200))
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(ic)
	btn.set_meta("lucide_icon", ic)

	var lbl := Label.new()
	lbl.text                 = label
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	UITheme.apply_label(lbl, Color(0.480, 0.340, 0.200), fs)
	vbox.add_child(lbl)
	btn.set_meta("lucide_label", lbl)

	btn.pressed.connect(func(): _on_tab_pressed(tab_id))
	return btn


func _set_tab_color(tab_id: String, active_id: String) -> void:
	var btn : Button = _tab_btns[tab_id]
	var col := Color(0.780, 0.380, 0.120) if tab_id == active_id else Color(0.480, 0.340, 0.200)
	if btn.has_meta("lucide_icon"):
		var ic : TextureRect = btn.get_meta("lucide_icon")
		if is_instance_valid(ic): ic.modulate = col
	if btn.has_meta("lucide_label"):
		var lbl : Label = btn.get_meta("lucide_label")
		if is_instance_valid(lbl): lbl.add_theme_color_override("font_color", col)


func _set_active_tab(tab_id: String) -> void:
	_active_tab = tab_id
	for tid in _tab_btns:
		_set_tab_color(tid, tab_id)


func _deactivate_tab() -> void:
	_active_tab = ""
	for tid in _tab_btns:
		_set_tab_color(tid, "")


func _hide_other_panels(keep: String) -> void:
	# Only close inactive panels — don't touch the one being opened
	if keep != "quests"      and is_instance_valid(_quest_panel):      _quest_panel.hide_panel()
	if keep != "leaderboard" and is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
	if keep != "stats"       and is_instance_valid(_stats_panel):      _stats_panel.hide_panel()


func _on_tab_pressed(tab_id: String) -> void:
	# Pressing the same tab again closes it
	if _active_tab == tab_id:
		match tab_id:
			"quests":      if is_instance_valid(_quest_panel):      _quest_panel.hide_panel()
			"leaderboard": if is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
			"stats":       if is_instance_valid(_stats_panel):      _stats_panel.hide_panel()
		_deactivate_tab()
		return

	# Close other panels, open this one
	_hide_other_panels(tab_id)
	_set_active_tab(tab_id)
	match tab_id:
		"quests":
			if is_instance_valid(_quest_panel):      _quest_panel.show_panel()
		"leaderboard":
			if is_instance_valid(_leaderboard_panel): _leaderboard_panel.show_panel()
		"stats":
			if is_instance_valid(_stats_panel):      _stats_panel.show_panel()


## Invite link support — "?vsroom=<id>" in the URL (see backend vsRoomInviteURL).
## Someone who clicks a shared VS link lands here, gets the VS panel opened
## straight to that room's detail/join view instead of the empty room list.
func _check_vsroom_deeplink() -> void:
	if not OS.has_feature("web"): return
	var url_raw = JavaScriptBridge.eval("window.location.search", true)
	if url_raw == null: return
	var url_str := str(url_raw)
	var idx := url_str.find("vsroom=")
	if idx < 0: return
	var room_id := url_str.substr(idx + 7).split("&")[0]
	if room_id == "": return
	_open_vs_panel()
	if is_instance_valid(_vs_panel) and _vs_panel.has_method("open_room"):
		_vs_panel.call("open_room", room_id)


## VS Rooms — async 1v1 challenge panel, opened from the main-menu VS button.
func _open_vs_panel() -> void:
	_start_bgm_if_needed()
	if _started: return
	if not is_instance_valid(_vs_panel):
		_build_vs_panel()
	_vs_panel.call("show_panel")


func _build_vs_panel() -> void:
	_vs_panel = CanvasLayer.new()
	_vs_panel.set_script(load("res://scripts/VSPanel.gd"))
	_vs_panel.layer = 16   # above quest/stats/leaderboard (15)
	add_child(_vs_panel)
	var pid := nimiq_address if nimiq_address != "" else nimiq_device_id
	_vs_panel.call("setup", pid)
	_vs_panel.connect("play_requested", _start_vs_round)
	_vs_panel.connect("replay_requested", func(seed: int, log: PackedByteArray, char_idx: int, nick: String, player_seed: int):
		if _started: return
		_block_lb_replay = false
		await _start_replay(seed, log, char_idx, "vs", player_seed)
	)
	_sync_panels()


## Called by VSPanel when the player presses "Play" on their side of a room.
## seed_str: the room's fixed seed (decimal string, int64-safe) — BOTH sides
## of a VS match play this exact same seed, never a locally-random one.
func _start_vs_round(room_id: String, role: String, seed_str: String) -> void:
	if _started: return

	if _auth_token == "":
		print("[VS] play pressed — not signed in, requesting auth")
		if is_instance_valid(_nimiq_bridge) and not _nimiq_bridge.auth_verified:
			_nimiq_bridge._do_sign_auth()
		var _conn_s := _nimiq_bridge.connect("auth_success", func(_t, _p):
			_start_vs_round(room_id, role, seed_str)
		, CONNECT_ONE_SHOT)
		return

	_started = true
	_block_lb_replay = true
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
	if is_instance_valid(_stats_panel):       _stats_panel.hide_panel()
	if is_instance_valid(_quest_panel):       _quest_panel.hide_panel()
	if is_instance_valid(_vs_panel):          _vs_panel.hide_panel()

	if is_instance_valid(_gm):
		_gm.set("vs_room_id", room_id)
		_gm.set("vs_role",    role)

	var seed_val : int = int(seed_str)
	_do_start_game(seed_val)


func _build_quest_panel() -> void:
	_quest_panel = CanvasLayer.new()
	_quest_panel.set_script(load("res://scripts/QuestPanel.gd"))
	_quest_panel.layer = 15
	add_child(_quest_panel)
	var pid := nimiq_address if nimiq_address != "" else nimiq_device_id
	_quest_panel.call("setup", pid)
	# token _sync_panels() ile gelecek
	# closed: panel X or outside click — just reset tab color
	_quest_panel.connect("closed", func(): _deactivate_tab())

	_leaderboard_panel = CanvasLayer.new()
	_leaderboard_panel.set_script(load("res://scripts/LeaderboardPanel.gd"))
	_leaderboard_panel.layer = 15
	add_child(_leaderboard_panel)
	_leaderboard_panel.call("setup")
	_leaderboard_panel.connect("closed", func(): _deactivate_tab())
	_leaderboard_panel.connect("replay_requested", _on_leaderboard_replay_requested)
	# LeaderboardPanel handles wallet connection internally via NimiqJS.request_account

	# Stats panel — reads from localStorage
	_stats_panel = CanvasLayer.new()
	_stats_panel.set_script(load("res://scripts/StatsPanel.gd"))
	_stats_panel.layer = 15
	add_child(_stats_panel)
	_stats_panel.call("setup", _gm)
	# token _sync_panels() ile gelecek
	_stats_panel.connect("closed", func(): _deactivate_tab())
	_stats_panel.connect("replay_requested", func(seed: int, log: PackedByteArray, char_idx: int, nick: String, player_seed: int):
		if _started: return
		_block_lb_replay = false
		await _start_replay(seed, log, char_idx, "stats", player_seed)
	)
	_stats_panel.connect("connect_requested", func():
		if not is_instance_valid(_nimiq_bridge): return
		if _nimiq_bridge.nimiq_address != "":
			_nimiq_bridge._do_sign_auth()
		else:
			_nimiq_bridge._poll_started = false
			_nimiq_bridge._poll()
	)

	# Panels created — feed current auth state to all of them
	_sync_panels()


# ─────────────────────────────────────────────────────
#  SETTINGS POPUP
# ─────────────────────────────────────────────────────
## Warm bej buton stilleyici — settings + account popup paylaşır
func _warm_btn_st(btn: Button, ghost: bool = false) -> void:
	var ri := 8
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s: StyleBoxFlat in [sn, sh, sp]:
		s.set_corner_radius_all(ri)
	if ghost:
		sn.bg_color = Color(0,0,0,0); sn.border_color = Color(0.780,0.380,0.120); sn.set_border_width_all(2)
		sh.bg_color = Color(0.780,0.380,0.120,0.18); sh.border_color = Color(0.820,0.450,0.160); sh.set_border_width_all(2)
		sp.bg_color = Color(0.780,0.380,0.120,0.32); sp.border_color = Color(0.640,0.300,0.080); sp.set_border_width_all(2)
		btn.add_theme_color_override("font_color",         Color(0.780,0.380,0.120))
		btn.add_theme_color_override("font_hover_color",   Color(0.820,0.450,0.160))
		btn.add_theme_color_override("font_pressed_color", Color(0.640,0.300,0.080))
	else:
		sn.bg_color = Color(0.780,0.380,0.120)
		sh.bg_color = Color(0.820,0.450,0.160)
		sp.bg_color = Color(0.640,0.300,0.080)
		btn.add_theme_color_override("font_color",         Color(0.957,0.898,0.800))
		btn.add_theme_color_override("font_hover_color",   Color(1.0,1.0,1.0))
		btn.add_theme_color_override("font_pressed_color", Color(0.957,0.898,0.800))
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)


func _build_settings_popup() -> void:
	_settings_popup = Control.new()
	_anchored(_settings_popup, Control.PRESET_FULL_RECT)
	_settings_popup.visible = false
	_settings_popup.z_index = 20
	_ui_root.add_child(_settings_popup)

	# Warm bej palette — QuestPanel/StatsPanel ile aynı
	const S_BG     := Color(0.957, 0.898, 0.800)
	const S_CARD   := Color(0.910, 0.850, 0.750)
	const S_BORDER := Color(0.580, 0.380, 0.220)
	const S_BROWN  := Color(0.220, 0.130, 0.060)
	const S_MID    := Color(0.480, 0.340, 0.200)
	const S_SEP    := Color(0.580, 0.380, 0.220, 0.4)

	# Warm bej buton helper — settings içinde kullan

	# Kart stili helper
	var _card_st := func() -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color     = S_CARD
		s.border_color = S_BORDER
		s.set_border_width_all(2)
		s.set_corner_radius_all(10)
		return s

	# Dimmer
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_anchored(dim, Control.PRESET_FULL_RECT)
	_settings_popup.add_child(dim)

	var at  := UITheme.get_theme_assets()
	var M2  := int(_p(0.020))
	var pad := int(_p(0.025))
	var ic  := int(_p(0.022))   # ikonlar küçük (%50 küçüldü)
	var fs  := int(_p(0.044))
	var sep := int(_p(0.014))
	const ICON_ORANGE := Color(0.780, 0.380, 0.120)  # oyunun asıl turuncusu

	# ── Main popup: above bottom bar, upper part of screen ──
	var bar_h  := _vh * 0.09
	var margin := _vh * 0.02
	var pw     := _p(0.88)
	var ph     := minf(_vh * 0.74, _vh - bar_h - margin * 2.0)
	var center_y := (_vh - bar_h) * 0.5

	var pc := PanelContainer.new()
	pc.anchor_left   = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top    = 0.0; pc.anchor_bottom = 0.0
	pc.offset_left   = -pw * 0.5; pc.offset_right  = pw * 0.5
	pc.offset_top    = center_y - ph * 0.5
	pc.offset_bottom = center_y + ph * 0.5
	var pc_st := StyleBoxFlat.new()
	pc_st.bg_color     = S_BG
	pc_st.border_color = S_BORDER
	pc_st.set_border_width_all(3)
	pc_st.set_corner_radius_all(14)
	pc_st.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	pc_st.shadow_size  = 10
	pc.add_theme_stylebox_override("panel", pc_st)
	_settings_popup.add_child(pc)


	# VBoxContainer directly inside PanelContainer — auto-sized
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	pc.add_child(outer)

	# ── Header row ─────────────────────────────────
	var hdr_mc := _make_margin_container(pad)
	outer.add_child(hdr_mc)

	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr_mc.add_child(hdr)

	var title_lbl := Label.new()
	title_lbl.text = "SETTINGS"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title_lbl, S_BROWN, int(_p(0.058)))
	hdr.add_child(title_lbl)

	# TOUCH-FIX: tap target was only ~0.048*_p — too small on phones.
	# Visual icon size unchanged; button (tappable area) grows, icon stays
	# centered at its original size via CenterContainer.
	var close_sz := int(_p(0.092))
	var close_ic_sz := int(close_sz * 0.72)  # icon now fills the bigger button instead of floating tiny inside it
	var close_btn := Button.new()
	close_btn.custom_minimum_size = Vector2(close_sz, close_sz)
	close_btn.pressed.connect(_close_settings)
	_warm_btn_st(close_btn)
	var close_center2 := CenterContainer.new()
	close_center2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_center2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_btn.add_child(close_center2)
	var close_ic2 := TextureRect.new()
	close_ic2.texture = load("res://assets/hud/hudX.png")
	close_ic2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_ic2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_ic2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_ic2.custom_minimum_size = Vector2(close_ic_sz, close_ic_sz)
	close_center2.add_child(close_ic2)
	hdr.add_child(close_btn)

	# ── Scroll content ─────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone        = 4
	scroll.follow_focus           = false
	scroll.mouse_filter           = Control.MOUSE_FILTER_STOP
	outer.add_child(scroll)

	var content_mc := _make_margin_container(pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", sep)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_mc.add_child(vbox)

	# ── Sound — master + per-sound (BGM / Jump / Damage) ──
	var snd_on_path : String = at.get("icon_sound_on", "")
	var snd_pc := PanelContainer.new()
	snd_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snd_pc.add_theme_stylebox_override("panel", _card_st.call())
	vbox.add_child(snd_pc)

	var snd_mc := _make_margin_container(pad)
	snd_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snd_pc.add_child(snd_mc)

	var snd_vbox := VBoxContainer.new()
	snd_vbox.add_theme_constant_override("separation", int(_p(0.010)))
	snd_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snd_mc.add_child(snd_vbox)

	# Master sound header row
	var snd_hdr_row := HBoxContainer.new()
	snd_hdr_row.add_theme_constant_override("separation", int(_p(0.016)))
	snd_vbox.add_child(snd_hdr_row)

	var snd_ic := TextureRect.new()
	snd_ic.custom_minimum_size = Vector2(ic, ic)
	snd_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	snd_ic.modulate = ICON_ORANGE
	# icon: muted veya vol=0 → volume-x, vol<0.5 → volume-1, vol>=0.5 → volume-2
	var at2s := UITheme.get_theme_assets()
	var _snd_icon_key := func(vol: float, muted: bool) -> String:
		if muted or vol <= 0.0: return "icon_sound_off"
		if vol < 0.5:           return "icon_sound_mid"   # volume-1 (yoksa volume-2 fallback)
		return "icon_sound_on"
	var _snd_icon_tex := func(vol: float, muted: bool) -> Texture2D:
		var key : String = _snd_icon_key.call(vol, muted)
		var p1 : String = at2s.get(key, "")
		if ResourceLoader.exists(p1): return load(p1)
		# fallback: mid → on, diğerleri direkt
		var fallback : String = "icon_sound_on" if key == "icon_sound_mid" else key
		var p2 : String = at2s.get(fallback, "")
		if ResourceLoader.exists(p2): return load(p2)
		return null
	var _init_tex : Texture2D = _snd_icon_tex.call(_volume, _muted)
	if _init_tex: snd_ic.texture = _init_tex
	snd_hdr_row.add_child(snd_ic)
	_sound_icon = snd_ic

	var snd_hdr_lbl := Label.new()
	snd_hdr_lbl.text = "Sound"
	snd_hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snd_hdr_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	UITheme.apply_label(snd_hdr_lbl, S_BROWN, fs)
	snd_hdr_row.add_child(snd_hdr_lbl)

	_sound_toggle = CheckButton.new()
	UITheme.apply_toggle_button(_sound_toggle)
	_sound_toggle.button_pressed = not _muted
	_sound_toggle.toggled.connect(func(p: bool):
		_on_sound_toggled(p)
		_save_settings()
		if is_instance_valid(snd_ic):
			var t : Texture2D = _snd_icon_tex.call(_volume, not p)
			if t: snd_ic.texture = t
			snd_ic.modulate = ICON_ORANGE
	)
	snd_hdr_row.add_child(_sound_toggle)

	# Master volume slider
	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0.0; _volume_slider.max_value = 1.0
	_volume_slider.step = 0.01;     _volume_slider.value = _volume
	_volume_slider.custom_minimum_size   = Vector2(0, int(_p(0.044)))
	_volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume_slider.editable = not _muted
	UITheme.apply_slider(_volume_slider)
	_volume_slider.value_changed.connect(_on_volume_changed)
	_volume_slider.value_changed.connect(func(val: float):
		if is_instance_valid(snd_ic):
			var t : Texture2D = _snd_icon_tex.call(val, _muted)
			if t: snd_ic.texture = t
	)
	snd_vbox.add_child(_volume_slider)

	# per-sound slider listesi — master toggle off yapınca hepsini dim et
	var _per_sliders : Array[HSlider] = []

	# Helper: build a per-sound row (icon | label | toggle | volume slider)
	# icon_key: "icon_sound_on" için volume seviyesine göre volume-2/volume-x seçer,
	#           "icon_music" için music ikonu sabit kalır.
	var _make_sound_row := func(label: String, enabled: bool, volume: float,
			on_toggle: Callable, on_volume: Callable, icon_key: String = "icon_sound_on") -> HSlider:
		var row_vbox := VBoxContainer.new()
		row_vbox.add_theme_constant_override("separation", int(_p(0.004)))
		row_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		snd_vbox.add_child(row_vbox)

		var sep2 := HSeparator.new()
		row_vbox.add_child(sep2)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(_p(0.012)))
		row_vbox.add_child(row)

		var at2 := UITheme.get_theme_assets()
		# volume seviyesine göre dinamik ikon seç (müzik satırı hariç sabit)
		var _row_icon_path := func(is_on: bool, vol: float) -> String:
			if icon_key == "icon_music":
				return at2.get("icon_music", "")
			if not is_on or vol <= 0.0: return at2.get("icon_sound_off", "")
			if vol < 0.5:
				var mid : String = at2.get("icon_sound_mid", "")
				if ResourceLoader.exists(mid): return mid
			return at2.get("icon_sound_on", "")

		var row_ic : TextureRect = null
		var ic_path : String = _row_icon_path.call(enabled, volume)
		if ResourceLoader.exists(ic_path):
			row_ic = TextureRect.new()
			row_ic.texture = load(ic_path)
			row_ic.custom_minimum_size = Vector2(ic, ic)
			row_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row_ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row_ic.modulate = ICON_ORANGE
			row.add_child(row_ic)

		var lbl := Label.new()
		lbl.text = label
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
		UITheme.apply_label(lbl, S_BROWN, int(_p(0.034)))
		row.add_child(lbl)

		var toggle := CheckButton.new()
		UITheme.apply_toggle_button(toggle)
		toggle.button_pressed = enabled
		toggle.toggled.connect(on_toggle)
		row.add_child(toggle)

		var slider := HSlider.new()
		slider.min_value = 0.0; slider.max_value = 1.0
		slider.step = 0.01;     slider.value = volume
		slider.custom_minimum_size   = Vector2(0, int(_p(0.014)))
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.editable = enabled and not _muted
		slider.modulate.a = 1.0 if (enabled and not _muted) else 0.4
		UITheme.apply_slider(slider)
		slider.value_changed.connect(on_volume)
		# slider değişince icon güncelle (volume-1/2/x)
		slider.value_changed.connect(func(val: float):
			if is_instance_valid(row_ic):
				var np : String = _row_icon_path.call(toggle.button_pressed, val)
				if ResourceLoader.exists(np):
					row_ic.texture  = load(np)
					row_ic.modulate = ICON_ORANGE
		)
		# per-toggle: icon güncelle + dim
		toggle.toggled.connect(func(p: bool):
			var active := p and not _muted
			slider.editable   = active
			slider.modulate.a = 1.0 if active else 0.4
			if is_instance_valid(row_ic):
				var np : String = _row_icon_path.call(p, slider.value)
				if ResourceLoader.exists(np):
					row_ic.texture  = load(np)
					row_ic.modulate = ICON_ORANGE
		)
		row_vbox.add_child(slider)
		return slider

	# ── Music başlığı ──
	var music_hdr := Label.new()
	music_hdr.text = "Music"
	UITheme.apply_label(music_hdr, S_MID, int(_p(0.026)))
	snd_vbox.add_child(music_hdr)

	_per_sliders.append(_make_sound_row.call("Background Music", _bgm_enabled, _bgm_volume,
		func(p: bool):
			_bgm_enabled = p
			_apply_audio_settings()
			_save_settings()
			if OS.has_feature("web"):
				if p and not _muted:
					_bgm_started = false
					_start_bgm_if_needed()
				elif not p:
					JavaScriptBridge.eval("if(window._gdSound) window._gdSound('bgm_stop');", true)
					_bgm_started = false,
		func(v: float):
			_bgm_volume = v
			_apply_audio_settings()
			_save_settings(),
		"icon_music"
	) as HSlider)

	# ── Effects başlığı ──
	var fx_sep := HSeparator.new()
	snd_vbox.add_child(fx_sep)
	var fx_hdr := Label.new()
	fx_hdr.text = "Effects"
	UITheme.apply_label(fx_hdr, S_MID, int(_p(0.026)))
	snd_vbox.add_child(fx_hdr)

	_per_sliders.append(_make_sound_row.call("Jump", _jump_enabled, _jump_volume,
		func(p: bool): _jump_enabled = p; _apply_audio_settings(); _save_settings(),
		func(v: float): _jump_volume = v; _apply_audio_settings(); _save_settings(),
		"icon_sound_on"
	) as HSlider)
	_per_sliders.append(_make_sound_row.call("Damage", _damage_enabled, _damage_volume,
		func(p: bool): _damage_enabled = p; _apply_audio_settings(); _save_settings(),
		func(v: float): _damage_volume = v; _apply_audio_settings(); _save_settings(),
		"icon_sound_on"
	) as HSlider)

	# Master toggle — per-sound slider'ları da dim et / aktif et
	_sound_toggle.toggled.connect(func(p: bool):
		for s : HSlider in _per_sliders:
			if is_instance_valid(s):
				s.editable  = p
				s.modulate.a = 1.0 if p else 0.4
	)

	# ── Vibration ──────────────────────────────────
	var vib_pc := PanelContainer.new()
	vib_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vib_pc.add_theme_stylebox_override("panel", _card_st.call())
	vbox.add_child(vib_pc)

	var vib_mc := _make_margin_container(pad)
	vib_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vib_pc.add_child(vib_mc)

	var vib_row := HBoxContainer.new()
	vib_row.add_theme_constant_override("separation", int(_p(0.016)))
	vib_mc.add_child(vib_row)

	var vib_ic := TextureRect.new()
	vib_ic.custom_minimum_size = Vector2(ic, ic)
	vib_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var tick_path : String = at.get("icon_tick", "")
	if ResourceLoader.exists(tick_path):
		vib_ic.texture = load(tick_path)
	vib_row.add_child(vib_ic)

	var vib_lbl := Label.new()
	vib_lbl.text = "Vibration"
	vib_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vib_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	UITheme.apply_label(vib_lbl, S_BROWN, fs)
	vib_row.add_child(vib_lbl)

	var vib_toggle := CheckButton.new()
	UITheme.apply_toggle_button(vib_toggle)
	vib_toggle.button_pressed = _vibration
	vib_toggle.toggled.connect(func(p: bool): _vibration = p; _save_settings())
	vib_row.add_child(vib_toggle)

	# iOS: Safari/WKWebView has no Vibration API and never will — show the
	# toggle (so the setting isn't mysteriously missing) but lock it off
	# instead of letting the player turn on something that can't ever work.
	if _is_ios:
		vib_toggle.button_pressed = false
		vib_toggle.disabled       = true
		vib_toggle.modulate.a     = 0.45
		vib_lbl.modulate.a        = 0.45
		vib_lbl.text              = "Vibration (unavailable on iOS)"

	_control_mode = "tap"

	# ── Background Selection ───────────────────────
	var bg_pc := PanelContainer.new()
	bg_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_pc.add_theme_stylebox_override("panel", _card_st.call())
	vbox.add_child(bg_pc)

	var bg_mc := _make_margin_container(pad)
	bg_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_pc.add_child(bg_mc)

	var bg_vbox := VBoxContainer.new()
	bg_vbox.add_theme_constant_override("separation", int(_p(0.010)))
	bg_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_mc.add_child(bg_vbox)

	# Header row: "Background" + Auto toggle
	var bg_hdr_row := HBoxContainer.new()
	bg_hdr_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_vbox.add_child(bg_hdr_row)

	var bg_title := Label.new()
	bg_title.text = "Background"
	bg_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(bg_title, S_BROWN, fs)
	bg_hdr_row.add_child(bg_title)

	# Auto toggle label
	var auto_lbl := Label.new()
	auto_lbl.text = "Auto"
	UITheme.apply_label(auto_lbl, S_MID, int(_p(0.026)))
	auto_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bg_hdr_row.add_child(auto_lbl)

	var auto_toggle := CheckButton.new()
	auto_toggle.button_pressed = _bg_auto
	UITheme.apply_toggle_button(auto_toggle, int(_p(0.052)))
	bg_hdr_row.add_child(auto_toggle)

	# Auto açıkken gösterilecek info
	var auto_info := Label.new()
	auto_info.text = "Changes automatically based on biome"
	auto_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(auto_info, S_MID, int(_p(0.022)))
	auto_info.visible = _bg_auto
	bg_vbox.add_child(auto_info)

	# Row showing selected background name: ◄  Forest  ►
	var bg_nav := HBoxContainer.new()
	bg_nav.alignment = BoxContainer.ALIGNMENT_CENTER
	bg_nav.add_theme_constant_override("separation", int(_p(0.018)))
	bg_nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_nav.modulate.a = 0.4 if _bg_auto else 1.0
	bg_vbox.add_child(bg_nav)

	var nav_sz := int(_p(0.060))

	var bg_left_btn := UITheme.make_selector_button(true, nav_sz)
	bg_nav.add_child(bg_left_btn)

	var bg_name_lbl := Label.new()
	bg_name_lbl.text = UITheme.BACKGROUNDS[_bg_selected]["name"]
	bg_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bg_name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(bg_name_lbl, S_BROWN, int(_p(0.040)))
	bg_nav.add_child(bg_name_lbl)

	var bg_right_btn := UITheme.make_selector_button(false, nav_sz)
	bg_nav.add_child(bg_right_btn)

	# Preview thumbnail
	var bg_preview := TextureRect.new()
	bg_preview.custom_minimum_size = Vector2(0, int(_p(0.18)))
	bg_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg_preview.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	bg_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_preview.texture = UITheme.get_background_texture(_bg_selected)
	bg_preview.modulate.a = 0.4 if _bg_auto else 1.0
	bg_vbox.add_child(bg_preview)

	# Auto toggle callback
	auto_toggle.toggled.connect(func(on: bool):
		_bg_auto = on
		auto_info.visible = on
		bg_nav.modulate.a     = 0.4 if on else 1.0
		bg_preview.modulate.a = 0.4 if on else 1.0
		bg_left_btn.disabled  = on
		bg_right_btn.disabled = on
		if not on:
			apply_selected_background()
		_save_settings()
	)
	bg_left_btn.disabled  = _bg_auto
	bg_right_btn.disabled = _bg_auto

	# Button callbacks
	var _change_bg := func(dir: int):
		_bg_selected = (_bg_selected + dir + UITheme.BACKGROUNDS.size()) % UITheme.BACKGROUNDS.size()
		bg_name_lbl.text = UITheme.BACKGROUNDS[_bg_selected]["name"]
		bg_preview.texture = UITheme.get_background_texture(_bg_selected)
		apply_selected_background()
		_save_settings()
	bg_left_btn.pressed.connect(func(): _change_bg.call(-1))
	bg_right_btn.pressed.connect(func(): _change_bg.call(1))

	# ── Nimiq Account ──────────────────────────────
	var acc_pc := PanelContainer.new()
	acc_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	acc_pc.add_theme_stylebox_override("panel", _card_st.call())
	vbox.add_child(acc_pc)

	var acc_mc := _make_margin_container(pad)
	acc_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	acc_pc.add_child(acc_mc)

	var acc_vbox := VBoxContainer.new()
	acc_vbox.add_theme_constant_override("separation", int(_p(0.010)))
	acc_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	acc_mc.add_child(acc_vbox)

	# Header row
	var acc_hdr := HBoxContainer.new()
	acc_hdr.add_theme_constant_override("separation", int(_p(0.012)))
	acc_vbox.add_child(acc_hdr)
	acc_hdr.add_child(UITheme.lucide_icon("wallet", ic, Color(0.780, 0.380, 0.120)))
	var acc_title := Label.new()
	acc_title.text = "Nimiq Account"
	acc_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	acc_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.apply_label(acc_title, S_BROWN, fs)
	acc_hdr.add_child(acc_title)

	# _sync_panels() garantili olarak bridge'den local'e sync etti — sadece local'i oku
	var _bridge_pid : String = _nimiq_bridge.auth_player_id if is_instance_valid(_nimiq_bridge) else nimiq_address
	var is_connected := nimiq_address != "" or _auth_token != "" or _bridge_pid != ""

	if is_connected:
		# Avatar + info row
		var av_row := HBoxContainer.new()
		av_row.add_theme_constant_override("separation", int(_p(0.014)))
		acc_vbox.add_child(av_row)

		# Avatar: texture fetched from identicons JS
		var av_size := int(_p(0.11))
		var av_img := TextureRect.new()
		var _addr_for_av : String = nimiq_address if nimiq_address != "" else _bridge_pid
		av_img.texture = _avatar_tex if _avatar_tex != null else _make_fallback_avatar(_addr_for_av, av_size)
		av_img.custom_minimum_size = Vector2(av_size, av_size)
		av_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		av_img.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		av_row.add_child(av_img)

		# Info column: label + full address
		var info_col := VBoxContainer.new()
		info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_col.add_theme_constant_override("separation", int(_p(0.004)))
		av_row.add_child(info_col)

		# Name + Edit button on one row — the separate "Display Name" section
		# further down was redundant (this label already shows the live
		# nickname/address, and updates the instant a new name is saved), so
		# per request it's gone and Edit lives right next to the name instead.
		var name_row := HBoxContainer.new()
		name_row.add_theme_constant_override("separation", int(_p(0.010)))
		info_col.add_child(name_row)

		var lbl_lbl := Label.new()
		var _eff_label : String = nimiq_label if nimiq_label != "" else (_bridge_pid.left(9) + "..." if _bridge_pid.length() > 9 else _bridge_pid)
		var _display_preview : String = _player_nickname if _player_nickname != "" else _eff_label
		lbl_lbl.text = _display_preview
		lbl_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl_lbl.clip_text = true
		UITheme.apply_label(lbl_lbl, S_BROWN, int(_p(0.034)))
		name_row.add_child(lbl_lbl)

		# Edit button — restored to its original size/solid style (was
		# temporarily shrunk + made ghost-style, reverted per request).
		var nick_edit_btn := Button.new()
		nick_edit_btn.text = "Edit"
		nick_edit_btn.add_theme_font_size_override("font_size", int(_p(0.028)))
		nick_edit_btn.custom_minimum_size = Vector2(_p(0.22), _p(0.068))
		_warm_btn_st(nick_edit_btn)
		if _nickname_cooldown_end > 0 and Time.get_unix_time_from_system() < _nickname_cooldown_end:  # determinism-ok: UI-only cooldown check
			var cd_dt := Time.get_datetime_dict_from_unix_time(_nickname_cooldown_end)
			nick_edit_btn.disabled = true
			nick_edit_btn.tooltip_text = "Can change after %02d.%02d.%04d" % [cd_dt.day, cd_dt.month, cd_dt.year]
		nick_edit_btn.pressed.connect(func():
			_open_nick_overlay()
		)
		name_row.add_child(nick_edit_btn)

		# Full address — wrap it in two lines (NQ.. first half / second half)
		var addr_lbl := Label.new()
		addr_lbl.text = nimiq_address if nimiq_address != "" else _bridge_pid
		addr_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		UITheme.apply_label(addr_lbl, S_MID, int(_p(0.022)))
		info_col.add_child(addr_lbl)

		# Expiry — show remaining time (fallback to localStorage if not in memory)
		var _eff_exp := nimiq_expires_at
		if _eff_exp <= 0 and OS.has_feature("web"):
			var _ls_exp = JavaScriptBridge.eval("parseInt(localStorage.getItem('nj_auth_exp') || '0', 10)", true)
			if _ls_exp != null: _eff_exp = int(_ls_exp)
		if _eff_exp > 0:
			var exp_lbl := Label.new()
			var now_unix := int(Time.get_unix_time_from_system())  # determinism-ok: UI countdown label only
			var remaining := _eff_exp - now_unix
			var exp_text := ""
			if remaining <= 0:
				exp_text = "Session expired"
				UITheme.apply_label(exp_lbl, Color(1.0, 0.4, 0.3, 1.0), int(_p(0.020)))
			else:
				var days := remaining / 86400
				var hours := (remaining % 86400) / 3600
				var mins := (remaining % 3600) / 60
				if days > 0:
					exp_text = "Session expires in %dd %dh" % [days, hours]
				elif hours > 0:
					exp_text = "Session expires in %dh %dm" % [hours, mins]
				else:
					exp_text = "Session expires in %dm" % mins
				UITheme.apply_label(exp_lbl, S_MID, int(_p(0.020)))
			exp_lbl.text = exp_text
			acc_vbox.add_child(exp_lbl)

		# Disconnect button
		if OS.has_feature("web"):
			var disc_btn := Button.new()
			disc_btn.text = "Disconnect"
			disc_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			disc_btn.add_theme_font_size_override("font_size", int(_p(0.028)))
			disc_btn.custom_minimum_size.y = int(_p(0.068))
			_warm_btn_st(disc_btn, true)
			disc_btn.pressed.connect(func():
				if is_instance_valid(_nimiq_bridge):
					_nimiq_bridge.auth_token      = ""
					_nimiq_bridge.auth_player_id  = ""
					_nimiq_bridge.auth_verified   = false
					_nimiq_bridge.auth_expires_at = 0
					_nimiq_bridge._poll_started   = false
					_nimiq_bridge.nimiq_address   = ""
					_nimiq_bridge.nimiq_label     = ""
					_nimiq_bridge.nimiq_avatar    = ""
					_nimiq_bridge.device_id       = ""
				nimiq_address        = ""
				nimiq_label          = ""
				nimiq_avatar         = ""
				nimiq_expires_at     = 0
				nimiq_device_id      = ""
				_avatar_tex          = null
				_auth_token          = ""
				_player_nickname     = ""
				_nickname_cooldown_end = 0
				if OS.has_feature("web"):
					JavaScriptBridge.eval("localStorage.removeItem('nj_auth_token')", true)
					JavaScriptBridge.eval("localStorage.removeItem('nj_auth_pid')", true)
					JavaScriptBridge.eval("localStorage.removeItem('nj_auth_exp')", true)
				_rebuild_settings_if_open()
			)
			acc_vbox.add_child(disc_btn)
	else:
		# Not connected
		var nc_row := HBoxContainer.new()
		nc_row.add_theme_constant_override("separation", int(_p(0.010)))
		acc_vbox.add_child(nc_row)
		nc_row.add_child(UITheme.lucide_icon("circle", int(_p(0.030)), S_MID))
		var nc_lbl := Label.new()
		nc_lbl.text = "Not connected"
		nc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(nc_lbl, S_MID, int(_p(0.030)))
		nc_row.add_child(nc_lbl)
		if OS.has_feature("web"):
			var connect_btn := Button.new()
			connect_btn.text = "Connect"
			connect_btn.add_theme_font_size_override("font_size", int(_p(0.030)))
			connect_btn.custom_minimum_size = Vector2(_p(0.28), _p(0.068))
			_warm_btn_st(connect_btn)
			connect_btn.pressed.connect(func():
				if not is_instance_valid(_nimiq_bridge): return
				connect_btn.disabled = true
				connect_btn.text = "Signing..."
				_nimiq_bridge.auth_verified  = false
				_nimiq_bridge.auth_attempted = false
				_nimiq_bridge.auth_token     = ""
				# Address already known — skip poll, go straight to sign
				if _nimiq_bridge.nimiq_address != "":
					_nimiq_bridge._do_sign_auth()
				else:
					# No address yet — full poll needed
					_nimiq_bridge._poll_started = false
					_nimiq_bridge._poll()
				# Re-enable button after a short delay; settings rebuild on auth_success signal
				await get_tree().create_timer(0.4).timeout
				if is_instance_valid(connect_btn):
					connect_btn.text = "Connect"
					connect_btn.disabled = false
			)
			nc_row.add_child(connect_btn)

	# ── About ──────────────────────────────────────
	var about_pc := PanelContainer.new()
	about_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	about_pc.add_theme_stylebox_override("panel", _card_st.call())
	vbox.add_child(about_pc)

	var about_mc := _make_margin_container(pad)
	about_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	about_pc.add_child(about_mc)

	var about_vbox := VBoxContainer.new()
	about_vbox.add_theme_constant_override("separation", int(_p(0.006)))
	about_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	about_mc.add_child(about_vbox)

	# About header — icon + text
	var about_hdr := HBoxContainer.new()
	about_hdr.add_theme_constant_override("separation", int(_p(0.010)))
	about_vbox.add_child(about_hdr)
	var info_ic := TextureRect.new()
	info_ic.custom_minimum_size = Vector2(int(_p(0.038)), int(_p(0.038)))
	info_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	info_ic.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	var info_path : String = UITheme.get_theme_assets().get("icon_info", "")
	if ResourceLoader.exists(info_path):
		info_ic.texture = load(info_path)
	about_hdr.add_child(info_ic)
	var about_title := Label.new()
	about_title.text = "About"
	UITheme.apply_label(about_title, S_BROWN, fs)
	about_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	about_hdr.add_child(about_title)

	var about_game := Label.new()
	about_game.text = "NimJump"
	about_game.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(about_game, S_BROWN, int(_p(0.052)))
	about_vbox.add_child(about_game)

	var about_dev := Label.new()
	about_dev.text = "By: the_dude"
	about_dev.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(about_dev, S_MID, int(_p(0.036)))
	about_vbox.add_child(about_dev)

	# Make all non-interactive containers inside scroll passthrough touch events
	# so ScrollContainer receives drag gestures regardless of where the finger lands
	_set_containers_pass(scroll)


# ─────────────────────────────────────────────────────
#  SETTINGS CALLBACKS
# ─────────────────────────────────────────────────────

## Recursively set MOUSE_FILTER_PASS on all layout containers inside a ScrollContainer.
## Interactive controls (Button, Slider, CheckButton, LineEdit, etc.) keep their default.
func _set_containers_pass(node: Node) -> void:
	for child in node.get_children():
		if child is Button or child is BaseButton or child is Slider or child is LineEdit:
			pass  # leave interactive controls alone
		elif child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_PASS
			_set_containers_pass(child)
		else:
			_set_containers_pass(child)


func _open_settings() -> void:
	# Her açılışta rebuild — auth state, nickname vs güncel olsun
	_sync_panels()
	if is_instance_valid(_settings_popup):
		_settings_popup.queue_free()
		_settings_popup = null
	_build_settings_popup()

	_settings_popup.visible    = true
	_settings_popup.modulate.a = 0.0
	_settings_popup.scale      = Vector2(0.90, 0.90)
	var tw := create_tween()
	if tw:
		tw.set_parallel(true)
		tw.tween_property(_settings_popup, "modulate:a", 1.0,         0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(_settings_popup, "scale",      Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Show account switch popup — calls Nimiq listAccounts, lists accounts, lets user pick
func _rebuild_settings_if_open() -> void:
	if not is_instance_valid(_settings_popup) or not _settings_popup.visible:
		return
	# FREEZE/LEAK FIX: this function awaits a frame before tearing down and
	# rebuilding the ENTIRE settings popup (dozens of Control/StyleBox nodes).
	# It's called from several auth/bridge callbacks (_on_nimiq_ready,
	# _on_auth_success, _on_auth_failed, _on_auth_expired) that can legitimately
	# fire more than once in quick succession. Without this guard, a second call
	# arriving while the first is still paused on `await process_frame` would
	# pass the same visibility check, then BOTH calls would queue_free() the
	# (still-valid-until-end-of-frame) popup and build a brand new one — the
	# first rebuild's new popup gets silently overwritten/orphaned by the
	# second, leaking a full Control tree instead of freeing it. Repeated
	# often enough (each open + each auth ping) this is exactly the kind of
	# thing that shows up as "sometimes when I open a menu it stutters/freezes"
	# over a long session. The guard makes overlapping calls just skip instead
	# of racing.
	if _settings_rebuilding:
		return
	_settings_rebuilding = true
	# Wait one frame so bridge state is fully written before reading
	await get_tree().process_frame
	if not is_instance_valid(_settings_popup) or not _settings_popup.visible:
		_settings_rebuilding = false
		return
	_sync_panels()
	_settings_popup.queue_free()
	_settings_popup = null
	_build_settings_popup()
	_settings_popup.visible = true
	_settings_popup.modulate.a = 1.0
	_settings_rebuilding = false

func _open_nick_overlay() -> void:
	if is_instance_valid(_nick_overlay):
		_nick_overlay.queue_free()
	_nick_overlay = Control.new()
	_nick_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_nick_overlay.z_index = 50
	_ui_root.add_child(_nick_overlay)

	const OV_BG     := Color(0.957, 0.898, 0.800)
	const OV_BORDER := Color(0.700, 0.520, 0.340)
	const OV_BROWN  := Color(0.220, 0.130, 0.060)
	const OV_MID    := Color(0.480, 0.340, 0.200)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.modulate.a = 0.0   # fades in below, instead of popping in instantly
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_nick_overlay.add_child(dim)

	# Kart: ekranın üst %5-%55 aralığında sabit — klavye açıldığında
	# viewport küçüldüğünde bile panel görünür kalır.
	var pw  := _p(0.88)
	var pc  := PanelContainer.new()
	pc.anchor_left   = 0.06; pc.anchor_right  = 0.94
	pc.anchor_top    = 0.05; pc.anchor_bottom = 0.55
	pc.offset_left   = 0.0;  pc.offset_right  = 0.0
	pc.offset_top    = 0.0;  pc.offset_bottom = 0.0
	var pc_st := StyleBoxFlat.new()
	pc_st.bg_color = OV_BG
	pc_st.border_color = OV_BORDER
	pc_st.set_border_width_all(3)
	pc_st.set_corner_radius_all(16)
	pc_st.shadow_color = Color(0,0,0,0.3)
	pc_st.shadow_size  = 12
	pc.add_theme_stylebox_override("panel", pc_st)
	pc.modulate.a = 0.0   # fades/scales in below — was popping in instantly with no animation
	pc.scale      = Vector2(0.92, 0.92)
	_nick_overlay.add_child(pc)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(_p(0.018)))
	pc.add_child(vb)

	var mc := _make_margin_container(int(_p(0.030)))
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(mc)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", int(_p(0.016)))
	mc.add_child(inner)

	# Başlık
	var hdr_row := HBoxContainer.new()
	inner.add_child(hdr_row)

	var hdr_lbl := Label.new()
	hdr_lbl.text = "Display Name"
	hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(hdr_lbl, OV_BROWN, int(_p(0.042)))
	hdr_row.add_child(hdr_lbl)

	# TOUCH-FIX: tap target was only ~0.048*_p — too small on phones.
	var x_btn := Button.new()
	x_btn.custom_minimum_size = Vector2(int(_p(0.092)), int(_p(0.092)))
	var x_ic_sz := int(_p(0.092) * 0.72)  # icon now fills the bigger button instead of floating tiny inside it
	_warm_btn_st(x_btn)
	var x_center := CenterContainer.new()
	x_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	x_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	x_btn.add_child(x_center)
	var x_ic := TextureRect.new()
	x_ic.texture = load("res://assets/hud/hudX.png")
	x_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	x_ic.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	x_ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	x_ic.custom_minimum_size = Vector2(x_ic_sz, x_ic_sz)
	x_center.add_child(x_ic)
	x_btn.pressed.connect(func(): _nick_overlay.queue_free(); _nick_overlay = null)
	hdr_row.add_child(x_btn)

	# Hint
	var hint := Label.new()
	hint.text = "Letters a-z and numbers 0-9 only, max 20 chars"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(hint, OV_MID, int(_p(0.024)))
	inner.add_child(hint)

	# LineEdit
	var le := LineEdit.new()
	le.placeholder_text = "your name here"
	le.text = _player_nickname
	le.max_length = 20
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size.y = int(_p(0.090))
	le.add_theme_font_size_override("font_size", int(_p(0.040)))
	le.focus_mode = Control.FOCUS_ALL
	le.virtual_keyboard_enabled = true
	var le_st := StyleBoxFlat.new()
	le_st.bg_color = Color(1.0, 0.97, 0.93)
	le_st.border_color = Color(0.780, 0.380, 0.120)
	le_st.set_border_width_all(2)
	le_st.set_corner_radius_all(10)
	le_st.content_margin_left = int(_p(0.020)); le_st.content_margin_right = int(_p(0.020))
	le_st.content_margin_top = int(_p(0.010));  le_st.content_margin_bottom = int(_p(0.010))
	le.add_theme_stylebox_override("normal", le_st)
	le.add_theme_stylebox_override("focus",  le_st)
	le.add_theme_color_override("font_color",             OV_BROWN)
	le.add_theme_color_override("font_placeholder_color", OV_MID)
	le.add_theme_color_override("caret_color",            Color(0.780, 0.380, 0.120))
	le.add_theme_color_override("selection_color",        Color(0.780, 0.380, 0.120, 0.35))
	inner.add_child(le)

	# Live filter
	le.text_changed.connect(func(t: String):
		var f := ""
		for ch in t.to_lower():
			if (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9'):
				f += ch
		if f != t:
			var col := le.caret_column
			le.text = f
			le.caret_column = clampi(col, 0, f.length())
	)

	# Status label
	var st_lbl := Label.new()
	st_lbl.text = ""
	st_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(st_lbl, OV_MID, int(_p(0.026)))
	inner.add_child(st_lbl)

	# Save butonu — tam genişlik
	var save_btn := Button.new()
	save_btn.text = "Save Name"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.custom_minimum_size.y = int(_p(0.090))
	save_btn.add_theme_font_size_override("font_size", int(_p(0.036)))
	_warm_btn_st(save_btn)
	inner.add_child(save_btn)

	save_btn.pressed.connect(func():
		var raw := le.text.strip_edges().to_lower()
		var valid := raw.length() >= 1 and raw.length() <= 20
		if valid:
			for ch in raw:
				if not (ch >= 'a' and ch <= 'z') and not (ch >= '0' and ch <= '9'):
					valid = false; break
		if not valid:
			st_lbl.text = "Use only a-z and 0-9, 1-20 chars"
			UITheme.apply_label(st_lbl, Color(1.0, 0.4, 0.3, 1.0), int(_p(0.026)))
			return
		save_btn.disabled = true
		save_btn.text = "Saving..."
		st_lbl.text = ""
		_set_nickname_async(raw, _auth_token, func(ok: bool, err: String):
			save_btn.disabled = false
			save_btn.text = "Save Name"
			if ok:
				st_lbl.text = "Saved!"
				UITheme.apply_label(st_lbl, Color(0.3, 0.85, 0.4, 1.0), int(_p(0.026)))
				_rebuild_settings_if_open()
				await get_tree().create_timer(0.5).timeout
				if is_instance_valid(_nick_overlay):
					_nick_overlay.queue_free(); _nick_overlay = null
			else:
				var msg := err
				if err.begins_with("cooldown"):
					msg = "On cooldown (30-day limit)"
				elif err == "nickname_taken":
					msg = "Already taken, try another"
				elif err == "invalid_nickname":
					msg = "Only a-z and 0-9, 1-20 chars"
				elif err == "not_authenticated" or err.begins_with("error_"):
					msg = "Connection failed, try again"
					Toast.network_error("set_nickname %s" % err)
				st_lbl.text = msg
				UITheme.apply_label(st_lbl, Color(1.0, 0.4, 0.3, 1.0), int(_p(0.026)))
		)
	)

	# Focus'u bir frame sonra ver (layout hazır olsun)
	await get_tree().process_frame
	if is_instance_valid(le):
		le.grab_focus()
		le.caret_column = le.text.length()

	# Entrance animation — dim fades in, card fades + scales up from its
	# own center. Runs after the layout frame above so pc.size is valid.
	if is_instance_valid(pc):
		pc.pivot_offset = pc.size * 0.5
	var ov_tw := create_tween()
	if ov_tw:
		ov_tw.set_parallel(true)
		ov_tw.tween_property(dim, "modulate:a", 1.0, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		ov_tw.tween_property(pc,  "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		ov_tw.tween_property(pc,  "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	# ── Klavye yükseklik takibi ─────────────────────────────────────
	# FIX: this used to also fetch the keyboard height from JS and subtract
	# it from _vh a SECOND time on focus — but _on_viewport_resized() already
	# shrinks _vh to the post-keyboard viewport height the moment the OS
	# resizes it (see the "KLAVYE AÇILINCA VIEWPORT KÜÇÜLME SORUNU" block
	# above). Subtracting kb_h again double-counted the keyboard, producing
	# a tiny/negative available_h and scrambling the panel's position —
	# exactly the "keyboard opens, screen shrinks, everything goes haywire"
	# bug. The panel is anchored with percentages (anchor_top=0.05,
	# anchor_bottom=0.55, set below), which Godot already re-lays-out
	# automatically against whatever the CURRENT viewport size is on every
	# resize — no manual repositioning code is needed at all.


func _close_settings() -> void:
	if is_instance_valid(_nick_overlay):
		_nick_overlay.queue_free()
		_nick_overlay = null
	if _settings_popup:
		var tw := create_tween()
		if tw:
			tw.set_parallel(true)
			tw.tween_property(_settings_popup, "modulate:a", 0.0,                  0.15).set_trans(Tween.TRANS_QUAD)
			tw.tween_property(_settings_popup, "scale",      Vector2(0.90, 0.90),  0.15).set_trans(Tween.TRANS_QUAD)
			tw.chain().tween_callback(func(): _settings_popup.visible = false)
		else:
			_settings_popup.visible = false


func _on_sound_toggled(pressed: bool) -> void:
	_muted = not pressed
	if _volume_slider:
		_volume_slider.editable = not _muted
	_apply_audio_settings()
	if OS.has_feature("web"):
		if _muted:
			JavaScriptBridge.eval("if(window._gdSound) window._gdSound('bgm_stop');", true)
		elif _bgm_enabled and _bgm_started:
			JavaScriptBridge.eval("if(window._gdSound) window._gdSound('bgm_play');", true)


func _on_volume_changed(val: float) -> void:
	_volume = val
	_apply_audio_settings()


# ─────────────────────────────────────────────────────
#  AUDIO SYSTEM
# ─────────────────────────────────────────────────────
func _setup_audio() -> void:
	# Tüm ses JS tarafında (index.html _gdSound / _gdSetBus).
	# Godot AudioStreamPlayer web'de res:// WAV yükleyemiyor.
	_apply_audio_settings()


func _apply_audio_settings() -> void:
	if not OS.has_feature("web"): return
	var master_vol := _volume if not _muted else 0.0
	JavaScriptBridge.eval("""
		if (window._gdSetBus) {
			window._gdSetBus('BGM',        %f, %s);
			window._gdSetBus('SFX_Jump',   %f, %s);
			window._gdSetBus('SFX_Damage', %f, %s);
			window._gdSetBus('Master',     %f, %s);
		}
	""" % [
		_bgm_volume,    str(not _bgm_enabled).to_lower(),
		_jump_volume,   str(not _jump_enabled).to_lower(),
		_damage_volume, str(not _damage_enabled).to_lower(),
		master_vol,     str(_muted).to_lower()
	], true)


## Browser autoplay policy: ilk kullanıcı etkileşimine kadar ses bloke
var _bgm_started    : bool = false
var _audio_unlocked : bool = false


func _start_bgm_if_needed() -> void:
	_audio_unlocked = true
	if not OS.has_feature("web"): return
	JavaScriptBridge.eval("""
		if (window._gdSound) {
			window._gdSound('unlock');
			window._gdSound('bgm_play');
		}
	""", true)
	_bgm_started = true
	print("[AUDIO] bgm_play sent to JS")


func play_jump_sound() -> void:
	if not _audio_unlocked: return
	if not _jump_enabled or _muted: return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if(window._gdSound) window._gdSound('jump_play');", true)


func play_damage_sound() -> void:
	if not _audio_unlocked: return
	if not _damage_enabled or _muted: return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if(window._gdSound) window._gdSound('damage_play');", true)


func _change_char_settings(dir: int) -> void:
	_char_index = (_char_index + dir + CHAR_NAMES.size()) % CHAR_NAMES.size()
	if _settings_char_lbl: _settings_char_lbl.text = "%s\n%s" % [CHAR_NAMES[_char_index], CHAR_DESCS[_char_index]]
	if _char_lbl:          _char_lbl.text = CHAR_NAMES[_char_index]
	if is_instance_valid(_player) and _player.has_method("set_char"):
		_player.call("set_char", _char_index)
	_save_settings()


# ─────────────────────────────────────────────────────
#  MAIN CALLBACKS
# ─────────────────────────────────────────────────────
func _on_play_pressed() -> void:
	_start_bgm_if_needed()  # ilk etkileşim → BGM başlat
	if _started: return

	# Sign-in required — request if no auth, wait again if rejected (game must not start)
	if _auth_token == "":
		print("[MAIN] play pressed — not signed in, requesting auth")
		if is_instance_valid(_nimiq_bridge) and not _nimiq_bridge.auth_verified:
			_nimiq_bridge._do_sign_auth()
		# On success start game, on error/rejection reset — user can press play again
		var _conn_s := _nimiq_bridge.connect("auth_success", func(_t, _p):
			_on_play_pressed()   # auth received, continue normal flow
		, CONNECT_ONE_SHOT)
		var _conn_f := _nimiq_bridge.connect("auth_failed", func(_r):
			pass  # handled by _on_auth_failed global handler
		, CONNECT_ONE_SHOT)
		return

	_started = true
	# Block late LB HTTP callbacks from starting replay
	_block_lb_replay = true
	# Close all panels
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
	if is_instance_valid(_stats_panel):       _stats_panel.hide_panel()
	if is_instance_valid(_quest_panel):       _quest_panel.hide_panel()

	_do_start_game()


# ── VS ─────────────────────────────────────────────────────────────────────────

var _vs_popup       : Control = null
var _vs_status_lbl  : Label   = null
var _vs_invite_btn  : Button  = null

func _on_vs_pressed_with_invite(invite_id: String) -> void:
	_show_vs_waiting_popup()
	if is_instance_valid(_vs_status_lbl):
		_vs_status_lbl.text = "Joining room..."
	var nick := _player_nickname if _player_nickname != "" else \
		(nimiq_label if nimiq_label != "" else "Player")
	VSManager.matched.connect(_on_vs_matched, CONNECT_ONE_SHOT)
	VSManager.match_timeout.connect(_on_vs_timeout, CONNECT_ONE_SHOT)
	VSManager.error.connect(_on_vs_error, CONNECT_ONE_SHOT)
	VSManager.opponent_left.connect(_on_vs_opponent_left_menu, CONNECT_ONE_SHOT)
	VSManager.countdown.connect(_on_vs_countdown)
	VSManager.join(nick, invite_id)


func _on_vs_pressed() -> void:
	if _started: return
	_show_vs_waiting_popup()
	var nick := _player_nickname if _player_nickname != "" else \
		(nimiq_label if nimiq_label != "" else "Player")
	# Check for invite param in URL
	var invite := ""
	if OS.has_feature("web"):
		var url_raw = JavaScriptBridge.eval("window.location.search", true)
		if url_raw != null:
			var url_str := str(url_raw)
			var idx := url_str.find("vs=")
			if idx >= 0:
				invite = url_str.substr(idx + 3).split("&")[0]

	# Connect VSManager signals
	VSManager.matched.connect(_on_vs_matched, CONNECT_ONE_SHOT)
	VSManager.match_timeout.connect(_on_vs_timeout, CONNECT_ONE_SHOT)
	VSManager.error.connect(_on_vs_error, CONNECT_ONE_SHOT)
	VSManager.opponent_left.connect(_on_vs_opponent_left_menu, CONNECT_ONE_SHOT)
	VSManager.countdown.connect(_on_vs_countdown)

	VSManager.join(nick, invite)


func _show_vs_waiting_popup() -> void:
	if is_instance_valid(_vs_popup):
		_vs_popup.queue_free()

	var ref := minf(minf(_vw, _vh), GameConstants.VW)
	_vs_popup = Control.new()
	_anchored(_vs_popup, Control.PRESET_FULL_RECT)
	_vs_popup.z_index = 30
	_ui_root.add_child(_vs_popup)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.70)
	_anchored(dim, Control.PRESET_FULL_RECT)
	_vs_popup.add_child(dim)

	var pc := PanelContainer.new()
	var pw := _p(0.80)
	var ph := _p(0.42)
	pc.anchor_left = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top  = 0.5; pc.anchor_bottom = 0.5
	pc.offset_left   = -pw * 0.5; pc.offset_right  = pw * 0.5
	pc.offset_top    = -ph * 0.5; pc.offset_bottom = ph * 0.5
	UITheme.apply_panel(pc)
	_vs_popup.add_child(pc)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(_p(0.016)))
	pc.add_child(vbox)

	var mc := _make_margin_container(int(_p(0.030)))
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	pc.add_child(mc)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", int(_p(0.018)))
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	mc.add_child(inner)

	var title := Label.new()
	title.text = "VS MODE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, UITheme.COL_GOLD, int(_p(0.054)))
	inner.add_child(title)

	_vs_status_lbl = Label.new()
	_vs_status_lbl.text = "Looking for opponent..."
	_vs_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vs_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	UITheme.apply_label(_vs_status_lbl, UITheme.COL_TEXT_DIM, int(_p(0.030)))
	inner.add_child(_vs_status_lbl)

	# Invite link button (hidden until room_id known)
	_vs_invite_btn = Button.new()
	_vs_invite_btn.text = "Copy Invite Link"
	_vs_invite_btn.add_theme_font_size_override("font_size", int(_p(0.028)))
	_vs_invite_btn.visible = false
	UITheme.apply_ghost_button(_vs_invite_btn)
	inner.add_child(_vs_invite_btn)
	_vs_invite_btn.pressed.connect(func():
		var url := VSManager.get_invite_url()
		if url != "" and OS.has_feature("web"):
			JavaScriptBridge.eval("navigator.clipboard && navigator.clipboard.writeText('%s')" % url, true)
		_vs_invite_btn.text = "Copied!"
		await get_tree().create_timer(1.0).timeout
		if is_instance_valid(_vs_invite_btn):
			_vs_invite_btn.text = "Copy Invite Link"
	)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", int(_p(0.030)))
	UITheme.apply_ghost_button(cancel_btn)
	inner.add_child(cancel_btn)
	cancel_btn.pressed.connect(_close_vs_popup)


func _close_vs_popup() -> void:
	VSManager.disconnect_room()
	if is_instance_valid(_vs_popup):
		_vs_popup.queue_free()
		_vs_popup = null
	# Disconnect lingering signals
	for sig in ["matched","match_timeout","error","opponent_left","countdown"]:
		var s := VSManager.get(sig) as Signal
		if s and s.is_connected(_get_vs_handler(sig)):
			pass  # one-shot signals disconnect automatically


func _get_vs_handler(_sig: String) -> Callable:
	return func(): pass  # placeholder


func _on_vs_matched(seed: String, slot: int, opponent: String) -> void:
	if not is_instance_valid(_vs_status_lbl): return
	_vs_status_lbl.text = "Opponent found: %s\nGet ready..." % opponent
	if is_instance_valid(_vs_invite_btn):
		_vs_invite_btn.visible = false
	# Show invite button for slot 0 while waiting
	if slot == 0 and VSManager.get_invite_url() != "":
		if is_instance_valid(_vs_invite_btn):
			_vs_invite_btn.visible = true


func _on_vs_timeout() -> void:
	if is_instance_valid(_vs_status_lbl):
		_vs_status_lbl.text = "No opponent found.\nShare the invite link."
	if is_instance_valid(_vs_invite_btn) and VSManager.get_invite_url() != "":
		_vs_invite_btn.visible = true


func _on_vs_error(msg: String) -> void:
	if is_instance_valid(_vs_status_lbl):
		if msg.begins_with("join_request_failed") or msg.begins_with("join_failed") or msg.begins_with("ws_connect_failed"):
			_vs_status_lbl.text = "Connection failed"
			Toast.network_error("vs %s" % msg)
		else:
			_vs_status_lbl.text = "Error. " + msg


func _on_vs_opponent_left_menu() -> void:
	_close_vs_popup()


func _on_vs_countdown(n: int) -> void:
	if not is_instance_valid(_vs_popup): return
	if n > 0:
		if is_instance_valid(_vs_status_lbl):
			_vs_status_lbl.text = str(n)
			_vs_status_lbl.add_theme_font_size_override("font_size", int(_p(0.14)))
	else:
		# n==0 → GO! — close popup, start game in VS mode
		_close_vs_popup_silent()
		# Disconnect countdown signal
		if VSManager.countdown.is_connected(_on_vs_countdown):
			VSManager.countdown.disconnect(_on_vs_countdown)
		_start_vs_game()


func _close_vs_popup_silent() -> void:
	if is_instance_valid(_vs_popup):
		_vs_popup.queue_free()
		_vs_popup = null


func _start_vs_game() -> void:
	if _started: return
	_started = true
	_block_lb_replay = true
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.hide_panel()
	if is_instance_valid(_stats_panel):       _stats_panel.hide_panel()
	if is_instance_valid(_quest_panel):       _quest_panel.hide_panel()

	# Apply VS seed to GM before starting
	var vs_seed := int(VSManager._seed) if VSManager._seed != "" else 0
	if vs_seed != 0 and is_instance_valid(_gm):
		_gm.call("vs_apply_seed", vs_seed)

	_do_start_game()
	# Activate VS mode in GM after game starts
	await get_tree().process_frame
	if is_instance_valid(_gm):
		_gm.call("vs_start")


## Polls /backend/developer-mode periodically for update_active. Doesn't
## block anything by itself — _do_start_game() checks the cached flag.
func _start_status_poll() -> void:
	if not OS.has_feature("web"): return
	_check_server_status()
	_status_poll_timer = Timer.new()
	_status_poll_timer.wait_time = _STATUS_POLL_SEC
	_status_poll_timer.autostart = true
	_status_poll_timer.timeout.connect(_check_server_status)
	add_child(_status_poll_timer)


func _check_server_status() -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return  # offline/unreachable — keep last known state, don't flip anything
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			return
		var d : Dictionary = j.get_data()
		_update_active = bool(d.get("update_active", false))
		var msg := str(d.get("update_message", ""))
		if msg != "":
			_update_message = msg
	)
	http.request(BACKEND_URL + "/backend/developer-mode")


func _do_start_game(forced_seed: int = 0) -> void:
	if _update_active:
		print("[MAIN] start blocked — game is in update mode")
		var inst := Toast.get_instance()
		if inst != null:
			inst.show_toast(_update_message, Toast.Kind.WARN)
		return

	var tw := create_tween()
	if tw:
		tw.tween_property(_ui_root, "modulate:a", 0.0, 0.35)
		tw.tween_callback(func():
			_ui_layer.visible = false
			_hud.visible      = true
			# Clean up stale game_over state (e.g. after leaderboard replay)
			var is_game_over : bool = _gm.get("_game_over") == true
			if is_game_over:
				_gm.set("_game_over", false)
			# If platforms are ready AND recording is active, activate immediately.
			# Otherwise call _start_session to get a fresh session.
			var platforms_ready : bool = _gm.get("game_seed") != 0 and _gm.get("_platforms") != null and (_gm.get("_platforms") as Array).size() > 0
			var is_recording    : bool = _gm.get("_replay_mode") == 1  # ReplayMode.RECORDING
			if platforms_ready and is_recording and _player and _player.has_method("activate"):
				_player.activate()
			else:
				print("[MAIN] platforms not ready or not recording — calling _start_session")
				# Freeze player — don't fall while _start_session is async
				if is_instance_valid(_player) and _player.has_method("reset_to_idle"):
					_player.call("reset_to_idle")
				if is_instance_valid(_gm):
					_gm.set("_game_over", false)
					_gm.call("_start_session", forced_seed)
		)


## Vibration wrapper — Godot's Input.vibrate_handheld() is a confirmed no-op on
## the HTML5/web export (engine limitation: godotengine/godot#96985), so on web
## we call the browser's navigator.vibrate() directly instead. This actually
## works on Android (Chrome / Chromium-based WebView, API 19+) but can NEVER
## work on iOS (Safari/WKWebView have no Vibration API at all) — _is_ios is
## checked first so we don't even attempt it there.
func _do_vibrate(ms: int) -> void:
	if not _vibration or _is_ios:
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval(
			"try { if (navigator.vibrate) navigator.vibrate(%d); } catch(e) {}" % ms, true)
	else:
		Input.vibrate_handheld(ms)


func _change_char(dir: int) -> void:
	_char_index = (_char_index + dir + CHAR_NAMES.size()) % CHAR_NAMES.size()
	if _char_lbl:          _char_lbl.text = CHAR_NAMES[_char_index]
	if _settings_char_lbl: _settings_char_lbl.text = "%s\n%s" % [CHAR_NAMES[_char_index], CHAR_DESCS[_char_index]]
	if is_instance_valid(_player) and _player.has_method("set_char"):
		_player.call("set_char", _char_index)
	_save_settings()


func _on_lives_changed(lives: int) -> void:
	# Damage sound + vibration when lives decrease
	if lives < _prev_lives and _started:
		play_damage_sound()
		_do_vibrate(120)   # 120 ms short pulse
	_prev_lives = lives

	for i in _life_icons.size():
		var ico := _life_icons[i]
		var full_tex  : Texture2D = ico.get_meta("heart_full",  null) if ico.has_meta("heart_full")  else null
		var empty_tex : Texture2D = ico.get_meta("heart_empty", null) if ico.has_meta("heart_empty") else null
		if i < lives:
			ico.texture   = full_tex
			ico.modulate  = Color.WHITE
		else:
			ico.texture   = empty_tex if empty_tex else full_tex
			ico.modulate  = Color(1.0, 1.0, 1.0, 0.4)


# ─────────────────────────────────────────────────────
#  GAME OVER — callbacks invoked by GameManager
# ─────────────────────────────────────────────────────
func show_game_over(p_score: int, p_best: int, p_stats: Dictionary = {}) -> void:
	print("[GAME_OVER] show_game_over called score=%d best=%d" % [p_score, p_best])
	# Death vibration — longer pulse
	_do_vibrate(400)

	if is_instance_valid(_score_display):
		_score_display.show_number(p_score)
	if is_instance_valid(_final_display):
		_final_display.show_number(p_score)
	if is_instance_valid(_claim_lbl):
		_claim_lbl.text = "Waiting for server score..."
		_claim_lbl.add_theme_color_override("font_color", UITheme.COL_TEXT_DARK)
	if is_instance_valid(_srv_score_display):
		_srv_score_display.visible = false
	if is_instance_valid(_claim_btn):
		_claim_btn.visible = false
	if is_instance_valid(_claim_status):
		_claim_status.text = ""
	# Stats grid doldur
	if is_instance_valid(_go_panel) and _go_panel.has_meta("stat_vals"):
		var sv : Array = _go_panel.get_meta("stat_vals")
		var _plat : int = p_stats.get("platforms", 0)
		var _kill : int = p_stats.get("kills",     0)
		var _coin : int = p_stats.get("coins",     0)
		if sv.size() >= 3:
			(sv[0] as Label).text = str(_plat)
			(sv[1] as Label).text = str(_kill)
			(sv[2] as Label).text = str(_coin)
	if is_instance_valid(_go_stats_lbl):
		_go_stats_lbl.text = ""
	_show_go_panel()

func update_score_display(p_score: int) -> void:
	if is_instance_valid(_score_display):
		_score_display.show_number(p_score)

func update_nimiq_display(p_count: int) -> void:
	if is_instance_valid(_nimiq_display):
		_nimiq_display.show_number(p_count)

func update_final_display(p_score: int) -> void:
	if is_instance_valid(_final_display):
		_final_display.show_number(p_score)
	if is_instance_valid(_score_display):
		_score_display.show_number(p_score)

func show_seed(p_seed: int) -> void:
	# Show seed info if needed (silent for now)
	print("[MAIN] game seed: %d" % p_seed)

func _submit_session_from_gm() -> void:
	# GameManager handles the submit itself (_submit_session),
	# calls _on_session_submitted via callback when backend responds.
	# This function is a placeholder for resetting claim UI.
	pass

func _on_quests_updated() -> void:
	# Quest panelini yenile
	if is_instance_valid(_quest_panel) and _quest_panel.has_method("refresh"):
		_quest_panel.call("refresh")

func _hide_go_panel() -> void:
	if not is_instance_valid(_go_panel): return
	_go_panel.visible = false
	var cont = _go_panel.get_meta("container") if _go_panel.has_meta("container") else null
	var dim  = _go_panel.get_meta("dim")       if _go_panel.has_meta("dim")       else null
	if dim  and is_instance_valid(dim):  dim.visible  = false
	if cont and is_instance_valid(cont): cont.visible = false


func _show_go_panel() -> void:
	if is_instance_valid(_go_panel): _go_panel.visible = true
	var cont = _go_panel.get_meta("container") if _go_panel.has_meta("container") else null
	var dim  = _go_panel.get_meta("dim")       if _go_panel.has_meta("dim")       else null
	if dim  and is_instance_valid(dim):  dim.visible  = true
	if cont and is_instance_valid(cont): cont.visible = true

	# Is replay available? — show/hide REPLAY button accordingly
	if _go_panel.has_meta("replay_btn"):
		var rb = _go_panel.get_meta("replay_btn")
		if is_instance_valid(rb):
			var has_rpl : bool = _gm and _gm.has_method("has_replay") and _gm.call("has_replay")
			var log_sz  : int  = _gm.get("_replay_log").size() if _gm else 0
			var rpl_seed: int  = _gm.get("_replay_seed")       if _gm else 0
			print("[GO_PANEL] has_replay=%s log_size=%d seed=%d" % [has_rpl, log_sz, rpl_seed])
			rb.visible  = has_rpl
			rb.disabled = false

	# Opening animation
	if is_instance_valid(_go_panel):
		_go_panel.modulate.a = 0.0
		_go_panel.scale      = Vector2(0.88, 0.88)
		var tw := create_tween()
		if tw:
			tw.set_parallel(true)
			tw.tween_property(_go_panel, "modulate:a", 1.0,          0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(_go_panel, "scale",      Vector2.ONE,  0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# ─────────────────────────────────────────────────────
#  SERVER SCORE + CLAIM
# ─────────────────────────────────────────────────────
func _on_session_submitted(sid: String, srv_score: int, flagged: bool) -> void:
	_session_id    = sid
	_claim_flagged = flagged
	_claim_done    = false

	if flagged:
		_claim_lbl.text = "Score could not be verified. Cheat detected."
		_claim_lbl.add_theme_color_override("font_color", UITheme.COL_RED)
		_srv_score_display.visible = false
		_claim_btn.visible = false
	else:
		_claim_lbl.text = "Server score:"
		_claim_lbl.add_theme_color_override("font_color", UITheme.COL_GREEN)
		_srv_score_display.show_number(srv_score)
		_srv_score_display.visible = true
		_claim_btn.visible = true
		_claim_status.text = ""


func _do_claim() -> void:
	if _claim_done or _session_id == "": return
	_claim_btn.disabled = true
	_claim_status.text  = "Claiming..."

	var req := HTTPRequest.new()
	add_child(req)
	var url := BACKEND_URL + "/api/sessions/%s/claim" % _session_id
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var parsed : Variant = JSON.parse_string(body.get_string_from_utf8())
			if parsed and parsed.has("claim_token"):
				_claim_done        = true
				_claim_btn.visible = false
				_claim_status.text = "Token: " + str(parsed["claim_token"])
				_claim_status.add_theme_color_override("font_color", UITheme.COL_GOLD)
			else:
				_claim_status.text  = "Claim failed"
				_claim_btn.disabled = false
		elif code == 409:
			_claim_status.text = "Already claimed"; _claim_btn.visible = false
		elif code == 403:
			_claim_status.text = "Rejected: cheat"; _claim_btn.visible = false
		else:
			_claim_status.text  = "Connection error"; _claim_btn.disabled = false
			Toast.network_error("claim code=%d" % code)
	)
	req.request(url, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, "{}")


# ─────────────────────────────────────────────────────
#  BACKEND PING + ERROR BANNER
# ─────────────────────────────────────────────────────

## "data:image/png;base64,…" or "data:image/svg+xml;base64,…" → ImageTexture
## For SVG, uses Godot's built-in SVG support (4.x).
## Generates a deterministic colored fallback avatar from address/nickname (works on all platforms)
func _make_fallback_avatar(address: String, size: int) -> ImageTexture:
	const PALETTE := [
		Color(0.13, 0.60, 0.90), Color(0.40, 0.78, 0.22),
		Color(0.96, 0.65, 0.14), Color(0.82, 0.28, 0.28),
		Color(0.60, 0.35, 0.85), Color(0.20, 0.72, 0.65),
		Color(0.95, 0.38, 0.60), Color(0.45, 0.55, 0.70),
	]
	var hash_val := 0
	for i in mini(address.length(), 12):
		hash_val = (hash_val * 31 + address.unicode_at(i)) & 0xFFFF
	var bg_col : Color = PALETTE[hash_val % PALETTE.size()]
	var letter := "?"
	for i in address.length():
		var c := address.unicode_at(i)
		if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
			letter = address[i].to_upper()
			break
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx := size * 0.5; var cy := size * 0.5; var r := size * 0.5
	for y in size:
		for x in size:
			var dx := x - cx + 0.5; var dy := y - cy + 0.5
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, bg_col)
	# Draw letter (3×5 bitmap)
	const GLYPHS := {
		"0":[7,5,5,5,7],"1":[2,6,2,2,7],"2":[7,1,7,4,7],"3":[7,1,7,1,7],
		"4":[5,5,7,1,1],"5":[7,4,7,1,7],"6":[7,4,7,5,7],"7":[7,1,1,1,1],
		"8":[7,5,7,5,7],"9":[7,5,7,1,7],
		"A":[2,5,7,5,5],"B":[6,5,6,5,6],"C":[7,4,4,4,7],"D":[6,5,5,5,6],
		"E":[7,4,6,4,7],"F":[7,4,6,4,4],"G":[7,4,5,5,7],"H":[5,5,7,5,5],
		"I":[7,2,2,2,7],"J":[1,1,1,5,7],"K":[5,5,6,5,5],"L":[4,4,4,4,7],
		"M":[5,7,5,5,5],"N":[5,7,7,5,5],"O":[7,5,5,5,7],"P":[6,5,6,4,4],
		"Q":[7,5,5,7,1],"R":[6,5,6,5,5],"S":[7,4,7,1,7],"T":[7,2,2,2,2],
		"U":[5,5,5,5,7],"V":[5,5,5,5,2],"W":[5,5,5,7,5],"X":[5,5,2,5,5],
		"Y":[5,5,7,2,2],"Z":[7,1,2,4,7],
	}
	if letter in GLYPHS:
		var ps := maxi(1, size / 10)
		var glyph : Array = GLYPHS[letter]
		var gw := 3 * ps; var gh := 5 * ps
		var ox := (size - gw) / 2; var oy := (size - gh) / 2
		for row in 5:
			for col in 3:
				if glyph[row] & (4 >> col):
					for py in ps:
						for px in ps:
							var ix := ox + col * ps + px
							var iy := oy + row * ps + py
							if ix >= 0 and iy >= 0 and ix < size and iy < size:
								img.set_pixel(ix, iy, Color.WHITE)
	return ImageTexture.create_from_image(img)


func _data_url_to_texture(data_url: String) -> ImageTexture:
	if DisplayServer.get_name() == "headless": return null
	var comma_idx := data_url.find(",")
	if comma_idx < 0:
		return null
	var b64 := data_url.substr(comma_idx + 1)
	var raw : PackedByteArray = Marshalls.base64_to_raw(b64)
	if raw.is_empty():
		return null
	var img := Image.new()
	var err : int
	if data_url.begins_with("data:image/svg"):
		err = img.load_svg_from_buffer(raw)
		if err == OK:
			# SVG'yi sabit piksel boyutuna rasterize et
			img.load_svg_from_buffer(raw, int(_p(0.18)) / float(img.get_width()))
	else:
		err = img.load_png_from_buffer(raw)
	if err != OK:
		push_warning("[Nimiq] Failed to load avatar error=%d" % err)
		return null
	return ImageTexture.create_from_image(img)


## Nimiq wallet card: avatar circle + short address
## Placed below the title, in the upper section of the screen.
## Only shown when a Nimiq address exists.
func _build_avatar_card() -> void:
	if nimiq_address == "":
		return   # Guest — no card

	var ref   := _ref
	var av_sz := int(ref * 0.115)   # avatar circle diameter
	var card_h := int(ref * 0.155)

	# Card container — anchored to top-center of screen
	var card := HBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", int(ref * 0.022))
	# anchor at top-center (0.5, 0) so offsets are relative to screen center-top
	card.anchor_left   = 0.5
	card.anchor_right  = 0.5
	card.anchor_top    = 0.0
	card.anchor_bottom = 0.0
	var half_w := int(ref * 0.38)
	var top_y  := int(_ph(0.08)) + int(_p(0.105)) + int(ref * 0.03)
	card.offset_left   = -half_w
	card.offset_right  =  half_w
	card.offset_top    = top_y
	card.offset_bottom = top_y + card_h
	_ui_root.add_child(card)
	_avatar_card = card

	# ── Avatar circle ───────────────────────────────
	var av_wrap := Control.new()
	av_wrap.custom_minimum_size = Vector2(av_sz, av_sz)
	av_wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.add_child(av_wrap)

	# White border circle (no StyleBox — draw circle via clip)
	var av_panel := Panel.new()
	av_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var av_sb := StyleBoxFlat.new()
	av_sb.bg_color = Color(0.95, 0.95, 0.95, 1.0)
	av_sb.corner_radius_top_left     = av_sz / 2
	av_sb.corner_radius_top_right    = av_sz / 2
	av_sb.corner_radius_bottom_left  = av_sz / 2
	av_sb.corner_radius_bottom_right = av_sz / 2
	av_sb.border_color = Color(0.96, 0.70, 0.13, 1.0)  # Nimiq yellow
	av_sb.border_width_left   = int(ref * 0.006)
	av_sb.border_width_right  = int(ref * 0.006)
	av_sb.border_width_top    = int(ref * 0.006)
	av_sb.border_width_bottom = int(ref * 0.006)
	av_panel.add_theme_stylebox_override("panel", av_sb)
	av_wrap.add_child(av_panel)

	# Identicon texture — real Nimiq avatar on web, fallback otherwise
	var av_img := TextureRect.new()
	av_img.texture = _avatar_tex if _avatar_tex != null else _make_fallback_avatar(nimiq_address, av_sz)
	av_img.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	av_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	av_img.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	av_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	av_panel.add_child(av_img)

	# ── Right side: address + connected label ───────
	var info_col := VBoxContainer.new()
	info_col.alignment = BoxContainer.ALIGNMENT_CENTER
	info_col.add_theme_constant_override("separation", int(ref * 0.010))
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_col.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	card.add_child(info_col)

	# Nickname or short address (big)
	var display_name := _player_nickname if _player_nickname != "" else (nimiq_label if nimiq_label != "" else "")
	var name_lbl := Label.new()
	name_lbl.text = display_name
	UITheme.apply_label(name_lbl, Color(0.98, 0.98, 0.98, 1.0), int(ref * 0.038))
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info_col.add_child(name_lbl)

	# Short NIM address (dim, smaller)
	if nimiq_label != "" and display_name != nimiq_label:
		var addr_lbl := Label.new()
		addr_lbl.text = nimiq_label
		UITheme.apply_label(addr_lbl, Color(0.65, 0.65, 0.65, 1.0), int(ref * 0.026))
		if ResourceLoader.exists("res://assets/fonts/RobotoMono-Regular.ttf"):
			addr_lbl.add_theme_font_override("font", load("res://assets/fonts/RobotoMono-Regular.ttf"))
		info_col.add_child(addr_lbl)

# ─────────────────────────────────────────────────────
#  REPLAY SYSTEM
# ─────────────────────────────────────────────────────
func _on_replay_pressed() -> void:
	if not _gm or not _gm.has_method("has_replay") or not _gm.call("has_replay"):
		return
	var log_data : PackedByteArray = _gm.call("get_replay_log")
	var seed_val : int = int(_gm.get("game_seed"))
	var char_idx : int = int(_gm.get("_replay_char"))
	var player_seed_val : int = int(_gm.get("_replay_player_seed"))
	await _start_replay(seed_val, log_data, char_idx, "game_over", player_seed_val)


func _on_leaderboard_replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, _nickname: String, player_seed: int = 0) -> void:
	# _block_lb_replay guards against stale HTTP callbacks firing after PLAY is pressed.
	# But if the user is in the lobby viewing the leaderboard and presses a replay button,
	# _block_lb_replay may still be true from a previous game session. Reset it here so
	# a deliberate replay button press is never silently swallowed.
	if _started: return   # game is actively running — ignore
	_block_lb_replay = false
	# NOTE: visibility guard removed — LeaderboardPanel now emits replay_requested
	# before calling hide_panel() (deferred), so the panel is still visible here.
	await _start_replay(seed, replay_log, char_idx, "leaderboard", player_seed)


func _start_replay(seed: int, replay_log: PackedByteArray, char_idx: int, source: String, player_seed: int = 0) -> void:
	if replay_log.is_empty(): return
	_replay_source = source
	# Hide menus, show HUD
	_enter_replay_ui_pre()
	# Start GM — let it run a handful of frames so player initializes and
	# first platform/character appear, then freeze for countdown.
	if _gm.is_connected("replay_finished", _exit_replay_ui):
		_gm.disconnect("replay_finished", _exit_replay_ui)
	var nickname := "viewer" if source != "game_over" else ""
	# Pause BEFORE starting so player stays at spawn position during countdown.
	# Previously replay ran 3 frames before pausing — player had already jumped.
	_gm.call("set_replay_paused", true)
	_gm.call("start_replay_external", seed, replay_log, char_idx, nickname, player_seed)
	_gm.call("set_replay_speed", 1.0)
	# One frame so the scene renders the player at start position before countdown
	await get_tree().process_frame
	# 3-2-1 overlay (character visible behind it)
	await _show_replay_countdown()
	# Unpause and wire up finish signal + bar
	_gm.call("set_replay_paused", false)
	_gm.connect("replay_finished", _exit_replay_ui, CONNECT_ONE_SHOT)
	# Build replay bar (ticks are now ready)
	_build_replay_bar()


## Shows HUD + hides menus but does NOT build replay bar yet.
func _enter_replay_ui_pre() -> void:
	_calib_saved_hud_vis = is_instance_valid(_hud) and _hud.visible
	if is_instance_valid(_go_panel):
		_go_panel.visible = false
		if _go_panel.has_meta("dim"):
			var _dim = _go_panel.get_meta("dim")
			if is_instance_valid(_dim): _dim.visible = false
		if _go_panel.has_meta("container"):
			var _cont = _go_panel.get_meta("container")
			if is_instance_valid(_cont): _cont.visible = false
	if is_instance_valid(_bottom_bar):        _bottom_bar.visible        = false
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.visible = false
	if is_instance_valid(_quest_panel):       _quest_panel.visible       = false
	if is_instance_valid(_stats_panel):       _stats_panel.visible       = false
	if is_instance_valid(_settings_popup):    _settings_popup.visible    = false
	if is_instance_valid(_ui_layer):          _ui_layer.visible          = false
	if is_instance_valid(_hud):               _hud.visible               = true


## 3-2-1 countdown overlay before replay starts. Awaitable.
func _show_replay_countdown() -> void:
	const DIGIT_PATHS := [
		"res://assets/hud/hud3.png",
		"res://assets/hud/hud2.png",
		"res://assets/hud/hud1.png",
	]
	var cl := CanvasLayer.new()
	cl.layer = 30
	add_child(cl)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(root)

	# Dark semi-transparent overlay
	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)

	var img_rect := TextureRect.new()
	img_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	img_rect.custom_minimum_size = Vector2(_ref * 0.38, _ref * 0.38)
	img_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	img_rect.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	img_rect.anchor_left   = 0.5; img_rect.anchor_right  = 0.5
	img_rect.anchor_top    = 0.5; img_rect.anchor_bottom = 0.5
	img_rect.offset_left   = -_ref * 0.19
	img_rect.offset_right  =  _ref * 0.19
	img_rect.offset_top    = -_ref * 0.19
	img_rect.offset_bottom =  _ref * 0.19
	img_rect.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root.add_child(img_rect)

	for path in DIGIT_PATHS:
		if not ResourceLoader.exists(path): continue
		img_rect.texture  = load(path)
		img_rect.modulate = Color(1, 1, 1, 0.0)
		img_rect.scale    = Vector2(1.4, 1.4)

		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(img_rect, "modulate:a", 1.0, 0.18)
		tw.tween_property(img_rect, "scale",      Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		await tw.finished

		await get_tree().create_timer(0.55).timeout

		var tw2 := create_tween()
		tw2.tween_property(img_rect, "modulate:a", 0.0, 0.18)
		await tw2.finished

	cl.queue_free()


func _enter_replay_ui() -> void:
	_calib_saved_hud_vis = is_instance_valid(_hud) and _hud.visible
	# Close all UIs
	if is_instance_valid(_go_panel):
		_go_panel.visible = false
		# go_dim (siyah overlay) da gizle
		if _go_panel.has_meta("dim"):
			var _dim = _go_panel.get_meta("dim")
			if is_instance_valid(_dim): _dim.visible = false
		if _go_panel.has_meta("container"):
			var _cont = _go_panel.get_meta("container")
			if is_instance_valid(_cont): _cont.visible = false
	if is_instance_valid(_bottom_bar):        _bottom_bar.visible        = false
	if is_instance_valid(_leaderboard_panel): _leaderboard_panel.visible = false
	if is_instance_valid(_quest_panel):       _quest_panel.visible       = false
	if is_instance_valid(_stats_panel):       _stats_panel.visible       = false
	if is_instance_valid(_settings_popup):    _settings_popup.visible    = false
	if is_instance_valid(_ui_layer):          _ui_layer.visible          = false
	# Only HUD and replay bar visible during playback
	if is_instance_valid(_hud):               _hud.visible               = true
	_build_replay_bar()


# Common restore when returning to lobby/leaderboard/stats screen
func _restore_lobby_ui() -> void:
	_started = false
	_block_lb_replay = false
	# Clear replay state in GM — prevent old replay from starting on PLAY press
	if is_instance_valid(_gm):
		_gm.set("_replay_seed",        0)
		_gm.set("_replay_log",         PackedByteArray())
		_gm.set("_replay_nickname",     "")
		_gm.set("_replay_total_ticks",  0)
	if is_instance_valid(_ui_layer):
		_ui_layer.visible = true
	if is_instance_valid(_ui_root):
		_ui_root.modulate.a = 1.0
	if is_instance_valid(_hud):
		_hud.visible = false
	if is_instance_valid(_bottom_bar):
		_bottom_bar.visible = true


func _exit_replay_ui() -> void:
	if is_instance_valid(_replay_bar):
		_replay_bar.queue_free()
		_replay_bar = null

	var src := _replay_source
	_replay_source = ""

	match src:
		"game_over":
			# Was watching own replay — just return to game over panel
			# _ui_layer stays closed (play button, bottom bar must not show)
			if is_instance_valid(_hud):      _hud.visible      = _calib_saved_hud_vis
			if is_instance_valid(_go_panel): _go_panel.visible = true
			_show_go_panel()
		"leaderboard":
			_restore_lobby_ui()
			if is_instance_valid(_leaderboard_panel):
				_leaderboard_panel.show_panel()
				if _leaderboard_panel.has_method("refresh"):
					_leaderboard_panel.call("refresh")
		"stats":
			_restore_lobby_ui()
			if is_instance_valid(_stats_panel):
				_stats_panel.show_panel()
		_:
			_restore_lobby_ui()

# Fonksiyon dışı, sınıfın en başında tanımlanması gereken değişken:
# var _replay_speed_idx : int = 0 
var _replay_speed_idx: int = 0

func _build_replay_bar() -> void:
	# --- REPLAY HER AÇILDIĞINDA HIZI 1X'E SIFIRLAMA KISMI ---
	_replay_speed_idx = 0
	if is_instance_valid(_gm):
		_gm.call("set_replay_speed", 1.0)
	# --------------------------------------------------------

	if is_instance_valid(_replay_bar):
		_replay_bar.queue_free()
	_replay_bar = CanvasLayer.new()
	_replay_bar.layer = 25
	add_child(_replay_bar)

	const C_MID    := Color(0.480, 0.340, 0.200)
	const C_TRACK  := Color(0.820, 0.760, 0.680)
	const C_BG     := Color(0.957, 0.898, 0.800)
	const C_BORDER := Color(0.700, 0.520, 0.340)
	var   C_ORANGE := UITheme.COL_ORANGE

	var seek_h  : float = _p(0.028)
	var pad_x   : float = _p(0.030)
	var pad_top : float = _p(0.016)
	var pad_bot : float = _p(0.016)
	var pad_sep : float = _p(0.012)
	var btn_h   : float = _p(0.085)
	var bar_h   : float = pad_top + seek_h * 3.2 + pad_sep + btn_h + pad_bot
	var sep     : int   = int(pad_sep)
	var fs_sm   : int   = int(_p(0.026))
	var ic_sm   : int   = int(btn_h * 0.50)
	var ic_lg   : int   = int(btn_h * 0.48)

	var _tick      : Array[int]  = [int(_gm.get("_replay_tick_count"))   if is_instance_valid(_gm) else 0]
	var _total     : Array[int]  = [maxi(1, int(_gm.get("_replay_total_ticks")) if is_instance_valid(_gm) else 1)]
	var _paused    : Array[bool] = [bool(_gm.get("_replay_paused"))      if is_instance_valid(_gm) else false]
	var _finished  : Array[bool] = [false]
	var _drag      : Array[bool] = [false]
	var _touch_idx : Array[int]  = [-1]
	var _drag_pct  : Array[float]= [0.0] 

	var _at := UITheme.get_theme_assets()
	var _load_icon := func(key: String) -> Texture2D:
		var path : String = _at.get(key, "")
		if path != "" and ResourceLoader.exists(path):
			return load(path) as Texture2D
		return null

	var _tex_play  : Texture2D = _load_icon.call("icon_play")
	var _tex_pause : Texture2D = _load_icon.call("icon_pause")
	var _tex_left  : Texture2D = _load_icon.call("icon_arrow_left")
	var _tex_right : Texture2D = _load_icon.call("icon_arrow_right")
	var _tex_x     : Texture2D = null
	if ResourceLoader.exists("res://assets/hud/hudX.png"):
		_tex_x = load("res://assets/hud/hudX.png")

	var _set_icon := func(b: Button, tex: Texture2D, ic_size: int):
		b.icon = tex
		b.text = ""
		b.expand_icon = true
		b.icon_alignment          = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width",  ic_size)
		b.add_theme_constant_override("icon_max_height", ic_size)

	var pause_btn : Button = null
	
	var _refresh_pause_icon := func(btn: Button):
		if not is_instance_valid(btn): return
		var use_play : bool = _finished[0] or _paused[0]
		var tex : Texture2D = _tex_play if use_play else _tex_pause
		if tex == null: return
		btn.text = ""
		btn.icon = tex
		btn.expand_icon = true
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		btn.add_theme_constant_override("icon_max_width", ic_lg)
		btn.add_theme_constant_override("icon_max_height", ic_lg)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_replay_bar.add_child(root)

	var panel_bg := Panel.new()
	var ps := StyleBoxFlat.new()
	ps.bg_color                   = C_BG
	ps.border_color               = C_BORDER
	ps.border_width_top           = 2
	ps.corner_radius_top_left     = int(_p(0.022))
	ps.corner_radius_top_right    = int(_p(0.022))
	ps.corner_radius_bottom_left  = 0
	ps.corner_radius_bottom_right = 0
	panel_bg.add_theme_stylebox_override("panel", ps)
	panel_bg.anchor_left    = 0.0; panel_bg.anchor_right  = 1.0
	panel_bg.anchor_top     = 1.0; panel_bg.anchor_bottom = 1.0
	panel_bg.offset_top     = -bar_h
	panel_bg.offset_bottom  = 0.0
	panel_bg.mouse_filter   = Control.MOUSE_FILTER_STOP
	root.add_child(panel_bg)

	var content := VBoxContainer.new()
	content.anchor_left   = 0.0; content.anchor_right  = 1.0
	content.anchor_top    = 1.0; content.anchor_bottom = 1.0
	content.offset_top    = -bar_h + pad_top
	content.offset_bottom = -pad_bot
	content.offset_left   = pad_x
	content.offset_right  = -pad_x
	content.add_theme_constant_override("separation", int(pad_sep))
	content.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root.add_child(content)

	var seek_hit := Control.new()
	seek_hit.custom_minimum_size   = Vector2(0, seek_h * 3.2)
	seek_hit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seek_hit.mouse_filter          = Control.MOUSE_FILTER_STOP
	content.add_child(seek_hit)

	var seek_bar := ProgressBar.new()
	seek_bar.min_value = 0.0; seek_bar.max_value = 1.0; seek_bar.value = 0.0
	seek_bar.show_percentage   = false
	seek_bar.custom_minimum_size = Vector2(0, seek_h)
	seek_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seek_bar.anchor_top    = 0.5; seek_bar.anchor_bottom = 0.5
	seek_bar.anchor_left   = 0.0; seek_bar.anchor_right  = 1.0
	seek_bar.offset_top    = -seek_h * 0.5
	seek_bar.offset_bottom =  seek_h * 0.5
	seek_bar.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	var sb_bg   := StyleBoxFlat.new(); sb_bg.bg_color   = C_TRACK; sb_bg.set_corner_radius_all(int(seek_h*0.5))
	var sb_fill := StyleBoxFlat.new(); sb_fill.bg_color = C_ORANGE; sb_fill.set_corner_radius_all(int(seek_h*0.5))
	seek_bar.add_theme_stylebox_override("background", sb_bg)
	seek_bar.add_theme_stylebox_override("fill",       sb_fill)
	seek_hit.add_child(seek_bar)

	var head_sz    : float = seek_h * 1.3
	var head_panel := TextureRect.new()
	head_panel.texture      = _load_icon.call("slider_grabber")
	head_panel.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head_panel.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	head_panel.custom_minimum_size = Vector2(head_sz, head_sz)
	head_panel.anchor_top    = 0.5; head_panel.anchor_bottom = 0.5
	head_panel.anchor_left   = 0.0; head_panel.anchor_right  = 0.0
	head_panel.offset_top    = -head_sz * 0.5; head_panel.offset_bottom = head_sz * 0.5
	head_panel.offset_left   = -head_sz * 0.5; head_panel.offset_right  = head_sz * 0.5
	head_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	seek_hit.add_child(head_panel)

	var _seek_width := func() -> float:
		var w : float = seek_hit.size.x
		if w <= 0.0: w = seek_hit.get_rect().size.x
		if w <= 0.0: w = _vw - pad_x * 2.0
		return w

	var _update_visual := func(local_x: float):
		var w : float = _seek_width.call()
		if w <= 0.0: return
		var pct : float = clampf(local_x / w, 0.0, 1.0)
		_drag_pct[0] = pct
		if is_instance_valid(seek_bar):
			seek_bar.value = pct
		if is_instance_valid(head_panel):
			head_panel.offset_left  = w * pct - head_sz * 0.5
			head_panel.offset_right = w * pct + head_sz * 0.5

	var _commit_seek := func():
		var target : int = int(_drag_pct[0] * float(_total[0]))
		if is_instance_valid(_gm) and _gm.has_method("seek_to_tick"):
			_gm.call("seek_to_tick", target)
			_tick[0]   = int(_gm.get("_replay_tick_count"))
			_paused[0] = bool(_gm.get("_replay_paused"))
		if _finished[0]:
			_finished[0] = false; _paused[0] = false
			if is_instance_valid(_gm): _gm.call("set_replay_paused", false)
		_refresh_pause_icon.call(pause_btn)

	seek_hit.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				_drag[0] = true
				_update_visual.call(ev.position.x)
			else:
				if _drag[0]: _commit_seek.call()
				_drag[0] = false
			get_viewport().set_input_as_handled()
		elif ev is InputEventMouseMotion and _drag[0]:
			_update_visual.call(ev.position.x)
			get_viewport().set_input_as_handled()
		elif ev is InputEventScreenTouch:
			if ev.pressed:
				_drag[0]      = true
				_touch_idx[0] = ev.index
				_update_visual.call(ev.position.x)
				get_viewport().set_input_as_handled()
			elif ev.index == _touch_idx[0]:
				if _drag[0]: _commit_seek.call()
				_drag[0]      = false
				_touch_idx[0] = -1
		elif ev is InputEventScreenDrag and ev.index == _touch_idx[0]:
			_update_visual.call(ev.position.x)
			get_viewport().set_input_as_handled()
	)

	panel_bg.gui_input.connect(func(ev: InputEvent):
		if not _drag[0]: return
		if ev is InputEventMouseMotion:
			_update_visual.call(ev.position.x - pad_x)
		elif ev is InputEventScreenDrag and ev.index == _touch_idx[0]:
			_update_visual.call(ev.position.x - pad_x)
		elif ev is InputEventMouseButton and not ev.pressed:
			_commit_seek.call()
			_drag[0] = false
		elif ev is InputEventScreenTouch and not ev.pressed and ev.index == _touch_idx[0]:
			_commit_seek.call()
			_drag[0]      = false
			_touch_idx[0] = -1
	)

	var _sync_initial_head := func():
		var w : float = _seek_width.call()
		if w > 0.0 and is_instance_valid(head_panel):
			var pct0 : float = float(_tick[0]) / float(maxi(_total[0], 1))
			head_panel.offset_left  = w * pct0 - head_sz * 0.5
			head_panel.offset_right = w * pct0 + head_sz * 0.5
	_sync_initial_head.call_deferred()

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", sep)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(hbox)

	var _mk_btn := func(min_w: float) -> Button:
		var b := Button.new()
		b.custom_minimum_size = Vector2(min_w, btn_h)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		UITheme.apply_button(b)
		return b

	var _mk_play_btn := func(min_w: float) -> Button:
		var b := Button.new()
		b.custom_minimum_size = Vector2(min_w, btn_h)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		UITheme.apply_play_button(b)
		return b

	var _mk_ghost_btn := func(min_w: float) -> Button:
		var b := Button.new()
		b.custom_minimum_size = Vector2(min_w, btn_h)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		UITheme.apply_ghost_button(b)
		return b

	var side_w : float = btn_h * 1.5

	var bk_btn := _mk_btn.call(side_w) as Button
	_set_icon.call(bk_btn, _tex_left, ic_sm)
	bk_btn.pressed.connect(func():
		if not is_instance_valid(_gm): return
		var t : int = int(_gm.get("_replay_tick_count"))
		_gm.call("seek_to_tick", maxi(0, t - 60))
		_tick[0]   = int(_gm.get("_replay_tick_count"))
		_paused[0] = bool(_gm.get("_replay_paused"))
		if _finished[0]: _finished[0] = false; _paused[0] = false; _gm.call("set_replay_paused", false)
		_refresh_pause_icon.call(pause_btn)
	)
	hbox.add_child(bk_btn)

	pause_btn = _mk_play_btn.call(btn_h * 2.4) as Button
	pause_btn.pressed.connect(func():
		if not is_instance_valid(_gm): return
		if _finished[0]:
			_finished[0] = false; _paused[0] = false
			_gm.call("seek_to_tick", 0)
			_gm.call("set_replay_paused", false)
			_refresh_pause_icon.call(pause_btn)
			return
		_paused[0] = not bool(_gm.get("_replay_paused"))
		_gm.call("set_replay_paused", _paused[0])
		_refresh_pause_icon.call(pause_btn)
	)
	hbox.add_child(pause_btn)
	_refresh_pause_icon.call_deferred(pause_btn)

	var fw_btn := _mk_btn.call(side_w) as Button
	_set_icon.call(fw_btn, _tex_right, ic_sm)
	fw_btn.pressed.connect(func():
		if not is_instance_valid(_gm): return
		var t : int = int(_gm.get("_replay_tick_count"))
		_gm.call("seek_to_tick", mini(_total[0], t + 60))
		_tick[0]   = int(_gm.get("_replay_tick_count"))
		_paused[0] = bool(_gm.get("_replay_paused"))
		_refresh_pause_icon.call(pause_btn)
	)
	hbox.add_child(fw_btn)

	# --- HIZ BUTONU DEĞİŞTİRİLEN KISIM ---
	var _spd_vals : Array[float]  = [1.0, 2.0, 4.0, 0.5]
	var _spd_lbls : Array[String] = ["1x", "2x", "4x", "0.5x"] 

	var spd_btn := _mk_ghost_btn.call(btn_h * 1.8) as Button
	spd_btn.text = _spd_lbls[_replay_speed_idx]
	spd_btn.add_theme_font_size_override("font_size", fs_sm)
	
	spd_btn.pressed.connect(func():
		if not is_instance_valid(spd_btn): return
		
		# Sınıf değişkeni güncelleniyor
		_replay_speed_idx = (_replay_speed_idx + 1) % _spd_vals.size()
		var spd : float = _spd_vals[_replay_speed_idx]
		
		if is_instance_valid(_gm): 
			_gm.call("set_replay_speed", spd)
			
		spd_btn.text = _spd_lbls[_replay_speed_idx]
		
		if spd != 1.0: 
			UITheme.apply_play_button(spd_btn)
		else:          
			UITheme.apply_ghost_button(spd_btn)
			
		spd_btn.add_theme_font_size_override("font_size", fs_sm)
	)
	hbox.add_child(spd_btn)
	# ------------------------------------

	var tick_lbl := Label.new()
	tick_lbl.text = "0:00 / 0:00"
	tick_lbl.add_theme_font_size_override("font_size", fs_sm)
	tick_lbl.add_theme_color_override("font_color", C_MID)
	tick_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tick_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	tick_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	tick_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(tick_lbl)

	var exit_btn := _mk_btn.call(side_w) as Button
	# Not: Button.icon yalnızca "icon_max_width" ile sınırlanır, "icon_max_height" diye
	# bir theme constant Godot'ta yok — bu yüzden kare olmayan hudX.png buton sınırlarının
	# dışına taşabiliyordu. Çözüm: dosyanın başka yerinde (close_ic2, satır ~2534) zaten
	# kanıtlanmış olan CenterContainer + TextureRect(KEEP_ASPECT_CENTERED + IGNORE_SIZE)
	# pattern'ini birebir kullanıyoruz.
	if _tex_x != null:
		var x_center := CenterContainer.new()
		x_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		x_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		exit_btn.add_child(x_center)
		var x_icon := TextureRect.new()
		x_icon.texture = _tex_x
		x_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		x_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		x_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		x_icon.custom_minimum_size = Vector2(ic_sm, ic_sm)
		x_center.add_child(x_icon)
	else:
		_set_icon.call(exit_btn, _tex_x, ic_sm)
	exit_btn.pressed.connect(func():
		if is_instance_valid(_gm):
			if _gm.is_connected("replay_finished", _exit_replay_ui):
				_gm.disconnect("replay_finished", _exit_replay_ui)
			_gm.call("stop_replay")
		_exit_replay_ui()
	)
	hbox.add_child(exit_btn)

	if not is_instance_valid(_gm) or not _gm.has_signal("replay_tick_changed"): return
	for c in _gm.get_signal_connection_list("replay_tick_changed"):
		if c.has("callable"): _gm.disconnect("replay_tick_changed", c["callable"])

	_gm.connect("replay_tick_changed", func(tick: int, total: int):
		_tick[0]  = tick
		_total[0] = maxi(total, 1)

		if not _drag[0]:
			var pct : float = float(tick) / float(_total[0])
			if is_instance_valid(seek_bar):
				seek_bar.value = pct
			if is_instance_valid(head_panel) and is_instance_valid(seek_hit):
				var w : float = seek_hit.size.x
				if w <= 0.0: w = seek_hit.get_rect().size.x
				if w > 0.0:
					head_panel.offset_left  = w * pct - head_sz * 0.5
					head_panel.offset_right = w * pct + head_sz * 0.5

		if is_instance_valid(tick_lbl):
			var s  : int = tick / 60;        var sm : int = s  % 60; var sh : int = s  / 60
			var ts : int = _total[0] / 60;   var tm : int = ts % 60; var th : int = ts / 60
			tick_lbl.text = "%d:%02d / %d:%02d" % [sh, sm, th, tm]

		var _gm_paused : bool = bool(_gm.get("_replay_paused"))
		if _gm_paused != _paused[0] and not _finished[0]:
			_paused[0] = _gm_paused
			_refresh_pause_icon.call(pause_btn)

		if tick >= _total[0] and not _finished[0]:
			_finished[0] = true; _paused[0] = true
			if is_instance_valid(_gm): _gm.call("set_replay_paused", true)
			_refresh_pause_icon.call(pause_btn)
	)

func apply_selected_background() -> void:
	var tex : Texture2D = UITheme.get_background_texture(_bg_selected)
	if is_instance_valid(_bg_rect):  _bg_rect.texture  = tex
	if is_instance_valid(_bg_rect2):
		_bg_rect2.texture    = tex
		_bg_rect2.modulate.a = 0.0

func transition_background(biome_id: String) -> void:
	if not _bg_auto: return   # Manuel modda biome geçişi devre dışı
	if not is_instance_valid(_bg_rect) or not is_instance_valid(_bg_rect2): return
	var new_tex : Texture2D = UITheme.get_background_texture_by_id(biome_id)
	if new_tex == null: return
	# Candy biome — pembemsi tint
	var tint := Color(1.0, 1.0, 1.0, 1.0)
	if biome_id == "candy":
		tint = Color(1.0, 0.82, 0.92, 1.0)
	_bg_rect2.texture    = new_tex
	_bg_rect2.modulate   = Color(tint.r, tint.g, tint.b, 0.0)
	var tw := create_tween()
	tw.tween_property(_bg_rect2, "modulate", tint, 1.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func():
		_bg_rect.texture   = new_tex
		_bg_rect.modulate  = tint
		_bg_rect2.modulate = Color(tint.r, tint.g, tint.b, 0.0)
	)
	# Geçiş yaratığı kaldırıldı


func _spawn_transition_creature(biome_id: String) -> void:
	# Biome'a göre texture ve renk seç
	var tex_path : String
	var tint     : Color
	match biome_id:
		"desert":
			tex_path = "res://assets/enemies/bee/move.png"
			tint     = Color(1.5, 1.2, 0.2, 0.55)
		"fall":
			tex_path = "res://assets/enemies/worm_green/idle.png"
			tint     = Color(1.2, 0.6, 0.2, 0.50)
		"sky":
			tex_path = "res://assets/enemies/flyman/fly.png"
			tint     = Color(0.6, 0.4, 1.5, 0.50)
		"candy":
			tex_path = "res://assets/enemies/ufo/ufo_idle.png"
			tint     = Color(1.5, 0.5, 1.2, 0.55)   # pembe/mor UFO
		_:  # grass (döngü başı)
			tex_path = "res://assets/enemies/sun/idle1.png"
			tint     = Color(0.4, 0.8, 1.5, 0.45)

	if not ResourceLoader.exists(tex_path): return
	var tex : Texture2D = load(tex_path)
	if tex == null: return

	# Silüet sprite — CanvasLayer 5 (HUD'un altında, oyunun üstünde)
	var cl := CanvasLayer.new()
	cl.layer = 5
	add_child(cl)

	var spr := Sprite2D.new()
	spr.texture      = tex
	spr.modulate     = Color(tint.r, tint.g, tint.b, 0.0)
	spr.z_index      = 10
	cl.add_child(spr)

	# 5x büyüt — dev silüet
	var base_sc : float = (_vw * 0.55) / maxf(float(tex.get_width()), 1.0)
	spr.scale = Vector2(base_sc, base_sc)

	# Sağdan sola kayarak geçer, ekranın ortasında belirir
	var start_x : float = _vw + _vw * 0.35
	var end_x   : float = -_vw * 0.35
	var mid_y   : float = _vh * 0.38

	spr.global_position = Vector2(start_x, mid_y)

	var dur : float = 2.4
	var tw2 := spr.create_tween()
	if tw2:
		# Fade in (0→tint.a) ilk 0.35 sn
		tw2.tween_property(spr, "modulate:a", tint.a, 0.35)
		# Hareket: sağdan sola
		tw2.parallel().tween_property(spr, "global_position:x", end_x, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		# Fade out son 0.5 sn
		tw2.tween_property(spr, "modulate:a", 0.0, 0.5).set_delay(dur - 0.85)
		tw2.tween_callback(func():
			if is_instance_valid(cl): cl.queue_free()
		)


# ─────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────
#  DEBUG OVERLAY
# ─────────────────────────────────────────────────────
var _dbg_layer  : CanvasLayer = null

func _open_overlay_debug() -> void:
	if is_instance_valid(_dbg_layer): return
	if not is_instance_valid(_player): return

	var info : Dictionary = _player.call("debug_get_info")
	var sy   : float = info.get("sy", 0.0)
	var sw   : float = info.get("sw", 20.0)
	var jp   : Vector2 = info.get("jp_pos", Vector2(0, sy))
	var wl   : Vector2 = info.get("wl_pos", Vector2(sw * 0.55, sy))

	_dbg_layer = CanvasLayer.new()
	_dbg_layer.layer = 100
	add_child(_dbg_layer)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	_dbg_layer.add_child(bg)

	var root := VBoxContainer.new()
	root.anchor_left = 0.0; root.anchor_right = 1.0
	root.anchor_top  = 0.0; root.anchor_bottom = 0.0
	root.offset_left = 20; root.offset_right = -20
	root.offset_top  = 60
	root.add_theme_constant_override("separation", 14)
	_dbg_layer.add_child(root)

	var title := Label.new()
	title.text = "OVERLAY DEBUG"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color.YELLOW)
	root.add_child(title)

	var ref_lbl := Label.new()
	ref_lbl.text = "sy=%.1f  sw=%.1f  jp=%s  wl=%s" % [sy, sw, jp, wl]
	ref_lbl.add_theme_font_size_override("font_size", 16)
	ref_lbl.add_theme_color_override("font_color", Color.WHITE)
	root.add_child(ref_lbl)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func():
		if is_instance_valid(_dbg_layer):
			_dbg_layer.queue_free()
			_dbg_layer = null
	)
	root.add_child(close_btn)


func _update_torch_state() -> void:
	if _torch_rects.is_empty(): return
	var ready : bool = is_instance_valid(_play_btn) and not _play_btn.disabled
	var tex_off := _TEX_TORCH_OFF
	var tex_a   := _TEX_TORCH_ON_A
	var tex_b   := _TEX_TORCH_ON_B

	if is_instance_valid(_torch_tween): _torch_tween.kill()

	if not ready:
		for t in _torch_rects:
			if is_instance_valid(t): t.texture = tex_off
		return

	# Flicker animation — between a/b
	_torch_tween = create_tween().set_loops()
	for t in _torch_rects:
		if is_instance_valid(t): t.texture = tex_a
	_torch_tween.tween_callback(func():
		for t in _torch_rects:
			if is_instance_valid(t): t.texture = tex_b
	).set_delay(0.25)
	_torch_tween.tween_callback(func():
		for t in _torch_rects:
			if is_instance_valid(t): t.texture = tex_a
	).set_delay(0.25)






class _ArcBar extends Control:
	var t_max    : float = 5.0
	var is_debuff: bool  = false
	var radius   : float = 0.0

	# t_cur setter — her değişimde redraw tetikle (yoksa _draw hiç çalışmaz)
	var _t_cur   : float = 5.0
	var t_cur    : float:
		get: return _t_cur
		set(v):
			_t_cur = v
			queue_redraw()

	# Cached geometry — rebuilt only when size changes
	var _geo_top         : Vector2
	var _geo_right       : Vector2
	var _geo_bot         : Vector2
	var _geo_left        : Vector2
	var _geo_cr          : float   = 0.0
	var _geo_th          : float   = 0.0
	var _geo_line_lens   : Array[float]   = []
	var _geo_arc_lens    : Array[float]   = []
	var _geo_arc_sweeps  : Array[float]   = []
	var _geo_centers     : Array[Vector2] = []
	var _geo_real_radii  : Array[float]   = []
	var _geo_angles_from : Array[float]   = []
	var _geo_total_len   : float   = 0.0
	var _geo_corners     : Array[Vector2] = []
	var _geo_size        : Vector2 = Vector2.ZERO

	func _ready() -> void:
		item_rect_changed.connect(_rebuild_geo)

	func _rebuild_geo() -> void:
		if size.x <= 0.0 or size.y <= 0.0: return
		if size == _geo_size: return
		_geo_size = size
		var ref := minf(size.x, size.y)
		_geo_th  = maxf(ref * 0.05, 0.5)
		var cx  := size.x * 0.5; var cy := size.y * 0.5; var pad := 2.0
		_geo_top   = Vector2(cx,           pad)
		_geo_right = Vector2(size.x - pad, cy)
		_geo_bot   = Vector2(cx,           size.y - pad)
		_geo_left  = Vector2(pad,          cy)
		_geo_cr    = size.x * 0.08
		_geo_corners = [_geo_top, _geo_right, _geo_bot, _geo_left, _geo_top]
		_geo_line_lens.clear(); _geo_arc_lens.clear(); _geo_arc_sweeps.clear()
		_geo_centers.clear();   _geo_real_radii.clear(); _geo_angles_from.clear()
		_geo_total_len = 0.0
		for i in 4:
			var a := _geo_corners[i]; var b := _geo_corners[i+1]; var c := _geo_corners[(i+2)%4]
			var ab := (b-a).normalized(); var bc := (c-b).normalized()
			var line_l := maxf(a.distance_to(b) - _geo_cr * 2.0, 0.0)
			_geo_line_lens.append(line_l); _geo_total_len += line_l
			var half_angle  := absf((-ab).angle_to(bc)) * 0.5
			var real_radius := _geo_cr * tan(half_angle)
			var center      := b + (-ab + bc).normalized() * (_geo_cr / cos(half_angle))
			var angle_from  := (b - ab * _geo_cr - center).angle()
			var angle_to    := (b + bc * _geo_cr - center).angle()
			if angle_to < angle_from: angle_to += TAU
			var sweep := angle_to - angle_from
			var arc_l := real_radius * sweep
			_geo_arc_lens.append(arc_l); _geo_arc_sweeps.append(sweep)
			_geo_centers.append(center); _geo_real_radii.append(real_radius)
			_geo_angles_from.append(angle_from)
			_geo_total_len += arc_l

	func _draw() -> void:
		if t_max <= 0.0: return
		if size != _geo_size: _rebuild_geo()
		if _geo_total_len <= 0.0: return
		var ratio := clampf(t_cur / t_max, 0.0, 1.0)
		var col : Color
		if ratio > 0.25:
			col = Color(1.0, 1.0, 1.0, 0.92)
		else:
			var f := ratio / 0.25
			col = Color(1.0, f * 0.8, f * 0.8, 0.92)
		_draw_diamond(Color(1, 1, 1, 0.15))
		_draw_diamond_partial(ratio, col)

	func _draw_diamond(col: Color) -> void:
		for i in 4:
			var a  := _geo_corners[i]; var b := _geo_corners[i + 1]; var c := _geo_corners[(i + 2) % 4]
			var ab := (b - a).normalized(); var bc := (c - b).normalized()
			draw_line(a + ab * _geo_cr, b - ab * _geo_cr, col, _geo_th, true)
			var half_angle  := absf((-ab).angle_to(bc)) * 0.5
			var real_radius := _geo_cr * tan(half_angle)
			var center      := b + (-ab + bc).normalized() * (_geo_cr / cos(half_angle))
			var angle_from  := (b - ab * _geo_cr - center).angle()
			var angle_to    := (b + bc * _geo_cr - center).angle()
			if angle_to < angle_from: angle_to += TAU
			draw_arc(center, real_radius, angle_from, angle_to, 24, col, _geo_th, true)

	func _draw_diamond_partial(ratio: float, col: Color) -> void:
		var target := _geo_total_len * ratio
		var drawn  := 0.0
		for i in 4:
			var a := _geo_corners[i]; var b := _geo_corners[i+1]
			var ab := (b-a).normalized(); var p0 := a + ab * _geo_cr
			var line_l := _geo_line_lens[i]
			if drawn < target and line_l > 0.0:
				var remain := target - drawn; var t := minf(remain / line_l, 1.0)
				draw_line(p0, p0.lerp(b - ab * _geo_cr, t), col, _geo_th, true)
				drawn += line_l * t
			var arc_l := _geo_arc_lens[i]
			if drawn < target and arc_l > 0.0:
				var remain := target - drawn; var t := minf(remain / arc_l, 1.0)
				draw_arc(_geo_centers[i], _geo_real_radii[i], _geo_angles_from[i],
					_geo_angles_from[i] + _geo_arc_sweeps[i] * t, 24, col, _geo_th, true)
				drawn += arc_l * t


# ═══════════════════════════════════════════════════════════════════════
#  DIGIT DISPLAY (inner class)  —  Numeric score display
# ═══════════════════════════════════════════════════════════════════════

class _DigitDisplay extends HBoxContainer:
	var _digit_size : int = 0
	var _textures   : Array[Texture2D] = []
	var _sprites    : Array[TextureRect] = []
	var _loaded     := false

	func _init(digit_height: int = 0) -> void:
		_digit_size = digit_height
		alignment             = BoxContainer.ALIGNMENT_CENTER
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		size_flags_vertical   = Control.SIZE_SHRINK_CENTER

	func _ready() -> void:
		if _digit_size <= 0:
			var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
			_digit_size = int(ref * 0.033)
		var sep := -int(_digit_size * 0.25)
		add_theme_constant_override("separation", sep)
		_load_textures()
		show_number(0)

	func _load_textures() -> void:
		if _loaded: return
		_loaded = true
		_textures.clear()
		for i in 10:
			var path := "res://assets/hud/hud%d.png" % i
			if ResourceLoader.exists(path):
				_textures.append(load(path))
			else:
				if DisplayServer.get_name() != "headless":
					var fw  := maxi(int(_digit_size * 0.7), 1)
					var fh  := maxi(_digit_size, 1)
					var img := Image.create(fw, fh, false, Image.FORMAT_RGBA8)
					img.fill(Color(1, 1, 1, 0))
					_textures.append(ImageTexture.create_from_image(img))
				else:
					_textures.append(null)

	func show_number(n: int) -> void:
		if not _loaded: _load_textures()
		var s : String = str(maxi(n, 0))
		while _sprites.size() < s.length():
			var tr := TextureRect.new()
			tr.stretch_mode       = TextureRect.STRETCH_SCALE
			tr.expand_mode        = TextureRect.EXPAND_IGNORE_SIZE
			tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			add_child(tr)
			_sprites.append(tr)
		for i in _sprites.size():
			_sprites[i].visible = i < s.length()
		for i in s.length():
			var digit := s.unicode_at(i) - 48
			var tex : Texture2D = _textures[digit] if digit < _textures.size() else null
			var tr    := _sprites[i]
			tr.texture = tex
			if tex and tex.get_height() > 0:
				var scale_f := float(_digit_size) / float(tex.get_height())
				var w       := int(tex.get_width() * scale_f)
				tr.custom_minimum_size = Vector2(w, _digit_size)
				tr.size               = Vector2(w, _digit_size)
			else:
				tr.custom_minimum_size
