extends Node2D

static var _is_headless : bool = DisplayServer.get_name() == "headless"

# ── [CRASH DEBUG] ──────────────────────────────────────────────────────────
# Toggle this to true to write a flush-every-tick trace log. print() output
# is buffered and gets lost on a hard native crash (0xc0000005) — this file
# is fsync'd after every single line, so whatever line is LAST in the file
# is the last tick that ran before the crash. Pinpoints exact tick + enemy.
# Set back to false once the bug is found; it's slow (disk I/O every tick).
static var _CRASH_DEBUG := true
static var _crash_log : FileAccess = null
func _crash_debug_open() -> void:
	if not _CRASH_DEBUG: return
	_crash_log = FileAccess.open("user://crash_trace.log", FileAccess.WRITE)
	printerr("[CRASH_DEBUG] trace log -> ", ProjectSettings.globalize_path("user://crash_trace.log"))
func _crash_debug_line(s: String) -> void:
	if not _CRASH_DEBUG or _crash_log == null: return
	_crash_log.store_line(s)
	_crash_log.flush()
# ─────────────────────────────────────────────────────────────────────────

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
const ITEM_BASE_PROB   := 0.22
const BROKEN_BASE_PROB := 0.05

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
var _replay_score     : int = 0       
var _replay_player_seed : int = 0     
var _replay_speed     : float = 1.0
var _replay_paused    : bool  = false
var _replay_speed_acc : float = 0.0
var _replay_nickname  : String = ""
# ── Player's own seed preserved before replay (used when returning to lobby) ──

# ── VS mode ──────────────────────────────────────────────────────────
var _vs_active        : bool   = false
var _vs_tick          : int    = 0      # local tick counter for VS
var _vs_last_rdir     : int    = 0      # cached rdir for current tick
var _ghost_sprite     : Sprite2D = null  # opponent ghost visual
var _ghost_x          : float  = 0.0
var _ghost_y          : float  = 0.0
var _ghost_dir        : int    = 0      # last received input dir
const _VS_GHOST_ALPHA : float  = 0.45
const _VS_GHOST_COLOR : Color  = Color(0.4, 0.8, 1.0, _VS_GHOST_ALPHA)
var _pre_replay_seed        : int = 0
var _pre_replay_player_seed : int = 0
var _pre_replay_char        : int = 0
signal replay_finished
signal replay_tick_changed(tick: int, total: int)

# ── Divergence detector ──────────────────────────────────────────────
# During RECORDING store (pos, score) every tick; compare during PLAYING
var _dbg_snapshots : Array = []   # [{pos, score, vel_y}]
var _dbg_enabled   : bool  = OS.is_debug_build()  # production: off → zero alloc per tick

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
const _BIOME_IDX         : Dictionary    = {"grass": 0, "desert": 1, "fall": 4, "sky": 2, "candy": 5}

# ── Hoisted temp arrays for _check_interactables (avoids per-tick allocation) ──
var _ci_to_remove  : Array[int]   = []
var _ci_seen       : Dictionary   = {}
var _ci_deduped    : Array[int]   = []

# ── Deterministic camera Y — used by all game logic (spawn/kill, death check) ──
# Visual camera.position.y lerps for smooth display; _sim_cam_y snaps instantly.
# Ensures platform spawn/despawn is identical at any replay speed.
var _sim_cam_y : float = 0.0


func init(p_cam, p_player, _p_score, _p_best, _p_final, p_main, p_seed: int = -1, p_skip_session: bool = false) -> void:
	print("[GM_INIT] reached, _CRASH_DEBUG=", _CRASH_DEBUG)
	_crash_debug_open()
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
		_start_session()


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
		"idle": [_t(en+"springman/stand.png"), _t(en+"springman/hurt.png"),
				 _t(en+"springman/stand.png")],
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
	if _CRASH_DEBUG:
		var p_pos  := player.global_position if is_instance_valid(player) else Vector2.ZERO
		var p_vel  := player.velocity if is_instance_valid(player) else Vector2.ZERO
		_crash_debug_line("TICK %d | player_ready=%s pos=(%.1f,%.1f) vel=(%.1f,%.1f) is_dead=%s lives=%s shield=%s poweredup=%s | score=%d highest_y=%.1f | enemies=%d platforms=%d" % [
			_replay_tick_count, player_ready, p_pos.x, p_pos.y, p_vel.x, p_vel.y,
			(player.get("is_dead") if is_instance_valid(player) else null),
			(player.get("lives") if is_instance_valid(player) else null),
			(player.get("has_shield") if is_instance_valid(player) else null),
			(player.get("is_powered_up") if is_instance_valid(player) else null),
			score, highest_y, _enemies.size(), _platforms.size()
		])
	if player_ready:
		player.simulate_tick()
		# Enemies ticked only when player is ready — keeps tick count equal in NORMAL and REPLAY
		for e in _enemies:
			if is_instance_valid(e):
				if _CRASH_DEBUG:
					var etype : int = e.get("enemy_type")
					var ename : String = Enemy.EnemyType.keys()[etype] if etype >= 0 and etype < Enemy.EnemyType.size() else "?"
					_crash_debug_line("  enemy id=%d type=%s(%d) pos=(%.1f,%.1f) setup=%s can_fly=%s stun=%.2f overlap=%s plat_valid=%s -> simulate_tick()" % [
						e.get_instance_id(), ename, etype, e.global_position.x, e.global_position.y,
						e.get("_setup_done"), e.get("can_fly"), e.get("_stun_timer"), e.get("_overlap_triggered"),
						is_instance_valid(e.get("_platform"))
					])
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
		_check_interactables()
	_tick_spring_resets()

	# ── VS: send local input + update ghost position ─────────────────
	if _vs_active and player_ready and _replay_mode == ReplayMode.RECORDING:
		_vs_tick += 1
		VSManager.send_input(_vs_tick, _vs_last_rdir)
		_vs_update_ghost()

	# ── Divergence detector ──────────────────────────────────────────
	if _dbg_enabled and player_ready:
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
				if not _is_headless and _replay_tick_count % 6 == 0:
					replay_tick_changed.emit(_replay_tick_count, _replay_total_ticks)
				if _dbg_enabled and _replay_tick_count % 100 == 0:
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
				var l_held := Input.is_action_pressed("ui_left")  or Input.is_action_pressed("move_left")
				var r_held := Input.is_action_pressed("ui_right") or Input.is_action_pressed("move_right")
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
		if _vs_active: _vs_last_rdir = rdir   # cache for VS send

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
			camera.position.y = lerpf(camera.position.y, _sim_cam_y, minf(25.0 * delta, 1.0))
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
#  VS MODE
# ───────────────────────────────────────────────────────────────────

## Called by Main.gd when VS match starts (countdown = 0)
## Force a specific seed for VS mode — call before activate()
func vs_apply_seed(seed_int: int) -> void:
	if seed_int == 0: return
	game_seed  = seed_int & 0x7FFFFFFFFFFFFFFF
	session_id = _make_local_session_id(seed_int)
	_init_game_from_seed()


func vs_start() -> void:
	_vs_active    = true
	_vs_tick      = 0
	_vs_last_rdir = 0
	_ghost_x      = VW * 0.5
	_ghost_y      = VH * 0.5
	_ghost_dir    = 0
	_spawn_ghost_sprite()
	# Connect VSManager signals
	if not VSManager.opponent_input.is_connected(_on_vs_opponent_input):
		VSManager.opponent_input.connect(_on_vs_opponent_input)
	if not VSManager.opponent_left.is_connected(_on_vs_opponent_left):
		VSManager.opponent_left.connect(_on_vs_opponent_left)


func vs_stop() -> void:
	_vs_active = false
	if is_instance_valid(_ghost_sprite):
		_ghost_sprite.queue_free()
		_ghost_sprite = null
	if VSManager.opponent_input.is_connected(_on_vs_opponent_input):
		VSManager.opponent_input.disconnect(_on_vs_opponent_input)
	if VSManager.opponent_left.is_connected(_on_vs_opponent_left):
		VSManager.opponent_left.disconnect(_on_vs_opponent_left)


func _spawn_ghost_sprite() -> void:
	if is_instance_valid(_ghost_sprite):
		_ghost_sprite.queue_free()
	_ghost_sprite = Sprite2D.new()
	# Reuse player texture as ghost — tinted blue
	if is_instance_valid(player) and player.get_child_count() > 0:
		var anim := player.get_node_or_null("AnimatedSprite2D")
		if anim and anim.sprite_frames:
			var frames : SpriteFrames = anim.sprite_frames
			var tex : Texture2D = frames.get_frame_texture("stand", 0)
			if tex:
				_ghost_sprite.texture = tex
	_ghost_sprite.modulate = _VS_GHOST_COLOR
	_ghost_sprite.z_index  = -1   # behind player
	_ghost_sprite.position = Vector2(_ghost_x, _ghost_y)
	add_child(_ghost_sprite)


func _vs_update_ghost() -> void:
	if not is_instance_valid(_ghost_sprite): return
	# Smoothly lerp ghost toward last known position
	# (position is approximate — based on inputs only, no full physics sim)
	var target := Vector2(_ghost_x, _ghost_y)
	_ghost_sprite.position = _ghost_sprite.position.lerp(target, 0.25)


func _on_vs_opponent_input(tick: int, dir: int) -> void:
	_ghost_dir = dir
	# Simple approximation: move ghost horizontally based on dir
	# Real position comes from deterministic sim — this is just visual smoothing
	_ghost_x += dir * 4.0   # rough pixels per tick
	# Camera-relative: ghost Y stays close to player Y (same seed = same height)
	# _shake_rng kullanılıyor — ghost Y görsel amaçlı ama tutarlı olsun
	if is_instance_valid(player):
		_ghost_y = player.global_position.y + _shake_rng.randf_range(-20.0, 20.0)


func _on_vs_opponent_left() -> void:
	vs_stop()


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
	if _rng.randf() < enemy_prob:
		_add_enemy(plat, use_diff, plat_score)
	elif _rng.randf() < ITEM_BASE_PROB:
		if _rng.randf() < 0.15:
			_spawn_spinning_card(plat.global_position + Vector2(0, -VH * 0.06))
		else:
			_add_item(plat, use_diff)


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
			if r3 < 0.30:
				_place_deco(plat, par + "particle_green.png", r4, int(VH * 0.01))
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
	cs.radius = int(VW * 0.023)
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
				Enemy.EnemyType.CLOUD,
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
		"candy":
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


func _add_enemy(plat: StaticBody2D, p_diff: float = -1.0, p_score: int = -1) -> void:
	var use_diff := p_diff if p_diff >= 0.0 else _difficulty()
	if _enemy_frames.is_empty(): return

	var available := _enemies_for_biome(p_score)
	if available.is_empty(): return

	var etype := available[_rng.randi() % available.size()]
	var frames : Dictionary = _enemy_frames.get(etype, {})
	if frames.is_empty(): return

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
			if is_instance_valid(e) and e.has_method("_die"):
				e.call("_die")
		)

	enemy.setup(etype, frames, use_diff)
	_enemies.append(enemy)
	if _CRASH_DEBUG:
		var ename : String = Enemy.EnemyType.keys()[etype] if etype >= 0 and etype < Enemy.EnemyType.size() else "?"
		_crash_debug_line("[SPAWN] tick=%d type=%s(%d) id=%d pos=(%.1f,%.1f) plat_pos=(%.1f,%.1f) seed=%d" % [
			_replay_tick_count, ename, etype, enemy.get_instance_id(),
			enemy.global_position.x, enemy.global_position.y,
			plat.global_position.x, plat.global_position.y, enemy_seed
		])

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


func _add_item(plat: StaticBody2D, p_diff: float = -1.0) -> void:
	var d  := p_diff if p_diff >= 0.0 else _difficulty()
	var w0 := int(lerpf(15, 8, d))
	var w1 := int(lerpf(3, 6, d))
	var w4 := int(lerpf(2, 4, d))
	var total := w0 + w1 + 1 + 1 + w4 + 1
	var roll  := _rng.randi() % total
	var chosen := 5
	var c := 0
	c += w0; if roll < c: chosen = 0
	else:
		c += w1; if roll < c: chosen = 1
		else:
			c += 1; if roll < c: chosen = 2
			else:
				c += 1; if roll < c: chosen = 3
				else:
					c += w4; if roll < c: chosen = 4
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
			radius = VW * 0.027
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
			if (px + p_half_w > ax - rsize.x * 0.5 and px - p_half_w < ax + rsize.x * 0.5 and
				py + p_half_h > ay - rsize.y * 0.5 and py - p_half_h < ay + rsize.y * 0.5):
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

		# Circle overlap: distance from player center to area center
		var ax : float = area.global_position.x
		var ay : float = area.global_position.y
		# Use player center vs circle center, expanded by player half-width
		var dx : float = px - ax
		var dy : float = (py - p_half_h * 0.5) - ay   # mid-body
		var dist_sq : float = dx * dx + dy * dy
		var touch_r : float = radius + p_half_w * 0.7
		if dist_sq < touch_r * touch_r:
			var etype : String = entry["type"]
			var is_spring      : bool = (etype == "spring")
			var is_spike       : bool = (etype == "spike")
			# proj_damage with one_shot=false stays alive (persistent cloud/zone)
			var is_persistent  : bool = (etype == "proj_damage" and
				entry["data"] is Dictionary and not entry["data"].get("one_shot", true))
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
	return clampf(float(score) / 3000.0, 0.0, 1.0)


func _biome_name_for_score(s: int) -> String:
	# 4 biom, 500'er puanlık dilimler, 2000'de başa döner (grass→desert→fall→sky→grass→...)
	var cycle : int = s % 2000
	if cycle < 0: cycle += 2000   # negatif skor güvenliği
	if cycle < 500:  return "grass"
	if cycle < 1000: return "desert"
	if cycle < 1500: return "fall"
	return "sky"


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
		replay_finished.emit()
		return

	if _replay_mode == ReplayMode.RECORDING:
		_replay_seed  = game_seed
		_replay_score = score
		_replay_char  = 0
		if is_instance_valid(main_node) and main_node.get("_char_index") != null:
			_replay_char = int(main_node.get("_char_index"))
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
	_submit_quest_progress()


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
	var escaped := JSON.stringify(arr).replace("'", "\\'")
	JavaScriptBridge.eval("localStorage.setItem('%s','%s')" % [key, escaped], true)

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


## forced_seed: used by VS Rooms — both sides of a match MUST play the exact
## same seed, provided by the server at room-create time (see Main._vs_room_seed).
## When set, skips local entropy generation entirely and just derives a
## session_id from it via _make_local_session_id (still locally unique, but
## game_seed itself is no longer random — that's the whole point of a VS match).
func _start_session(forced_seed: int = 0) -> void:
	if forced_seed != 0:
		game_seed  = forced_seed & 0x7FFFFFFFFFFFFFFF
		session_id = _make_local_session_id(game_seed)
		print("[GM] _start_session VS forced_seed=%d session=%s" % [game_seed, session_id])
		_init_game_from_seed()
		return

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
		player.set("is_dead",          false)
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
		player.set("_speed_boost",       false)
		player.set("_jump_boost",        false)
		player.set("_speed_boost_timer", 0.0)
		player.set("_jump_boost_timer",  0.0)
		player.set("_invincible",      0.0)
		player.set("_hurt_flash",      0.0)
		player.set("god_mode",         false)

	_rng.seed       = game_seed
	_shake_rng.seed = game_seed ^ 0xCAFEBABE
	_enemy_spawn_counter = 0

	_replay_log         = PackedByteArray()
	_replay_seed        = 0
	_replay_nickname    = ""
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
		player.velocity = Vector2.ZERO
		if is_instance_valid(camera):
			camera.offset = Vector2.ZERO
		if player.has_method("set_char"):
			player.call("set_char", _replay_char)
		
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
		player.velocity = Vector2.ZERO
		if is_instance_valid(camera): camera.offset = Vector2.ZERO
		if player.has_method("set_char"): player.call("set_char", _replay_char)

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
	# Non-blocking: her 500 tick'te bir frame'e yield et → UI donmaz
	_is_seeking = true
	var seek_batch := 500 if not _is_headless else 999999
	var _seek_prev_tick : int = -1
	var _seek_stall     : int = 0
	while _replay_tick_count < target_tick and not _game_over:
		var batch_end := mini(_replay_tick_count + seek_batch, target_tick)
		while _replay_tick_count < batch_end and not _game_over:
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
		# Eğer hâlâ hedef tick'e ulaşmadıysak bir sonraki frame'i bekle
		# Headless'ta await yok — tüm tick'ler senkron işlenir
		if _replay_tick_count < target_tick and not _game_over:
			if not _is_headless:
				await get_tree().process_frame
	# Always clear seeking flag — even if game_over fired mid-loop
	_is_seeking = false

	# After silent sim: kill any leftover tweens + snap all enemies to correct positions
	for e in _enemies:
		if is_instance_valid(e) and e.has_method("seek_reset"):
			e.call("seek_reset")

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


func start_replay_external(ext_seed: int, ext_log: PackedByteArray, ext_char: int, ext_nickname: String = "", ext_player_seed: int = 0) -> void:
	if ext_log.is_empty() or ext_seed == 0:
		push_warning("[REPLAY] External: invalid seed or log")
		return
	print("[REPLAY_EXT] called seed=%d bytes=%d nick=%s stack=%s" % [ext_seed, ext_log.size(), ext_nickname, str(get_stack())])
	_replay_seed        = ext_seed
	_replay_log         = ext_log
	_replay_char        = ext_char
	_replay_player_seed = ext_player_seed
	_replay_nickname    = ext_nickname   # set before start_replay so it survives
	start_replay()
	_replay_nickname    = ext_nickname   # re-set after, start_replay() may clear it

func set_replay_speed(spd: float) -> void:
	_replay_speed     = spd
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
	_pending_spring_resets.clear()
	_biome_enemy_cache.clear()
	_last_biome_score = -1

	if is_instance_valid(player):
		player.velocity = Vector2.ZERO
		player.set("has_shield",      false)
		player.set("is_powered_up",   false)
		player.set("powerup_timer",   0.0)
		player.set("powerup_type",    "")
		player.set("_mirror_active",  false)
		player.set("_mirror_timer",   0.0)
		player.set("_drunk_active",   false)
		player.set("_drunk_timer",    0.0)
		player.set("_eq_active",      false)
		player.set("_eq_debuff_timer",0.0)
		player.set("_eq_offset",      Vector2.ZERO)
		player.set("god_mode",        false)
		if player.has_method("set_char"):
			player.call("set_char", _pre_replay_char)
	if is_instance_valid(camera):
		camera.offset = Vector2.ZERO

	# ── Rebuild lobby scene with the player's OWN pre-replay seed ──
	if _pre_replay_seed != 0:
		highest_y  = 0
		score      = 0
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
		player.set("is_dead",         false)
		player.set("_initialized",    false)
		player.set("has_shield",      false)
		player.set("is_powered_up",   false)
		player.set("powerup_timer",   0.0)
		player.set("powerup_type",    "")
		player.set("lives",           3)
		player.set("_mirror_active",  false)
		player.set("_mirror_timer",   0.0)
		player.set("_drunk_active",   false)
		player.set("_drunk_timer",    0.0)
		player.set("_drunk_t",        0.0)
		player.set("_eq_active",      false)
		player.set("_eq_timer",       0.0)
		player.set("_eq_debuff_timer",0.0)
		player.set("_eq_offset",      Vector2.ZERO)
		player.set("_speed_boost",       false)
		player.set("_jump_boost",        false)
		player.set("_speed_boost_timer", 0.0)  # was "_boost_timer" — stale name from before the timer-sharing fix
		player.set("_jump_boost_timer",  0.0)
		player.set("_invincible",     0.0)
		player.set("_hurt_flash",     0.0)
		player.set("god_mode",        false)
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
# ── Quest progress (server-side validated) ──────────────────────────────────
func _submit_quest_progress() -> void:
	if session_id == "":
		return
	var pid := ""
	var main_node = get_tree().get_root().get_node_or_null("Main")
	if main_node and main_node.get("nimiq_address") != null:
		pid = str(main_node.get("nimiq_address"))
	if pid == "" or pid == "Guest":
		return

	var body := JSON.stringify({
		"player_id":  pid,
		"session_id": session_id,
	})

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, body_resp: PackedByteArray):
		http.queue_free()
		if code == 401:
			# 401 here means token was missing or expired — don't trigger re-sign,
			# quest progress is best-effort and server processes it via submit anyway
			print("[GM] quests/progress 401 — skipping, no re-sign")
			return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body_resp.get_string_from_utf8()) == OK:
				var data = j.get_data()
				if data is Dictionary and data.has("completed"):
					var done : Array = data["completed"]
					if done.size() > 0:
						print("[GM] Quest completed: ", done)
						if main_node and main_node.has_method("_on_quests_updated"):
							main_node.call("_on_quests_updated")
	)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var _qtok := ""
	var _qmn = get_tree().get_root().get_node_or_null("Main")
	if _qmn and _qmn.get("_auth_token") != null:
		_qtok = str(_qmn.get("_auth_token"))
	if _qtok == "":
		return  # no token — skip, will retry via flush_pending after sign-in
	headers.append("Authorization: Bearer " + _qtok)
	var _e := http.request(BACKEND_URL + "/backend/quests/progress", headers, HTTPClient.METHOD_POST, body)


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

	var pid := ""
	var nickname := ""
	var main_node_ref = get_tree().get_root().get_node_or_null("Main")
	if main_node_ref:
		if main_node_ref.get("nimiq_address") != null:
			pid = str(main_node_ref.get("nimiq_address"))
		if main_node_ref.get("_nickname") != null:
			nickname = str(main_node_ref.get("_nickname"))

	var char_idx : int = 0
	if main_node_ref and main_node_ref.get("_char_index") != null:
		char_idx = int(main_node_ref.get("_char_index"))

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
		"score":       score,
		"ticks":       rle_ticks,  # RLE'den decode — server ile her zaman eşleşir
		"char":        char_idx,
		"player_id":   pid,
		"nickname":    nickname,
		"nonce":       Time.get_unix_time_from_system() * 1000,
		"replay_log":  replay_b64,
		"player_seed": str(_replay_player_seed),
		"client_version": GameVersion.CLIENT_VERSION,
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
	http.request_completed.connect(func(_r, code, _h, _b):
		http.queue_free()
		print("[GM] submit code=%d sid=%s" % [code, sid.left(8)])
		# 200 or 4xx (except 401) → definitive answer → drop from queue
		# 401 → no auth yet → keep in queue, retry when signed in
		# 0 / 5xx / 429 → network/server error → keep in queue, retry
		if code == 200:
			_pending_remove(sid)
		elif code == 401:
			# Not authenticated — keep in queue, notify Main to show sign-in
			print("[GM] submit 401 — no auth, keeping in queue until signed in")
			_notify_auth_expired()
			_ensure_retry_timer()
		elif code == 409 and _b != null and _b.get_string_from_utf8().find("version_mismatch") != -1:
			# Server rejected this replay because our client build is out of
			# date compared to the server's configured replay version.
			print("[GM] submit 409 version_mismatch — dropping sid=%s" % sid.left(8))
			_pending_remove(sid)
			Toast.get_instance().show_toast(
				"Your game version is out of date. Please refresh the page to update.", Toast.Kind.WARN)
		elif code >= 400 and code < 500:
			# 400/403/409 etc. — permanent rejection, drop
			print("[GM] submit %d — permanent rejection, dropping sid=%s" % [code, sid.left(8)])
			_pending_remove(sid)
		else:
			# 0 (network err), 5xx, 429 — transient, retry
			print("[GM] submit failed (code=%d), staying in queue" % code)
			Toast.network_error("submit code=%d" % code)
			_ensure_retry_timer()
	)
	var _e := http.request(BACKEND_URL + "/backend/submit", headers, HTTPClient.METHOD_POST, body)


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
		http.request_completed.connect(func(_r, code, _h, _b):
			http.queue_free()
			print("[GM] flush submit code=%d sid=%s" % [code, _sid.left(8)])
			if code == 200:
				_pending_remove(_sid)
		)
		var _e := http.request(BACKEND_URL + "/backend/submit", f_headers, HTTPClient.METHOD_POST, body)
		if _e != OK:
			http.queue_free()
