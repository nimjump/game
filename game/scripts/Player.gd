extends CharacterBody2D

var _vw : float = GameConstants.VW
var _vh : float = GameConstants.VH

# ── Hitbox sabitleri — TÜM çarpışma kontrolleri buradan okur ──
const HITBOX_W_RATIO : float = 0.024   # p_half_w = _vw * bu
const HITBOX_H_RATIO : float = 0.025   # p_half_h = _vh * bu
var _gravity_override     : float = -1.0
var _jump_override        : float = -1.0
var _spring_override      : float = -1.0
var _move_override        : float = -1.0
var _jetpack_override     : float = -1.0

var GRAVITY      : float:
	get: return _gravity_override     if _gravity_override     != -1.0 else _vh * 2.25
	set(v): _gravity_override     = v
var JUMP_SPEED   : float:
	get: return _jump_override        if _jump_override        != -1.0 else -_vh * 1.1875
	set(v): _jump_override        = v
var SPRING_SPEED : float:
	get: return _spring_override      if _spring_override      != -1.0 else -_vh * 1.9
	set(v): _spring_override      = v
var MOVE_SPEED   : float:
	get: return _move_override        if _move_override        != -1.0 else _vw * 0.475
	set(v): _move_override        = v
var JETPACK_LIFT : float:
	get: return _jetpack_override     if _jetpack_override     != -1.0 else -_vh * 0.525
	set(v): _jetpack_override     = v

var CHAR_STATS : Array[Dictionary] = []

var is_dead        := false
var _manual_tick   := false
var _game_manager  : Node  = null  # GM reference — for manual platform collision
# NOT cached on purpose: PLATFORM_W/PLATFORM_H are read directly from
# _game_manager every tick in the landing-check block below. This used to be
# cached here (PL-01) to skip two float reads a tick — a negligible saving —
# but caching state that outlives a single tick, on a Player node that
# persists across repeated replay views in the same page session, is exactly
# the class of bug this whole file has been fighting (see the _prev_velocity_y
# and _was_on_floor fixes elsewhere). Every cache here is one more place a
# reset can be forgotten. Reading directly costs nothing measurable and can
# never go stale.
var _visual_tick   : int  = 0    # increments each physics frame for visual fx (sin waves etc)
# _visual_time — real elapsed seconds (delta-accumulated), NOT a tick count.
# The jetpack/wings "running out" glow pulse used to drive its sine wave off
# _visual_tick directly (sin(_visual_tick * 0.015)) — a per-TICK counter, not
# per-SECOND. Any hitch in the visual physics_process rate (mobile browser
# tab throttling, a GC pause, a slow frame — this runs inside a webview,
# frame pacing is never perfectly steady there) changes how many ticks land
# in a given real-world second, so the sine wave's actual speed wobbled with
# frame rate instead of staying constant — that unevenness is what read as
# "flickering / not quite smooth" on jetpack and wings alike (both go
# through this same glow-pulse code, unlike the jetpack-only flame blink).
# Driving it off real elapsed time instead makes the pulse rate constant
# regardless of any frame-rate hiccups.
var _visual_time  : float = 0.0
var _initialized   := false
var has_shield     := false
var is_powered_up  := false
var powerup_timer  := 0.0
var powerup_type   := ""
var lives          := 3
const MAX_LIVES    := 3

signal died
signal collected_item(type: String)
signal lives_changed(new_lives: int)
signal jumped

var _anim_sprite   : AnimatedSprite2D
var _hurt_flash    := 0.0
var _invincible    := 0.0
var _idle_tween    : Tween

var _overlay_jetpack  : Sprite2D
var _overlay_wing_l   : Sprite2D
var _overlay_wing_r   : Sprite2D
var _overlay_bubble   : Sprite2D
var _overlay_flame    : Sprite2D
var _overlay_flame_r  : Sprite2D
var _flame_timer      := 0.0
var _flame_visible    := true
# Cached overlay state — only write visible/flip when changed
var _ov_jet    := false
var _ov_wings  := false
var _ov_shield := false
var _ov_flame  := true
# GL-01: cached glow state — 0=off, 1=jetpack, 2=shield, to avoid per-frame modulate+scale writes
var _glow_state  : int = 0
# OV-01: cached powerup type flags — avoids powerup_type == "jetpack"/"wings" string compare every frame
var _powerup_is_jetpack := false
var _powerup_is_wings   := false
# OV-02: cached modulate to detect if Color.WHITE write can be skipped
var _ov_modulate_white  := true
# CD-01: true when camera offset is non-zero, so drift-back lerp is skipped when at rest
var _cam_offset_active  := false
# CM-01: cached area collision mask bit — only call set_collision_mask_value when it actually changes
var _area_col_enabled   := true

# ── Debuff state ─────────────────────────────────────────────
var _mirror_active    := false
var _mirror_timer     := 0.0
var _drunk_active     := false
var _drunk_t          := 0.0
var _drunk_timer      := 0.0
var _eq_active        := false
var _eq_timer         := 0.0
var _eq_offset        := Vector2.ZERO
var _eq_debuff_timer  := 0.0
const DEBUFF_DURATION := 5.0
# Sprite visual dimensions — calculated in _ready based on _vh
var _sc  := 0.28       
var _sh  := 75.88      
var _sw  := 42.0       
var _sy  := -19.0      
var _st  := -57.0      
var _sb  := 19.0       

# ── Speed / Jump boost ──────────────────────────────────────
# BUG FIX: speed_boost and jump_boost used to share a single _boost_timer.
# Picking up either type reset that ONE shared timer, so if you picked up
# speed_boost, then jump_boost a moment later, the timer got reset for
# BOTH — meaning whichever one you grabbed LAST decided when they both wore
# off together, instead of each running its own independent countdown from
# when it was actually picked up. Split into two separate timers so each
# powerup type's remaining time is its own.
var _speed_boost       := false
var _jump_boost        := false
var _speed_boost_timer := 0.0
var _jump_boost_timer  := 0.0
const BOOST_DURATION   := 6.0

# ── DEBUG: God Mode ──────────────────────────────────────────
var god_mode          := false
var _jetpack_debug    := false
var _wings_debug      := false
var _god_key_held     := false
var _j_key_held       := false
var _k_key_held       := false
var _h_key_held       := false
var _show_hitbox      := false
var _hitbox_overlay_node : Node = null

class _HitboxOverlay extends Node2D:
	var _player : Node
	func _init(p: Node) -> void:
		_player = p
	func _process(_d: float) -> void:
		queue_redraw()
		if Input.is_key_pressed(KEY_H):
			var col := _player.get_node_or_null("PlayerCollision")
			if col and col.shape is CapsuleShape2D:
				print("[HITBOX] radius=", col.shape.radius, " height=", col.shape.height, " pos=", col.position)
	func _draw() -> void:
		if not is_instance_valid(_player): return
		if not _player.get("_show_hitbox"): return
		# AABB — GameManager'ın kullandığı gerçek çarpışma kutusu
		var gm : Node = _player.get("_game_manager")
		if not is_instance_valid(gm): return
		var hw : float = float(gm.get("VW")) * HITBOX_W_RATIO
		var hh : float = float(gm.get("VH")) * HITBOX_H_RATIO
		var c  := Color(0.0, 1.0, 0.2, 1.0)
		# Fizik (platform) hitbox — mavi
		draw_rect(Rect2(-hw, -hh, hw * 2.0, hh * 2.0), Color(0.2, 0.6, 1.0, 1.0), false, 2.0)
		# Düşman AABB — yeşil (aynı boyut)
		draw_rect(Rect2(-hw, -hh, hw * 2.0, hh * 2.0), c, false, 1.0)

var _drunk_ghost_timer := 0.0
const DRUNK_GHOST_INTERVAL := 0.08   
const DRUNK_GHOST_TICKS := 7   # ticks between ghost echoes

var _replay_dir    : int = 0  

var _rng              : RandomNumberGenerator = RandomNumberGenerator.new()
var _visual_rng       : RandomNumberGenerator = RandomNumberGenerator.new()  # visual-only, never affects game state

var _was_on_floor     := false
var _prev_velocity_y  := 0.0
# DETERMINISM FIX: snapshot of velocity.y taken at the very start of this
# tick, i.e. the TRUE previous tick's final velocity. is_stomping() must use
# this instead of _prev_velocity_y — that variable gets overwritten with
# THIS tick's post-physics velocity at the bottom of simulate_tick(), and
# GameManager runs `player.simulate_tick()` BEFORE `for e in _enemies:
# e.simulate_tick()` in the same tick. So by the time an enemy calls
# is_stomping() (from its own simulate_tick(), later in the same GM tick),
# _prev_velocity_y no longer holds "last tick's velocity" — it already holds
# "this tick's velocity", which can be a freshly-bounced upward value if the
# player landed on a platform earlier in this same tick. That misclassifies
# a legitimate stomp as a non-stomp (or vice versa). _tick_entry_velocity_y
# is captured before ANY of this tick's physics runs, so it's stable and
# correct regardless of what happens to velocity later in the same tick.
var _tick_entry_velocity_y := 0.0
var _trail_timer      := 0.0
const TRAIL_INTERVAL  := 0.04
const TRAIL_TICKS      := 5   # ticks between trail spawns (≈ TRAIL_INTERVAL at 60fps)
var _base_scale       := Vector2(0.28, 0.28)  
var _glow_spr         : Sprite2D
var _cam_ref          : Camera2D = null   

static var _dust_tex  : ImageTexture = null
static var _trail_tex : ImageTexture = null

var _frames_stand  : Array[Texture2D] = []
var _frames_walk   : Array[Texture2D] = []
var _frames_jump   : Array[Texture2D] = []
var _frames_hurt   : Array[Texture2D] = []
var _frames_ready  : Array[Texture2D] = []

var _current_anim  := "stand"

static var _glow_tex_cache : ImageTexture = null
static var _glow_tex_size  : int = -1

# PL-09: StringName constants for animation strings
const _ANIM_STAND := &"stand"
const _ANIM_JUMP  := &"jump"
const _ANIM_WALK  := &"walk"
const _ANIM_RUN   := &"run"

# PL-01/02: Cached GM properties — read once, avoids .get() overhead per tick
var _gm_platforms    = null   # untyped — GM array ref (not deep-copied)
var _gm_in_replay    : bool = false

# PL-05: Cached _replay_mode
var _gm_replay_mode : bool = false

# PL-10: Cached has_method for damage call
var _gm_has_hit : bool = false

# PL-07: Dirty flag for glow scale
var _glow_active : bool = false

# PL-11/12: Reuse squash and hurt tweens
var _squash_tween : Tween = null
var _hurt_tween   : Tween = null

# PL-03: Object pool for landing sparks
const _SPARK_POOL_SIZE := 12
var _spark_pool       : Array[Sprite2D] = []
var _spark_idx        : int = 0
var _spark_tween_pool : Array[Tween]    = []  # PERF-TW: reuse tweens, kill+recreate avoids alloc

# PL-04: Object pool for trail ghosts
const _TRAIL_POOL_SIZE := 8
var _trail_pool : Array[Sprite2D] = []
var _trail_idx  : int = 0
var _trail_tween_pool : Array[Tween] = []  # PERF-TW: reuse trail tweens

# PL-05: Object pool for drunk ghost echoes (2 per trigger × max overlap)
const _DRUNK_GHOST_POOL_SIZE := 6
var _drunk_ghost_pool : Array[Sprite2D] = []
var _drunk_ghost_idx  : int = 0


func _ready() -> void:
	_vw = GameConstants.VW
	_vh = GameConstants.VH
	_sc = (_vh * 0.095) / 271.0
	_sh = 271.0 * _sc
	_sw = 150.0 * _sc
	_sy = -_sh * 0.25          
	_st = _sy - _sh * 0.5
	_sb = _sy + _sh * 0.5
	_base_scale = Vector2(_sc, _sc)
	# All characters share identical physics — cosmetic-only selection.
	# Values match the property defaults (gravity=_vh*2.25, jump=-_vh*1.1875,
	# spring=-_vh*1.9, move=_vw*0.475, jetpack=-_vh*0.525) so that
	# set_char() applying these overrides produces the same result as having
	# no override at all. This also eliminates server/client score divergence
	# that arose when a non-default character index was sent in the replay.
	var _cs := { "gravity": _vh * 2.25, "jump": -_vh * 1.1875, "spring": -_vh * 1.9, "move": _vw * 0.475, "jetpack": -_vh * 0.525 }
	CHAR_STATS = [_cs, _cs, _cs, _cs, _cs]
	add_to_group("player")
	z_index = 100

	if OS.is_debug_build():
		var dbg := _HitboxOverlay.new(self)
		dbg.name     = "HitboxOverlay"
		dbg.z_index  = 200
		dbg.top_level = false
		add_child(dbg)
		_hitbox_overlay_node = dbg

	var rect := RectangleShape2D.new()
	rect.size = Vector2(_vw * HITBOX_W_RATIO * 2.0, _vh * HITBOX_H_RATIO * 2.0)
	var col := CollisionShape2D.new()
	col.shape    = rect
	col.position = Vector2(0, 0)
	col.name     = "PlayerCollision"
	add_child(col)
	col.owner    = get_tree().edited_scene_root if Engine.is_editor_hint() else self

	collision_layer = 1
	collision_mask  = 2 | 4

	if _is_headless:
		return

	_load_frames(0)

	_anim_sprite = AnimatedSprite2D.new()
	# Same class of bug as Platform.gd's CollisionShape2D: without an explicit
	# name, add_child()'s default force_readable_name=false gives this an
	# internal placeholder name, breaking GameManager._spawn_ghost_sprite()'s
	# get_node_or_null("AnimatedSprite2D") lookup (used to source the ghost
	# effect's texture) — it silently found nothing and skipped the visual.
	_anim_sprite.name = "AnimatedSprite2D"
	_anim_sprite.sprite_frames = _build_sprite_frames()
	_anim_sprite.scale = Vector2(_sc, _sc)
	_anim_sprite.position = Vector2(0, _sy)
	_anim_sprite.play("stand")
	add_child(_anim_sprite)

	_overlay_jetpack = _make_overlay("res://assets/items/jetpack.png",
		Vector2(0, -2.0),
		Vector2(0.316, 0.316), -1)
	_overlay_wing_l  = _make_overlay("res://assets/items/wing_left.png",
		Vector2(-25.0, -10.0),
		Vector2(0.32, 0.32), 1)
	_overlay_wing_r  = _make_overlay("res://assets/items/wing_right.png",
		Vector2( 25.0, -10.0),
		Vector2(0.32, 0.32), 1)
	_overlay_bubble  = _make_overlay("res://assets/items/bubble.png",
		Vector2(0, _sy),
		Vector2(0.388, 0.388), 1)
	_overlay_flame   = _make_overlay("res://assets/particles/flame.png",
		Vector2(-13.0, 35.0),
		Vector2(0.30, 0.30), -1)
	_overlay_flame_r = _make_overlay("res://assets/particles/flame.png",
		Vector2( 13.0, 35.0),
		Vector2(0.30, 0.30), -1)

	_glow_spr = Sprite2D.new()
	_glow_spr.z_index = -1
	_glow_spr.visible = false
	var glow_sz := int(_vw * 0.107)
	if _glow_tex_cache == null or _glow_tex_size != glow_sz:
		_glow_tex_size = glow_sz
		var glow_img := Image.create(glow_sz, glow_sz, false, Image.FORMAT_RGBA8)
		var half := glow_sz * 0.5
		for gx in glow_sz:
			for gy in glow_sz:
				var dx := gx - half
				var dy := gy - half
				var dist := sqrt(dx*dx + dy*dy) / half
				var alpha := clampf(1.0 - dist, 0.0, 1.0)
				alpha = alpha * alpha * 0.55
				glow_img.set_pixel(gx, gy, Color(1.0, 1.0, 1.0, alpha))
		_glow_tex_cache = ImageTexture.create_from_image(glow_img)
	_glow_spr.texture = _glow_tex_cache
	_glow_spr.scale   = Vector2(1.2, 1.2)
	add_child(_glow_spr)

	if _dust_tex == null:
		var dsz := int(_vw * 0.013)
		var di := Image.create(dsz, dsz, false, Image.FORMAT_RGBA8)
		di.fill(Color(0.85, 0.82, 0.75, 0.9))
		_dust_tex = ImageTexture.create_from_image(di)
	if _trail_tex == null:
		var tsz := int(_vw * 0.007)
		var ti := Image.create(tsz, tsz, false, Image.FORMAT_RGBA8)
		ti.fill(Color(1.0, 1.0, 1.0, 1.0))
		_trail_tex = ImageTexture.create_from_image(ti)

	_gravity_override  = -1.0
	_jump_override     = -1.0
	_spring_override   = -1.0
	_move_override     = -1.0
	_jetpack_override  = -1.0

	# PL-03: Pre-create spark pool (top_level so global_position is world-space)
	for _si in _SPARK_POOL_SIZE:
		var _sp := Sprite2D.new()
		_sp.texture   = _dust_tex
		_sp.z_index   = 3
		_sp.visible   = false
		_sp.top_level = true
		add_child(_sp)
		_spark_pool.append(_sp)
	# PERF-TW: pre-fill spark tween pool with nulls — replaced on first use
	_spark_tween_pool.resize(_SPARK_POOL_SIZE)
	_spark_tween_pool.fill(null)

	# PL-04: Pre-create trail pool (top_level so global_position is world-space)
	for _ti in _TRAIL_POOL_SIZE:
		var _tp := Sprite2D.new()
		_tp.z_index   = -2
		_tp.visible   = false
		_tp.top_level = true
		add_child(_tp)
		_trail_pool.append(_tp)
	# PERF-TW: pre-fill trail tween pool
	_trail_tween_pool.resize(_TRAIL_POOL_SIZE)
	_trail_tween_pool.fill(null)

	# PL-05: Pre-create drunk ghost pool (top_level, world-space echoes)
	for _dgi in _DRUNK_GHOST_POOL_SIZE:
		var _dg := Sprite2D.new()
		_dg.z_index   = -1
		_dg.visible   = false
		_dg.top_level = true
		add_child(_dg)
		_drunk_ghost_pool.append(_dg)

	position = Vector2(_vw * 0.5, _vh * 0.70)
	_cam_ref = get_viewport().get_camera_2d() if get_viewport() else null
	_start_idle_anim()


func set_char(index: int) -> void:
	if _is_headless: return
	_load_frames(index)
	if is_instance_valid(_anim_sprite):
		_anim_sprite.sprite_frames = _build_sprite_frames()
		_anim_sprite.play(_current_anim)


func _load_frames(index: int = 0) -> void:
	var dir  := "res://assets/players/bunny%d/" % (index + 1)
	var _t   := func(n): return load(dir + n) if ResourceLoader.exists(dir + n) else _fallback_tex(Color(1, 0.8, 0.2))
	_frames_stand = [_t.call("stand.png")]
	_frames_ready = [_t.call("ready.png")]
	_frames_walk  = [_t.call("walk1.png"), _t.call("walk2.png")]
	_frames_jump  = [_t.call("jump.png")]
	_frames_hurt  = [_t.call("hurt.png")]


func _build_sprite_frames() -> SpriteFrames:
	var sf := SpriteFrames.new()
	sf.add_animation("stand");
	sf.set_animation_loop("stand", true);  sf.set_animation_speed("stand", 4.0)
	for t in _frames_stand: sf.add_frame("stand", t)
	sf.add_animation("walk");  sf.set_animation_loop("walk", true);   sf.set_animation_speed("walk", 8.0)
	for t in _frames_walk:  sf.add_frame("walk", t)
	sf.add_animation("jump");
	sf.set_animation_loop("jump", false);  sf.set_animation_speed("jump", 4.0)
	for t in _frames_jump:  sf.add_frame("jump", t)
	sf.add_animation("hurt");  sf.set_animation_loop("hurt", false);  sf.set_animation_speed("hurt", 6.0)
	for t in _frames_hurt:  sf.add_frame("hurt", t)
	sf.add_animation("ready");
	sf.set_animation_loop("ready", false); sf.set_animation_speed("ready", 4.0)
	for t in _frames_ready: sf.add_frame("ready", t)
	return sf


func _make_overlay(path: String, offset: Vector2, sc: Vector2, z: int = 1) -> Sprite2D:
	var spr := Sprite2D.new()
	if ResourceLoader.exists(path): spr.texture = load(path)
	spr.position = offset
	spr.scale    = sc
	spr.visible  = false
	spr.z_index  = z
	add_child(spr)
	return spr


## DEBUG: set overlay offsets at runtime
func debug_set_jetpack_offset(x: float, y: float) -> void:
	if is_instance_valid(_overlay_jetpack):
		_overlay_jetpack.position = Vector2(x, y)
	# flame'ler jetpack'in alt kısmında (_sb - _sy kadar aşağısında)
	var flame_dy := (_sb - _sy) + _vh * 0.006
	if is_instance_valid(_overlay_flame):
		_overlay_flame.position  = Vector2(x - _sw * 0.18, y + flame_dy)
	if is_instance_valid(_overlay_flame_r):
		_overlay_flame_r.position = Vector2(x + _sw * 0.18, y + flame_dy)

func debug_set_wings_offset(x: float, y: float) -> void:
	if is_instance_valid(_overlay_wing_l):
		_overlay_wing_l.position = Vector2(-x, y)
	if is_instance_valid(_overlay_wing_r):
		_overlay_wing_r.position = Vector2( x, y)

func debug_get_info() -> Dictionary:
	return {
		"sy": _sy, "st": _st, "sb": _sb, "sh": _sh, "sw": _sw,
		"jp_pos": _overlay_jetpack.position if is_instance_valid(_overlay_jetpack) else Vector2.ZERO,
		"wl_pos": _overlay_wing_l.position  if is_instance_valid(_overlay_wing_l)  else Vector2.ZERO,
		"fl_pos": _overlay_flame.position   if is_instance_valid(_overlay_flame)   else Vector2.ZERO,
	}

func debug_set_flame_offset(x: float, y: float) -> void:
	if is_instance_valid(_overlay_flame):
		_overlay_flame.position  = Vector2(-absf(x), y)
	if is_instance_valid(_overlay_flame_r):
		_overlay_flame_r.position = Vector2( absf(x), y)


func _fallback_tex(color: Color) -> ImageTexture:
	var fw := int(_sw) if _sw > 1.0 else int(_vw * 0.07)
	var fh := int(_sh) if _sh > 1.0 else int(_vh * 0.095)
	var img := Image.create(fw, fh, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func _start_idle_anim() -> void:
	_run_idle_loop()

func _run_idle_loop() -> void:
	if _is_headless: return
	if _initialized or is_dead: return
	_anim_sprite.scale = Vector2(0.28, 0.28)
	_anim_sprite.play("stand")
	var tw := create_tween()
	if not tw: return
	_idle_tween = tw
	tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tw.tween_interval(0.9)
	tw.tween_callback(func():
		if not _initialized and not is_dead:
			_anim_sprite.play("ready")
	)
	tw.tween_interval(0.7)
	tw.tween_callback(func():
		if not _initialized and not is_dead:
			_run_idle_loop()
	)


func activate() -> void:
	if _idle_tween:
		_idle_tween.kill()
		_idle_tween = null
	is_dead      = false
	velocity     = Vector2.ZERO
	_initialized = true
	# NOTE: PLATFORM_W/PLATFORM_H used to be cached here (see field comment
	# above) with a reset-on-activate() as a bandaid. There's no cache left
	# to reset anymore — the landing check now reads _game_manager.PLATFORM_W/H
	# directly every tick, so this class of bug can't happen again.

	# BUG FIX (the real "first jump sometimes doesn't count" bug): landing on
	# a platform only calls on_player_landed() — the thing that actually
	# increments the platform's break counter — if `_prev_velocity_y > _vh *
	# 0.0625` (see the landing block, ~line 758). _prev_velocity_y was NEVER
	# reset here, same stale-across-replay-plays class of bug as the
	# PLATFORM_W/H cache above: since the Player node persists across
	# repeated replay views in the same page session, this variable kept
	# whatever value it had at the exact instant the PREVIOUS replay ended
	# (could be anything — mid-fall, mid-jump, any sign/magnitude). On the
	# very first landing of a NEW replay, THAT leftover value — not the
	# current run's own fall speed — decided whether this gate passed. If it
	# happened to sit below the threshold, the first landing was silently
	# never counted at all, requiring one fewer real bounce to reach
	# MAX_JUMPS on that platform — exactly the "first jump sometimes counted
	# by the platform, sometimes not" behavior reported, independent of any
	# float-boundary tie-break. Reset it here so every new game/replay
	# starts this gate clean, just like a live "Play Again" full scene
	# reload already does for free (since that path recreates Player from
	# scratch, defaults included) — this only mattered for the
	# no-scene-reload replay-viewing path.
	_prev_velocity_y = 0.0
	# Same reason as _prev_velocity_y above — this is the newer sibling
	# variable used by is_stomping(); must not leak a value from whatever
	# replay/session ran before this one.
	_tick_entry_velocity_y = 0.0

	# DEFENSIVE: same stale-across-replay-views risk class as the two fixes
	# above — _was_on_floor drives just_landed/just_jumped edge detection
	# (~line 798-800). Currently only feeds squash/stretch VFX (cosmetic), so
	# this isn't a confirmed score/determinism bug today, but it's one future
	# gameplay hook away from becoming one, and it costs nothing to reset it
	# alongside the other two so every new game/replay starts every
	# landing-adjacent gate from a clean, identical state.
	_was_on_floor = false

	if !_is_headless:
		_anim_sprite.scale = Vector2(0.28, 0.28)
		_anim_sprite.play("stand")


## Called when returning to lobby after a replay ends.
## Fixes character to the "stand" frame and restarts the idle animation loop.
func reset_to_idle() -> void:
	if _is_headless: return
	if _idle_tween:
		_idle_tween.kill()
		_idle_tween = null
	_initialized   = false
	_current_anim  = "stand"
	velocity       = Vector2.ZERO
	if is_instance_valid(_anim_sprite):
		_anim_sprite.scale = Vector2(0.28, 0.28)
		_anim_sprite.stop()
		_anim_sprite.play("stand")
		_anim_sprite.set_frame_and_progress(0, 0.0)
	_start_idle_anim()


static var _is_headless : bool = (DisplayServer.get_name() == "headless")


func _physics_process(delta: float) -> void:
	# Physics state is ticked by GM via simulate_tick().
	# Visual-only updates run here once per rendered frame — independent of replay speed.
	if _is_headless: return
	queue_redraw()
	if not _initialized or is_dead: return
	_update_animation()
	_update_overlays_visual(delta)
	_update_glow()
	_update_camera_drift(delta)
	_visual_tick += 1
	_visual_time += delta


func simulate_tick() -> void:
	const delta := 1.0 / 60.0   # fixed delta — deterministic physics independent of frame drops
	if is_dead or not _initialized: return

	# DETERMINISM FIX: capture the true previous-tick velocity BEFORE this
	# tick changes it. See the comment on _tick_entry_velocity_y above.
	_tick_entry_velocity_y = velocity.y

	# PL-02: _gm_in_replay cached — re-read each tick (replay mode can change mid-game)
	# Direct field access avoids .get() string lookup
	if _game_manager != null:
		_gm_in_replay = (_game_manager._replay_mode == 2)
	if not _gm_in_replay and OS.is_debug_build():
		if Input.is_key_pressed(KEY_G) and not _god_key_held:
			_god_key_held = true
			god_mode = true
			lives = 99
			emit_signal("lives_changed", lives)
		if not Input.is_key_pressed(KEY_G):
			_god_key_held = false

		if Input.is_key_pressed(KEY_J) and not _j_key_held:
			_j_key_held = true
			_jetpack_debug = not _jetpack_debug
			if _jetpack_debug:
				activate_powerup("jetpack")
				powerup_timer = 999999.0
			else:
				is_powered_up = false
				powerup_type  = ""
		if not Input.is_key_pressed(KEY_J):
			_j_key_held = false

		if Input.is_key_pressed(KEY_K) and not _k_key_held:
			_k_key_held = true
			_wings_debug = not _wings_debug
			if _wings_debug:
				activate_powerup("wings")
				powerup_timer = 999999.0
			else:
				is_powered_up = false
				powerup_type  = ""
		if not Input.is_key_pressed(KEY_K):
			_k_key_held = false

		if Input.is_key_pressed(KEY_H) and not _h_key_held:
			_h_key_held = true
			_show_hitbox = not _show_hitbox
		if not Input.is_key_pressed(KEY_H):
			_h_key_held = false


	if is_powered_up:
		powerup_timer -= delta
		if powerup_timer <= 0.0:
			is_powered_up       = false
			powerup_type        = ""
			_powerup_is_jetpack = false
			_powerup_is_wings   = false
			_glow_state = -1  # force glow refresh

	# Speed / Jump boost timers — independent, see note at declaration above
	if _speed_boost:
		_speed_boost_timer -= delta
		if _speed_boost_timer <= 0.0:
			_speed_boost = false
	if _jump_boost:
		_jump_boost_timer -= delta
		if _jump_boost_timer <= 0.0:
			_jump_boost = false

	# Debuff timers — each independent
	if _mirror_active:
		_mirror_timer -= delta
		if _mirror_timer <= 0.0:
			_mirror_active = false
	if _drunk_active:
		_drunk_timer -= delta
		_drunk_t += delta * 1.8  # physics timer — drives visual sway in _physics_process
		if _drunk_timer <= 0.0:
			_drunk_active = false
	if _eq_active:
		_eq_debuff_timer -= delta
		_eq_timer += delta
		_eq_offset = Vector2(sin(_eq_timer * 18.0) * _vw * 0.012, cos(_eq_timer * 14.0) * _vh * 0.006)
		if _eq_debuff_timer <= 0.0:
			_eq_active  = false
			_eq_offset  = Vector2.ZERO
			_eq_timer   = 0.0
			if is_instance_valid(_cam_ref): _cam_ref.offset = Vector2.ZERO
	# Visual: drunk cam sway + color pulse run in _physics_process per frame

	# [PERF] process invincible and hurt_flash in one block
	if _invincible > 0.0:
		_invincible = maxf(0.0, _invincible - delta)
	if _hurt_flash > 0.0:
		_hurt_flash -= delta
	# modulate updates are visual — handled in _physics_process

	if is_powered_up:
		velocity.y = move_toward(velocity.y, JETPACK_LIFT, GRAVITY * delta * 0.6)
	else:
		velocity.y += GRAVITY * delta

	# Input: GM sets _replay_dir in all modes
	var dir_int : int = _replay_dir
	# Mirror debuff — reverse controls
	if _mirror_active:
		dir_int = -dir_int
	var dir := float(dir_int)
	var current_move := MOVE_SPEED * (1.35 if _speed_boost else 1.0)
	velocity.x = dir * current_move

	# Platform collision active only when falling (checked with manual AABB)
	var want_plat_col : bool = velocity.y > 0 and not is_powered_up
	# CM-01: cache area collision mask state — avoid physics server query every tick
	var want_area_col : bool = not is_powered_up
	if want_area_col != _area_col_enabled:
		_area_col_enabled = want_area_col
		set_collision_mask_value(4, want_area_col)

	# Manual AABB platform collision — independent of Godot physics server,
	# deterministic even across multiple calls in the same frame.
	var motion := velocity * delta
	var landed := false
	var _landed_collider = null

	if want_plat_col and _game_manager != null:
		# Apply motion
		global_position += motion

		# Player bounds — tek kaynak: GameManager p_half_w / p_half_h
		var p_hw     : float = _vw * HITBOX_W_RATIO
		var p_hh     : float = _vh * HITBOX_H_RATIO
		var p_bottom : float = global_position.y + p_hh
		var p_left   : float = global_position.x - p_hw
		var p_right  : float = global_position.x + p_hw
		var p_bottom_prev : float = (global_position.y - motion.y) + p_hh

		# PL-01: direct field access — avoids .get() string hash every tick
		var platforms : Array = _game_manager._platforms
		# NOT cached — read live every tick (see field-declaration comment).
		var pw : float = _game_manager.PLATFORM_W
		var ph : float = _game_manager.PLATFORM_H
		const LAND_EPS := 0.05
		if platforms != null:
			for plat in platforms:
				if not is_instance_valid(plat): continue
				# Platform bounds
				var plat_top    : float = plat.global_position.y - ph * 0.5
				var plat_bottom : float = plat.global_position.y + ph * 0.5
				var plat_left   : float = plat.global_position.x - pw * 0.5
				var plat_right  : float = plat.global_position.x + pw * 0.5

				# X overlap
				if p_right < plat_left or p_left > plat_right: continue
				# Did we pass top-to-bottom? Sweep check handles tunneling at high velocity:
				# condition: was above (or inside) plat top in prev frame AND now at or below plat top
				# Extended: p_bottom_prev <= plat_bottom covers the case where player
				# tunneled through the entire platform thickness in one tick.
				#
				# HARDENING: added a tiny epsilon (0.05px in this game's virtual
				# coordinate space) to both sides of the comparison. This was a
				# STRICT boundary check on continuously-accumulated floats —
				# exactly on the tick where the player's swept segment just
				# grazes plat_top (most likely right at spawn, when the player
				# starts sitting exactly ON the platform with zero gap), a
				# sub-0.01-unit rounding difference could flip "landed" from
				# true to false or vice versa on that one tick, which is
				# indistinguishable from a real missed/extra landing from the
				# outside. The epsilon makes the tie resolve the same way
				# every time instead of being exactly on the knife's edge.
				if p_bottom_prev <= plat_bottom + LAND_EPS and p_bottom >= plat_top - LAND_EPS:
					# Land on platform top
					global_position.y = plat_top - p_hh
					landed = true
					_landed_collider = plat
					break
	else:
		# Moving up / jetpack — no platforms, just apply motion
		global_position += motion

	# Earthquake offset computed above — applied visually in _physics_process

	# Platform collision: landed flag set above
	if landed:
		velocity.y = JUMP_SPEED * (1.35 if _jump_boost else 1.0)
		emit_signal("jumped")
		# BUG FIX: this gate used to require _prev_velocity_y > _vh * 0.0625 —
		# i.e. "must have been falling reasonably fast" — before counting the
		# landing toward the platform's break counter at all. Reported bug:
		# jumping UP onto a platform at a steep/shallow angle (arc barely
		# clears the platform's top edge before immediately coming back down
		# onto it) legitimately lands with only a SMALL fall velocity — that
		# real, physical landing was silently never counted, so platforms
		# reached this way could never break no matter how many times you
		# actually bounced on them. The gate conflated "how far did I fall
		# before touching down" with "did I actually land" — those aren't the
		# same thing, and only the latter should matter. Lowered to a tiny
		# epsilon that only filters out the genuine non-cases (moving upward,
		# or exactly stationary — floating-point noise, not a real landing),
		# without rejecting legitimate shallow-arc landings.
		if _prev_velocity_y > 0.001:
			if _landed_collider and _landed_collider.has_method("on_player_landed"):
				_landed_collider.on_player_landed()

	# Screen edge wrap
	if global_position.x > _vw + 20.0:
		global_position.x = -20.0
	elif global_position.x < -20.0:
		global_position.x = _vw + 20.0

	if !_is_headless and is_instance_valid(_anim_sprite):
		var want_flip := velocity.x < 0
		if velocity.x != 0 and _anim_sprite.flip_h != want_flip:
			_anim_sprite.flip_h = want_flip

	# Squash & Stretch — is_on_floor() doesn't work with move_and_collide,
	# use landed flag and velocity change instead
	var just_landed := landed and not _was_on_floor
	var just_jumped := _was_on_floor and not landed and velocity.y < -_vh * 0.25
	_was_on_floor = landed

	if just_landed:
		_do_squash()
		_spawn_dust()
	elif just_jumped:
		_do_stretch()

	# Motion trail — tick-based so speed-invariant
	if !_is_headless:
		var fast_vertical := not landed and velocity.y < -_vh * 0.875
		if fast_vertical:
			_trail_timer += 1  # count ticks, not seconds
			if _trail_timer >= TRAIL_TICKS:
				_trail_timer = 0
				_spawn_trail()
		else:
			_trail_timer = 0

		# Drunk ghost echo — tick-based
		if _drunk_active:
			_drunk_ghost_timer += 1
			if _drunk_ghost_timer >= DRUNK_GHOST_TICKS:
				_drunk_ghost_timer = 0
				_spawn_drunk_ghost()

	_prev_velocity_y = velocity.y
	# Cross-platform determinism: snap physics state to fixed grid (WASM vs native drift)
	global_position.x = snappedf(global_position.x, 0.01)
	global_position.y = snappedf(global_position.y, 0.01)
	velocity.x = snappedf(velocity.x, 0.01)
	velocity.y = snappedf(velocity.y, 0.01)
	# _update_animation / _update_overlays / _update_glow run in _physics_process (frame-rate)


func _update_animation() -> void:
	if _is_headless: return
	var target := "stand"
	if velocity.y < -100:       target = "jump"
	elif abs(velocity.x) > 10: target = "walk"
	if target != _current_anim:
		_current_anim = target
		_anim_sprite.play(_current_anim)


func _update_overlays_visual(delta: float) -> void:
	if _is_headless: return
	# Drunk camera sway + color
	if _drunk_active:
		if is_instance_valid(_cam_ref):
			_cam_ref.offset = Vector2(
				sin(_drunk_t * 1.1) * _vw * 0.025,
				cos(_drunk_t * 0.8) * _vh * 0.018
			)
			_cam_offset_active = true
		var pulse := (sin(_drunk_t * 2.5) + 1.0) * 0.5
		if is_instance_valid(_anim_sprite):
			_anim_sprite.modulate = Color(1.0, 0.85 + pulse * 0.15, 0.3 + pulse * 0.2)
		_ov_modulate_white = false
	# Earthquake cam offset
	if _eq_active and is_instance_valid(_cam_ref):
		_cam_ref.offset    = _eq_offset
		_cam_offset_active = true
	# Hurt flash
	# OV-02: only write modulate when changing state — avoids Color.WHITE write every frame when idle
	if _hurt_flash > 0.0:
		if is_instance_valid(_anim_sprite):
			_anim_sprite.modulate = Color(1, 0.3, 0.3, 1)
		_ov_modulate_white = false
	elif not _drunk_active:
		if not _ov_modulate_white and is_instance_valid(_anim_sprite):
			_anim_sprite.modulate = Color.WHITE
			_ov_modulate_white = true
	# OV-01: Use cached bool flags instead of powerup_type string comparison every frame
	var jet   := is_powered_up and _powerup_is_jetpack
	var wings := is_powered_up and _powerup_is_wings
	if jet != _ov_jet:
		_ov_jet = jet
		_overlay_jetpack.visible = jet
	if wings != _ov_wings:
		_ov_wings = wings
		_overlay_wing_l.visible = wings
		_overlay_wing_r.visible = wings
	if wings and is_instance_valid(_anim_sprite):
		var fh := _anim_sprite.flip_h
		if _overlay_wing_l.flip_h != fh:
			_overlay_wing_l.flip_h = fh
			_overlay_wing_r.flip_h = fh
	if has_shield != _ov_shield:
		_ov_shield = has_shield
		_overlay_bubble.visible = has_shield

	if jet:
		var blinking := powerup_timer < 1.5
		if blinking:
			_flame_timer += delta
			if _flame_timer >= 0.12:
				_flame_timer   = 0.0
				_flame_visible = not _flame_visible
		else:
			_flame_timer   = 0.0
			_flame_visible = true
		if _flame_visible != _ov_flame:
			_ov_flame = _flame_visible
			_overlay_flame.visible   = _flame_visible
			_overlay_flame_r.visible = _flame_visible
	else:
		if _ov_flame:
			_ov_flame = false
			_overlay_flame.visible   = false
			_overlay_flame_r.visible = false


func do_spring_jump() -> void:
	if is_powered_up and (_powerup_is_jetpack or _powerup_is_wings): return
	velocity.y = SPRING_SPEED * (1.4 if _jump_boost else 1.0)
	if is_instance_valid(_anim_sprite): _anim_sprite.play("jump")


func activate_powerup(type: String) -> void:
	match type:
		"jetpack":
			is_powered_up = true
			powerup_timer = 5.0
			powerup_type  = type
			_powerup_is_jetpack = true
			_powerup_is_wings   = false
			velocity.y    = -_vh * 0.75
			_glow_state = -1  # force glow refresh on next frame
			activate_powerup_flash()
		"wings":
			is_powered_up = true
			powerup_timer = 4.0
			powerup_type  = type
			_powerup_is_jetpack = false
			_powerup_is_wings   = true
			velocity.y    = -_vh * 0.75
			_glow_state = -1
			activate_powerup_flash()
		"speed_boost":
			_speed_boost = true
			_speed_boost_timer = BOOST_DURATION
			activate_powerup_flash()
		"jump_boost":
			_jump_boost  = true
			_jump_boost_timer = BOOST_DURATION
			activate_powerup_flash()
		# ── Kalkan ───────────────────────────────────────────
		"bubble":
			has_shield  = true
			_glow_state = -1
			activate_powerup_flash()
		# ── Debufflar ────────────────────────────────────────
		"mirror":
			_mirror_active = true
			_mirror_timer  = DEBUFF_DURATION
			activate_powerup_flash()
		"earthquake":
			_eq_active       = true
			_eq_timer        = 0.0
			_eq_debuff_timer = DEBUFF_DURATION
			activate_powerup_flash()
		"drunk":
			_drunk_active = true
			_drunk_t      = 0.0
			_drunk_timer  = DEBUFF_DURATION
			activate_powerup_flash()


func open_mystery_box() -> void:
	var outcomes := ["speed_boost", "jump_boost", "mirror", "earthquake", "drunk"]
	if _rng == null:
		push_error("[Player] open_mystery_box: _rng is null — replay determinizmi bozulur!")
		return
	var picked : String = outcomes[_rng.randi() % outcomes.size()]
	activate_powerup(picked)


func apply_shield() -> void:
	has_shield = true


func add_life(amount: int = 1) -> void:
	lives = min(lives + amount, MAX_LIVES)
	emit_signal("lives_changed", lives)


func full_heal() -> void:
	lives = MAX_LIVES
	has_shield = true
	emit_signal("lives_changed", lives)


func is_stomping() -> bool:
	# DETERMINISM FIX: was reading _prev_velocity_y, but by the time an enemy
	# calls this (later in the same GM tick, after player.simulate_tick() has
	# already run and already overwritten _prev_velocity_y with THIS tick's
	# outcome), that no longer means "previous tick". Use the tick-entry
	# snapshot instead — see _tick_entry_velocity_y declaration.
	return _tick_entry_velocity_y > _vh * 0.04


func hit_enemy() -> void:
	if god_mode: return
	if is_powered_up: return
	if _invincible > 0: return
	if has_shield:
		has_shield  = false
		_glow_state = -1
		emit_signal("collected_item", "shield_lost")
		_hurt_flash = 0.8
		# BUG FIX: real damage below grants _invincible = 1.2 so a persistent
		# hazard (standing on a spike, sitting in overlapping rain/dirt damage
		# across multiple ticks) can't hit twice in a row. Losing the shield
		# used to skip this entirely — the very next tick, still overlapping
		# the same hazard, would find has_shield already false and take a
		# REAL life immediately. Shield break now gets the same grace window.
		_invincible = 1.2
		if is_instance_valid(_anim_sprite): _anim_sprite.play("hurt")
		return
	lives -= 1
	emit_signal("lives_changed", lives)
	# Notify GameManager for quest tracking
	if is_instance_valid(_game_manager) and _game_manager.has_method("on_player_took_damage"):
		_game_manager.call("on_player_took_damage")
	if lives <= 0:
		die()
		return
	_invincible = 1.2
	_hurt_flash = 0.8
	if is_instance_valid(_anim_sprite): _anim_sprite.play("hurt")
	if !_is_headless:
		var tw := create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_interval(0.5)
			tw.tween_callback(func():
				if not is_dead and is_instance_valid(_anim_sprite): _anim_sprite.play("stand")
			)


func die() -> void:
	if is_dead: return
	is_dead = true
	print("[PLAYER_DIE] lives=%d pos=(%.1f,%.1f) vel=(%.1f,%.1f)" % [lives, global_position.x, global_position.y, velocity.x, velocity.y])
	if is_instance_valid(_anim_sprite): _anim_sprite.play("hurt")
	if !_is_headless and is_instance_valid(_anim_sprite):
		var tw := create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(_anim_sprite, "modulate", Color(1.2, 0.2, 0.2, 1.0), 0.08)
			tw.tween_property(_anim_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.15)
	emit_signal("died")


func _do_squash() -> void:
	if _is_headless: return
	if _squash_tween and _squash_tween.is_valid(): _squash_tween.kill()
	_squash_tween = create_tween()
	if not _squash_tween: return
	_squash_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_squash_tween.tween_property(_anim_sprite, "scale", Vector2(_base_scale.x * 1.22, _base_scale.y * 0.80), 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_squash_tween.tween_property(_anim_sprite, "scale", _base_scale, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _do_stretch() -> void:
	if _is_headless: return
	if _squash_tween and _squash_tween.is_valid(): _squash_tween.kill()
	_squash_tween = create_tween()
	if not _squash_tween: return
	_squash_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_squash_tween.tween_property(_anim_sprite, "scale", Vector2(_base_scale.x * 0.82, _base_scale.y * 1.22), 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_squash_tween.tween_property(_anim_sprite, "scale", _base_scale, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _spawn_dust() -> void:
	# PL-03: Use pre-allocated spark pool — no Sprite2D.new() or add_child per landing
	if _is_headless: return
	if _spark_pool.is_empty(): return
	for i in 6:
		var _sidx : int = _spark_idx
		var p : Sprite2D = _spark_pool[_sidx]
		_spark_idx = (_sidx + 1) % _spark_pool.size()
		if not is_instance_valid(p): continue
		p.scale    = Vector2(1.0, 1.0)
		p.modulate = Color(1.0, 1.0, 1.0, 1.0)
		p.visible  = true
		p.global_position = global_position + Vector2(_visual_rng.randf_range(-_vw * 0.03, _vw * 0.03), _vh * 0.0125)
		var angle  := _visual_rng.randf_range(PI * 0.85, PI * 1.15) + (i - 3) * 0.22
		var speed  := _visual_rng.randf_range(_vh * 0.069, _vh * 0.15)
		var vel    := Vector2(cos(angle), sin(angle)) * speed
		var dur    := _visual_rng.randf_range(0.22, 0.38)
		# PERF-TW: kill previous tween on this slot and recreate — avoids orphaned Tween allocs
		var _old_stw : Tween = _spark_tween_pool[_sidx]
		if _old_stw and _old_stw.is_valid(): _old_stw.kill()
		var tw := create_tween()
		_spark_tween_pool[_sidx] = tw
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(p, "global_position", p.global_position + vel * dur, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(p, "scale", Vector2(2.5, 2.5), dur * 0.7)
			tw.parallel().tween_property(p, "modulate:a", 0.0, dur)
			tw.tween_callback(func(): if is_instance_valid(p): p.visible = false)


func _spawn_trail() -> void:
	# PL-04: Use pre-allocated trail pool — no Sprite2D.new() or add_child per frame
	if _is_headless: return
	if not is_instance_valid(_anim_sprite): return
	if _trail_pool.is_empty(): return
	var sf := _anim_sprite.sprite_frames
	if not sf: return
	var anim_name := _anim_sprite.animation
	if not sf.has_animation(anim_name): return
	var frame_idx := _anim_sprite.frame
	if frame_idx >= sf.get_frame_count(anim_name): return
	var ghost : Sprite2D = _trail_pool[_trail_idx]
	var _tidx : int = _trail_idx
	_trail_idx = (_trail_idx + 1) % _trail_pool.size()
	if not is_instance_valid(ghost): return
	ghost.texture  = sf.get_frame_texture(anim_name, frame_idx)
	ghost.scale    = _anim_sprite.scale * (1.0 / _anim_sprite.scale.x) * 0.26
	ghost.flip_h   = _anim_sprite.flip_h
	ghost.modulate = Color(0.5, 0.8, 1.0, 0.35)
	ghost.visible  = true
	ghost.global_position = global_position
	# PERF-TW: kill previous tween on this slot and reuse
	var _old_tw : Tween = _trail_tween_pool[_tidx]
	if _old_tw and _old_tw.is_valid(): _old_tw.kill()
	var tw := create_tween()
	_trail_tween_pool[_tidx] = tw
	if tw:
		tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		tw.tween_property(ghost, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_LINEAR)
		tw.tween_callback(func(): if is_instance_valid(ghost): ghost.visible = false)


func _spawn_drunk_ghost() -> void:
	# PL-05: Use pre-allocated drunk ghost pool — no Sprite2D.new() or add_child per trigger
	if _is_headless: return
	if not is_instance_valid(_anim_sprite): return
	if _drunk_ghost_pool.is_empty(): return
	var sf := _anim_sprite.sprite_frames
	if not sf: return
	var anim_name := _anim_sprite.animation
	if not sf.has_animation(anim_name): return
	var frame_idx := _anim_sprite.frame
	if frame_idx >= sf.get_frame_count(anim_name): return
	var tex := sf.get_frame_texture(anim_name, frame_idx)

	for i in 2:
		var ghost : Sprite2D = _drunk_ghost_pool[_drunk_ghost_idx]
		_drunk_ghost_idx = (_drunk_ghost_idx + 1) % _drunk_ghost_pool.size()
		if not is_instance_valid(ghost): continue
		ghost.texture  = tex
		ghost.scale    = _anim_sprite.scale
		ghost.flip_h   = _anim_sprite.flip_h
		ghost.modulate = Color(1.2, 0.4, 0.3, 0.45) if i == 0 else Color(0.3, 0.6, 1.2, 0.45)
		ghost.visible  = true
		var offset_x := (-1 if i == 0 else 1) * _vw * 0.018
		ghost.global_position = global_position + Vector2(_anim_sprite.position.x + offset_x, _anim_sprite.position.y)
		var tw := ghost.create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(ghost, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_LINEAR)
			tw.tween_callback(func(): if is_instance_valid(ghost): ghost.visible = false)


func _update_camera_drift(delta: float) -> void:
	# CD-01: _cam_offset_active tracks whether the offset is non-zero — avoids length_squared
	# + lerp computation every frame when the camera is already at rest.
	if _is_headless: return
	if not is_instance_valid(_cam_ref): return
	if not _drunk_active and not _eq_active:
		if _cam_offset_active:
			if _cam_ref.offset.length_squared() > 0.01:
				_cam_ref.offset = _cam_ref.offset.lerp(Vector2.ZERO, minf(12.0 * delta, 1.0))
			else:
				_cam_ref.offset  = Vector2.ZERO
				_cam_offset_active = false


func _update_glow() -> void:
	# GL-01: Use _glow_state dirty tracking to avoid per-frame modulate+scale writes when nothing changed.
	# State: -1=force refresh, 0=off, 1=jetpack, 2=wings/shield
	if _is_headless: return
	if not is_instance_valid(_glow_spr): return
	if is_powered_up:
		# Flickering alpha when timer < 1.5 must run every frame — but only when actually flickering
		if powerup_timer < 1.5:
			var col : Color = Color(1.0, 0.5, 0.1, 0.7) if _powerup_is_jetpack else Color(0.3, 0.7, 1.0, 0.7)
			# Time-based (not tick-based, see _visual_time's doc comment) —
			# 0.9 rad/sec matches the old tick-based rate at a steady 60fps,
			# but now stays that same speed even when frame pacing wobbles.
			col.a = 0.7 * (0.4 + 0.6 * sin(_visual_time * 0.9))
			if _glow_state != 1: _glow_spr.visible = true
			_glow_spr.modulate = col
			_glow_spr.scale    = Vector2(1.4, 1.4)
			_glow_state = 1
		else:
			var want_state : int = 1
			if _glow_state != want_state:
				_glow_state = want_state
				_glow_spr.visible  = true
				_glow_spr.modulate = Color(1.0, 0.5, 0.1, 0.7) if _powerup_is_jetpack else Color(0.3, 0.7, 1.0, 0.7)
				_glow_spr.scale    = Vector2(1.4, 1.4)
	elif has_shield:
		if _glow_state != 2:
			_glow_state        = 2
			_glow_spr.visible  = true
			_glow_spr.modulate = Color(0.2, 0.8, 1.0, 0.45)
			_glow_spr.scale    = Vector2(1.1, 1.1)
	else:
		if _glow_state != 0:
			_glow_state       = 0
			_glow_spr.visible = false


func activate_powerup_flash() -> void:
	if _is_headless: return
	var tw := create_tween()
	if not tw: return
	tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tw.tween_property(_anim_sprite, "modulate", Color(2.0, 2.0, 2.0, 1.0), 0.07)
	tw.tween_property(_anim_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.25).set_trans(Tween.TRANS_QUAD)
