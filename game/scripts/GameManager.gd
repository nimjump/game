extends Node2D

static var _is_headless : bool = DisplayServer.get_name() == "headless"


## Headless replay sim runs thousands of ticks in one frame — queue_free() never
## flushes until a frame ends, so nodes pile up and the worker times out.
func _discard_node(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	# NOTE: always use queue_free(), even in headless mode. A synchronous
	# free() here destroys the node immediately, but other objects can still
	# hold a live reference to it (e.g. a platform's `platform_broke` lambda
	# capturing the enemy that stood on it — see _spawn_enemy_on_platform).
	# If that signal/lambda fires after a hard free(), Godot detects the
	# freed capture and logs "Lambda capture ... was freed" (best case) or
	# crashes on a true use-after-free (worst case — this is the same root
	# cause as the earlier 0xc0000005 native crash). queue_free() defers
	# destruction to the end of the frame, which is still processed every
	# tick in headless/server mode, so this costs nothing functionally.
	n.queue_free()

## Emitted when platforms have spawned and the game is ready to play.
signal ready_to_play

# ── Input edge-latch (catch-up-burst-proof) ──────────────────────────────
# Input.is_action_pressed() only reflects the CURRENT polled state at the
# instant it's called. When render FPS drops below the fixed 60Hz physics
# rate (mobile/web under load, backgrounded tab resuming, lag spike), Godot
# runs several _physics_process() calls back-to-back to catch up
# (Project Settings > physics > common > max_physics_steps_per_frame) with
# ZERO new input events processed in between those calls — every tick in
# that burst reads the exact same is_action_pressed() result. A very short
# tap that starts AND ends entirely inside one such burst is therefore
# invisible to is_action_pressed() on EVERY tick of that burst, and never
# makes it into the RLE replay log at all — the input is silently dropped
# during recording itself, independent of any client/server sim mismatch.
# This is almost certainly the real source of "left/right doesn't register
# 100% of the time" reports.
#
# FIX: _input() fires once per real OS input event (key down/up), not once
# per rendered frame, so it can't miss an edge the way polling can. Latch
# the press edge into a one-shot "pending" flag here, OR it into the normal
# is_action_pressed() read at the actual tick-consumption site below, and
# clear it after exactly one tick has consumed it — so a fast tap is
# guaranteed to register for at least one simulated tick, but never gets
# artificially stretched across more than one.
# NOTE: only feeds the KEYBOARD fallback path (used when Main isn't driving
# control, e.g. editor/desktop testing without Main.gd's touch/gyro layer).
# The primary touch/gyro path is fixed the same way in Main.gd.
var _kb_left_pending  := false
var _kb_right_pending := false

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left") or event.is_action_pressed("move_left"):
		_kb_left_pending = true
	if event.is_action_pressed("ui_right") or event.is_action_pressed("move_right"):
		_kb_right_pending = true

# ── Screen dimensions — single source of truth: GameConstants ───────
var VW : float = GameConstants.VW
var VH : float = GameConstants.VH

# ── Cached layout constants (set in init, never change after) ────────
var PLATFORM_W   : float = 0.0
var PLATFORM_H   : float = 0.0
var SPAWN_ABOVE  : float = 0.0
var DESPAWN_BELOW: float = 0.0
var BASE_GAP     : float = 0.0
var MAX_GAP      : float = 0.0

var JETPACK_GAP : float = 9999.0

const DIFFICULTY_RATE := 0.00012
const ENEMY_BASE_PROB  := 0.25
const ENEMY_MAX_PROB   := 0.40
const BROKEN_BASE_PROB := 0.05
const CARD_PROB        := 0.02   # Şans kartı — item'dan bağımsız, sabit %2
# ITEM_BASE_PROB kaldırıldı — item çıkma ihtimali artık _item_spawn_prob()
# içinde, nimiq/carrot/golden_carrot ağırlıklarından dinamik hesaplanıyor.

# ── Referanslar ─────────────────────────────────────────────────────
var camera      : Camera2D
var player      : CharacterBody2D
var main_node   : Node
var _main_has_control    : bool = false
var _main_has_score      : bool = false
var _main_has_best       : bool = false
var _main_has_pwrup_hud  : bool = false

# ── Oyun durumu ─────────────────────────────────────────────────────
var highest_y   := 0  # int — deterministic score independent of float drift
var score       := 0
var best_score  := 0
var _game_over  := false

# ── Calibration mode — enemy-free flat ground simulation ────────────
var calib_mode  := false

# ── Platform takip ─────────────────────────────────────────────────
var _platforms      : Array[Node2D] = []
var _enemies        : Array[Node2D] = []
var _highest_plat_y := 0.0

# ── Interactable registry — tick-accurate AABB collision ───────────
# Each entry: { "area": Area2D, "type": String, "data": Variant }
# Types: "item", "spike", "spring", "card"
# Replaces Area2D.body_entered signal (which is frame-based, not tick-based)
var _interactables  : Array[Dictionary] = []

# TUNNEL FIX: player's position at the end of the PREVIOUS tick, captured
# right before _check_interactables() runs. At high fall speed the player
# can move further in one tick than an interactable's touch radius/rect —
# a pure "am I overlapping right now" test (position-only, no sweep) can
# then find the player already past the spring/item/spike on the very
# first tick it would have overlapped, so the pickup/trigger is silently
# skipped entirely. This mirrors the exact class of bug Player.gd's
# platform landing check already guards against with p_bottom_prev — see
# the "Sweep check handles tunneling at high velocity" comment there.
# _ci_prev_pos is Vector2.ZERO-initialized and refreshed to "invalid" on
# every scene reset below so the very first tick after spawn never sweeps
# from a stale/zeroed position (that would falsely test from (0,0)).
var _ci_prev_pos       : Vector2 = Vector2.ZERO
var _ci_prev_pos_valid : bool    = false

# ── Texture cache ───────────────────────────────────────────────────
var _ground_sets    : Array[Dictionary] = []
var _enemy_frames   : Dictionary = {}
var _item_frames    : Dictionary = {}


# ── Seed + RNG ──────────────────────────────────────────────────────
var _rng            : RandomNumberGenerator = RandomNumberGenerator.new()
var _shake_rng      : RandomNumberGenerator = RandomNumberGenerator.new() 
var game_seed       : int = 0
var _spawn_pending  := false
# Monotonic, order-independent counter for enemy seeds — does NOT touch _rng state,
# so enemy seeding can't desync between client/server due to spawn-timing differences (B2 fix).
var _enemy_spawn_counter : int = 0

# ── Kamera shake ────────────────────────────────────────────────────
var _shake_timer    := 0.0
var _shake_strength := 0.0

var session_id      : String = ""
# ── VS Rooms — set by Main._start_vs_round() right before _start_session(),
# cleared after the submit body is built so a normal solo run right after a
# VS match never gets mistakenly tagged. Empty vs_room_id = normal solo play.
var vs_room_id      : String = ""
var vs_role         : String = ""   # "creator" or "opponent"
# ── MITM protection — one-time keys from prefetch ────────────────────

# ── Quest counters (reset each match, printed as QUEST_RESULT on replay end) ──
var _quest_kills          : int = 0   # total enemy kills
var _quest_flying_kills   : int = 0   # kills of flying enemy types
var _quest_mosquito_kills : int = 0   # MOSQUITO enemy kills specifically
var _quest_platforms      : int = 0   # platforms passed (landed)
var _quest_coins          : int = 0   # gold/silver/bronze coins collected
var _quest_golden_carrots : int = 0   # golden carrots collected
var _quest_powerups       : int = 0   # powerup items picked up (jetpack/wings/bubble)
var _quest_took_damage    : bool = false   # true if player took any damage
var _quest_item_types     : Dictionary = {}  # set of collected item type ids
var _quest_used_mirror    : bool = false   # true if mirror debuff was active
var _quest_used_powerup   : bool = false   # true if any powerup was active this match
var _quest_no_coins       : bool = false   # true if player collected zero coins all match
var _quest_ticks          : int = 0   # replay ticks elapsed (= play time)
var _quest_score          : int = 0   # final score (same as score var, convenience)
var _quest_enemy_types    : Dictionary = {}  # set of distinct enemy types killed
var _quest_combo          : int = 0   # current kill-combo (consecutive kills)
var _quest_combo_max      : int = 0   # highest kill-combo reached
var _quest_noHit_streak   : int = 0   # consecutive platforms landed without damage
var _quest_noHit_max      : int = 0   # best no-hit platform streak
var _quest_highest_y_plat : int = 0   # max platforms at highest_y point (= altitude counter)
var _quest_kills_no_dmg   : int = 0   # kills accumulated while took_damage is still false

var BACKEND_URL : String = ApiConfig.base_url()   # resolved at runtime (same origin on web)
const POOL_MIN       := 3   

var _platform_script : Script = null
var _enemy_script    : Script = null
var _item_script     : Script = null

var _biome_enemy_cache : Dictionary = {}
var _last_biome_score  : int = -1
var _active_biome      : String = ""

var _deco_tex_cache : Dictionary = {}

# ── Boss sistemi ─────────────────────────────────────────────────────

# ── Drunk ghost platform ─────────────────────────────────────────────
var _drunk_plat_timer : float = 0.0
const DRUNK_PLAT_INTERVAL := 0.35  

# ── Replay sistemi ───────────────────────────────────────────────────
enum ReplayMode { OFF, RECORDING, PLAYING }
var _replay_mode      : ReplayMode = ReplayMode.OFF
var _is_seeking       : bool = false  # true during seek_to_tick silent loop — suppresses tweens
var _replay_log       : PackedByteArray = PackedByteArray()  
var _last_tick_ms     : int = 0   # real timestamp (for time_scale detection)
var _after_delta_marker : bool = false  # true for exactly one tick after writing a delta marker — prevents extending into marker bytes
var _replay_tick_count : int = 0   # how many ticks recorded / played
var _rle_run_pos      : int = 0   # PLAYING: current RLE byte position
var _rle_run_rem      : int = 0   # PLAYING: ticks remaining in current run
var _rle_run_val      : int = 0   # PLAYING: direction value of current run
var _replay_tick      : int = 0
var _replay_total_ticks : int = 0  # RLE decoded total tick count (correct total for seek bar)
var _replay_seed      : int = 0
var _replay_char      : int = 0
# Per-match "was gyro tilt control active" flag — travels alongside seed/char
# through submit → stored Session → server replay-verification worker,
# exactly the same pipeline _replay_char already uses (see set_gyro_control_active()'s
# doc comment on Player.gd for why this can't just be read live off the
# current settings toggle at replay time).
var _replay_gyro_active : bool = false
var _replay_score     : int = 0
var _replay_player_seed : int = 0     
var _replay_speed     : float = 1.0
var _replay_paused    : bool  = false
var _replay_speed_acc : float = 0.0
var _replay_nickname  : String = ""
# ── Player's own seed preserved before replay (used when returning to lobby) ──

var _pre_replay_seed        : int = 0
var _pre_replay_player_seed : int = 0
var _pre_replay_char        : int = 0
signal replay_finished
signal replay_tick_changed(tick: int, total: int)

# ── Divergence detector ──────────────────────────────────────────────
# During RECORDING store (pos, score) every tick; compare during PLAYING
var _dbg_snapshots : Array = []   # [{pos, score, vel_y}]
var _dbg_enabled   : bool  = OS.is_debug_build()
# Only compare a replay against the local recording that produced it. Watching
# somebody else's replay must never reuse the previous player's trace; doing so
# produced misleading [DIV] messages and made clean replays look suspicious.
var _replay_debug_compare : bool = false  # production: off → zero alloc per tick

# ── Always-on lightweight checkpoint log (client + server, RELEASE builds too) ──
# _dbg_enabled (above) is debug-build-only AND only ever compares a client's own
# RECORDING against its own local PLAYING pass — it never runs in production and
# never touches what the SERVER actually computed, so a real client-vs-server
# (WASM vs headless-native) desync leaves zero forensic trail: today the only
# signal is ParseFlagReason's aggregate score-diff percentage, with no way to
# tell which tick things first went sideways.
# This is unconditional (works in release/production, both RECORDING on a real
# client and PLAYING during server-side verification via seek_to_tick) and
# intentionally NOT gated on _is_seeking — server verification always runs
# through seek_to_tick()'s silent burst, so gating on that would mean the
# server side of the comparison never gets recorded at all.
# Cheap: one small dict every _CKPT_EVERY ticks (~60 entries for a 5-min run).
# Sent by the client in the /submit payload as "ckpt" and written into the
# server replay's --out JSON as "ckpt" — the backend can diff the two arrays
# to pinpoint the first tick where position/score/rng state parted ways.
var _ckpt_log        : Array = []
const _CKPT_EVERY : int = 300  # ~5s at 60 ticks/sec

var _powerup_hud_dirty : bool = true
# Powerup HUD 20 FPS'te güncellenir (60 physics tick / 3 = 20).
# Her tick çizmek gereksiz — bar smooth görünür, CPU tasarrufu sağlanır.
var _powerup_hud_tick  : int  = 0
var _card_fx_tex_cache : Dictionary = {}
var _lucky_textures : Array[Texture2D] = []

# ── Hoisted const arrays for _add_item / _spawn_spinning_card ────────
var _ITEM_TYPES : Array = [
	Item.ItemType.NIMIQ,
	Item.ItemType.CARROT, Item.ItemType.JETPACK, Item.ItemType.WINGS,
	Item.ItemType.BUBBLE, Item.ItemType.GOLDEN_CARROT,
]
const _CARD_POWERUP_LIST : Array[String] = ["jetpack", "drunk", "wings", "earthquake", "bubble", "mirror"]
const _CARD_IS_GOOD_LIST : Array[bool]   = [true, false, true, false, true, false]
const _CARD_GOOD_SLOTS   : Array[int]    = [0, 2, 4]
const _CARD_BAD_SLOTS    : Array[int]    = [1, 3, 5]
const _BIOME_IDX         : Dictionary    = {"grass": 0, "desert": 1, "fall": 4, "sky": 2, "space": 5}

# ── Hoisted temp arrays for _check_interactables (avoids per-tick allocation) ──
var _ci_to_remove  : Array[int]   = []
var _ci_seen       : Dictionary   = {}
var _ci_deduped    : Array[int]   = []

# ── Deterministic camera Y — used by all game logic (spawn/kill, death check) ──
# Visual camera.position.y lerps for smooth display; _sim_cam_y snaps instantly.
# Ensures platform spawn/despawn is identical at any replay speed.
var _sim_cam_y : float = 0.0


func init(p_cam, p_player, _p_score, _p_best, _p_final, p_main, p_seed: int = -1, p_skip_session: bool = false) -> void:
	camera    = p_cam
	player    = p_player
	main_node = p_main
	if is_instance_valid(main_node):
		_main_has_control   = main_node.has_method("get_control_dir")
		_main_has_score     = main_node.has_method("update_score_display")
		_main_has_best      = main_node.has_method("update_best_display")
		_main_has_pwrup_hud = main_node.has_method("update_powerup_hud")
	process_physics_priority = -1

	# Cache layout constants derived from VW/VH (computed once, never change)
	PLATFORM_W    = VW * 0.193
	PLATFORM_H    = VH * 0.0225
	SPAWN_ABOVE   = VH * 1.75
	DESPAWN_BELOW = VH * 1.125
	BASE_GAP      = VH * 0.119
	MAX_GAP       = VH * 0.1875

	game_seed  = 0
	session_id = ""
	# In headless server-replay mode we do not start the new-session/seed flow
	# (_start_session) — it is an async coroutine (uses await) that would later
	# resume and interrupt the active replay simulation (by clearing
	# _platforms/_replay_log and switching to RECORDING mode via _init_game_from_seed),
	# which caused crashes due to lambdas accessing freed nodes.
	player.died.connect(_on_player_died)
	player.collected_item.connect(_on_item_event)
	player.set("_game_manager", self)

	_platform_script = load("res://scripts/Platform.gd")
	_enemy_script    = load("res://scripts/Enemy.gd")
	_item_script     = load("res://scripts/Item.gd")

	_load_all_textures()
	_export_physics_config()

	# First platform and torches — always here, independent of everything
	if not p_skip_session and not _is_headless:
		_spawn_start_platform()

	if not p_skip_session:
		# silent_boot=true: this is the scene's automatic first session, which
		# on a "Play Again" reload can fire while _is_authed() is already true
		# (cached token restored synchronously) but the Nimiq bridge is still
		# connecting for real. A failed/slow seed fetch here isn't a genuine
		# connectivity problem, so don't show a network-error toast for it —
		# see _start_session_from_issued_seed / _start_session for details.
		_start_session(0, true)


# ───────────────────────────────────────────────────────────────────
#  TEXTURE LOADING
# ───────────────────────────────────────────────────────────────────
func _t(path: String) -> Texture2D:
	# =================================================================
	# HEADLESS GRAPHICS CRASH FIX:
	# Never call load() in headless mode even if the file exists on disk!
	# No Image/GPU operations — return null.
	# =================================================================
	if _is_headless:
		return null

	# In normal graphical mode the game loads without issues
	if ResourceLoader.exists(path):
		return load(path)

	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5))
	return ImageTexture.create_from_image(img)


func _load_all_textures() -> void:
	var ground_pairs := [
		["ground_grass",  "ground_grass_broken",  "grass"],
		["ground_sand",   "ground_sand_broken",   "sand"],
		["ground_snow",   "ground_snow_broken",   "snow"],
		["ground_stone",  "ground_stone_broken",  "stone"],
		["ground_wood",   "ground_wood_broken",   "wood"],
		["ground_cake",   "ground_cake_broken",   "cake"],
	]
	var env := "res://assets/environment/"
	for pair in ground_pairs:
		_ground_sets.append({
			"normal": _t(env + pair[0] + ".png"),
			"broken": _t(env + pair[1] + ".png"),
			"name":   pair[2],
		})

	var en := "res://assets/enemies/"
	_enemy_frames[Enemy.EnemyType.FLYMAN] = {
		"fly":  [_t(en+"flyman/fly.png"), _t(en+"flyman/jump.png"),
				 _t(en+"flyman/stand.png"), _t(en+"flyman/jump.png")],
		"idle": [_t(en+"flyman/still_stand.png"), _t(en+"flyman/still_fly.png"),
				 _t(en+"flyman/still_jump.png"), _t(en+"flyman/still_fly.png")],
		"hurt": [_t(en+"flyman/still_stand.png")],
	}
	_enemy_frames[Enemy.EnemyType.WINGMAN] = {
		"fly":  [_t(en+"wingman/1.png"), _t(en+"wingman/2.png"),
				 _t(en+"wingman/3.png"), _t(en+"wingman/4.png"),
				 _t(en+"wingman/5.png"), _t(en+"wingman/4.png"),
				 _t(en+"wingman/3.png"), _t(en+"wingman/2.png")],
		"idle": [_t(en+"wingman/1.png"), _t(en+"wingman/2.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPIKEMAN] = {
		"walk": [_t(en+"spikeman/stand.png"), _t(en+"spikeman/walk1.png"),
				 _t(en+"spikeman/walk2.png"), _t(en+"spikeman/walk1.png")],
		"idle": [_t(en+"spikeman/stand.png")],
		"hurt": [_t(en+"spikeman/jump.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPIKEBALL] = {
		"idle": [_t(en+"spikeball/idle1.png"), _t(en+"spikeball/idle2.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPRINGMAN] = {
		"idle": [_t(en+"springman/stand.png")],
		"hurt": [_t(en+"springman/hurt.png")],
	}
	_enemy_frames[Enemy.EnemyType.SUN] = {
		"idle": [_t(en+"sun/idle1.png"), _t(en+"sun/idle2.png")],
	}
	_enemy_frames[Enemy.EnemyType.CLOUD] = {
		"idle": [_t(en+"cloud/idle.png")],
	}
	_enemy_frames[Enemy.EnemyType.BARNACLE] = {
		"idle":   [_t(en+"barnacle/idle.png")],
		"attack": [_t(en+"barnacle/attack.png")],
		"hurt":   [_t(en+"barnacle/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.BEE] = {
		"fly":  [_t(en+"bee/idle.png"), _t(en+"bee/move.png"),
				 _t(en+"bee/idle.png"), _t(en+"bee/move.png")],
		"hurt": [_t(en+"bee/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.FLY] = {
		"fly":  [_t(en+"fly/idle.png"), _t(en+"fly/move.png"),
				 _t(en+"fly/idle.png"), _t(en+"fly/move.png")],
		"hurt": [_t(en+"fly/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.FROG] = {
		"idle": [_t(en+"frog/idle.png")],
		"walk": [_t(en+"frog/move.png")],
		"hurt": [_t(en+"frog/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.MOUSE] = {
		"walk": [_t(en+"mouse/idle.png"), _t(en+"mouse/move.png"),
				 _t(en+"mouse/idle.png"), _t(en+"mouse/move.png")],
		"hurt": [_t(en+"mouse/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_BLOCK] = {
		"idle": [_t(en+"slime_block/idle.png"), _t(en+"slime_block/move.png")],
		"hurt": [_t(en+"slime_block/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_BLUE] = {
		"walk": [_t(en+"slime_blue/idle.png"), _t(en+"slime_blue/move.png")],
		"hurt": [_t(en+"slime_blue/hit.png"), _t(en+"slime_blue/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_GREEN] = {
		"walk": [_t(en+"slime_green/idle.png"), _t(en+"slime_green/move.png")],
		"hurt": [_t(en+"slime_green/hit.png"), _t(en+"slime_green/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_PURPLE] = {
		"walk": [_t(en+"slime_purple/idle.png"), _t(en+"slime_purple/move.png")],
		"hurt": [_t(en+"slime_purple/hit.png"), _t(en+"slime_purple/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SNAIL] = {
		"walk":  [_t(en+"snail/idle.png"), _t(en+"snail/move.png")],
		"shell": [_t(en+"snail/shell.png")],
	}
	_enemy_frames[Enemy.EnemyType.WORM_GREEN] = {
		"walk": [_t(en+"worm_green/idle.png"), _t(en+"worm_green/move.png"),
				 _t(en+"worm_green/idle.png"), _t(en+"worm_green/move.png")],
		"hurt": [_t(en+"worm_green/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.WORM_PINK] = {
		"walk": [_t(en+"worm_pink/idle.png"), _t(en+"worm_pink/move.png"),
				 _t(en+"worm_pink/idle.png"), _t(en+"worm_pink/move.png")],
		"hurt": [_t(en+"worm_pink/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_FIRE] = {
		"walk": [_t(en+"slime_fire/walk_a.png"), _t(en+"slime_fire/walk_b.png"),
				 _t(en+"slime_fire/walk_a.png"), _t(en+"slime_fire/walk_b.png")],
		"idle": [_t(en+"slime_fire/rest.png")],
		"hurt": [_t(en+"slime_fire/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.LADYBUG] = {
		"fly":  [_t(en+"ladybug/fly.png"), _t(en+"ladybug/walk_a.png"),
				 _t(en+"ladybug/fly.png"), _t(en+"ladybug/walk_b.png")],
		"idle": [_t(en+"ladybug/rest.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPIDER] = {
		"walk": [_t(en+"spider/idle.png"), _t(en+"spider/walk1.png"),
				 _t(en+"spider/walk2.png"), _t(en+"spider/walk1.png")],
		"hurt": [_t(en+"spider/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.GHOST] = {
		"idle": [_t(en+"ghost/idle.png")],
		"dead": [_t(en+"ghost/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.UFO] = {
		"idle": [_t("res://assets/kenney_alien_ufo/PNG/shipGreen_manned.png")],
		"dead": [_t("res://assets/kenney_alien_ufo/PNG/shipGreen_damage2.png")],
	}
	var al := "res://assets/enemies/"
	_enemy_frames[Enemy.EnemyType.ALIEN_GREEN] = {
		"walk": [_t(al+"alien_green/idle.png"), _t(al+"alien_green/walk1.png"),
				 _t(al+"alien_green/idle.png"), _t(al+"alien_green/walk2.png")],
		"hurt": [_t(al+"alien_green/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.ALIEN_BLUE] = {
		"walk": [_t(al+"alien_blue/idle.png"), _t(al+"alien_blue/walk1.png"),
				 _t(al+"alien_blue/idle.png"), _t(al+"alien_blue/walk2.png")],
		"jump": [_t(al+"alien_blue/jump.png")],
		"hurt": [_t(al+"alien_blue/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.ALIEN_PINK] = {
		"walk":  [_t(al+"alien_pink/idle.png"), _t(al+"alien_pink/walk1.png"),
				  _t(al+"alien_pink/idle.png"), _t(al+"alien_pink/walk2.png")],
		"shoot": [_t(al+"alien_pink/shoot.png")],
		"hurt":  [_t(al+"alien_pink/dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.ALIEN_YELLOW] = {
		"walk": [_t(al+"alien_yellow/idle.png"), _t(al+"alien_yellow/walk1.png"),
				 _t(al+"alien_yellow/idle.png"), _t(al+"alien_yellow/walk2.png")],
		"hurt": [_t(al+"alien_yellow/dead.png")],
	}

	var it := "res://assets/items/"
	_item_frames[Item.ItemType.NIMIQ]         = [_t(it + "nimiq_hexagon_item.png")]
	_item_frames[Item.ItemType.CARROT]        = [_t(it + "carrot.png")]
	_item_frames[Item.ItemType.GOLDEN_CARROT] = [_t(it + "carrot_gold.png")]
	_item_frames[Item.ItemType.JETPACK]       = [_t(it + "jetpack_item.png")]
	_item_frames[Item.ItemType.WINGS]         = [_t(it + "powerup_wings.png")]
	_item_frames[Item.ItemType.BUBBLE]        = [_t(it + "powerup_bubble.png")]
	_item_frames[Item.ItemType.MYSTERY_BOX] = [
		_t(it + "powerup_jetpack.png"),
		_t(it + "powerup_wings.png"),
		_t(it + "powerup_bubble.png"),
		_t(it + "debuff_earthquake.png"),
		_t(it + "debuff_drunk.png"),
		_t(it + "debuff_mirror.png"),
	]

	_lucky_textures = [
		_t(it + "powerup_jetpack.png"),
		_t(it + "debuff_drunk.png"),
		_t(it + "powerup_wings.png"),
		_t(it + "debuff_earthquake.png"),
		_t(it + "powerup_bubble.png"),
		_t(it + "debuff_mirror.png"),
	]


# ───────────────────────────────────────────────────────────────────
#  MAIN LOOP
# ───────────────────────────────────────────────────────────────────
func _physics_process(_delta: float) -> void:
	# seek_to_tick runs _run_one_tick() synchronously — never double-simulate
	if _is_seeking: return
	if _game_over or player == null or camera == null: return

	if _replay_mode == ReplayMode.PLAYING:
		if _replay_paused:
			player.set("_replay_dir", 0)
			return

		_replay_speed_acc += _replay_speed
		while _replay_speed_acc >= 1.0:
			if _game_over: break
			_replay_speed_acc -= 1.0
			_run_one_tick()
	else:
		# NORMAL GAME or RECORDING mode
		_run_one_tick()

func _run_one_tick() -> void:
	_simulate_gm_tick()
	# GM-RT: compute player_ready once; direct field access avoids .get() string lookup
	var player_ready : bool = is_instance_valid(player) and player._initialized
	# TUNNEL FIX: snapshot position BEFORE this tick's physics move, so
	# _check_interactables() below can sweep prev→current instead of testing
	# only the post-move point. Must be captured here, not inside
	# _check_interactables(), since that's the only place we still have
	# "where the player was before simulate_tick() ran this tick".
	var ci_pos_before : Vector2 = player.global_position if player_ready else Vector2.ZERO
	if player_ready:
		player.simulate_tick()
		# Enemies ticked only when player is ready — keeps tick count equal in NORMAL and REPLAY
		for e in _enemies:
			if is_instance_valid(e):
				e.simulate_tick()
	# Platform break timers — fixed tick instead of Godot delta (deterministic at 2x/4x)
	for i in range(_platforms.size() - 1, -1, -1):
		var plat := _platforms[i]
		if not is_instance_valid(plat): continue
		if plat.simulate_tick():   # true = break finished, remove
			_discard_node(plat)
			_platforms.remove_at(i)
	# ── Tick-accurate interactable collision ─────────────────────────
	# Area2D.body_entered is frame-based — fires once per frame regardless of
	# replay speed. At 2x/4x/8x this causes missed or delayed pickups.
	# Instead: check AABB overlap every tick manually.
	if player_ready:
		if _ci_prev_pos_valid:
			_ci_prev_pos = ci_pos_before
		else:
			# First tick after spawn/reset: no real "previous" position yet —
			# sweep from the current position (degenerates to a point test,
			# same as before) rather than from a stale/zeroed one.
			_ci_prev_pos = player.global_position
			_ci_prev_pos_valid = true
		_check_interactables()
	_tick_spring_resets()

	# ── Divergence detector ──────────────────────────────────────────
	# Also skipped during seek_to_tick()'s silent burst — see comment above.
	if _dbg_enabled and _replay_debug_compare and not _is_seeking and player_ready:
		var snap_pos   : Vector2 = player.global_position
		var snap_score : int     = score
		var snap_vel   : float   = player.velocity.y
		var snap_plats : int     = _platforms.size()
		if _replay_mode == ReplayMode.RECORDING:
			_dbg_snapshots.append({"pos": snap_pos, "score": snap_score, "vel_y": snap_vel, "plats": snap_plats})
		elif _replay_mode == ReplayMode.PLAYING:
			# _replay_tick_count is incremented before simulate_tick runs,
			# so snapshot index is _replay_tick_count - 1
			var t : int = _replay_tick_count - 1
			if t >= 0 and t < _dbg_snapshots.size():
				var ref_snap : Dictionary = _dbg_snapshots[t]
				var dp : float = snap_pos.distance_to(ref_snap.pos)
				var ds : int   = abs(snap_score - int(ref_snap.score))
				var dv : float = abs(snap_vel   - float(ref_snap.vel_y))
				if dp > 0.5 or ds > 0 or dv > 1.0:
					print("[DIV] tick=%d  Δpos=%.2f  Δscore=%d  Δvel_y=%.2f  plats=%d(ref=%d)" \
						% [t, dp, ds, dv, snap_plats, int(ref_snap.plats)])

	# ── Checkpoint log (always on, release builds too — see field comment) ──
	# Deliberately NOT gated on _is_seeking: server-side verification always
	# runs through seek_to_tick()'s silent burst, so gating on that would mean
	# the server side of the client-vs-server comparison never gets recorded.
	if player_ready and _replay_mode != ReplayMode.OFF:
		if _replay_tick_count == 1:
			_ckpt_log.clear()  # new run — drop any stale entries from a previous game/replay
		if _replay_tick_count % _CKPT_EVERY == 0:
			var _breaking_count := 0
			var _crumble_count := 0
			for _cp in _platforms:
				if not is_instance_valid(_cp): continue
				if bool(_cp.get("_breaking")): _breaking_count += 1
				if bool(_cp.get("_crumble_shaking")): _crumble_count += 1
			_ckpt_log.append({
				"t":  _replay_tick_count,
				"s":  score,
				# Position/velocity are already snapped to the 0.01 grid by
				# Player.gd every tick — *100 + round gives a clean int so the
				# JSON payload stays small and comparison is exact, not float.
				"x":  int(round(player.global_position.x * 100.0)),
				"y":  int(round(player.global_position.y * 100.0)),
				"vy": int(round(player.velocity.y * 100.0)),
				# _rng.state is a full 64-bit int — stringified so JSON (IEEE-754
				# double under the hood) can't silently lose precision on it.
				"rng": str(_rng.state),
				"platforms": _platforms.size(),
				"breaking": _breaking_count,
				"crumbling": _crumble_count,
			})


func _simulate_gm_tick() -> void:
	const delta := 1.0 / 60.0   # fixed delta — deterministic physics
	# Speed hack guard — time_scale manipulation detected, force back
	if Engine.time_scale != 1.0:
		Engine.time_scale = 1.0
	
	if player._initialized:
		var rdir : int = 0
		if _replay_mode == ReplayMode.PLAYING:
			# ── READ FROM LOG ──
			# RLE read: _rle_run_pos = current byte index, _rle_run_rem = ticks remaining in current run
			if _rle_run_rem <= 0:
				# Yeni run oku
				while _rle_run_pos < _replay_log.size():
					var b : int = _replay_log[_rle_run_pos]
					if b == 0xFF:
						# Delta marker — skip (3 byte), but guard against truncated marker at buffer end
						if _rle_run_pos + 2 < _replay_log.size():
							_rle_run_pos += 3
						else:
							break  # truncated — exit loop cleanly instead of reading OOB zeros
						continue
					_rle_run_val = (b & 0x03) - 1        # -1=left, 0=neutral, 1=right
					_rle_run_rem = max(1, (b >> 2) & 0x3F)
					_rle_run_pos += 1
					break
			if _rle_run_rem > 0:
				rdir = _rle_run_val
				_rle_run_rem -= 1
				_replay_tick_count += 1
				_replay_tick = _replay_tick_count   # keep in sync — _replay_tick was never incremented before
				# Skip UI signal + debug print entirely while seek_to_tick() is
				# doing its silent re-sim burst — the world is hidden and
				# nothing reads these until the loop finishes, so emitting/
				# printing on every 6th/100th tick of a multi-thousand-tick
				# seek was pure wasted work slowing the "instant" jump down.
				if not _is_headless and not _is_seeking and _replay_tick_count % 6 == 0:
					replay_tick_changed.emit(_replay_tick_count, _replay_total_ticks)
				if _dbg_enabled and _replay_debug_compare and not _is_seeking and _replay_tick_count % 100 == 0:
					print("[SNAP] tick=%d score=%d pos=(%.2f,%.2f) vel_y=%.2f rng=%d" % [_replay_tick_count, score, player.position.x, player.position.y, player.velocity.y, _rng.state])
			else:
				_game_over     = true
				_replay_mode   = ReplayMode.OFF
				# "viewer" = leaderboard/stats/web replay — log ended, just stop, do not emit
				if _replay_nickname == "viewer":
					_replay_paused = true
					if is_instance_valid(player):
						player.set("is_dead",      false)
						player.set("_initialized", false)
						player.velocity = Vector2.ZERO
					return
				_replay_paused = false
				# Print quest result for server-side analysis (headless replay log ended)
				if _is_headless:
					var lives_left : int = 0
					if is_instance_valid(player) and player.get("lives") != null:
						lives_left = int(player.get("lives"))
					print("[QUEST_RESULT] " + JSON.stringify({
						"score":           score,
						"ticks":           _replay_tick_count,
						"kills":           _quest_kills,
						"flying_kills":    _quest_flying_kills,
						"mosquito_kills":  _quest_mosquito_kills,
						"platforms":       _quest_platforms,
						"coins":           _quest_coins,
						"golden_carrots":  _quest_golden_carrots,
						"powerups":        _quest_powerups,
						"took_damage":     _quest_took_damage,
						"item_types":      _quest_item_types.size(),
						"lives_left":      lives_left,
						"used_mirror":     _quest_used_mirror,
						"used_powerup":    _quest_used_powerup,
						"no_coins":        _quest_coins == 0,
						"enemy_types":     _quest_enemy_types.size(),
						"combo_max":       _quest_combo_max,
						"nohit_max":       _quest_noHit_max,
						"kills_no_dmg":    _quest_kills_no_dmg,
						"highest_y":       highest_y,
					}))
				for child in get_children().duplicate():
					if child == player or child == camera: continue
					if child is HTTPRequest: continue
					child.queue_free()
				_platforms.clear()
				_enemies.clear()
				replay_finished.emit()
				return
		else:
			# ── NORMAL GAME: read from keyboard / touch / gyro ──
			# Use control mode defined in main node if available, else keyboard fallback
			if _main_has_control and is_instance_valid(main_node):
				rdir = main_node.call("get_control_dir")
			else:
				# Keyboard fallback (desktop / editor)
				# Edge-latch OR'd in — see _kb_left_pending/_kb_right_pending doc
				# comment above _input() for why plain is_action_pressed() alone
				# can silently miss a fast tap during a physics catch-up burst.
				var l_held := Input.is_action_pressed("ui_left")  or Input.is_action_pressed("move_left") or _kb_left_pending
				var r_held := Input.is_action_pressed("ui_right") or Input.is_action_pressed("move_right") or _kb_right_pending
				_kb_left_pending  = false
				_kb_right_pending = false
				if r_held and not l_held:
					rdir = 1
				elif l_held and not r_held:
					rdir = -1

			# ── RECORDING: RLE log ──
			# Format: [val:2bit | count:6bit] = 1 byte per run (max 63 tick)
			# Delta timer run: val=3 (0b11) → [0b11 | count:6bit][lo][hi] = 3 byte
			# val 0=neutral 1=right 2=left (val+1 → rdir+1)
			if _replay_mode == ReplayMode.RECORDING:
				var val : int = (rdir + 1) & 0x03  # 0=neutral 1=right 2=left
				# BUG FIX: old code checked `last byte != 0xFF` to avoid extending into
				# delta markers. But a delta marker is [0xFF][lo][hi] — and lo/hi are
				# NOT 0xFF, so the old code extended into them, corrupting the log.
				# This caused replay to show inputs held longer than actually pressed
				# (e.g. full right traversal instead of a short tap).
				# Fix: use _after_delta_marker flag — set true right after writing the
				# 3-byte marker, cleared on the very next RLE byte write.
				if not _after_delta_marker and _replay_log.size() > 0:
					var last_byte : int = _replay_log[_replay_log.size() - 1]
					var last_val  : int = last_byte & 0x03
					var last_cnt  : int = (last_byte >> 2) & 0x3F
					if last_val == val and last_cnt < 63:
						_replay_log[_replay_log.size() - 1] = val | ((last_cnt + 1) << 2)
					else:
						_replay_log.append(val | (1 << 2))  # new run, count=1
				else:
					_replay_log.append(val | (1 << 2))  # first run or after marker
				_after_delta_marker = false
				_replay_tick_count += 1
				if _replay_tick_count == 1:
					_last_tick_ms = Time.get_ticks_msec()  # determinism-ok: only feeds the 0xFF delta-marker bytes, which server RLE decode skips over entirely (never affects simulation)
				# Her 60 tick'te delta marker yaz
				elif _replay_tick_count % 60 == 0:
					var now_ms : int = Time.get_ticks_msec()  # determinism-ok: see above, skipped bytes on decode
					var tick_delta : int = clampi(now_ms - _last_tick_ms, 0, 65535)
					_last_tick_ms = now_ms
					_replay_log.append(0xFF)
					_replay_log.append(tick_delta & 0xFF)
					_replay_log.append((tick_delta >> 8) & 0xFF)
					_after_delta_marker = true


		player.set("_replay_dir", rdir)

	# Track mirror debuff activation for quest system
	if not _quest_used_mirror and is_instance_valid(player) and player._mirror_active:
		_quest_used_mirror = true

	camera.position.x = VW * 0.5

	if calib_mode:
		# Calibration: camera fixed, no score, player kept at ground level
		camera.position.y = VH * 0.5
		# Prevent player from falling below the ground line — place back on platform
		var floor_y := VH * 0.72 - PLATFORM_H * 0.5 - VH * 0.018
		if player.position.y > floor_y:
			player.position.y = floor_y
			player.velocity.y = player.JUMP_SPEED
	else:
		# Physics camera snaps instantly — deterministic at any replay speed
		var target_y := minf(_sim_cam_y, player.position.y)
		_sim_cam_y = target_y
		# Visual camera lerps smoothly (display only — does NOT affect game logic)
		if not _is_headless:
			# BUG FIX (general movement flicker — reported worst going up, but
			# present moving any direction): project settings have
			# 2d/snap/snap_2d_transforms_to_pixel=true for crisp pixel-art
			# rendering. That snap happens per-node, independently, at render
			# time. The player sprite's position is an exact deterministic
			# simulated value each tick, but this camera lerp produces a
			# continuously-changing SUB-PIXEL value approaching it — so every
			# frame, Godot's snap rounds the camera to the nearest pixel
			# independently of where it rounds the player, and the gap
			# between those two independent roundings drifts by a whole
			# pixel back and forth as the lerp's fractional part crosses
			# rounding boundaries — exactly what reads as "flickering" during
			# any sustained movement, since the camera is CONSTANTLY chasing
			# a moving target (never settles, unlike a stationary camera
			# where the same rounding mismatch would just be a single static
			# 1px offset, never a visible flicker). Rounding the camera's own
			# driving value to a whole pixel BEFORE Godot's internal snap
			# ever sees it removes that extra, independently-drifting
			# rounding source — the snap then has nothing left to disagree
			# with the player's own already-integer-ish position about.
			camera.position.y = roundf(lerpf(camera.position.y, _sim_cam_y, minf(25.0 * delta, 1.0)))
		else:
			camera.position.y = _sim_cam_y

		# Score calculation: snap position to integer — clears float drift
		var height : int = int(VH * 0.72) - int(player.position.y)
		if height > highest_y:
			highest_y = height
			score     = highest_y / 10
			if _main_has_score and is_instance_valid(main_node):
				main_node.call("update_score_display", score)
			var _new_biome := _biome_name_for_score(score)
			if _new_biome != _active_biome:
				_active_biome = _new_biome
				if is_instance_valid(main_node) and main_node.has_method("transition_background"):
					main_node.call("transition_background", _new_biome)
			if score > best_score:
				best_score = score
				if _main_has_best and is_instance_valid(main_node):
					main_node.call("update_best_display", best_score)

		if player.position.y > _sim_cam_y + VH * 0.75:
			if player.god_mode:
				player.velocity.y = player.JUMP_SPEED * 1.5
			elif player.has_shield:
				player.has_shield = false
				player.velocity.y = player.JUMP_SPEED * 1.7
				player._hurt_flash = 0.6
			else:
				if _dbg_enabled:
					var nearest_plat_dist := 99999.0
					var nearest_plat_y := 0.0
					var nearest_plat_x := 0.0
					for _dbg_plat in _platforms:
						if not is_instance_valid(_dbg_plat): continue
						var _dy : float = abs(_dbg_plat.global_position.y - player.position.y)
						if _dy < nearest_plat_dist:
							nearest_plat_dist = _dy
							nearest_plat_y = _dbg_plat.global_position.y
							nearest_plat_x = _dbg_plat.global_position.x
					var xoverlap_plat_y := 0.0
					var xoverlap_plat_dist := 99999.0
					var pw2 : float = PLATFORM_W * 0.5
					var px2 : float = player.position.x
					for _dbg_plat2 in _platforms:
						if not is_instance_valid(_dbg_plat2): continue
						var _plx : float = _dbg_plat2.global_position.x
						if px2 + VW * 0.040 < _plx - pw2 or px2 - VW * 0.040 > _plx + pw2: continue
						var _dy2 : float = abs(_dbg_plat2.global_position.y - player.position.y)
						if _dy2 < xoverlap_plat_dist:
							xoverlap_plat_dist = _dy2
							xoverlap_plat_y = _dbg_plat2.global_position.y
					print("[FALL_OFF] tick=%d score=%d cam_y=%.1f player=(%.1f,%.1f) vel_y=%.1f nearest=(%.1f,%.1f) dist=%.1f xoverlap_y=%.1f xoverlap_dist=%.1f" % [_replay_tick, score, _sim_cam_y, player.position.x, player.position.y, player.velocity.y, nearest_plat_x, nearest_plat_y, nearest_plat_dist, xoverlap_plat_y, xoverlap_plat_dist])
				player.die()

	# Powerup HUD: 60 tick'ten 3'te bir güncelle = 20 FPS
	# queue_redraw her tick tetiklenirse gereksiz draw call — 20 FPS yeterince smooth
	_powerup_hud_tick += 1
	if _powerup_hud_tick >= 3:
		_powerup_hud_tick = 0
		_update_powerup_hud()
	_manage_platforms()
	_apply_camera_shake(delta)

	if player._drunk_active:
		_drunk_plat_timer += delta
		if _drunk_plat_timer >= DRUNK_PLAT_INTERVAL:
			_drunk_plat_timer = 0.0
			_spawn_drunk_platform_ghost()


# ───────────────────────────────────────────────────────────────────
#  PLATFORM MANAGEMENT
# ───────────────────────────────────────────────────────────────────
func _manage_platforms() -> void:
	if game_seed == 0: return  
	var cam_y      := _sim_cam_y
	var cam_top    := cam_y - VH * 0.5
	var spawn_line := cam_top - SPAWN_ABOVE
	var kill_line  := cam_y + VH * 0.5 + DESPAWN_BELOW

	while _highest_plat_y > spawn_line:
		var plat_height := (VH * 0.72) - _highest_plat_y
		var diff_now    := clampf(plat_height / 30000.0, 0.0, 1.0)
		var gap_now   : float = lerpf(BASE_GAP, MAX_GAP, diff_now) + _rng.randf_range(0.0, BASE_GAP * 0.3)
		_highest_plat_y -= snappedf(gap_now, 0.01)
		_highest_plat_y = snappedf(_highest_plat_y, 0.01)
		var x         := snappedf(_rng.randf_range(VW * 0.10, VW * 0.90), 0.01)
		var is_broken := _rng.randf() < lerpf(BROKEN_BASE_PROB, 0.28, diff_now)
		_spawn_platform(Vector2(x, _highest_plat_y), is_broken, false, diff_now)

	# MP-01: Platforms are always valid (we own them) — skip double is_instance_valid check.
	# queue_free then remove_at in one pass.
	for i in range(_platforms.size() - 1, -1, -1):
		var plat := _platforms[i]
		if not is_instance_valid(plat):
			_platforms.remove_at(i)
			continue
		if plat.position.y > kill_line:
			_discard_node(plat)
			_platforms.remove_at(i)

	# MP-02: Direct field access for _setup_done and can_fly — avoids .get() string lookup per enemy per tick.
	for i in range(_enemies.size() - 1, -1, -1):
		var e := _enemies[i]
		if not is_instance_valid(e):
			_enemies.remove_at(i)
			continue
		if e.global_position.y > kill_line:
			_discard_node(e)
			_enemies.remove_at(i)
			continue
		# Orphan check: ground enemy whose platform scrolled off
		if e._setup_done and not e.can_fly and not is_instance_valid(e._platform):
			_discard_node(e)
			_enemies.remove_at(i)


func _spawn_start_platform() -> void:
	var start_plat_y := VH * 0.72 + VH * 0.03
	_spawn_platform(Vector2(VW * 0.5, start_plat_y), false, true)
	if player:
		player.position = Vector2(VW * 0.5, start_plat_y - PLATFORM_H * 0.5 - VH * 0.025)
	if _platforms.size() > 0:
		_add_start_torches(_platforms[0])


func _spawn_initial_platforms() -> void:
	var start_plat_y := VH * 0.72 + VH * 0.03
	_highest_plat_y = start_plat_y
	_spawn_platform(Vector2(VW * 0.5, start_plat_y), false, true)
	if player:
		# Use the EXACT same snap formula as Player.simulate_tick landing:
		#   global_position.y = plat_top - p_hh
		# where plat_top = plat.global_position.y - PLATFORM_H * 0.5
		#   and p_hh     = VH * Player.HITBOX_H_RATIO  (= VH * 0.025)
		# This guarantees recording and any replay/seek start from identical
		# float values — a 1-tick difference here cascades into full RNG desync.
		var plat_top : float = start_plat_y - PLATFORM_H * 0.5
		var p_hh     : float = VH * 0.025   # Player.HITBOX_H_RATIO
		player.position = Vector2(VW * 0.5, plat_top - p_hh)
	if not calib_mode and not _is_headless and _platforms.size() > 0:
		_add_start_torches(_platforms[0])
	for _i in 6:
		_highest_plat_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(VW * 0.13, VW * 0.87)
		_spawn_platform(Vector2(x, _highest_plat_y), false, true)
	for _i in 14:
		_highest_plat_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(VW * 0.10, VW * 0.90)
		var init_diff := clampf(((VH * 0.72) - _highest_plat_y) / 30000.0, 0.0, 1.0)
		_spawn_platform(Vector2(x, _highest_plat_y), false, false, init_diff)


func _spawn_drunk_platform_ghost() -> void:
	if _is_headless: return
	var cam_top    := camera.position.y - VH * 0.6
	var cam_bottom := camera.position.y + VH * 0.6
	var visible : Array[Node2D] = []
	for plat in _platforms:
		if not is_instance_valid(plat): continue
		var py : float = plat.position.y
		if py >= cam_top and py <= cam_bottom:
			visible.append(plat)
	if visible.is_empty(): return

	var count := mini(2, visible.size())
	for _i in count:
		var src : Node2D = visible[_shake_rng.randi() % visible.size()]
		var spr_node : Sprite2D = null
		for child in src.get_children():
			if child is Sprite2D:
				spr_node = child as Sprite2D
				break
		if not spr_node: continue
		var tex : Texture2D = spr_node.texture
		if not tex: continue

		var ghost := Sprite2D.new()
		ghost.texture  = tex
		ghost.z_index  = 5
		ghost.scale = spr_node.scale
		ghost.modulate = Color(0.8, 1.0, 0.4, 0.38)
		add_child(ghost)
		var offset_x := (_shake_rng.randf() - 0.5) * PLATFORM_W * 1.2
		var offset_y := (_shake_rng.randf() - 0.5) * VH * 0.08
		ghost.global_position = src.global_position + Vector2(offset_x, offset_y)

		var tw := ghost.create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(ghost, "global_position:x",
				ghost.global_position.x + (_shake_rng.randf() - 0.5) * VW * 0.04, 0.5)
			tw.parallel().tween_property(ghost, "modulate:a", 0.0, 0.5).set_trans(Tween.TRANS_SINE)
			tw.tween_callback(func():
				if is_instance_valid(ghost):
					ghost.queue_free())


func _spawn_platform(pos: Vector2, broken: bool, safe: bool = false, p_diff: float = -1.0) -> void:
	if _platform_script == null: return
	var use_diff := p_diff if p_diff >= 0.0 else _difficulty()
	var plat := StaticBody2D.new()
	plat.position = Vector2(snappedf(pos.x, 0.01), snappedf(pos.y, 0.01))
	add_child(plat)
	plat.set_script(_platform_script)

	var plat_height := (VH * 0.72) - pos.y
	var plat_score  := int(plat_height * 0.1)
	var ground_set : Dictionary = _ground_set_for_score(plat_score)
	# CRUMBLE: 600+ puandan itibaren artan ihtimalle, normal platformların yerini alır
	var crumble_chance : float = clampf((float(plat_score) - 600.0) / 1400.0, 0.0, 0.35)
	var is_crumble : bool = not broken and not safe and _rng.randf() < crumble_chance
	var ptype : Platform.PlatformType
	if broken:
		ptype = Platform.PlatformType.BROKEN
	elif is_crumble:
		ptype = Platform.PlatformType.CRUMBLE
	else:
		ptype = Platform.PlatformType.NORMAL
	var tex   : Texture2D = ground_set.get("broken" if broken else "normal", null)
	var b_tex : Texture2D = ground_set.get("broken", null)

	plat.setup(ptype, tex, Vector2(PLATFORM_W, PLATFORM_H), b_tex, use_diff)
	plat.game_manager = self
	_platforms.append(plat)

	if safe: return

	# No decoration/enemy/item/spike in calibration mode — plain flat platform
	if calib_mode: return

	if not broken:
		var gname := ground_set.get("name", "") as String
		if gname != "":
			_add_deco(plat, gname)

	if broken: return

	var gap_check : float = lerpf(BASE_GAP, MAX_GAP, use_diff)
	if gap_check >= JETPACK_GAP:
		_add_spring(plat)
		return

	if _rng.randf() < 0.05:
		_add_spring(plat)
		return

	var _spike_roll   := _rng.randf()
	var _spike_b_roll := _rng.randf()
	var gname2 := ground_set.get("name", "") as String
	if not broken and gname2 in ["grass", "sand", "cake"] and _spike_roll < 0.18:
		_add_spikes(plat)
	elif not broken and gname2 in ["stone", "wood", "snow"] and _spike_b_roll < 0.12:
		_add_spike_bottom(plat)

	var enemy_prob := lerpf(ENEMY_BASE_PROB, ENEMY_MAX_PROB, use_diff)
	var placed_etype : int = -1
	if _rng.randf() < enemy_prob:
		placed_etype = _add_enemy(plat, use_diff, plat_score)

	# user request: "duran bloklar" (SPRINGMAN, SLIME_BLOCK gibi hareket etmeyen/
	# sabit duran düşmanlar) varsa aynı platformda item ÇIKMASIN — şans kartı
	# (spinning card) da dahil. Önceki hâlde "_blocks_item" sadece _add_item()
	# roll'unu (nimiq/carrot/altın havuç) atlıyordu; "and" kısa-devre yaptığı
	# için _blocks_item true olduğunda if-koşulu hemen false oluyor ve kod
	# else'e düşüp şans kartını YİNE deniyordu — kullanıcının fark ettiği bug
	# tam buydu (springman'in üstünde şans kutusu çıkıyordu).
	var _blocking_static_types := [Enemy.EnemyType.SPRINGMAN, Enemy.EnemyType.SLIME_BLOCK]
	var _blocks_item : bool = placed_etype in _blocking_static_types

	# Item artık düşmandan tamamen BAĞIMSIZ kontrol ediliyor — yaratıklı
	# bir platformda da nimiq/carrot/altın havuç çıkabilir, biri diğerini
	# engellemez. Tek istisna: _blocking_static_types — o platformlarda ne
	# item ne şans kartı çıkar.
	var item_prob := _item_spawn_prob(use_diff)
	if _blocks_item:
		pass  # duran blok var — item ve şans kartı roll'u tamamen atlanır
	elif _rng.randf() < item_prob:
		_add_item(plat, use_diff)
	else:
		# Şans kartı bağımsız/sabit %CARD_PROB olsun diye, item rolünü
		# kaçıran ihtimal üzerinden telafili roll (elif olduğu için
		# ham CARD_PROB kullanırsak gerçek sonuç CARD_PROB'un altında
		# kalırdı).
		var card_roll_thresh := CARD_PROB / maxf(1.0 - item_prob, 0.0001)
		if _rng.randf() < card_roll_thresh:
			_spawn_spinning_card(plat.global_position + Vector2(0, -VH * 0.06))


func _cached_tex(path: String) -> Texture2D:
	if _is_headless: return null
	if _deco_tex_cache.has(path):
		return _deco_tex_cache[path]
	if not ResourceLoader.exists(path):
		return null
	var t := load(path) as Texture2D
	_deco_tex_cache[path] = t
	return t


func _add_deco(plat: StaticBody2D, gname: String) -> void:
	var env := "res://assets/environment/"
	var par := "res://assets/particles/"
	var r0 := _rng.randf(); var r1 := _rng.randf(); var r2 := _rng.randf()
	var r3 := _rng.randf(); var r4 := _rng.randf_range(-VW * 0.067, VW * 0.067)

	# Deko X konumları PLATFORM_W oranıyla — ekrandan bağımsız
	# ±0.145 = mantar/snow ≈ plat genişliğinin %14.5'i (eski ±28 px sabit)
	# ±0.165 = grass/cake  ≈ plat genişliğinin %16.5'i (eski ±32 px sabit)
	# ±0.175 = kaktüs       ≈ plat genişliğinin %17.5'i (eski ±34 px sabit)
	# ±0.195 = taş          ≈ plat genişliğinin %19.5'i (eski ±38 px sabit)
	var _dw145 := PLATFORM_W * 0.145
	var _dw165 := PLATFORM_W * 0.165
	var _dw175 := PLATFORM_W * 0.175
	var _dw195 := PLATFORM_W * 0.195
	match gname:
		"grass":
			if r0 < 0.60:
				var grass := "grass1.png" if r1 < 0.5 else "grass2.png"
				var side  := -_dw165 if r2 < 0.5 else _dw165
				_place_deco(plat, env + grass, side, int(VH * 0.0275))
			# user request: çimen dışındaki yeşil parçacık dekorasyonu kaldırıldı
		"sand":
			if r0 < 0.70:
				var cx := -_dw175 if r1 < 0.5 else _dw175
				_place_deco(plat, env + "cactus.png", cx, int(VH * 0.0325))
		"wood":
			if r0 < 0.25:
				_place_deco(plat, env + "mushroom_brown.png", -_dw145, int(VH * 0.0275))
				_place_deco(plat, env + "mushroom_red.png",    _dw145, int(VH * 0.0225))
			elif r0 < 0.50:
				var mush := "mushroom_brown.png" if r1 < 0.5 else "mushroom_red.png"
				var side := -_dw145 if r2 < 0.5 else _dw145
				_place_deco(plat, env + mush, side, int(VH * 0.0275))
		"snow":
			if r0 < 0.55:
				var gb   := "grass_brown1.png" if r1 < 0.5 else "grass_brown2.png"
				var side := -_dw165 if r2 < 0.5 else _dw165
				_place_deco(plat, env + gb, side, int(VH * 0.0225))
		"stone":
			if r0 < 0.40:
				var side := -_dw195 if r1 < 0.5 else _dw195
				_place_deco(plat, par + "particle_grey.png", side, int(VH * 0.0125))
		"cake":
			# Şeker rengi partiküller — pembe ve bej
			if r0 < 0.55:
				var side := -_dw165 if r1 < 0.5 else _dw165
				_place_deco(plat, par + "particle_beige.png", side, int(VH * 0.0125))
			if r3 < 0.35:
				_place_deco(plat, par + "particle_pink.png" if ResourceLoader.exists(par + "particle_pink.png") else par + "particle_beige.png", r4, int(VH * 0.01))


func _place_deco(plat: StaticBody2D, path: String, x: float, target_h: int) -> void:
	if _is_headless: return
	var tex := _cached_tex(path)
	if not tex: return
	var half_plat := PLATFORM_W * 0.5 - PLATFORM_W * 0.031  # eski: 6.0 px sabit → PLATFORM_W * 0.031
	x = clampf(x, -half_plat, half_plat)
	# Spike çakışma kontrolü — spike olan X bölgesine deko koyma
	for child in plat.get_children():
		if not is_instance_valid(child): continue
		if not child is Area2D: continue
		if abs(child.position.x - x) < PLATFORM_W * 0.12:
			return
	var sc := float(target_h) / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture  = tex
	spr.scale    = Vector2(sc, sc)
	spr.z_index  = 1
	spr.position = Vector2(x, -(PLATFORM_H * 0.5) - float(target_h) * 0.5)
	plat.add_child(spr)


func _add_start_torches(plat: StaticBody2D) -> void:
	var tex_off := _cached_tex("res://assets/pack/torch_off.png")
	var tex_a   := _cached_tex("res://assets/pack/torch_on_a.png")
	var tex_b   := _cached_tex("res://assets/pack/torch_on_b.png")
	if not tex_off or not tex_a or not tex_b: return
	var torch_h  := int(VH * 0.038)
	var sc       := float(torch_h) / float(tex_a.get_height())
	var y_pos    := -(PLATFORM_H * 0.5) - float(torch_h) * 0.5
	var offset_x := VW * 0.065
	var has_seed := game_seed != 0
	for side in [-1, 1]:
		var spr    := AnimatedSprite2D.new()
		var frames := SpriteFrames.new()
		frames.add_animation("flicker")
		frames.set_animation_loop("flicker", true)
		frames.set_animation_speed("flicker", 4.0)
		frames.add_frame("flicker", tex_a)
		frames.add_frame("flicker", tex_b)
		frames.add_animation("off")
		frames.set_animation_loop("off", false)
		frames.add_frame("off", tex_off)
		spr.sprite_frames = frames
		spr.scale    = Vector2(sc, sc)
		spr.z_index  = 2
		spr.position = Vector2(side * offset_x, y_pos)
		spr.set_meta("start_torch", true)
		if has_seed:
			spr.play("flicker")
		else:
			spr.play("off")
		plat.add_child(spr)


func _add_spikes(_plat: StaticBody2D) -> void:
	# Spike removed from gameplay — RNG consumed to keep replay state in sync.
	var _p := _rng.randi() % 3
	var _s := _rng.randi() % 2


func _add_spike_bottom(_plat: StaticBody2D) -> void:
	# Spike removed from gameplay — RNG consumed to keep replay state in sync.
	var _p := _rng.randi() % 2


func _add_spring(plat: StaticBody2D) -> void:
	var headless := _is_headless

	var area := Area2D.new()
	area.collision_layer = 4
	area.collision_mask  = 1
	area.monitoring   = false
	area.monitorable  = false
	area.position     = Vector2(0, 0)
	plat.add_child(area)

	# Spring height for collision positioning.
	# IMPORTANT: this must be IDENTICAL in headless (server) and visual (client)
	# modes — it feeds directly into area.position below, which is the actual
	# collision shape Y offset, not just a visual value. Previously the visual
	# branch overwrote h_out with float(tex_out.get_height()) * sc, derived from
	# the real spring_out.png texture. If that texture isn't perfectly square,
	# h_out differs from headless's VH*0.035 approximation — causing the spring's
	# trigger zone to sit at a different Y between client recording and server
	# replay, which diverges the player's trajectory from that point on (while
	# the run can still end at the same tick count by coincidence — this exactly
	# matches observed [REPLAY_SIM] logs: ticks identical, score off by a few points).
	var h_out := VH * 0.035  # fixed — same value in every mode, never overwritten below
	var anim : AnimatedSprite2D = null

	if not headless:
		var tex_in  := _cached_tex("res://assets/items/spring_in.png")
		var tex_mid := _cached_tex("res://assets/items/spring.png")
		var tex_out := _cached_tex("res://assets/items/spring_out.png")

		if tex_out and tex_out.get_width() > 0:
			var sf := SpriteFrames.new()
			sf.add_animation("idle"); sf.set_animation_loop("idle", false); sf.set_animation_speed("idle", 1.0)
			sf.add_frame("idle", tex_out)
			sf.add_animation("press"); sf.set_animation_loop("press", false); sf.set_animation_speed("press", 8.0)
			if tex_mid: sf.add_frame("press", tex_mid)
			if tex_in:  sf.add_frame("press", tex_in)
			sf.add_animation("release"); sf.set_animation_loop("release", false); sf.set_animation_speed("release", 6.0)
			if tex_in:  sf.add_frame("release", tex_in)
			if tex_mid: sf.add_frame("release", tex_mid)
			sf.add_frame("release", tex_out)

			anim = AnimatedSprite2D.new()
			anim.sprite_frames = sf
			var sc := (VH * 0.035) / float(tex_out.get_width())  # eski: 28.0 px sabit → VH * 0.035
			anim.scale = Vector2(sc, sc)
			# NOTE: h_out is intentionally NOT recomputed from tex_out.get_height() here
			# anymore — see comment above. Visual sprite is simply scaled/positioned
			# within the area; the area's own position (and thus collision) stays fixed.
			anim.position = Vector2.ZERO
			anim.play("idle")
			area.add_child(anim)

	var cs := CircleShape2D.new()
	cs.radius = int(VW * 0.023 * 1.6)   # bumped 1.3x -> 1.6x (user request) — 1.3x still felt too small
	var col := CollisionShape2D.new()
	col.shape    = cs
	col.position = Vector2.ZERO
	area.add_child(col)

	area.position = Vector2(0, -(PLATFORM_H * 0.5) - h_out * 0.5)
	# Tick-accurate: registered in _interactables, checked each tick by GM
	# used_ref is an Array[bool] so the lambda closure shares the same reference
	var used_ref : Array = [false]
	_interactables.append({
		"area": area, "type": "spring",
		"data": {"used_ref": used_ref, "anim": anim},
		"used": false, "_cached": false, "_r": 0.0
	})


func _enemies_for_biome(p_score: int = -1) -> Array[Enemy.EnemyType]:
	var use_score := p_score if p_score >= 0 else score
	var biome_score_bucket := (use_score / 500) * 500  
	if biome_score_bucket == _last_biome_score and _biome_enemy_cache.has("list"):
		return _biome_enemy_cache["list"]

	_last_biome_score = biome_score_bucket
	var biome : String = _biome_name_for_score(use_score)
	var pool : Array[Enemy.EnemyType] = []

	match biome:
		"grass":
			pool = [
				Enemy.EnemyType.BEE,
				Enemy.EnemyType.FROG,
				Enemy.EnemyType.SNAIL,
				Enemy.EnemyType.WORM_GREEN,
				Enemy.EnemyType.LADYBUG,
				Enemy.EnemyType.SPIDER,
				Enemy.EnemyType.SLIME_GREEN,
			]
		"desert":
			pool = [
				Enemy.EnemyType.SPIKEBALL,
				Enemy.EnemyType.SPIKEMAN,
				Enemy.EnemyType.SPRINGMAN,
				Enemy.EnemyType.FLY,
				Enemy.EnemyType.MOUSE,
				Enemy.EnemyType.SPIDER,
			]
		"fall":
			pool = [
				Enemy.EnemyType.FLYMAN,
				Enemy.EnemyType.WINGMAN,
				Enemy.EnemyType.BARNACLE,
				Enemy.EnemyType.WORM_PINK,
				# user request: cloud enemy disabled — removed from spawn pool
				Enemy.EnemyType.GHOST,
			]
		"sky":
			pool = [
				Enemy.EnemyType.SUN,
				Enemy.EnemyType.SLIME_FIRE,
				Enemy.EnemyType.SLIME_BLUE,
				Enemy.EnemyType.SLIME_PURPLE,
				Enemy.EnemyType.SLIME_BLOCK,
				Enemy.EnemyType.GHOST,
			]
		"space":
			# Uzay biyomu: mevcut uzaylılar tekrar aktif. Her tipin kendi
			# hareket/AI davranışı Enemy.gd içinde korunur.
			pool = [
				Enemy.EnemyType.UFO,
				Enemy.EnemyType.ALIEN_GREEN,
				Enemy.EnemyType.ALIEN_BLUE,
				Enemy.EnemyType.ALIEN_PINK,
				Enemy.EnemyType.ALIEN_YELLOW,
				Enemy.EnemyType.ALIEN_GREEN,  # daha sık
				Enemy.EnemyType.ALIEN_YELLOW, # daha sık
			]

	var available : Array[Enemy.EnemyType] = []
	for t in pool:
		if _enemy_frames.has(t):
			available.append(t)
	_biome_enemy_cache["list"] = available
	return available


## Registers an enemy that was spawned OUTSIDE the normal _add_enemy() path
## (currently: baby worms split off from a killed adult, see
## Enemy.gd::_worm_spawn_baby) into the same _enemies array that drives
## simulate_tick() every physics frame. Without this, such an enemy sits in
## the scene tree fully initialized but never actually ticks — no movement,
## no AI, no platform-snap — because `for e in _enemies: e.simulate_tick()`
## is the only thing that ever calls simulate_tick() on anyone.
func register_split_enemy(e: Node) -> void:
	if is_instance_valid(e) and not _enemies.has(e):
		_enemies.append(e)


func _add_enemy(plat: StaticBody2D, p_diff: float = -1.0, p_score: int = -1) -> int:
	var use_diff := p_diff if p_diff >= 0.0 else _difficulty()
	if _enemy_frames.is_empty(): return -1

	var available := _enemies_for_biome(p_score)
	if available.is_empty(): return -1

	var etype := available[_rng.randi() % available.size()]
	var frames : Dictionary = _enemy_frames.get(etype, {})
	if frames.is_empty(): return -1

	var enemy : EnemyBase = _enemy_script.new()
	add_child(enemy)
	var alien_types := [Enemy.EnemyType.ALIEN_GREEN, Enemy.EnemyType.ALIEN_BLUE,
						Enemy.EnemyType.ALIEN_PINK, Enemy.EnemyType.ALIEN_YELLOW]
	var y_offset : float = PLATFORM_H * 0.5 + VH * 0.0225
	if etype in alien_types:
		y_offset = PLATFORM_H * 0.5 + VW * 0.09  # sprite yüksekliğinin yarısı (2.25x scale)
	enemy.global_position = plat.global_position + Vector2(0, -y_offset)

	enemy.set("_platform", plat)
	# B2 fix: seed derived from game_seed + a monotonic spawn counter + enemy type,
	# independent of _rng's current state — so spawn-order/timing jitter between
	# client and server can no longer desync per-enemy RNG (does not consume _rng).
	var enemy_seed : int = hash(game_seed ^ (_enemy_spawn_counter << 16) ^ int(etype))
	_enemy_spawn_counter += 1
	enemy._rng.seed = enemy_seed

	# Pass player reference directly — in headless mode get_tree().get_nodes_in_group()
	# accesses SceneTree which causes a crash; this avoids it.
	enemy.set("_player_ref", player)
	enemy.set("_gm_ref", self)   # GameManager ref for projectile AABB registration

	if plat.has_method("connect_enemy"):
		plat.connect_enemy(enemy)
	elif plat.has_signal("platform_broke"):
		# Same fix as Platform.gd's connect_enemy() — capture instance ID, not
		# the Node itself, to avoid the engine's "Lambda capture ... was freed"
		# log noise when the enemy dies before the platform breaks.
		var enemy_id := enemy.get_instance_id()
		plat.platform_broke.connect(func():
			var e := instance_from_id(enemy_id)
			# ZOMBIE-NODE FIX: same class of bug as Platform.gd's connect_enemy —
			# is_instance_valid() alone can't tell a genuinely-dead enemy from
			# one that's merely un-flushed inside a seek_to_tick() server-replay
			# burst (queue_free() never flushes mid-run there). e._removed is
			# set synchronously the instant the enemy actually dies, so it
			# catches the case is_instance_valid() misses and prevents _die()
			# from double-firing (double-counted kills / stat desync between
			# client recording and server verification of the same replay).
			if is_instance_valid(e) and not bool(e.get("_removed")) and e.has_method("_die"):
				e.call("_die")
		)

	enemy.setup(etype, frames, use_diff)
	_enemies.append(enemy)

	# Springman veya slime block varsa aynı platformdaki spike'ları kaldır — çakışmasın
	if etype == Enemy.EnemyType.SPRINGMAN or etype == Enemy.EnemyType.SLIME_BLOCK:
		for i in range(_interactables.size() - 1, -1, -1):
			var entry := _interactables[i]
			if entry.get("type") == "spike":
				var area_raw = entry.get("area")
				if not is_instance_valid(area_raw): continue
				var spike_area := area_raw as Area2D
				if spike_area == null: continue
				if spike_area.get_parent() == plat:
					spike_area.queue_free()
					_interactables.remove_at(i)

	return int(etype)


# Bir platformda GERÇEK item (kart hariç) çıkma ihtimali (enemy'den bağımsız).
# Değerler artık DOĞRUDAN yüzde puanı (oyun başında):
#   NIMIQ %8, CARROT %5, GOLDEN_CARROT %2, BUBBLE/JETPACK/WINGS %1.34 (değişmedi)
# NIMIQ/CARROT/GOLDEN_CARROT zorlukla azalıyor, diğerleri sabit.
# total zaten yüzde birimi olduğundan /100 basit oranlama yeterli (ekstra K
# katsayısına gerek yok — önceki bug buradan kaynaklanmıştı).
func _item_spawn_prob(d: float) -> float:
	var w0 := lerpf(8.0, 4.27, d)    # NIMIQ
	var w1 := lerpf(5.0, 2.5,  d)    # CARROT
	var w4 := 1.34                    # BUBBLE (sabit, değişmedi)
	var w5 := lerpf(2.0, 1.0,  d)    # GOLDEN_CARROT
	var total := w0 + w1 + 1.34 + 1.34 + w4 + w5   # JETPACK=1.34, WINGS=1.34 sabit
	return total / 100.0


func _add_item(plat: StaticBody2D, p_diff: float = -1.0) -> void:
	var d  := p_diff if p_diff >= 0.0 else _difficulty()
	# Ağırlıklar x100 hassasiyetle tutuluyor, oran _item_spawn_prob ile aynı.
	var w0 := int(round(lerpf(800.0, 427.0, d)))   # NIMIQ
	var w1 := int(round(lerpf(500.0, 250.0, d)))   # CARROT
	var w4 := 134                                   # BUBBLE (sabit)
	var w5 := int(round(lerpf(200.0, 100.0, d)))   # GOLDEN_CARROT
	var total := w0 + w1 + 134 + 134 + w4 + w5     # JETPACK=134, WINGS=134 sabit
	var roll  := _rng.randi() % total
	var chosen := 5
	var c := 0
	c += w0; if roll < c: chosen = 0
	else:
		c += w1; if roll < c: chosen = 1
		else:
			c += 134; if roll < c: chosen = 2
			else:
				c += 134; if roll < c: chosen = 3
				else:
					c += w4; if roll < c: chosen = 4
					# else: chosen = 5 (GOLDEN_CARROT) — kalan pay
	var itype : Item.ItemType = _ITEM_TYPES[chosen]
	var item : Item = _item_script.new()
	add_child(item)
	item.global_position = plat.global_position + Vector2(0, -VH * 0.06)
	# _visual_rng seed: burst/animasyon partikülleri replay'de aynı görünsün
	if item.get("_visual_rng") != null:
		item.get("_visual_rng").seed = _rng.state ^ 0xBEEFCAFE
	item.setup(itype, _item_frames.get(itype, []))
	item.item_collected.connect(_on_item_collected)
	# Disable Area2D signal — collision handled by _check_interactables each tick
	item.monitoring  = false
	item.monitorable = false
	_interactables.append({"area": item, "type": "item", "data": item, "used": false, "_cached": false, "_r": 0.0})


func _spawn_spinning_card(spawn_pos: Vector2) -> void:
	# RNG consumed first — must be identical regardless of headless/visual mode
	var is_good    := _rng.randf() < 0.5
	var result_slot := (_CARD_GOOD_SLOTS if is_good else _CARD_BAD_SLOTS)[_rng.randi() % 3]

	var headless := _is_headless

	# Collision area — always created
	var area := Area2D.new()
	area.collision_layer = 4
	area.collision_mask  = 1
	area.monitoring  = false   # tick-accurate: no signal
	area.monitorable = false
	area.global_position = spawn_pos
	add_child(area)

	var cs := CircleShape2D.new()
	cs.radius = VW * 0.027
	var col_shape := CollisionShape2D.new()
	col_shape.shape = cs
	area.add_child(col_shape)

	var pname : String = _CARD_POWERUP_LIST[result_slot]
	var fx_color := Color(0.4, 1.0, 0.5) if _CARD_IS_GOOD_LIST[result_slot] else Color(1.0, 0.4, 0.3)
	var anim_ref : AnimatedSprite2D = null
	var sf_ref   : SpriteFrames = null

	if not headless:
		var loaded : Array[Texture2D] = _lucky_textures
		var ITEM_SIZE := VW * 0.053

		var sf := SpriteFrames.new()
		sf.add_animation("spin")
		sf.set_animation_loop("spin", true)
		sf.set_animation_speed("spin", 8.0)
		for tex in loaded:
			if tex != null:
				sf.add_frame("spin", tex)
		sf_ref = sf

		var anim := AnimatedSprite2D.new()
		anim.sprite_frames = sf
		anim.z_index = 5
		if loaded.size() > 0 and loaded[0] and loaded[0].get_width() > 0:
			var md0 := maxf(float(loaded[0].get_width()), float(loaded[0].get_height()))
			anim.scale = Vector2(ITEM_SIZE / md0, ITEM_SIZE / md0)
		anim.play("spin")
		area.add_child(anim)
		anim_ref = anim

		var bob := anim.create_tween()
		bob.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		bob.set_loops()
		bob.tween_property(anim, "position:y", -VH * 0.00625, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		bob.tween_property(anim, "position:y",  VH * 0.00625, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Tick-accurate: registered in _interactables, checked each tick by GM
	_interactables.append({
		"area": area, "type": "card",
		"data": {
			"powerup": pname,
			"fx_color": fx_color,
			"anim": anim_ref,
			"sf": sf_ref,
			"result_slot": result_slot,
		},
		"used": false, "_cached": false, "_r": 0.0
	})


# ─────────────────────────────────────────────────────────────────
#  TICK-ACCURATE INTERACTABLE COLLISION
#  Area2D.body_entered fires once per FRAME — not per tick.
#  At 2x/4x/8x replay speed, multiple ticks run per frame so the
#  signal may fire late or miss the overlap entirely.
#  Solution: check AABB overlap every tick, same as platform collision.
# ─────────────────────────────────────────────────────────────────

func _register_interactable(area: Area2D, type: String, data: Variant = null) -> void:
	# Disable the Area2D body_entered signal — we handle collision manually
	area.monitoring  = false
	area.monitorable = false
	_interactables.append({"area": area, "type": type, "data": data, "used": false, "_cached": false, "_r": 0.0})

func _check_interactables() -> void:
	if not is_instance_valid(player): return
	if not player._initialized: return

	# Player AABB — matches manual platform collision constants
	var px : float = player.global_position.x
	var py : float = player.global_position.y
	var p_half_w : float = VW * player.HITBOX_W_RATIO
	var p_half_h : float = VH * player.HITBOX_H_RATIO

	# TUNNEL FIX: this tick's movement segment, prev→current player center.
	# Every overlap test below checks the player's swept path against the
	# interactable instead of only the single post-move point — the same
	# fix Player.gd's platform landing already applies (p_bottom_prev), now
	# applied to springs/items/spikes/cards. At high fall speed the
	# post-move-only point can land clean past a small interactable's
	# radius/rect while the segment connecting the two ticks still passed
	# straight through it — that tick was a full skip, not a near-miss.
	var seg_x0 : float = _ci_prev_pos.x
	var seg_y0 : float = _ci_prev_pos.y
	var seg_x1 : float = px
	var seg_y1 : float = py

	# WRAP FIX: Player.gd wraps global_position.x directly (screen edge
	# teleport, exit right / re-enter left or vice versa) *inside the same
	# tick* that _ci_prev_pos was snapshotted from — before the wrap. The
	# swept-path tunnel-fix above/below then sees a "movement" spanning
	# almost the full screen width in one tick and happily reports every
	# item/spike/spring near the player's Y as "the player's path passed
	# through it", triggering pickups/damage in the middle of the screen
	# that never actually happened. A real single-tick horizontal move is
	# nowhere near this large — only a wrap teleport is — so detect it by
	# the jump size and collapse the segment to a point (post-wrap position
	# only, no sweep) for this tick instead of tunnel-checking across it.
	if absf(seg_x1 - seg_x0) > VW * 0.5:
		seg_x0 = seg_x1
		seg_y0 = seg_y1

	_ci_to_remove.clear()

	for i in _interactables.size():
		# Guard: array may have been cleared mid-loop by a game-over/reset signal
		if i >= _interactables.size(): break
		var entry : Dictionary = _interactables[i]
		if entry["used"]: continue
		var area_raw = entry["area"]
		if not is_instance_valid(area_raw): continue
		var area : Area2D = area_raw as Area2D
		if area == null: continue

		# ── Deterministic ballistic trajectory (identical on client & server) ──
		# Projectiles (slime spit/mini, cloud rain, worm dirt) store a "traj"
		# dict in their data instead of relying on a position-tweening Tween,
		# which never advances in headless mode (no frames are rendered during
		# seek_to_tick / server simulation). Driving position here, once per
		# tick, keeps damage collision in sync between recording and replay.
		var entry_data = entry["data"]
		if entry_data is Dictionary and entry_data.has("traj"):
			var traj : Dictionary = entry_data["traj"]
			if not traj.get("landed", false):
				traj["vel"] = (traj["vel"] as Vector2) + (traj["accel"] as Vector2) * float(traj["dt"])
				traj["pos"] = (traj["pos"] as Vector2) + (traj["vel"] as Vector2) * float(traj["dt"])
				area.global_position = traj["pos"]
				var land_y : float = float(traj.get("land_y", INF))
				if (traj["pos"] as Vector2).y > land_y and (traj["vel"] as Vector2).y > 0.0:
					traj["landed"]     = true
					traj["ticks_left"] = int(traj.get("land_extra_ticks", 0))
				else:
					traj["ticks_left"] = int(traj.get("ticks_left", 999999)) - 1
			else:
				traj["ticks_left"] = int(traj.get("ticks_left", 0)) - 1
			if traj["ticks_left"] <= 0:
				entry["used"] = true
				_ci_to_remove.append(i)
				var on_expire : Callable = entry_data.get("on_expire", Callable())
				if on_expire.is_valid(): on_expire.call()
				continue

		# CI-01: Radius cached on first tick via "_cached" bool — avoids entry.has() hash every tick
		var radius : float
		if entry["_cached"]:
			radius = entry["_r"]
		else:
			# First time: scan children once and cache shape data
			radius = VW * 0.027 * 1.2   # matches Item.gd's actual 1.2x hitbox — only hit if the real child shape is somehow missing
			for child in area.get_children():
				if child is CollisionShape2D and child.shape is CircleShape2D:
					radius = (child.shape as CircleShape2D).radius
					break
				elif child is CollisionShape2D and child.shape is RectangleShape2D:
					radius = -2.0  # rect marker
					entry["_rect_child_pos"] = child.position
					entry["_rect_size"] = (child.shape as RectangleShape2D).size
					break
			entry["_r"]      = radius
			entry["_cached"] = true

		if radius == -2.0:
			# Rectangle AABB (spike bottom etc.)
			var rsize : Vector2 = entry["_rect_size"]
			var ax : float = area.global_position.x
			var ay : float = area.global_position.y + entry["_rect_child_pos"].y
			# HARDENING: same float-boundary tie-break class as the platform
			# landing bug — a strict overlap test on continuously-accumulated
			# floats can flip right at the edge between two runs of the same
			# replay. Small epsilon (see Player.gd LAND_EPS) makes the trigger
			# consistent instead of knife-edge.
			const _OVERLAP_EPS := 0.05
			# TUNNEL FIX: swept AABB — X range unchanged (horizontal speed is
			# never large enough in one tick to matter here), Y range widened
			# to cover the whole prev→current vertical span instead of just
			# the current tick's Y. A fast fall can otherwise cross a thin
			# rect (spike strip) entirely within one tick and never register
			# as "inside" on either endpoint.
			var seg_y_min : float = min(seg_y0, seg_y1) - p_half_h
			var seg_y_max : float = max(seg_y0, seg_y1) + p_half_h
			if (px + p_half_w > ax - rsize.x * 0.5 - _OVERLAP_EPS and px - p_half_w < ax + rsize.x * 0.5 + _OVERLAP_EPS and
				seg_y_max > ay - rsize.y * 0.5 - _OVERLAP_EPS and seg_y_min < ay + rsize.y * 0.5 + _OVERLAP_EPS):
				var etype2 : String = entry["type"]
				var is_spring2     : bool = (etype2 == "spring")
				var is_spike2      : bool = (etype2 == "spike")
				var is_persistent2 : bool = (etype2 == "proj_damage" and
					entry["data"] is Dictionary and not entry["data"].get("one_shot", true))
				if not is_spring2 and not is_spike2 and not is_persistent2:
					entry["used"] = true
					_ci_to_remove.append(i)
				_trigger_interactable(entry, area)
			continue

		# Circle overlap vs the player's swept path (mid-body line from
		# prev tick's position to this tick's position), not just the
		# current point. TUNNEL FIX: at high fall speed the current-point-
		# only test can find the player already past the circle on the
		# very first tick that would have overlapped it — the segment
		# still passed through even though neither endpoint sits inside.
		var ax : float = area.global_position.x
		var ay : float = area.global_position.y
		# Mid-body line endpoints (same -p_half_h*0.5 offset the old point
		# test used, applied to both ends of the segment).
		var mx0 : float = seg_x0
		var my0 : float = seg_y0 - p_half_h * 0.5
		var mx1 : float = seg_x1
		var my1 : float = seg_y1 - p_half_h * 0.5
		# Closest point on segment [m0,m1] to the circle center (ax, ay).
		var ex : float = mx1 - mx0
		var ey : float = my1 - my0
		var seg_len_sq : float = ex * ex + ey * ey
		var t : float = 0.0
		if seg_len_sq > 0.0000001:
			t = ((ax - mx0) * ex + (ay - my0) * ey) / seg_len_sq
			t = clamp(t, 0.0, 1.0)
		var cx : float = mx0 + ex * t
		var cy : float = my0 + ey * t
		var dx : float = cx - ax
		var dy : float = cy - ay
		var dist_sq : float = dx * dx + dy * dy
		# HARDENING: +0.05 before squaring — same tie-break fix as the rect
		# overlap above and Player.gd's platform-landing check.
		var touch_r : float = radius + p_half_w * 0.7 + 0.05
		if dist_sq < touch_r * touch_r:
			var etype : String = entry["type"]
			var is_spring      : bool = (etype == "spring")
			var is_spike       : bool = (etype == "spike")
			# proj_damage with one_shot=false stays alive (persistent cloud/zone)
			var is_persistent  : bool = (etype == "proj_damage" and
				entry["data"] is Dictionary and not entry["data"].get("one_shot", true))
			# SPRING: only triggers coming down onto it from above — jumping up
			# into it from underneath the platform no longer works (user request).
			# py > ay + eps means the player's center is BELOW the spring's
			# center (Y grows downward), i.e. approaching from underneath.
			# BUG FIX: position alone isn't enough — on a one-way platform the
			# player's center crosses to being numerically "above" the spring
			# (py <= ay) the instant they pass through from below, WHILE STILL
			# MOVING UPWARD (haven't hit the jump apex yet). That crossing tick
			# used to satisfy py <= ay and trigger the spring immediately, which
			# looked/felt exactly like triggering it from underneath. Requiring
			# velocity.y >= 0 (actually falling, not still rising) closes that
			# gap — the spring now only fires while genuinely descending onto it.
			#
			# TUNNEL-FIX UPDATE: this direction check now uses seg_y0 (the
			# player's position at the START of this tick, i.e. before this
			# tick's move) instead of py (the position AFTER this tick's
			# move). With the swept test above, the tick that finally
			# registers contact can be one where the player has already
			# moved past the spring's center (py <= ay) despite genuinely
			# falling onto it from above all tick — using the pre-move Y
			# preserves "was above it a moment ago" as the real signal for
			# "approached from above", instead of re-introducing the exact
			# from-below false-trigger the original bugfix above closed.
			# Player.simulate_tick() runs BEFORE this function and changes
			# velocity.y immediately on a normal platform landing (it sets
			# JUMP_SPEED). Reading player.velocity.y here therefore sees the
			# POST-landing upward velocity, not the velocity that approached
			# the spring. That made a spring on a breaking platform fire in
			# live timing but be rejected during replay at the boundary.
			# _tick_entry_velocity_y is captured at the very start of the same
			# deterministic tick, before platform landing/bounce resolution.
			var falling : bool = float(player.get("_tick_entry_velocity_y")) >= 0.0
			if is_spring and (seg_y0 > ay + 0.05 or not falling):
				continue
			if not is_spring and not is_spike and not is_persistent:
				entry["used"] = true
				_ci_to_remove.append(i)
			_trigger_interactable(entry, area)

	# Remove used/dead entries (reverse order to keep indices valid)
	# Deduplicate first — same index can appear twice if rect+circle both matched
	_ci_seen.clear()
	_ci_deduped.clear()
	for idx in _ci_to_remove:
		if not _ci_seen.has(idx):
			_ci_seen[idx] = true
			_ci_deduped.append(idx)
	_ci_deduped.sort()
	for i in range(_ci_deduped.size() - 1, -1, -1):
		var ri : int = _ci_deduped[i]
		if ri < _interactables.size():
			_interactables.remove_at(ri)

func trigger_springs_on_landing(plat: Node) -> void:
	# Deterministic landing hook. The old spring path depended only on the
	# swept circle test after Player.simulate_tick(); when the same tick also
	# started a platform break, tiny client/native boundary differences could
	# make the spring trigger on one side but not the other. Landing already
	# resolved the exact platform, so use that authoritative event.
	if not is_instance_valid(plat) or not is_instance_valid(player): return
	if bool(plat.get("_breaking")):
		# The platform may have entered break state on this landing; the spring
		# is still allowed to finish the landing bounce before removal.
		pass
	var p_half_w : float = VW * player.HITBOX_W_RATIO
	for entry in _interactables:
		if entry.get("type", "") != "spring": continue
		var area_raw = entry.get("area")
		if not is_instance_valid(area_raw): continue
		var area := area_raw as Area2D
		if area == null or area.get_parent() != plat: continue
		var used_ref : Array = (entry.get("data") as Dictionary).get("used_ref", [false])
		if used_ref[0]: continue
		var spring_r := VW * 0.023 * 1.6
		if absf(player.global_position.x - area.global_position.x) <= p_half_w + spring_r + 0.05:
			_trigger_interactable(entry, area)


func _trigger_interactable(entry: Dictionary, area: Area2D) -> void:
	var type : String  = entry["type"]
	var data : Variant = entry["data"]
	match type:
		"item":
			# data = Item node
			var item_node = data
			if is_instance_valid(item_node) and item_node.has_method("_on_body_entered"):
				item_node.call("_on_body_entered", player)
		"spike":
			if is_instance_valid(player) and player.has_method("hit_enemy"):
				if not player.get("is_powered_up"):
					player.call("hit_enemy")
		"spring":
			if is_instance_valid(player) and player.get("is_powered_up"):
				return  # jetpack/wings aktifken spring player'a hiç etki etmesin
			var spring_data : Dictionary = data if data is Dictionary else {}
			var used_ref : Array = spring_data.get("used_ref", [false])
			if used_ref[0]: return
			used_ref[0] = true
			if is_instance_valid(player) and player.has_method("do_spring_jump"):
				player.call("do_spring_jump")
			if not _is_headless:
				apply_camera_shake(4.0, 0.15)
				var anim_node = spring_data.get("anim", null)
				if is_instance_valid(anim_node): anim_node.play("press")
				# Visual-only anim tween (does NOT control used_ref reset)
				var tw := area.create_tween()
				if tw:
					tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
					tw.tween_interval(0.18)
					tw.tween_callback(func():
						if is_instance_valid(anim_node): anim_node.play("release")
					)
					tw.tween_interval(0.35)
					tw.tween_callback(func():
						if is_instance_valid(anim_node): anim_node.play("idle")
					)
			# Always reset used_ref via tick-based counter (deterministic for recording & replay)
			_pending_spring_resets.append({"ref": used_ref, "ticks": 32})
		"card":
			var card_data : Dictionary = data if data is Dictionary else {}
			var pname : String = card_data.get("powerup", "")
			if pname != "" and is_instance_valid(player) and player.has_method("activate_powerup"):
				player.call("activate_powerup", pname)
				_powerup_hud_dirty = true
			if not _is_headless:
				var fx_color : Color = card_data.get("fx_color", Color(0.4, 1.0, 0.5))
				_spawn_card_fx(area.global_position, fx_color)
				# Visual pop anim — area freed after tween
				var anim_node = card_data.get("anim", null)
				var sf_node   = card_data.get("sf", null)
				var result_slot : int = card_data.get("result_slot", 0)
				if is_instance_valid(anim_node) and is_instance_valid(sf_node):
					sf_node.set_animation_loop("spin", false)
					anim_node.stop()
					var _fc : int = sf_node.get_frame_count("spin")
					if _fc > 0:
						anim_node.set_frame_and_progress(result_slot % _fc, 0.0)
					var pop : Tween = anim_node.create_tween()
					if pop:
						pop.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
						pop.tween_property(anim_node, "scale", anim_node.scale * 1.5, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
						pop.tween_property(anim_node, "scale", Vector2.ZERO, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
						pop.tween_callback(func():
							if is_instance_valid(area):
								area.queue_free())
					return   # area freed by tween
			if is_instance_valid(area): area.queue_free()
		"proj_damage":
			# Slime projectile — deal damage if not powered up, then free if one_shot
			if is_instance_valid(player) and player.has_method("hit_enemy"):
				if not player.get("is_powered_up"):
					player.call("hit_enemy")
			var one_shot : bool = true
			if data is Dictionary: one_shot = data.get("one_shot", true)
			if one_shot:
				var on_hit : Callable = data.get("on_expire", Callable()) if data is Dictionary else Callable()
				if on_hit.is_valid(): on_hit.call()
				elif is_instance_valid(area): area.queue_free()
		"rain_damage":
			# Cloud rain drop — deal damage if not powered up, then free
			if is_instance_valid(player) and player.has_method("hit_enemy"):
				if not player.get("is_powered_up"):
					player.call("hit_enemy")
			var on_hit2 : Callable = data.get("on_expire", Callable()) if data is Dictionary else Callable()
			if on_hit2.is_valid(): on_hit2.call()
			elif is_instance_valid(area): area.queue_free()
		"dirt_damage":
			# Worm dirt block — deal damage if not powered up, then destroy via worm handler
			if is_instance_valid(player) and player.has_method("hit_enemy"):
				if not player.get("is_powered_up"):
					player.call("hit_enemy")
			# Destruction is handled by the enemy node that owns the dirt
			var enemy_ref = data.get("enemy", null) if data is Dictionary else null
			if is_instance_valid(enemy_ref) and enemy_ref.has_method("_worm_destroy_dirt"):
				enemy_ref.call("_worm_destroy_dirt", area, true)
			elif is_instance_valid(area):
				area.queue_free()

# Spring reset timer list — headless mode only
var _pending_spring_resets : Array[Dictionary] = []

func _tick_spring_resets() -> void:
	for i in range(_pending_spring_resets.size() - 1, -1, -1):
		_pending_spring_resets[i]["ticks"] -= 1
		if _pending_spring_resets[i]["ticks"] <= 0:
			var ref : Array = _pending_spring_resets[i]["ref"]
			if ref.size() > 0: ref[0] = false
			_pending_spring_resets.remove_at(i)


# ─────────────────────────────────────────────────────────────────
#  CARD FX PARTICLE
# ─────────────────────────────────────────────────────────────────
func _spawn_card_fx(pos: Vector2, col: Color) -> void:
	if _is_headless: return
	var key : int = col.to_rgba32()
	if not _card_fx_tex_cache.has(key):
		var sz  : int = maxi(4, int(VW * 0.010))
		var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
		img.fill(col)
		_card_fx_tex_cache[key] = ImageTexture.create_from_image(img)
	var tex : ImageTexture = _card_fx_tex_cache[key] as ImageTexture

	for i in 10:
		var p := Sprite2D.new()
		p.texture  = tex
		p.z_index  = 6
		add_child(p)
		p.global_position = pos
		var angle := _shake_rng.randf_range(0.0, TAU)
		var speed := _shake_rng.randf_range(VW * 0.1, VW * 0.28)
		var vel   := Vector2(cos(angle), sin(angle)) * speed
		var dur   := _shake_rng.randf_range(0.28, 0.52)
		var tw    := p.create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(p, "global_position", p.global_position + vel * dur, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(p, "modulate:a", 0.0, dur)
			tw.tween_callback(func():
				if is_instance_valid(p):
					p.queue_free())


# ─────────────────────────────────────────────────────────────────
#  DIFFICULTY
# ─────────────────────────────────────────────────────────────────
func _difficulty() -> float:
	# user request: first 500 points should feel noticeably easier — ramp
	# very gently from 0 to 0.10 over that stretch, then continue the climb
	# to 1.0 at score 3000 same as before (curve is continuous at score=500,
	# 0.10 there either way it's computed).
	if score < 500:
		return clampf(float(score) / 500.0, 0.0, 1.0) * 0.10
	return clampf(0.10 + (float(score) - 500.0) / 2500.0 * 0.90, 0.0, 1.0)


func _biome_name_for_score(s: int) -> String:
	# 5 biyom, 500'er puanlık dilimler:
	# grass → desert → fall → sky → space → tekrar grass.
	# Uzay biyomu özellikle 2000-2499 aralığındadır; bu aralıkta
	# uzaylı havuzu açılır ve Enemy.gd içindeki özel AI'lar çalışır.
	var cycle : int = s % 2500
	if cycle < 0: cycle += 2500   # negatif skor güvenliği
	if cycle < 500:  return "grass"
	if cycle < 1000: return "desert"
	if cycle < 1500: return "fall"
	if cycle < 2000: return "sky"
	return "space"


func _ground_set_for_score(s: int) -> Dictionary:
	var bname := _biome_name_for_score(maxi(s, 0))
	var idx   : int = _BIOME_IDX.get(bname, 0)
	if idx < _ground_sets.size():
		return _ground_sets[idx]
	if not _ground_sets.is_empty():
		return _ground_sets[0]
	return {}


# ─────────────────────────────────────────────────────────────────
#  CAMERA SHAKE
# ─────────────────────────────────────────────────────────────────
func apply_camera_shake(strength: float, duration: float) -> void:
	_shake_strength = strength
	_shake_timer    = duration

func _apply_camera_shake(delta: float) -> void:
	# CS-01: When not shaking, only zero the offset once (when shake just ended)
	if _shake_timer <= 0.0:
		if _shake_timer > -1.0:   # first tick after shake ended: reset offset once
			if is_instance_valid(camera): camera.offset = Vector2.ZERO
			_shake_timer = -999.0  # sentinel: already zeroed, skip forever
		return
	_shake_timer -= delta
	if is_instance_valid(camera):
		camera.offset = Vector2(
			_shake_rng.randf_range(-_shake_strength, _shake_strength),
			_shake_rng.randf_range(-_shake_strength, _shake_strength)
		)


# ─────────────────────────────────────────────────────────────────
#  POWERUP HUD
# ─────────────────────────────────────────────────────────────────
func _update_powerup_hud() -> void:
	if not _main_has_pwrup_hud or not is_instance_valid(main_node): return
	if not is_instance_valid(player): return
	var _ptype : String = player.get("powerup_type")
	var _ptmax : float  = 4.0 if _ptype == "wings" else 5.0
	# BUG FIX: shield_timer was passed as player.get("powerup_timer") — the
	# SAME jetpack/wings timer, copy-pasted by mistake. has_shield has no
	# timer of its own in Player.gd at all (it's permanent until the player
	# takes a hit, see Player.gd ~line 930), so the shield's HUD ring was
	# literally ticking down in sync with whatever the flight powerup's
	# remaining time happened to be — exactly the "one powerup's timer UI
	# affects the other" symptom reported. Since shield has no real
	# countdown, show it as a full/static ring (t_cur == t_max) instead.
	const _SHIELD_TMAX := 1.0
	main_node.call("update_powerup_hud",
		player.get("is_powered_up"),
		_ptype,
		player.get("powerup_timer"),
		_ptmax,
		player.get("has_shield"),
		_SHIELD_TMAX,
		_SHIELD_TMAX,
		player.get("_mirror_active"),
		player.get("_mirror_timer"),
		player.get("_eq_active"),
		player.get("_eq_debuff_timer"),
		player.get("_drunk_active"),
		player.get("_drunk_timer")
	)


# ─────────────────────────────────────────────────────────────────
#  ITEM EVENTS
# ─────────────────────────────────────────────────────────────────
func _on_item_event(_type: String) -> void:
	pass

func _on_item_collected(type: int, _points: int) -> void:
	# Track item collection for quest counters
	_quest_item_types[type] = true
	match type:
		Item.ItemType.NIMIQ:
			_quest_coins += 1
			if is_instance_valid(main_node) and main_node.has_method("update_nimiq_display"):
				main_node.call("update_nimiq_display", _quest_coins)
		Item.ItemType.GOLDEN_CARROT:
			_quest_golden_carrots += 1
		Item.ItemType.JETPACK, Item.ItemType.WINGS, Item.ItemType.BUBBLE:
			_quest_powerups += 1
			_quest_used_powerup = true
			_powerup_hud_dirty = true
	# Her item toplandığında HUD refresh — powerup aktif olmuş olabilir
	_powerup_hud_dirty = true


# ─────────────────────────────────────────────────────────────────
#  PLAYER DIED
# ─────────────────────────────────────────────────────────────────

# Flying enemy types — used for quest tracking
var FLYING_ENEMY_TYPES : Array = [
	Enemy.EnemyType.FLYMAN, Enemy.EnemyType.WINGMAN, Enemy.EnemyType.BEE,
	Enemy.EnemyType.FLY, Enemy.EnemyType.LADYBUG, Enemy.EnemyType.CLOUD,
	Enemy.EnemyType.UFO,
]

func on_enemy_killed(etype: int = -1) -> void:
	_quest_kills += 1
	if not _quest_took_damage:
		_quest_kills_no_dmg += 1
	if etype >= 0:
		if etype in FLYING_ENEMY_TYPES:
			_quest_flying_kills += 1
		if etype == Enemy.EnemyType.FLY:  # mosquito = FLY type
			_quest_mosquito_kills += 1
		_quest_enemy_types[etype] = true
	# Kill combo — increment; no missed-jump tracking needed (kills are consecutive)
	_quest_combo += 1
	_quest_combo_max = maxi(_quest_combo_max, _quest_combo)

func on_platform_landed() -> void:
	_quest_platforms += 1
	if not _quest_took_damage:
		_quest_noHit_streak += 1
		_quest_noHit_max = maxi(_quest_noHit_max, _quest_noHit_streak)
	else:
		_quest_noHit_streak = 0
	# Track altitude progress (platforms as proxy for height reached)
	_quest_highest_y_plat = _quest_platforms

func on_player_took_damage() -> void:
	_quest_took_damage = true
	# Reset combo and no-hit streak on damage
	_quest_combo        = 0
	_quest_noHit_streak = 0

## Reset all quest counters to zero — called at the start of every match/replay.
func _reset_quest_counters() -> void:
	_quest_kills          = 0
	_quest_flying_kills   = 0
	_quest_mosquito_kills = 0
	_quest_platforms      = 0
	_quest_coins          = 0
	if is_instance_valid(main_node) and main_node.has_method("update_nimiq_display"):
		main_node.call("update_nimiq_display", 0)
	_quest_golden_carrots = 0
	_quest_powerups       = 0
	_quest_took_damage    = false
	_quest_item_types     = {}
	_quest_used_mirror    = false
	_quest_used_powerup   = false
	_quest_no_coins       = false
	_quest_enemy_types    = {}
	_quest_combo          = 0
	_quest_combo_max      = 0
	_quest_noHit_streak   = 0
	_quest_noHit_max      = 0
	_quest_highest_y_plat = 0
	_quest_kills_no_dmg   = 0
	# Boss reset

# ─────────────────────────────────────────────────────────────────
func _on_player_died() -> void:
	print("[DIED] _game_over=%s _replay_mode=%d _replay_nickname=%s" % [str(_game_over), _replay_mode, _replay_nickname])
	if _game_over: return
	_game_over = true

	if _replay_mode == ReplayMode.PLAYING:
		# "viewer" = leaderboard/stats/web replay — player died, just stop, do not emit
		# Exit button calls stop_replay() → replay_finished is emitted then
		if _replay_nickname == "viewer":
			print("[DIED] viewer replay ended — pausing, NOT emitting replay_finished")
			_replay_mode   = ReplayMode.OFF
			_replay_paused = true
			# Freeze player — reset is_dead/velocity so it doesn't stay broken on lobby return
			if is_instance_valid(player):
				player.set("is_dead",    false)
				player.set("_initialized", false)
				player.velocity = Vector2.ZERO
			return
		_replay_mode = ReplayMode.OFF
		_replay_paused = false
		# Print quest result for server-side analysis (headless replay)
		if _is_headless:
			var lives_left : int = 0
			if is_instance_valid(player) and player.get("lives") != null:
				lives_left = int(player.get("lives"))
			print("[QUEST_RESULT] " + JSON.stringify({
				"score":           score,
				"ticks":           _replay_tick_count,
				"kills":           _quest_kills,
				"flying_kills":    _quest_flying_kills,
				"mosquito_kills":  _quest_mosquito_kills,
				"platforms":       _quest_platforms,
				"coins":           _quest_coins,
				"golden_carrots":  _quest_golden_carrots,
				"powerups":        _quest_powerups,
				"took_damage":     _quest_took_damage,
				"item_types":      _quest_item_types.size(),
				"lives_left":      lives_left,
				"used_mirror":     _quest_used_mirror,
				"used_powerup":    _quest_used_powerup,
				"no_coins":        _quest_coins == 0,
				"enemy_types":     _quest_enemy_types.size(),
				"combo_max":       _quest_combo_max,
				"nohit_max":       _quest_noHit_max,
				"kills_no_dmg":    _quest_kills_no_dmg,
				"highest_y":       highest_y,
			}))
		for child in get_children().duplicate():
			if child == player or child == camera: continue
			if child is HTTPRequest: continue
			child.queue_free()
		_platforms.clear()
		_enemies.clear()
		# BUG FIX ("watched own replay to the end, went back — leftover
		# projectiles/particles still flying, character still showing
		# hurt-flash/invincibility tint/debuffs"): this is the ONE cleanup
		# block in the whole file that queue_free()'s the scene without
		# also clearing _interactables (the tick-driven trajectory table
		# still-in-flight rocks/dirt/rain read from every physics tick —
		# see _check_interactables()) and without resetting the player's
		# transient state. Every other reset path in this file (stop_replay,
		# reset_for_lobby, _init_game_from_seed, start_replay, seek_to_tick,
		# prep_worker_job) clears all of these; this one was the odd one out.
		_drunk_plat_timer = 0.0
		_interactables.clear()
		_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
		_pending_spring_resets.clear()
		_biome_enemy_cache.clear()
		_last_biome_score = -1
		if is_instance_valid(player):
			player.velocity = Vector2.ZERO
			if player.has_method("reset_transient_state"):
				player.call("reset_transient_state")
		if is_instance_valid(camera):
			camera.offset = Vector2.ZERO
		replay_finished.emit()
		return

	if _replay_mode == ReplayMode.RECORDING:
		_replay_seed  = game_seed
		_replay_score = score
		_replay_char  = 0
		if is_instance_valid(main_node) and main_node.get("_char_index") != null:
			_replay_char = int(main_node.get("_char_index"))
		_replay_gyro_active = false
		if is_instance_valid(main_node) and main_node.get("_control_mode") != null:
			_replay_gyro_active = (str(main_node.get("_control_mode")) == "gyro")
		_replay_mode = ReplayMode.OFF
		print("[REPLAY] Recording complete. %d ticks (%d bytes), seed=%d" % [_replay_tick_count, _replay_log.size(), _replay_seed])

	if is_instance_valid(main_node):
		if main_node.has_method("show_seed"):
			main_node.call("show_seed", game_seed)
		if main_node.has_method("update_final_display"):
			main_node.call("update_final_display", score)
		if main_node.has_method("show_game_over"):
			var _go_stats := {
				"platforms": _quest_platforms,
				"kills":     _quest_kills,
				"coins":     _quest_coins,
				"combo_max": _quest_combo_max,
			}
			main_node.call("show_game_over", score, best_score, _go_stats)

	_submit_session()


const LS_PENDING := "nj_pending_submissions"

## Returns true only if the user is signed in (has a valid auth token).
## Guest players never submit or prefetch — everything stays local.
func _is_authed() -> bool:
	if not is_instance_valid(main_node): return false
	var tok = main_node.get("_auth_token")
	return tok != null and str(tok) != ""

## 401 gelince Main'e bildir — token temizlensin
func _notify_auth_expired() -> void:
	if is_instance_valid(main_node) and main_node.has_method("_on_auth_expired"):
		main_node.call("_on_auth_expired")

func _ls_get(key: String) -> Array:
	if not OS.has_feature("web"):
		return []
	var raw = JavaScriptBridge.eval("localStorage.getItem('%s')" % key, true)
	if raw == null or str(raw) == "null" or str(raw) == "":
		return []
	var raw_str : String = str(raw)
	var j := JSON.new()
	if j.parse(raw_str) == OK and j.get_data() is Array:
		return j.get_data()
	return []

func _ls_set(key: String, arr: Array) -> void:
	if not OS.has_feature("web"):
		return
	# BUG FIX: this used to build the JS eval() string by hand — JSON.stringify(arr)
	# then a naive .replace("'", "\\'") to escape single quotes for embedding inside
	# a single-quoted JS string literal. That only escapes quote CHARACTERS; when
	# any queued entry's own "body" field is ITSELF a JSON string (which it always
	# is here — see _pending_save below), JSON.stringify()'s OWN escaping of that
	# nested string's double-quotes produces literal backslash-quote (\") sequences
	# in the output. Embedding THAT raw inside a JS string literal is wrong: JS's
	# own string-literal parser treats \" as an escape sequence for a bare quote,
	# silently consuming the backslash — the nested JSON's quotes end up
	# unescaped once eval() runs, corrupting the stored JSON (exactly the
	# "[PendingSubmissions] failed to parse ... Expected '}' or ','" report this
	# was causing). Base64-encoding the JSON text sidesteps the whole class of
	# problem: base64 only ever contains [A-Za-z0-9+/=], which never needs any
	# escaping to embed in a JS string literal, so atob() on the JS side always
	# reconstructs the exact original bytes with zero ambiguity.
	var json_str := JSON.stringify(arr)
	var b64 := Marshalls.utf8_to_base64(json_str)
	JavaScriptBridge.eval("localStorage.setItem('%s', atob('%s'))" % [key, b64], true)

func _ls_remove(key: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("localStorage.removeItem('%s')" % key, true)

func _ls_get_str(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var raw = JavaScriptBridge.eval("localStorage.getItem('%s') || ''" % key, true)
	return str(raw) if raw != null else ""

func _ls_set_str(key: String, val: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("localStorage.setItem('%s','%s')" % [key, val], true)


# ───────────────────────────────────────────────────────────────────
#  SERVER-ISSUED OFFLINE SEED QUEUE
# ───────────────────────────────────────────────────────────────────
# See backend/game/seed_batch.go for the full design rationale. Short
# version: while online, the client asks POST /backend/seeds/issue for a
# small batch of server-signed (seed, expiry, sig) tuples and stores them
# locally. Play then consumes one at a time, fully offline, with zero
# further server contact — but because the signature can only ever be
# produced by the server (the signing key never ships to the client), the
# player can only ever play a seed we actually handed them, not one they
# picked or generated themselves. This replaces the old pure-client-side
# seed generation, which let anyone locally pre-simulate unlimited
# candidate seeds and only ever submit the best one ("seed shopping").
#
# Guests (not signed in) are exempt entirely — see the _is_authed() branch
# in _start_session below — and keep the old fully-local generation, since
# /backend/seeds/issue requires an auth token. A guest run that somehow
# gets flushed to /backend/submit after later signing in will just come
# back bad_seed_signature (no seed_sig/seed_expiry attached) and get
# dropped by the existing pending-queue permanent-rejection handling in
# flush_pending() — no special-casing needed for that, it falls out for
# free from the existing code path.

const LS_SEED_QUEUE   := "nj_seed_queue"
const SEED_BATCH_SIZE := 10   # MUST match backend/game/seed_batch.go's SeedBatchSize

var _seed_queue            : Array = []   # [{seed:String, expiry:String, sig:String, player_id:String}, ...]
var _seed_queue_loaded     : bool  = false

## Bumped at the top of every _start_session() call. Lets an in-flight
## (awaiting) call detect that a *newer* call has since started — e.g. the
## lobby's background "auth just arrived, upgrade guest seed to a signed
## one" reseed racing against the player mashing Play before it resolves —
## and bail out without clobbering the newer call's state.
var _session_gen           : int   = 0
var _seed_refill_in_flight : bool  = false

## seed_sig / seed_expiry for the CURRENTLY ACTIVE game_seed. Empty string
## for guest play or VS-room forced seeds — neither goes through the
## issued-seed path (see submitReq.SeedSig's doc comment on the server for
## why both are exempt from the signature check). Attached to the submit
## payload in _submit_session() below.
var _current_seed_sig    : String = ""
var _current_seed_expiry : String = ""

## BUG FIX ("legitimate run rejected as bad_seed_signature even though the
## player WAS signed in"): a run that starts as a guest (seed generated
## locally, sig/expiry correctly left blank) can have wallet sign-in
## complete mid-run — e.g. a background Hub sign resolving a few seconds
## after Play. _submit_session() used to read player_id live off main_node
## at SUBMIT time, while _current_seed_sig/_current_seed_expiry stay frozen
## at whatever they were when the seed was chosen (START time). That
## produces an internally-inconsistent payload: a real, current, authed
## player_id paired with the blank sig/expiry from before that auth
## existed — server-side this is indistinguishable from a forged seed and
## gets correctly rejected, even though the run itself was legitimate; it
## was just unlucky timing (signed in mid-flight).
## Fix: snapshot the player_id (and nickname) at the exact moment the seed
## is locked in (same instant _current_seed_sig/_current_seed_expiry are
## set), and have _submit_session() use THIS snapshot instead of re-reading
## live auth state later. Empty string here means "was a guest at seed
## pick time" — submit correctly sends blank player_id + blank sig/expiry
## together in that case, which the server accepts as an honest guest run.
var _session_player_id   : String = ""
var _session_nickname    : String = ""

func _current_player_id() -> String:
	if not is_instance_valid(main_node): return ""
	var v = main_node.get("nimiq_address")
	return str(v) if v != null else ""

## Snapshots player_id/nickname at the exact moment a run's seed is locked
## in — called from every branch of _start_session() right alongside where
## _current_seed_sig/_current_seed_expiry are set, so the two can never
## drift apart. See the doc comment on _session_player_id above for why
## this exists. Guest-at-start-time correctly snapshots as "" — that's the
## honest state to submit under, even if the player signs in mid-run.
func _snapshot_session_identity() -> void:
	_session_player_id = _current_player_id()
	_session_nickname  = ""
	if is_instance_valid(main_node) and main_node.get("_nickname") != null:
		_session_nickname = str(main_node.get("_nickname"))

func _load_seed_queue() -> void:
	if _seed_queue_loaded: return
	_seed_queue_loaded = true
	_seed_queue = _ls_get(LS_SEED_QUEUE)

func _save_seed_queue() -> void:
	_ls_set(LS_SEED_QUEUE, _seed_queue)

## Drops any entry that doesn't belong to the currently signed-in player
## (e.g. a device shared between two accounts — a seed signed for player A
## will always fail VerifyIssuedSeed if submitted under player B) or that
## has already expired. Both would only ever get rejected server-side
## anyway, so there's no point holding onto them.
func _prune_seed_queue() -> void:
	var pid := _current_player_id()
	var now := Time.get_unix_time_from_system()
	var kept : Array = []
	for e in _seed_queue:
		if not (e is Dictionary): continue
		if str(e.get("player_id", "")) != pid: continue
		if int(str(e.get("expiry", "0"))) <= now: continue
		kept.append(e)
	if kept.size() != _seed_queue.size():
		_seed_queue = kept
		_save_seed_queue()

## Pops one seed tuple off the front of the queue (oldest-issued first).
## Returns {} if the queue is empty.
func _consume_seed_from_queue() -> Dictionary:
	_load_seed_queue()
	_prune_seed_queue()
	if _seed_queue.is_empty():
		return {}
	var e : Dictionary = _seed_queue.pop_front()
	_save_seed_queue()
	return e

## Fetches a fresh SEED_BATCH_SIZE batch from POST /backend/seeds/issue and
## appends it to the local queue. Returns true on success. If a request is
## already in flight, returns false immediately rather than firing a
## second one.
func _request_seed_batch() -> bool:
	if _seed_refill_in_flight:
		return false
	var pid := _current_player_id()
	if pid == "":
		return false
	var _mn = get_tree().get_root().get_node_or_null("Main")
	var tok := ""
	if _mn and _mn.get("_auth_token") != null:
		tok = str(_mn.get("_auth_token"))
	if tok == "":
		return false

	_seed_refill_in_flight = true
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + tok])
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 12.0
	http.request_completed.connect(ApiConfig.check_clock_skew)
	var _e := http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/seeds/issue"), headers, HTTPClient.METHOD_POST, "")
	if _e != OK:
		http.queue_free()
		_seed_refill_in_flight = false
		return false

	var result : Array = await http.request_completed
	_seed_refill_in_flight = false
	if not is_instance_valid(http):
		return false
	http.queue_free()
	var code : int = result[1]
	var body : PackedByteArray = result[3]
	if code != 200:
		print("[GM] seed batch issue failed code=%d" % code)
		if code == 401:
			_notify_auth_expired()
		return false

	var j := JSON.new()
	if j.parse(body.get_string_from_utf8()) != OK:
		print("[GM] seed batch issue — bad JSON response")
		return false
	var data = j.get_data()
	if not (data is Dictionary) or not (data.get("seeds") is Array):
		print("[GM] seed batch issue — unexpected response shape")
		return false

	_load_seed_queue()
	for s in data["seeds"]:
		if not (s is Dictionary): continue
		_seed_queue.append({
			"seed":      str(s.get("seed", "")),
			"expiry":    str(s.get("expiry", "")),
			"sig":       str(s.get("sig", "")),
			"player_id": pid,
		})
	_save_seed_queue()
	print("[GM] seed batch issued — queue size now %d" % _seed_queue.size())
	return true

## Background top-up — fires when the queue drops below POOL_MIN, but never
## blocks the caller (fire-and-forget; by the time this is called the game
## already has a seed to play from — see _start_session_from_issued_seed
## below). Skips quietly if we're offline or a request is already running.
func _maybe_refill_seed_queue() -> void:
	_load_seed_queue()
	_prune_seed_queue()
	if _seed_queue.size() >= POOL_MIN: return
	if _seed_refill_in_flight: return
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("navigator.onLine", true)
		if v != null and not bool(v): return
	await _request_seed_batch()

## Authed play path: consume one seed from the local server-issued queue,
## topping it up first in the background if it's running low, or blocking
## (with a fetch-and-wait, or a clear offline message) if it's completely
## empty. Returns false if the caller should NOT start a game yet — true
## once game_seed / session_id / _current_seed_sig / _current_seed_expiry
## are all set and ready for _init_game_from_seed().
func _start_session_from_issued_seed(my_gen: int, silent_boot: bool = false) -> bool:
	_load_seed_queue()
	_prune_seed_queue()

	var online := true
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("navigator.onLine", true)
		online = bool(v) if v != null else true

	if _seed_queue.is_empty():
		if not online:
			if silent_boot:
				print("[GM] silent_boot: queue empty + offline — falling back to local seed, no toast")
				return false
			print("[GM] seed queue empty + offline — blocking new run until reconnect")
			if is_instance_valid(main_node) and main_node.has_method("_on_offline_no_seeds"):
				main_node.call("_on_offline_no_seeds")
			else:
				Toast.network_error("offline — no saved runs available, reconnect to fetch more")
			return false
		# Online but empty (first-ever launch, or a long-offline stretch that
		# fully drained the queue) — fetch a batch right now and wait for it,
		# since there's nothing else to play from.
		var got := await _request_seed_batch()
		if my_gen != _session_gen:
			return false  # a newer _start_session() took over while we awaited
		if not got or _seed_queue.is_empty():
			# silent_boot = this call came from init()'s automatic first
			# session, not a player-initiated Play press. At this exact
			# moment (fresh scene load / reload_current_scene) the Nimiq
			# bridge is very likely still connecting even though a cached
			# auth token already made _is_authed() return true (see
			# _cached_auth_token_for_reload in Main.gd) — so a failed/slow
			# fetch here is NOT a real connectivity problem, just a race.
			# Don't scare the player with a network-error toast for
			# something that self-heals: _start_session() falls back to a
			# local guest seed below, and _maybe_refresh_lobby_seed() swaps
			# it for a real one the moment auth actually finishes connecting.
			if not silent_boot:
				Toast.network_error("couldn't fetch a new run — try again")
			return false
	elif _seed_queue.size() < POOL_MIN and online:
		# Already have enough to play NOW — top up in the background, don't
		# make the player wait for a request they don't need yet.
		_maybe_refill_seed_queue()

	var entry := _consume_seed_from_queue()
	if entry.is_empty():
		if not silent_boot:
			Toast.network_error("couldn't fetch a new run — try again")
		return false

	if my_gen != _session_gen:
		# Stale coroutine — a newer _start_session() has already taken over
		# (e.g. lobby auth-reseed racing the player's own Play press). Put
		# the seed back at the front of the queue instead of consuming it
		# for nothing, and don't touch game_seed/session_id/_current_seed_sig
		# — the newer call owns those now.
		_seed_queue.push_front(entry)
		_save_seed_queue()
		return false

	var seed_val : int = int(str(entry.get("seed", "0")))
	if seed_val == 0:
		return false
	game_seed            = seed_val & 0x7FFFFFFFFFFFFFFF
	session_id           = _make_local_session_id(game_seed)
	_current_seed_sig    = str(entry.get("sig", ""))
	_current_seed_expiry = str(entry.get("expiry", ""))
	_snapshot_session_identity()
	print("[GM] _start_session ISSUED seed=%d session=%s queue_remaining=%d" % [game_seed, session_id, _seed_queue.size()])
	return true


## forced_seed: used by VS Rooms — both sides of a match MUST play the exact
## same seed, provided by the server at room-create time (see Main._vs_room_seed).
## When set, skips local entropy generation entirely and just derives a
## session_id from it via _make_local_session_id (still locally unique, but
## game_seed itself is no longer random — that's the whole point of a VS match).
func _start_session(forced_seed: int = 0, silent_boot: bool = false) -> void:
	_session_gen += 1
	var my_gen := _session_gen

	if forced_seed != 0:
		game_seed  = forced_seed & 0x7FFFFFFFFFFFFFFF
		session_id = _make_local_session_id(game_seed)
		_current_seed_sig    = ""
		_current_seed_expiry = ""
		_snapshot_session_identity()
		print("[GM] _start_session VS forced_seed=%d session=%s" % [game_seed, session_id])
		_init_game_from_seed()
		return

	if _is_authed():
		# NOTE: this function is itself a coroutine now (it awaits inside
		# _start_session_from_issued_seed when the queue needs a network
		# round-trip). Callers that don't `await _start_session(...)` are
		# fine — GDScript runs a coroutine synchronously up to its first
		# actual suspension point, so the common case (queue already has a
		# seed, nothing to await) behaves exactly like before. Only the
		# empty-queue-while-online case visibly waits before platforms spawn.
		var ok := await _start_session_from_issued_seed(my_gen, silent_boot)
		if my_gen != _session_gen:
			return  # superseded by a newer _start_session() while we awaited
		if ok:
			_init_game_from_seed()
			return
		if not silent_boot:
			return  # blocked, or a real player-initiated request failed — already toasted
		# silent_boot + genuinely failed (not superseded): this is init()'s
		# automatic first session racing the Nimiq bridge, not a player
		# action, so fall through to a local guest seed instead of leaving
		# the lobby stuck with nothing to render. _maybe_refresh_lobby_seed()
		# swaps this for a real signed seed the moment auth actually
		# finishes connecting — see the comments in
		# _start_session_from_issued_seed above.
		print("[GM] silent_boot fallback — building local seed while auth/bridge catches up")

	# ── Guest (signed-out), or silent_boot fallback above: fully local generation ──
	_current_seed_sig    = ""
	_current_seed_expiry = ""
	_snapshot_session_identity()

	# ── OFFLINE SEED: 128-bit entropy, fully local, zero server contact at play time ──
	# hi and lo are independent 64-bit halves; game_seed = hi ^ lo (positive 63-bit).
	# session_id = hex(hi) + hex(lo) = 32-char hex sent to server on submit.
	# Birthday collision probability after 2M games ≈ 1/10^22 — mathematically impossible.
	# determinism-ok: this generates game_seed itself (the ONE non-deterministic
	# input allowed), runs once client-side before any replay recording starts.
	# Everything downstream reads from _rng which is seeded from game_seed — none
	# of this ever runs again during server replay.
	var t_usec : int = Time.get_ticks_usec()  # determinism-ok
	var t_unix : int = Time.get_unix_time_from_system()  # determinism-ok
	var rh1 : int = randi(); var rh2 : int = randi()  # determinism-ok
	var rl1 : int = randi(); var rl2 : int = randi()  # determinism-ok
	var hi  : int = ((rh1 << 32) | (rh2 & 0xFFFFFFFF)) ^ t_usec
	var lo  : int = ((rl1 << 32) | (rl2 & 0xFFFFFFFF)) ^ t_unix
	if hi == 0: hi = t_usec | 0xBEEF0001
	if lo == 0: lo = t_unix | 0xCAFE0002
	# session_id carries full 128-bit entropy
	session_id = "%016x%016x" % [hi & 0x7FFFFFFFFFFFFFFF, lo & 0x7FFFFFFFFFFFFFFF]
	# game_seed = positive 63-bit derived from both halves
	game_seed  = (hi ^ lo) & 0x7FFFFFFFFFFFFFFF
	if game_seed == 0: game_seed = (hi & 0x7FFFFFFFFFFFFFFF) | 1
	print("[GM] _start_session LOCAL seed=%d session=%s" % [game_seed, session_id])
	_init_game_from_seed()

## session_id = hex(hi) + hex(lo) — 32 hex chars, sent to server on submit
func _make_local_session_id(seed_val: int) -> String:
	var ts : int = Time.get_unix_time_from_system()  # determinism-ok: session_id salt, not replayed
	return "%016x%016x" % [seed_val & 0x7FFFFFFFFFFFFFFF, ts & 0x7FFFFFFFFFFFFFFF]

## All game-state reset logic (split out from old _apply_slot so replay can reuse it)
func _init_game_from_seed() -> void:
	if game_seed == 0:
		print("[GM] seed=0, aborting init")
		return
	# Clean up nodes from previous game
	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		child.queue_free()
	_platforms.clear()
	_enemies.clear()
	_drunk_plat_timer = 0.0
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()
	_biome_enemy_cache.clear()
	_last_biome_score = -1
	_game_over = false
	highest_y  = 0
	score      = 0

	# BUG FIX: this function runs for EVERY new game start (normal PLAY from
	# the main menu, not just "PLAY AGAIN" which does a full scene reload and
	# gets a clean slate for free). It never reset the player's lives,
	# powerups, or debuffs — so returning to the menu any way OTHER than
	# "PLAY AGAIN" (e.g. after a normal game-over, or after a VS match) and
	# starting a new game carried over whatever state the player died with:
	# 0 lives, an active shield/boost/jetpack, mirror/earthquake/drunk debuffs
	# still running, even leftover debug god_mode. There was already a
	# `reset_for_lobby()` function written to do exactly this reset, but it
	# was never called from anywhere in the whole codebase — dead code.
	# Doing the reset right here instead guarantees it runs on every single
	# path that starts a game, no matter how the player got back to the menu.
	if is_instance_valid(player):
		player.velocity = Vector2.ZERO
		# BUG FIX ("replay izledim sonra oyun başlattım kalp replayin son
		# durumundaydı, 3'ten başlamadı" / "hiçbir eksik kalmasın... tam
		# reset"): this used to be its own third hand-written copy of the
		# lives/shield/powerup/debuff field list — a THIRD place (alongside
		# stop_replay() and Main.gd's shortcut belt-and-suspenders reset)
		# that had to be kept manually in sync, exactly the class of drift
		# risk reset_transient_state() was created to kill. Now routes
		# through the same single shared helper as the other two call
		# sites, so every field it resets (lives + signal emit, shield,
		# powerup, mirror/drunk/earthquake debuffs, speed/jump boosts,
		# hurt-flash, invincibility, god_mode) is guaranteed identical here
		# too — this function runs on every real game start (normal PLAY
		# from the menu, any VS round, anything that reaches
		# _start_session()), not just the replay-return paths.
		if player.has_method("reset_transient_state"):
			player.call("reset_transient_state")

	_rng.seed       = game_seed
	_shake_rng.seed = game_seed ^ 0xCAFEBABE
	_enemy_spawn_counter = 0

	_replay_log         = PackedByteArray()
	_replay_seed        = 0
	_replay_nickname    = ""
	_replay_debug_compare = false
	_replay_total_ticks = 0
	_replay_tick        = 0   # kept in sync with _replay_tick_count during PLAYING
	_replay_tick_count  = 0
	_last_tick_ms       = 0
	_after_delta_marker = false
	_rle_run_rem        = 0
	_rle_run_val        = 0
	_replay_mode        = ReplayMode.RECORDING
	_dbg_snapshots.clear()
	if is_instance_valid(player) and player.get("_rng") != null:
		var player_seed : int = game_seed ^ 0xDEADBEEF
		player.get("_rng").seed = player_seed
		_replay_player_seed = player_seed
		# _visual_rng: death partikülleri replay'de de aynı görünsün
		if player.get("_visual_rng") != null:
			player.get("_visual_rng").seed = player_seed ^ 0xF00DCAFE
	print("[REPLAY] Recording started")
	var char_idx_now : int = 0
	if is_instance_valid(main_node) and main_node.get("_char_index") != null:
		char_idx_now = int(main_node.get("_char_index"))
	if player.has_method("set_char"):
		player.call("set_char", char_idx_now)
	# Live match start (RECORDING) — apply the CURRENT control-mode setting
	# for the gyro-only movement ramp (see Player.gd's
	# set_gyro_control_active doc comment). Safe to read live here since
	# this only runs once, at the very start of the match.
	if player.has_method("set_gyro_control_active") and is_instance_valid(main_node) and main_node.get("_control_mode") != null:
		player.call("set_gyro_control_active", str(main_node.get("_control_mode")) == "gyro")
	print("[GM] _init_game_from_seed char_idx=%d GRAVITY=%.2f JUMP=%.2f" % [char_idx_now, player.get("GRAVITY"), player.get("JUMP_SPEED")])
	_sim_cam_y = VH * 0.72
	_highest_plat_y = VH * 0.72
	if is_instance_valid(camera):
		camera.offset   = Vector2.ZERO
		camera.position = Vector2(VW * 0.5, _sim_cam_y)
	_spawn_initial_platforms()
	print("[GM] platforms spawned, game ready")
	ready_to_play.emit()

func start_replay() -> void:
	# Clear nickname on direct call; start_replay_external overrides it afterward
	_replay_nickname = ""
	if _replay_log.is_empty():
		print("[REPLAY] Log empty, no replay")
		return
	if _replay_seed == 0:
		print("[REPLAY] Seed=0, no replay")
		return

	# RLE decode: calculate and store real tick count.
	# Uses max(1, count) — identical to the PLAYING path — so seek bar matches playback exactly.
	_replay_total_ticks = 0
	var _rle_di : int = 0
	while _rle_di < _replay_log.size():
		var _rle_db : int = _replay_log[_rle_di]
		if _rle_db == 0xFF:
			if _rle_di + 2 < _replay_log.size():
				_rle_di += 3
			else:
				break  # truncated marker at end of buffer — stop cleanly
			continue
		_replay_total_ticks += max(1, (_rle_db >> 2) & 0x3F)  # matches PLAYING path: max(1, ...)
		_rle_di += 1
	print("[REPLAY] Playback starting — bytes=%d decoded_ticks=%d seed=%d" % [_replay_log.size(), _replay_total_ticks, _replay_seed])
	if not _replay_debug_compare:
		_dbg_snapshots.clear()

	# ── Save the player's OWN seed for returning to lobby (only on first entry) ──
	if _replay_mode != ReplayMode.PLAYING:
		_pre_replay_seed = game_seed
		_pre_replay_char = 0
		if is_instance_valid(main_node) and main_node.get("_char_index") != null:
			_pre_replay_char = int(main_node.get("_char_index"))
		if is_instance_valid(player) and player.get("_rng") != null:
			_pre_replay_player_seed = int(player.get("_rng").seed)

	_game_over   = false
	highest_y   = 0
	score       = 0
	_reset_quest_counters()

	# Clear everything — keep only protected nodes
	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		child.queue_free()
	_platforms.clear()
	_enemies.clear()
	_drunk_plat_timer = 0.0
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()

	if is_instance_valid(player):
		player.set("is_dead",         false)

		# =================================================================
		# FIX: Always set _initialized=false here.
		# activate() is called unconditionally below and sets _initialized=true
		# correctly in both headless and visual modes.
		# Setting it true here before activate() caused a race condition:
		# ticks could start running before velocity/position were finalized,
		# producing divergence on the very first tick.
		# =================================================================
		player.set("_initialized", false)
		# Kill any pending idle tween immediately (headless has no Tween.TWEEN_PROCESS_IDLE)
		if "_idle_tween" in player and player._idle_tween:
			player._idle_tween.kill()
			player._idle_tween = null
			
		player.set("has_shield",      false)
		player.set("is_powered_up",   false)
		player.set("powerup_timer",   0.0)
		player.set("powerup_type",    "")
		player.set("lives",           3)
		player.set("_mirror_active",  false)
		player.set("_mirror_timer",   0.0)
		player.set("_drunk_active",   false)
		player.set("_drunk_timer",    0.0)
		player.set("_drunk_t",         0.0)
		player.set("_eq_active",      false)
		player.set("_eq_timer",       0.0)
		player.set("_eq_debuff_timer",0.0)
		player.set("_eq_offset",      Vector2.ZERO)
		player.set("_speed_boost",    false)
		player.set("_jump_boost",     false)
		player.set("_boost_timer",    0.0)
		player.set("_invincible",     0.0)
		player.set("_hurt_flash",     0.0)
		player.set("god_mode",        false)
		player.set("_powerup_is_jetpack", false)
		player.set("_powerup_is_wings",   false)
		# Same HUD-desync fix as _init_game_from_seed's identical reset block
		# above — direct player.set("lives", 3) doesn't emit lives_changed,
		# so the heart HUD wouldn't reflect the reset back to 3 at the start
		# of THIS replay either without this.
		if player.has_signal("lives_changed"):
			player.emit_signal("lives_changed", 3)
		player.velocity = Vector2.ZERO
		if is_instance_valid(camera):
			camera.offset = Vector2.ZERO
		if player.has_method("set_char"):
			player.call("set_char", _replay_char)
		if player.has_method("set_gyro_control_active"):
			player.call("set_gyro_control_active", _replay_gyro_active)

	_biome_enemy_cache.clear()
	_last_biome_score = -1
	_active_biome     = ""
	_shake_timer      = 0.0
	_shake_strength   = 0.0
	# NOTE: _dbg_snapshots is intentionally NOT cleared here — it holds the
	# RECORDING-mode reference trace from the game that just ended, which
	# PLAYING mode compares itself against (see _simulate_gm_tick divergence
	# detector). Clearing it here would silently disable [DIV] logging.

	_rng.seed       = _replay_seed
	_shake_rng.seed = _replay_seed ^ 0xCAFEBABE  # same seed as normal mode
	_enemy_spawn_counter = 0
	game_seed  = _replay_seed
	if is_instance_valid(player) and player.get("_rng") != null:
		player.get("_rng").seed = _replay_player_seed
		# _visual_rng: replay'de görsel partiküller de aynı olsun
		if player.get("_visual_rng") != null:
			player.get("_visual_rng").seed = _replay_player_seed ^ 0xF00DCAFE

	_replay_mode      = ReplayMode.PLAYING
	_replay_tick      = 0
	_replay_tick_count = 0
	_rle_run_pos      = 0
	_rle_run_rem      = 0
	_rle_run_val      = 0
	_replay_speed     = 1.0
	# NOTE: _replay_paused intentionally NOT forced here.
	# Visual clients call set_replay_paused(true) BEFORE start_replay_external so the
	# player stays frozen at spawn during countdown. Headless always starts unpaused.
	if _is_headless:
		_replay_paused = false
	_replay_speed_acc = 0.0
	# _replay_nickname is set by start_replay_external, reset here

	if is_instance_valid(camera) and is_instance_valid(player):
		camera.position = Vector2(VW * 0.5, VH * 0.72)

	_sim_cam_y = VH * 0.72
	_highest_plat_y = VH * 0.72

	_spawn_initial_platforms()

	# activate() sets _initialized=true, stops idle tween, and zeroes velocity.
	# Must be called AFTER all player state resets above so it sees a clean slate.
	if is_instance_valid(player) and player.has_method("activate"):
		player.call("activate")

	print("[REPLAY] Playback ready")
	
func has_replay() -> bool:
	# _replay_seed is set when recording completes (on player death).
	# Fall back to game_seed if _replay_seed wasn't set yet.
	var seed_ok : bool = (_replay_seed != 0) or (game_seed != 0 and _replay_mode == ReplayMode.OFF)
	return _replay_log.size() > 0 and seed_ok

func get_replay_log() -> PackedByteArray:
	return _replay_log

## Seek replay to a specific tick — reset scene and simulate up to that tick
func seek_to_tick(target_tick: int) -> void:
	if _replay_log.is_empty() or _replay_seed == 0: return
	target_tick = clampi(target_tick, 0, _replay_total_ticks)
	var _was_paused : bool = _replay_paused   # restore pause state after seek

	# Reset scene (same as start_replay)
	_game_over = false
	highest_y  = 0
	score      = 0
	_reset_quest_counters()

	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		_discard_node(child)
	_platforms.clear()
	_enemies.clear()
	_drunk_plat_timer = 0.0
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()

	if is_instance_valid(player):
		player.set("is_dead",          false)
		player.set("_initialized",     false)
		player.set("has_shield",       false)
		player.set("is_powered_up",    false)
		player.set("powerup_timer",    0.0)
		player.set("powerup_type",     "")
		player.set("lives",            3)
		player.set("_mirror_active",   false)
		player.set("_mirror_timer",    0.0)
		player.set("_drunk_active",    false)
		player.set("_drunk_timer",     0.0)
		player.set("_drunk_t",         0.0)
		player.set("_eq_active",       false)
		player.set("_eq_timer",        0.0)
		player.set("_eq_debuff_timer", 0.0)
		player.set("_eq_offset",       Vector2.ZERO)
		player.set("_speed_boost",     false)
		player.set("_jump_boost",      false)
		player.set("_boost_timer",     0.0)
		player.set("_invincible",      0.0)
		player.set("_hurt_flash",      0.0)
		player.set("god_mode",         false)
		player.set("_powerup_is_jetpack", false)
		player.set("_powerup_is_wings",   false)
		# Same HUD-desync fix as start_replay()/_init_game_from_seed() —
		# direct player.set("lives", 3) doesn't emit lives_changed, so
		# seeking back to an earlier tick wouldn't refresh the heart HUD.
		if player.has_signal("lives_changed"):
			player.emit_signal("lives_changed", 3)
		player.velocity = Vector2.ZERO
		if is_instance_valid(camera): camera.offset = Vector2.ZERO
		if player.has_method("set_char"): player.call("set_char", _replay_char)
		if player.has_method("set_gyro_control_active"): player.call("set_gyro_control_active", _replay_gyro_active)

	_biome_enemy_cache.clear()
	_last_biome_score = -1
	_active_biome     = ""
	_shake_timer      = 0.0
	_shake_strength   = 0.0
	# NOTE: _dbg_snapshots intentionally NOT cleared — see start_replay() note.

	_rng.seed       = _replay_seed
	_shake_rng.seed = _replay_seed ^ 0xCAFEBABE
	_enemy_spawn_counter = 0
	game_seed       = _replay_seed
	if is_instance_valid(player) and player.get("_rng") != null:
		player.get("_rng").seed = _replay_player_seed
		# _visual_rng: seek replay'de de görsel tutarlı olsun
		if player.get("_visual_rng") != null:
			player.get("_visual_rng").seed = _replay_player_seed ^ 0xF00DCAFE

	_replay_mode      = ReplayMode.PLAYING
	_replay_tick      = 0
	_replay_tick_count = 0
	_replay_speed_acc = 0.0
	_rle_run_pos      = 0
	_rle_run_rem      = 0
	_rle_run_val      = 0

	if is_instance_valid(camera) and is_instance_valid(player):
		camera.position = Vector2(VW * 0.5, VH * 0.72)
	_sim_cam_y      = VH * 0.72
	_highest_plat_y = VH * 0.72
	_spawn_initial_platforms()
	# Kill idle tween before activate so no callback fires during the silent seek loop
	if is_instance_valid(player) and "_idle_tween" in player and player._idle_tween:
		player._idle_tween.kill()
		player._idle_tween = null
	if is_instance_valid(player) and player.has_method("activate"):
		player.call("activate")

	# Silently simulate up to target tick — suppress tweens during this loop
	#
	# UI FIX: "seeking should jump straight there, not fast-forward through
	# the whole thing" — the re-simulation loop below is unavoidable (there's
	# no stored per-tick snapshot to jump to directly, the only way to reach
	# an arbitrary tick deterministically is to replay every tick from 0).
	# It used to yield a frame every 500 ticks so the UI thread never hung —
	# but the world is now hidden for the whole duration (see visible=false
	# below), so there's nothing left for those in-between frames to show:
	# spreading the work across several frames just added wall-clock delay
	# for no visual benefit ("100 tick 100 tick" stepping the user still felt
	# even with the screen blanked). Since the world isn't drawn during this
	# loop, run every tick back-to-back in one shot instead — the game only
	# reappears once it's already sitting exactly on the target tick.
	visible = false
	_is_seeking = true
	var _seek_prev_tick : int = -1
	var _seek_stall     : int = 0
	while _replay_tick_count < target_tick and not _game_over:
		_run_one_tick()
		# Safety: abort if tick counter stops advancing (prevents worker hang)
		if _replay_tick_count == _seek_prev_tick:
			_seek_stall += 1
			if _seek_stall > 5000:
				push_error("[SEEK_STALL] tick=%d target=%d seed=%d — forcing stop" % [_replay_tick_count, target_tick, _replay_seed])
				_game_over = true
				break
		else:
			_seek_stall = 0
			_seek_prev_tick = _replay_tick_count
	# Always clear seeking flag — even if game_over fired mid-loop
	_is_seeking = false

	# After silent sim: kill any leftover tweens + snap all enemies to correct positions
	for e in _enemies:
		if is_instance_valid(e) and e.has_method("seek_reset"):
			e.call("seek_reset")

	# Reveal the world again now that everything is already snapped to the
	# target tick — see the "visible = false" comment above.
	visible = true

	# Snap visual camera to sim camera instantly (no lerp artifact)
	if is_instance_valid(camera):
		camera.position.y = _sim_cam_y

	# Restore pause state that was active before seek
	_replay_paused = _was_paused

	replay_tick_changed.emit(_replay_tick_count, _replay_total_ticks)


## Persistent worker: reset transient state between jobs without full re-init.
func prep_worker_job() -> void:
	# ── Replay / seek state ─────────────────────────────────────────
	_game_over          = true
	_replay_mode        = ReplayMode.OFF
	_replay_paused      = false
	_is_seeking         = false
	_replay_log         = PackedByteArray()
	_replay_seed        = 0
	_replay_player_seed = 0
	_replay_char        = 0
	_replay_nickname    = ""
	_replay_total_ticks = 0
	_replay_tick        = 0
	_replay_tick_count  = 0
	_replay_speed       = 1.0
	_replay_speed_acc   = 0.0
	_rle_run_pos        = 0
	_rle_run_rem        = 0
	_rle_run_val        = 0
	_last_tick_ms       = 0
	_after_delta_marker = false
	_enemy_spawn_counter    = 0
	highest_y               = 0
	score                   = 0
	_game_over              = false  # allow _init_game_from_seed to run on next job
	game_seed               = 0
	session_id              = ""
	_sim_cam_y              = VH * 0.72
	_highest_plat_y         = VH * 0.72
	_drunk_plat_timer       = 0.0
	_shake_timer            = 0.0
	_shake_strength         = 0.0
	_active_biome           = ""
	_last_biome_score       = -1
	_spawn_pending          = false
	_powerup_hud_dirty      = true
	_pre_replay_seed        = 0
	_pre_replay_player_seed = 0
	_pre_replay_char        = 0

	# ── Caches / registries ─────────────────────────────────────────
	_biome_enemy_cache.clear()
	_dbg_snapshots.clear()
	_ci_to_remove.clear()
	_ci_seen.clear()
	_ci_deduped.clear()

	# ── Quest counters ──────────────────────────────────────────────
	_reset_quest_counters()

	# ── Scene nodes ─────────────────────────────────────────────────
	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		_discard_node(child)
	_platforms.clear()
	_enemies.clear()
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()

	# ── Camera ──────────────────────────────────────────────────────
	if is_instance_valid(camera):
		camera.offset   = Vector2.ZERO
		camera.position = Vector2(VW * 0.5, VH * 0.72)

	# ── Player ──────────────────────────────────────────────────────
	if is_instance_valid(player):
		player.set("is_dead",          false)
		player.set("_initialized",     false)
		player.set("has_shield",       false)
		player.set("is_powered_up",    false)
		player.set("powerup_timer",    0.0)
		player.set("powerup_type",     "")
		player.set("lives",            3)
		player.set("_mirror_active",   false)
		player.set("_mirror_timer",    0.0)
		player.set("_drunk_active",    false)
		player.set("_drunk_timer",     0.0)
		player.set("_drunk_t",         0.0)
		player.set("_eq_active",       false)
		player.set("_eq_timer",        0.0)
		player.set("_eq_debuff_timer", 0.0)
		player.set("_eq_offset",       Vector2.ZERO)
		player.set("_speed_boost",     false)
		player.set("_jump_boost",      false)
		player.set("_boost_timer",     0.0)
		player.set("_invincible",      0.0)
		player.set("_hurt_flash",      0.0)
		player.set("god_mode",         false)
		player.velocity = Vector2.ZERO
		if "_idle_tween" in player and player._idle_tween:
			player._idle_tween.kill()
			player._idle_tween = null


func start_replay_external(ext_seed: int, ext_log: PackedByteArray, ext_char: int, ext_nickname: String = "", ext_player_seed: int = 0, ext_gyro_active: bool = false) -> void:
	if ext_log.is_empty() or ext_seed == 0:
		push_warning("[REPLAY] External: invalid seed or log")
		return
	print("[REPLAY_EXT] called seed=%d bytes=%d nick=%s stack=%s" % [ext_seed, ext_log.size(), ext_nickname, str(get_stack())])
	_replay_seed        = ext_seed
	_replay_log         = ext_log
	_replay_char        = ext_char
	_replay_player_seed = ext_player_seed
	_replay_gyro_active = ext_gyro_active   # gyro-only movement ramp — see set_gyro_control_active doc comment
	_replay_nickname    = ext_nickname   # set before start_replay so it survives
	# Empty nickname is the local game-over replay. Leaderboard/stats/VS/web
	# viewers use a non-empty marker and must not be compared to our old trace.
	_replay_debug_compare = (ext_nickname == "")
	start_replay()
	_replay_nickname    = ext_nickname   # re-set after, start_replay() may clear it

func set_replay_speed(spd: float) -> void:
	# Transport controls must never feed NaN/negative/zero into the accumulator.
	# A zero/invalid value could leave the bar apparently frozen after a seek.
	_replay_speed     = clampf(spd if is_finite(spd) else 1.0, 0.25, 16.0)
	_replay_speed_acc = 0.0  # reset accumulated excess ticks

func set_replay_paused(paused: bool) -> void:
	_replay_paused    = paused
	_replay_speed_acc = 0.0  # reset accumulation on pause/unpause transition

func stop_replay() -> void:
	print("[STOP_REPLAY] called — _replay_mode=%d _replay_nickname=%s" % [_replay_mode, _replay_nickname])
	# Allow call even after natural finish (mode already OFF) to rebuild lobby
	if _replay_mode == ReplayMode.RECORDING: return
	var _was_viewer := (_replay_nickname == "viewer")
	_game_over          = true
	_replay_mode        = ReplayMode.OFF
	_replay_paused      = false
	_replay_nickname    = ""
	_replay_debug_compare = false
	_replay_total_ticks = 0
	_replay_tick        = 0
	_replay_tick_count  = 0
	_replay_speed_acc   = 0.0
	_rle_run_pos        = 0
	_rle_run_rem        = 0
	_rle_run_val        = 0
	# viewer replay (someone else's) → clear log/seed, reset game_seed (force new session)
	# kendi oyunun replay'i (game_over) → log/seed koru, game over paneli tekrar izleyebilsin
	if _was_viewer:
		_replay_seed     = 0
		_replay_log      = PackedByteArray()
	# Clear scene — don't leave the last replay frame in the background
	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		child.queue_free()
	_platforms.clear()
	_enemies.clear()
	_drunk_plat_timer = 0.0
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()
	_biome_enemy_cache.clear()
	_last_biome_score = -1

	if is_instance_valid(player):
		player.velocity = Vector2.ZERO
		# BUG FIX ("replay izledim çıktım, playe bastım ama replay
		# izlediğim versiyondaki son candan başladım... sadece can değil
		# özel güç/hasar animasyonu falan herşey resetlenmeli"): this used
		# to hand-clear only a subset of fields (shield/powerup/debuffs),
		# missing is_dead/lives entirely and ALSO missing _hurt_flash (red
		# damage flash), _invincible (post-damage i-frames), speed/jump
		# boosts and a couple debuff timers — any of which could leak
		# straight through into whatever session gets reactivated next
		# (e.g. still LOOKING freshly hurt from a replay that ended
		# mid-damage-flash). Now calls Player.gd's own
		# reset_transient_state(), the single shared source of truth for
		# "every leftover match-transient flag/timer is cleared" — see its
		# doc comment. The lobby's seed/background is deliberately left
		# untouched below (same seed as before you watched a replay — Play
		# instantly continuing that exact scene is the intended, non-jarring
		# UX, not a bug), so this only resets state, never the seed.
		if player.has_method("reset_transient_state"):
			player.call("reset_transient_state")
		if player.has_method("set_char"):
			player.call("set_char", _pre_replay_char)
	if is_instance_valid(camera):
		camera.offset = Vector2.ZERO

	# ── Rebuild lobby scene with the player's OWN pre-replay seed ──
	if _pre_replay_seed != 0:
		highest_y  = 0
		score      = 0
		# BUG FIX ("sol üstte gösterilen toplanan nim sayısı replaydan
		# çıkınca silinmedi"): score/highest_y were already reset above, but
		# _quest_coins (the counter behind the top-left NIM icon display) —
		# and every other per-match quest counter (kills, platforms,
		# powerups, etc.) — never was. _reset_quest_counters() already
		# existed and already calls update_nimiq_display(0) itself, it was
		# just never called from this, the actual "exit replay" path (it
		# was only wired into the unused reset_for_lobby()). Call it here
		# too so the NIM counter — and everything else it tracks — goes
		# back to 0 the moment the lobby is rebuilt, not just score.
		_reset_quest_counters()
		game_seed  = _pre_replay_seed
		_rng.seed       = _pre_replay_seed
		_shake_rng.seed = _pre_replay_seed ^ 0xCAFEBABE
		_enemy_spawn_counter = 0
		if is_instance_valid(player) and player.get("_rng") != null:
			player.get("_rng").seed = _pre_replay_player_seed
		if is_instance_valid(camera) and is_instance_valid(player):
			camera.position = Vector2(VW * 0.5, VH * 0.72)
		_sim_cam_y      = VH * 0.72
		_highest_plat_y = VH * 0.72
		_spawn_initial_platforms()
		if _was_viewer:
			# Viewer replay exit — start RECORDING, seed/platforms ready
			_replay_log        = PackedByteArray()
			_replay_seed       = 0
			_replay_tick       = 0
			_replay_tick_count = 0
			_replay_speed_acc  = 0.0
			_rle_run_pos       = 0
			_rle_run_rem       = 0
			_rle_run_val       = 0
			_replay_mode       = ReplayMode.RECORDING
			print("[REPLAY] Recording started (viewer exit restore)")
		if is_instance_valid(player) and player.has_method("reset_to_idle"):
			player.call("reset_to_idle")
		if is_instance_valid(main_node) and main_node.has_method("update_score_display"):
			main_node.call("update_score_display", score)

	replay_finished.emit()


## Bring GM to a clean initial state for lobby after leaderboard replay.
## Fetches a new session and re-spawns platforms.
func reset_for_lobby() -> void:
	# First reset all replay/game state
	_game_over = false
	highest_y  = 0
	score      = 0
	_reset_quest_counters()
	_replay_mode = ReplayMode.OFF
	_replay_paused = false
	_replay_log    = PackedByteArray()
	_replay_tick   = 0
	_dbg_snapshots.clear()
	_biome_enemy_cache.clear()
	_last_biome_score = -1
	_drunk_plat_timer = 0.0
	_interactables.clear()
	_ci_prev_pos_valid = false  # TUNNEL FIX: next tick must not sweep from stale pos
	_pending_spring_resets.clear()

	# Clear scene objects
	for child in get_children().duplicate():
		if child == player or child == camera: continue
		if child is HTTPRequest: continue
		child.queue_free()
	_platforms.clear()
	_enemies.clear()

	# Put player into idle
	if is_instance_valid(player):
		player.velocity = Vector2.ZERO
		player.set("_initialized",    false)
		# Same shared helper as every other reset call site (stop_replay(),
		# _init_game_from_seed(), Main.gd's shortcut) — was previously its
		# own fourth hand-written copy of this field list (and, being dead
		# code, was never even exercised to notice it had also drifted:
		# missing the lives_changed signal emit that the other three copies
		# needed a dedicated bug fix for). Routing through
		# reset_transient_state() means this can never silently drift again
		# if it's ever wired up.
		if player.has_method("reset_transient_state"):
			player.call("reset_transient_state")
		if player.has_method("reset_to_idle"):
			player.call("reset_to_idle")

	if is_instance_valid(camera):
		camera.offset   = Vector2.ZERO
		camera.position = Vector2(VW * 0.5, VH * 0.72)

	# Reset score display
	if is_instance_valid(main_node) and main_node.has_method("update_score_display"):
		main_node.call("update_score_display", 0)

	# Start new session (fetches new seed from backend, spawns platforms)
	game_seed  = 0
	session_id = ""
	_start_session()




# ── Speed hack guard: stamp game start on server the moment first tick is recorded ──
# ── Quest progress ──────────────────────────────────────────────────────────
# NOTE: There used to be a separate _submit_quest_progress() here that POSTed
# to /backend/quests/progress right after _submit_session(). That endpoint is
# gone — the server now applies quest progress itself, as a side effect of
# verifying the replay inside the /backend/submit handler, so the client
# never needs to trigger it. All that's left client-side is refreshing the
# quest panel UI once the submit response confirms the server has processed
# the run — see the `code == 200` branch in _send_submit_with_retry() below,
# which calls Main._on_quests_updated() to re-fetch GET /bj/quests.


# ───────────────────────────────────────────────────────────────────
#  PHYSICS CONFIG EXPORT
# ───────────────────────────────────────────────────────────────────
func _export_physics_config() -> void:
	return

# ───────────────────────────────────────────────────────────────────
#  SESSION SUBMIT (AES-CBC + HMAC)
# ───────────────────────────────────────────────────────────────────
func _submit_session() -> void:
	# Guest (signed-out) oyuncular da buradan geçer: _send_submit_with_retry
	# her durumda önce localStorage'a yazar (pending queue), ağ isteğini ise
	# sadece auth varsa atar. Auth yoksa kayıt queue'da bekler; Main._on_auth_success
	# sign-in olunca flush_pending() çağırıp bekleyen kaydı otomatik gönderir.
	if session_id == "" or score <= 0:
		return

	# HARDENING: session_id is derived FROM game_seed at _start_session() time
	# (_make_local_session_id(game_seed)), so in the normal path they can
	# never disagree. But if some future code path ever resets game_seed to 0
	# (e.g. mid-run reset/reinit race) without also clearing session_id, this
	# would silently submit "seed": "0" — a payload the server will reject
	# anyway, but only after a wasted round-trip and with a confusing error
	# for the player. Fail fast and loud here instead, before any network
	# call is made, so it shows up in logs as exactly what it is.
	if game_seed == 0:
		push_error("[SUBMIT] aborting — session_id=%s but game_seed=0 (seed/session desync)" % session_id)
		return

	# BUG FIX (see _session_player_id doc comment above _start_session):
	# player_id/nickname MUST come from the identity snapshot taken when
	# this run's seed was locked in, NOT read live off main_node here.
	# Reading live meant a wallet sign-in completing mid-run (started as
	# guest, Hub sign resolves a few seconds into the run) would submit a
	# real/current player_id paired with the blank sig/expiry from before
	# that auth existed — an internally-inconsistent payload the server
	# correctly rejects as bad_seed_signature, even though the run was
	# legitimate and just had unlucky timing.
	var pid := _session_player_id
	var nickname := _session_nickname
	var main_node_ref = get_tree().get_root().get_node_or_null("Main")

	var char_idx : int = 0
	if main_node_ref and main_node_ref.get("_char_index") != null:
		char_idx = int(main_node_ref.get("_char_index"))

	# Gyro-only movement ramp (see Player.gd's set_gyro_control_active doc
	# comment) — recorded once per match here, same pattern as char_idx just
	# above, so the server's replay verification knows whether to apply the
	# ramp too. Read live off Main's current control-mode setting — safe
	# because it can't change mid-match (no in-run UI for it).
	var gyro_active : bool = false
	if main_node_ref and main_node_ref.get("_control_mode") != null:
		gyro_active = (str(main_node_ref.get("_control_mode")) == "gyro")

	var replay_b64 := ""
	# RLE'den gerçek tick sayısını decode et — _replay_tick_count ile değil bununla gönder.
	# Web'de frame timing düzensiz olduğunda _replay_tick_count kayabilir ama RLE her zaman doğru.
	var rle_ticks : int = 0
	if _replay_log.size() > 0:
		replay_b64 = Marshalls.raw_to_base64(_replay_log)
		var _ri : int = 0
		while _ri < _replay_log.size():
			var _rb : int = _replay_log[_ri]
			if _rb == 0xFF:
				if _ri + 2 < _replay_log.size():
					_ri += 3
				else:
					break  # truncated marker at end of buffer — stop cleanly
				continue
			rle_ticks += max(1, (_rb >> 2) & 0x3F)
			_ri += 1
		print("[SUBMIT] replay_log bytes=%d rle_decoded_ticks=%d recorded_ticks=%d player_seed=%d" % [_replay_log.size(), rle_ticks, _replay_tick_count, _replay_player_seed])

	# ── Build submit payload — seed included, server verifies on receipt ──
	var payload := {
		"session":     session_id,
		"seed":        str(game_seed),
		# Proof this seed was actually issued by POST /backend/seeds/issue to
		# this exact player — see game/seed_batch.go server-side and the
		# _current_seed_sig/_current_seed_expiry doc comment above
		# _start_session. Empty strings for guest play / VS-room forced
		# seeds, which the server exempts from this check by design.
		"seed_sig":    _current_seed_sig,
		"seed_expiry": _current_seed_expiry,
		"score":       score,
		"ticks":       rle_ticks,  # RLE'den decode — server ile her zaman eşleşir
		"char":        char_idx,
		"gyro_active": gyro_active,
		"player_id":   pid,
		"nickname":    nickname,
		"nonce":       Time.get_unix_time_from_system() * 1000,
		"replay_log":  replay_b64,
		"player_seed": str(_replay_player_seed),
		"client_version": GameVersion.CLIENT_VERSION,
		# Diagnostic-only, never trusted for scoring: lets the backend pinpoint
		# the first tick where the server's re-simulation parted ways with what
		# this client actually saw, instead of just an aggregate score-diff %.
		"ckpt": _ckpt_log,
	}
	if vs_room_id != "":
		payload["vs_room_id"] = vs_room_id
		payload["vs_role"]    = vs_role
		print("[SUBMIT] tagging as VS room=%s role=%s" % [vs_room_id, vs_role])
	var body := JSON.stringify(payload)
	_send_submit_with_retry(session_id, body)
	# One-shot tag — a solo run right after a VS match must not inherit it.
	vs_room_id = ""
	vs_role    = ""


## Payload ready — write to localStorage FIRST, THEN send.
## On success delete. On failure / offline → stays in pending, retry will try again.
func _send_submit_with_retry(sid: String, body: String) -> void:
	# 1. First: write to disk — zero error tolerance
	if OS.has_feature("web"):
		_pending_save(sid, body)

	# 2. Internet check
	var online := true
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("navigator.onLine", true)
		online = bool(v) if v != null else true

	if not online:
		print("[GM] offline — in pending, waiting for retry sid=%s" % sid.left(8))
		_ensure_retry_timer()
		return

	# 3. Auth check — Main._auth_token getter reads NimiqBridge first (single source of truth)
	var _auth_tok := ""
	var _mn = get_tree().get_root().get_node_or_null("Main")
	if _mn and _mn.get("_auth_token") != null:
		_auth_tok = str(_mn.get("_auth_token"))
	if _auth_tok == "":
		print("[GM] not authed — keeping sid=%s in pending until sign-in" % sid.left(8))
		return
	var headers := PackedStringArray(["Content-Type: application/json"])
	if _auth_tok != "":
		headers.append("Authorization: Bearer " + _auth_tok)
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 12.0
	# BUG FIX: "Lambda capture at index 0 was freed" — GameManager (self) or
	# this http node can be freed mid-flight (e.g. "Play Again" ->
	# reload_current_scene) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(_r, code, _h, _b):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		print("[GM] submit code=%d sid=%s" % [code, sid.left(8)])
		# 200 or 4xx (except 401) → definitive answer → drop from queue
		# 401 → no auth yet → keep in queue, retry when signed in
		# 0 / 5xx / 429 → network/server error → keep in queue, retry
		if code == 200:
			_pending_remove(sid)
			# Server has finished verifying the replay and, as part of that,
			# already applied any quest progress from this run
			# (Store.UpdateQuestProgressFromReplay). Just refresh the quest
			# panel UI so completed quests show up — no separate progress
			# request needed.
			var _qmn2 = get_tree().get_root().get_node_or_null("Main")
			if is_instance_valid(_qmn2) and _qmn2.has_method("_on_quests_updated"):
				_qmn2.call("_on_quests_updated")
		elif code == 401:
			# Not authenticated — keep in queue, notify Main to show sign-in
			print("[GM] submit 401 — no auth, keeping in queue until signed in")
			_notify_auth_expired()
			_ensure_retry_timer()
		elif code >= 400 and code < 500 and code != 429:
			# 400/403/409 etc. — permanent rejection, drop
			# BUG FIX: 429 used to fall into THIS branch (it's inside 400..500)
			# even though the comment on the final `else` below always claimed
			# 429 was treated as transient/retried — it never actually was,
			# because this `elif` caught it first and dropped the submission
			# from the pending queue for good. In practice: if a player's
			# replay-verification concurrency cap was hit
			# (too_many_pending_replays — see maxReplayInFlightPerPlayer in
			# backend/handlers/server.go) or the generic per-IP rate limiter
			# briefly rejected a submit, the run's score was silently
			# discarded instead of retried a moment later. 429 now falls
			# through to the retry branch below, matching what the comment
			# always said should happen.
			print("[GM] submit %d — permanent rejection, dropping sid=%s" % [code, sid.left(8)])
			# bad_seed_signature: the one permanent-rejection reason worth a
			# user-facing toast. Covers a real forged/tampered seed (should
			# never happen from the real client), genuine 30-day expiry, AND
			# — see _session_player_id doc comment above _start_session — a
			# guest run whose wallet sign-in completed mid-flight, which
			# submits under a real player_id but with the blank sig/expiry
			# from before that auth existed. Every other 400/403/409 reason
			# (seed_already_used, bad_vs_role, etc.) stays a silent drop,
			# same as before — those aren't something the player can act on.
			#
			# BUG FIX: this used to always say "expired" regardless of
			# which of those causes it actually was, which misdiagnosed the
			# mid-flight-signin case as a stale-queue issue. We can't
			# recover the server's specific reason from a bare
			# "bad_seed_signature" string, but we CAN tell locally whether
			# THIS body ever had a sig/expiry to begin with.
			var _err_msg := ""
			var _j := JSON.new()
			if _j.parse(_b.get_string_from_utf8()) == OK and _j.get_data() is Dictionary:
				_err_msg = str(_j.get_data().get("error", ""))
			if _err_msg == "bad_seed_signature":
				var _had_sig := false
				var _bj := JSON.new()
				if _bj.parse(body) == OK and _bj.get_data() is Dictionary:
					var _bd = _bj.get_data()
					_had_sig = str(_bd.get("seed_sig", "")) != "" and str(_bd.get("seed_expiry", "")) != ""
				var _inst := Toast.get_instance()
				if _inst != null:
					if _had_sig:
						_inst.show_toast("A saved run expired before it could be submitted and was not counted.", Toast.Kind.ERROR)
					else:
						_inst.show_toast("A run started before you signed in couldn't be verified and was not counted.", Toast.Kind.ERROR)
			_pending_remove(sid)
		else:
			# 0 (network err), 5xx, 429 (rate-limited — transient, not a
			# rejection of the submission itself) — retry.
			print("[GM] submit failed (code=%d), staying in queue" % code)
			Toast.network_error("submit code=%d" % code)
			_ensure_retry_timer()
	)
	var _e := http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/submit"), headers, HTTPClient.METHOD_POST, body)


## Save {sid, body} dict to pending queue
func _pending_save(sid: String, body: String) -> void:
	if not OS.has_feature("web"): return
	var pending := _ls_get(LS_PENDING)
	# Overwrite if same sid already exists
	for i in pending.size():
		if pending[i] is Dictionary and pending[i].get("sid", "") == sid:
			pending[i] = {"sid": sid, "body": body}
			_ls_set(LS_PENDING, pending)
			return
	pending.append({"sid": sid, "body": body})
	_ls_set(LS_PENDING, pending)


## Remove from pending queue by sid
func _pending_remove(sid: String) -> void:
	if not OS.has_feature("web"): return
	var pending := _ls_get(LS_PENDING)
	pending = pending.filter(func(e): return not (e is Dictionary and e.get("sid","") == sid))
	_ls_set(LS_PENDING, pending)
	print("[GM] pending cleared sid=%s, remaining=%d" % [sid.left(8), pending.size()])


## Retry timer — calls flush_pending every 15 seconds
var _retry_timer : Timer = null

func _ensure_retry_timer() -> void:
	if is_instance_valid(_retry_timer): return
	_retry_timer = Timer.new()
	_retry_timer.wait_time  = 15.0
	_retry_timer.autostart  = false
	_retry_timer.one_shot   = false
	_retry_timer.timeout.connect(flush_pending)
	add_child(_retry_timer)
	_retry_timer.start()
	print("[GM] retry timer started (15s interval)")


# ───────────────────────────────────────────────────────────────────
#  PREFETCH ATTEMPT (with retry logic)
# ───────────────────────────────────────────────────────────────────
# ───────────────────────────────────────────────────────────────────
#  PENDING SUBMIT FLUSH (called on app startup)
# ───────────────────────────────────────────────────────────────────
func flush_pending() -> void:
	if not OS.has_feature("web"):
		return
	var pending := _ls_get(LS_PENDING)
	if pending.is_empty():
		# Queue empty — timer not needed
		if is_instance_valid(_retry_timer):
			_retry_timer.stop()
			_retry_timer.queue_free()
			_retry_timer = null
		return

	# Auth check — don't flush until signed in
	var _fmn0 = get_tree().get_root().get_node_or_null("Main")
	var _ftok0 := str(_fmn0.get("_auth_token")) if _fmn0 and _fmn0.get("_auth_token") != null else ""
	if _ftok0 == "":
		print("[GM] flush_pending: not authed — waiting for sign-in")
		if is_instance_valid(_retry_timer): _retry_timer.stop()
		return

	# Internet check
	var v = JavaScriptBridge.eval("navigator.onLine", true)
	var online := bool(v) if v != null else true
	if not online:
		print("[GM] flush_pending: offline, skip -- retry in 15s")
		_ensure_retry_timer()
		return

	# Send each pending submission
	var to_send : Array = pending.duplicate()
	for entry in to_send:
		if not (entry is Dictionary): continue
		var sid  : String = entry.get("sid", "")
		var body : String = entry.get("body", "")
		if sid == "" or body == "": continue

		var _ftok := ""
		var _fmn = get_tree().get_root().get_node_or_null("Main")
		if _fmn and _fmn.get("_auth_token") != null:
			_ftok = str(_fmn.get("_auth_token"))
		var f_headers := PackedStringArray(["Content-Type: application/json"])
		if _ftok != "":
			f_headers.append("Authorization: Bearer " + _ftok)
		var http := HTTPRequest.new()
		add_child(http)
		http.timeout = 12.0
		var _sid := sid
		# BUG FIX: "Lambda capture at index 0 was freed" — GameManager (self)
		# or this http node can be freed mid-flight (e.g. "Play Again" ->
		# reload_current_scene) before the response lands.
		var _alive : WeakRef = weakref(self)
		http.request_completed.connect(ApiConfig.check_clock_skew)
		http.request_completed.connect(func(_r, code, _h, _b):
			if not is_instance_valid(http): return
			http.queue_free()
			if _alive.get_ref() == null: return
			print("[GM] flush submit code=%d sid=%s" % [code, _sid.left(8)])
			# BUG FIX ("always shows 6 pending"): this used to only ever call
			# _pending_remove() on code==200 — any other response (including a
			# DEFINITIVE, permanent rejection like 400/403/409) was silently
			# ignored, leaving the entry in the queue forever. _send_submit_
			# with_retry() (the in-run submit path) already drops on permanent
			# 4xx rejections; flush_pending() — the path every retry tick and
			# every login's _check_pending_submissions() actually reads from —
			# never did, so a handful of stuck/invalid entries (expired
			# session, already-claimed replay, etc.) sat in localStorage
			# forever, retried every 15s but never cleared, and the same
			# stale count kept showing up on every single login. Now mirrors
			# _send_submit_with_retry()'s code handling exactly: only 401 (not
			# authed yet), 429 (rate-limited), and 0/5xx (network/server
			# error) are left in the queue to retry — everything else,
			# success or permanent rejection, is removed.
			if code == 200:
				_pending_remove(_sid)
			elif code == 401 or code == 429 or code == 0 or code >= 500:
				pass  # transient — leave in queue, next retry tick will try again
			else:
				# Permanent rejection (400/403/409/etc.) — drop, it will never succeed.
				print("[GM] flush submit %d — permanent rejection, dropping sid=%s" % [code, _sid.left(8)])
				# BUG FIX: this used to always say "expired" for EVERY
				# bad_seed_signature, but that's only one of several
				# distinct server-side causes (see VerifyIssuedSeed in
				# backend/game/seed_batch.go) — missing sig/expiry
				# entirely (most commonly: a guest run whose wallet
				# sign-in completed mid-flight, see the
				# _session_player_id snapshot fix above _start_session),
				# a signature mismatch, or genuine 30-day expiry.
				# Reporting all three as "expired" hid the real cause.
				# We can't recover the server's specific reason from a
				# bare "bad_seed_signature" string, but we CAN tell
				# locally whether this queued body ever had a sig/expiry
				# to begin with — that already disambiguates the most
				# common real-world case from genuine expiry.
				var _err_msg := ""
				var _j := JSON.new()
				if _j.parse(_b.get_string_from_utf8()) == OK and _j.get_data() is Dictionary:
					_err_msg = str(_j.get_data().get("error", ""))
				if _err_msg == "bad_seed_signature":
					var _had_sig := false
					var _bj := JSON.new()
					if _bj.parse(body) == OK and _bj.get_data() is Dictionary:
						var _bd = _bj.get_data()
						_had_sig = str(_bd.get("seed_sig", "")) != "" and str(_bd.get("seed_expiry", "")) != ""
					var _inst := Toast.get_instance()
					if _inst != null:
						if _had_sig:
							_inst.show_toast("A saved run expired before it could be submitted and was not counted.", Toast.Kind.ERROR)
						else:
							_inst.show_toast("A run started before you signed in couldn't be verified and was not counted.", Toast.Kind.ERROR)
				_pending_remove(_sid)
		)
		var _e := http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/submit"), f_headers, HTTPClient.METHOD_POST, body)
		if _e != OK:
			http.queue_free()
