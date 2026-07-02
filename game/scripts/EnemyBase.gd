extends Area2D
class_name EnemyBase

# ── Sabitler ──────────────────────────────────────────────────────────────────
var _vw : float = GameConstants.VW
var _vh : float = GameConstants.VH
var PATROL_RANGE : float:
	get: return _vw * 0.108
var target_anim_size : float:
	get: return _vw * 0.08
# Vertical gap used whenever an enemy is snapped/landed onto a platform's top
# surface. Must be >= half of target_anim_size (0.04*_vw) so the sprite's
# bottom edge never overlaps the platform — otherwise enemies visibly sink
# into the platform. Kept as a fixed constant (not derived from the actual
# texture) so headless replay/anti-cheat verification stays bit-identical
# with the graphical client, which is the only place textures are loaded.
var PLATFORM_STAND_GAP : float:
	get: return _vw * 0.055  # was 0.04 — enemies were visibly sinking into platforms across the board
# Per-enemy-type fine-tune: most enemies look right with PLATFORM_STAND_GAP,
# but a sprite with unusual padding/shape (e.g. a flatter or top-heavy asset)
# can still look like it's sinking or floating even after the generic value
# is correct for everyone else. Set this in _special_setup() for that one
# enemy type instead of touching the shared constant.
# NOTE: a plain "-1 = unset" sentinel doesn't work here because negative
# override values are a valid, intended case (pushes the enemy DOWN into the
# platform). So "is it set" is tracked with its own bool instead of inferring
# it from the sign of the value.
var _platform_gap_override        : float = 0.0
var _platform_gap_override_active : bool  = false

func _platform_gap() -> float:
	return _platform_gap_override if _platform_gap_override_active else PLATFORM_STAND_GAP
const PATROL_TIME  := 1.3

# ── DEBUG: live platform-bounds visualiser ───────────────────────────
# Set to true to draw, on screen, the exact numbers the AI uses every frame:
#   • YELLOW box  = the platform's real CollisionShape2D rectangle
#   • CYAN lines  = _get_plat_bounds() left/right edges (what the AI reads)
#   • GREEN lines = the actual clamp range (edges + _vw*0.04 margin)
#   • RED dot     = the enemy's own global_position.x
# If the cyan/green lines don't line up with the yellow box, the bounds maths
# is wrong. Flip this to false (or delete this block) to turn the overlay off.
const DEBUG_DRAW_BOUNDS := false

# ── State variables ──────────────────────────────────────────────────────────────────
var _rng           : RandomNumberGenerator = RandomNumberGenerator.new()
# Per-instance chase/follow speed multiplier — rolled once from this enemy's
# own seeded _rng (see base_setup()) so that same-type enemies chasing the
# player at the same time don't all move in perfect lockstep. Deterministic:
# _rng is seeded from game_seed + a monotonic spawn counter (GameManager
# _spawn_enemy_on_platform) before setup() ever runs, so client and server
# always roll the identical value for the identical enemy.
var _speed_variance : float = 1.0
var difficulty     := 0.0
var enemy_type     : int
var can_fly        := false
var _platform      : Node = null
var _anim          : AnimatedSprite2D
var _col           : CollisionShape2D
var _tween         : Tween
var _effect_spr    : Sprite2D
var _setup_done    := false
var _start_x       := 0.0
var _start_y       := 0.0
var _state         := "idle"
var _state_timer   := 0.0
var _stun_timer    := 0.0
var _hp            := 1

# [PERF] Direct Player Reference (get_tree crash fix)
var _player_ref    : Node = null
var _gm_ref        : Node = null   # GameManager ref — for projectile AABB registration
var _player_cache_miss : int = 0   # throttle: retry get_nodes_in_group max once per 60 ticks

# [PERF] Snap cache
var _snap_target_y    : float = 0.0
var _snap_dirty       := true
var _snap_disabled    := false
var _xclamp_disabled  := false  # mid-transit movers (e.g. spider web climb) set this to skip the per-tick platform-bounds clamp

# ── Platform bounds cache (for mouse, frog, spikeman) ────────────────────────────
var _plat_bounds_valid := false
var _plat_left_x       := 0.0
var _plat_right_x      := 0.0
var _plat_shape        : CollisionShape2D = null   # [PERF] EN-02: cached per-platform shape

# ── Tick-based patrol ────────────────────────────────────────────────────────────────────────
var _patrol_active  := false
var _patrol_left_x  := 0.0
var _patrol_right_x := 0.0
var _patrol_period  := 1.0
var _patrol_timer   := 0.0

# ── Tick-based vertical bob ───────────────────────────────────────────────────────────────────────────
var _bob_active    := false
var _bob_amplitude := 0.0
var _bob_period    := 1.0
var _bob_timer     := 0.0

# ── Deterministic collision detection ────────────────────────────────────────────────────────
var _overlap_triggered := false

# ── Animasyon guard ────────────────────────────────────────────────────────────────────────────
var _patrol_controls_flip := false

# ── Tick-based general movement engine ────────────────────────────────────────────────────────────────────
var _move_segments : Array = []
var _move_active   := false

# ── Active tweens list (for seek cleanup) ─────────────────────────────────────
var _active_tweens : Array[Tween] = []

# [PERF] EN-05: cached headless flag — avoids DisplayServer.get_name() string compare every call
var _is_headless : bool = false

# [PERF] EN-06: cached vertical overlap offset
var _overlap_v_offset : Vector2 = Vector2.ZERO


func _ready() -> void:
	# Fixed virtual world resolution, matching GameManager's VW/VH and the
	# platform coordinate space — single source of truth: GameConstants.
	_vw = GameConstants.VW
	_vh = GameConstants.VH
	# [PERF] EN-05: cache headless flag once
	_is_headless = DisplayServer.get_name() == "headless"
	# [PERF] EN-06: cache overlap vertical offset
	_overlap_v_offset = Vector2(0, _vh * 0.00375)
	collision_layer = 4
	collision_mask  = 1
	monitoring  = false
	monitorable = true

	var cs := CircleShape2D.new()
	cs.radius = int(_vw * 0.03)
	_col = CollisionShape2D.new()
	_col.shape = cs
	add_child(_col)

	# DEBUG: lift the enemy above platform decorations so the bounds overlay
	# (drawn by _draw) is always visible on top. Harmless; only when debug is on.
	if DEBUG_DRAW_BOUNDS:
		z_index = 10

	# Visual nodes — skip in headless
	if not _is_headless:
		_anim = AnimatedSprite2D.new()
		add_child(_anim)
		_effect_spr = Sprite2D.new()
		_effect_spr.visible = false
		_effect_spr.z_index = 2
		add_child(_effect_spr)

	# Cache on first scene entry as fallback if GameManager didn't provide it externally
	_cache_player_reference()

func base_setup(etype: int, anim_frames: Dictionary, diff: float) -> void:
	difficulty = diff
	enemy_type = etype
	_start_x   = global_position.x
	_overlap_triggered = false

	_hp        = _base_hp_for(etype)
	_snap_dirty = true

	# ±12% chase/follow speed variance — see field comment above. Rolled here
	# (not in _special_setup) so it's set before ANY AI code can possibly run,
	# regardless of per-type setup order.
	_speed_variance = _rng.randf_range(0.88, 1.12)

	# Calculate platform bounds cache (for mouse/frog/spikeman boundary checks)
	_plat_bounds_valid = false
	if is_instance_valid(_platform):
		var _ps := _platform.get_node_or_null("CollisionShape2D")
		if _ps and _ps.shape:
			var _le0 : Vector2 = _ps.to_global(Vector2(-_ps.shape.size.x * 0.5, 0.0))
			var _re0 : Vector2 = _ps.to_global(Vector2( _ps.shape.size.x * 0.5, 0.0))
			_plat_left_x       = _le0.x
			_plat_right_x      = _re0.x
			_plat_bounds_valid = true

	_build_anim(anim_frames)
	# NOTE: _special_setup() MUST run BEFORE _start_y is computed below — it's
	# what sets _platform_gap_override / _platform_gap_override_active (the
	# per-enemy-type _gap_fix dict in Enemy.gd). Running it first means
	# _platform_gap() already returns the overridden value the first time
	# _start_y is calculated, instead of silently falling back to the
	# generic PLATFORM_STAND_GAP (the bug that made _gap_fix edits do nothing).
	_special_setup()

	if is_instance_valid(_platform):
		var ps := _platform.get_node_or_null("CollisionShape2D")
		if ps and ps.shape:
			_start_y = _platform.global_position.y - ps.shape.size.y * 0.5 - _platform_gap()
		else:
			_start_y = global_position.y
	else:
		_start_y = global_position.y

	# Ensure player reference is set during setup
	_cache_player_reference()
	_setup_done = true


func _base_hp_for(etype: int) -> int:
	return 1


func _build_anim(anim_frames: Dictionary) -> void:
	if _is_headless: return
	if not is_instance_valid(_anim): return
	var anim_fps := _anim_fps_for(enemy_type)
	var sf := SpriteFrames.new()
	for anim_name in anim_frames:
		sf.add_animation(anim_name)
		sf.set_animation_loop(anim_name, true)
		sf.set_animation_speed(anim_name, anim_fps)
		for tex in anim_frames[anim_name]:
			sf.add_frame(anim_name, tex)
	_anim.sprite_frames = sf
	# Play ilk animasyonu hemen başlat
	if anim_frames.size() > 0:
		_anim.play(anim_frames.keys()[0])

	if anim_frames.size() > 0:
		var first_key : String = anim_frames.keys()[0]
		var tex = sf.get_frame_texture(first_key, 0)
		if tex and tex.get_width() > 0:
			var mx := maxf(float(tex.get_width()), float(tex.get_height()))
			_anim.scale = Vector2(target_anim_size / mx, target_anim_size / mx)


func _anim_fps_for(_etype: int) -> float:
	return 8.0


# ── Sanal metodlar ───────────────────────────────────────────────────────────────────────────────
func _special_setup() -> void:
	pass

func _special_process(_delta: float) -> void:
	pass

func _special_hit(_body: Node, _stomped: bool, _powered: bool) -> bool:
	return false


# ── Physics loop ─────────────────────────────────────────────────────────────────────────────────────
# IMPORTANT: enemies are driven exclusively by GameManager via simulate_tick()
# (just like the player, whose _physics_process is also a no-op). The previous
# version ran a SECOND clamp here every Godot physics frame, which fought with
# the AI/clamp inside simulate_tick() at different timings (especially at 2x/4x
# replay speed) — that double-write caused the jitter, edge-sliding and the
# "lurch toward the player" behaviour. All movement and clamping now lives in
# simulate_tick() so there is a single source of truth for position.
func _physics_process(_delta: float) -> void:
	pass

func simulate_tick() -> void:
	const delta := 1.0 / 60.0
	if not _setup_done: return
	if _stun_timer > 0:
		_stun_timer -= delta
		return
	_state_timer -= delta
	_snap_to_platform()
	# AI runs BEFORE patrol so that, on the frame a chase starts/ends, the AI can
	# stop/redirect the patrol first. Otherwise _tick_patrol would write the patrol
	# position and the chase would overwrite it in the same frame — a visible jump.
	_special_process(delta)
	_tick_patrol(delta)
	_tick_bob(delta)
	_tick_move()
	# Hard clamp — ground enemies must never leave their platform. Uses the live
	# platform bounds when valid and falls back to cached/viewport bounds when the
	# platform ref is stale, so a freed platform can never let an enemy slide off.
	# _xclamp_disabled: mid-transit movers (e.g. spider web climb) set this so this
	# clamp doesn't yank them back toward the OLD platform's bounds every tick while
	# they're lerping toward a new one — without this check that yank looked like
	# a teleport at the start/end of the climb.
	if not can_fly and not _xclamp_disabled:
		global_position.x = _clamp_x_to_platform(global_position.x, 1.0)
	# DETERMINISM FIX: snap enemy position to the same fixed grid Player.gd uses
	# (see GameConstants.gd / Player.gd:739-742). _tick_patrol/_tick_bob/_special_process
	# (move_toward + sin/cos) accumulate raw floats every tick; sin/cos/libm can round
	# differently between client (WASM) and headless server (native), and that drift
	# compounds over thousands of ticks. Player position was already snapped, but enemy
	# position was not — so the two sides could reach a hair-different distance right at
	# the _tick_player_overlap() threshold and disagree about a stomp/hit, causing
	# server-replay to diverge (die earlier/later) from the client even with identical
	# input + identical seed. Snapping BEFORE the overlap check, not after, ensures both
	# sides evaluate the same threshold test against the same quantized position.
	global_position.x = snappedf(global_position.x, 0.01)
	global_position.y = snappedf(global_position.y, 0.01)
	_tick_player_overlap()
	if DEBUG_DRAW_BOUNDS:
		queue_redraw()   # refresh the on-screen bounds overlay every tick


func _tick_patrol(delta: float) -> void:
	if not _patrol_active:
		_patrol_controls_flip = false
		return
	if _patrol_period <= 0.0: return
	_patrol_timer += delta
	while _patrol_timer >= _patrol_period:
		_patrol_timer -= _patrol_period
	var phase  := (_patrol_timer / _patrol_period) * TAU
	var mid_x  := (_patrol_left_x + _patrol_right_x) * 0.5
	var half   := (_patrol_right_x - _patrol_left_x) * 0.5
	var new_x  := mid_x + cos(phase) * half
	if not _is_headless and is_instance_valid(_anim):
		var s := sin(phase)
		# 24=ALIEN_GREEN 25=ALIEN_BLUE 26=ALIEN_PINK 27=ALIEN_YELLOW
		var alien_types_set : bool = enemy_type >= 24 and enemy_type <= 27
		if s > 0.0001:
			_patrol_controls_flip = true
			_anim.flip_h = true if alien_types_set else false
		elif s < -0.0001:
			_patrol_controls_flip = true
			_anim.flip_h = false if alien_types_set else true
	global_position.x = new_x


func _tick_bob(delta: float) -> void:
	if not _bob_active: return
	if _bob_period <= 0.0: return
	_bob_timer += delta
	while _bob_timer >= _bob_period:
		_bob_timer -= _bob_period
	var phase := (_bob_timer / _bob_period) * TAU
	global_position.y = _start_y + sin(phase) * _bob_amplitude


func _snap_to_platform() -> void:
	if can_fly: return
	if _snap_disabled: return
	# EN-SP: When not dirty, skip platform validity check entirely — just apply cached Y.
	# _snap_dirty is set to true whenever the platform reference changes (setup, frog jump, etc.)
	if _snap_dirty:
		if not is_instance_valid(_platform): return
		var plat_shape := _platform.get_node_or_null("CollisionShape2D")
		if plat_shape and plat_shape.shape:
			_snap_target_y = _platform.global_position.y - plat_shape.shape.size.y * 0.5 - _platform_gap()
		else:
			_snap_target_y = global_position.y
		_snap_dirty = false
	global_position.y = _snap_target_y


func _tick_player_overlap() -> void:
	# EN-PO: _get_player() already returns only the player node — no need for is_in_group check.
	# Use dist_sq to avoid sqrt; cache _overlap_v_offset avoids Vector2 alloc per tick.
	var p := _get_player()
	if not p: return
	var dx : float = (p.global_position.x) - global_position.x
	var dy : float = (p.global_position.y + _overlap_v_offset.y) - global_position.y
	var dist_sq   : float = dx * dx + dy * dy
	var threshold : float = _vw * 0.043
	if dist_sq <= threshold * threshold:
		if not _overlap_triggered:
			_overlap_triggered = true
			_on_body_entered(p)
	else:
		_overlap_triggered = false


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"): return
	# Uçarken sadece uçan yaratıklar hasar verebilir
	var player_flying : bool = body.get("is_powered_up") and \
		(body.get("_powerup_is_jetpack") or body.get("_powerup_is_wings"))
	if player_flying and not can_fly: return
	var rel_y   : float = body.global_position.y - global_position.y
	var from_above : bool = rel_y < _vh * 0.01
	var stomped : bool = from_above and body.is_stomping()
	var powered : bool  = body.is_powered_up
	if _special_hit(body, stomped, powered): return
	if stomped:
		body.velocity.y = -_vh * 0.5
		_die()
	elif not powered:
		body.hit_enemy()


# ── General tick-based movement engine ────────────────────────────────────────────────────────────────────────────────
func _move_to(target: Vector2, secs: float, ein: bool = false, eout: bool = false,
		bnc: bool = false, cb: Callable = Callable()) -> void:
	var ticks := maxi(1, int(round(secs * 60.0)))
	# If queue has segments, from_pos = last segment's to_pos (chaining fix)
	# If queue is empty, from_pos = current global_position
	var from : Vector2 = (_move_segments.back() as MoveSegment).to_pos \
		if not _move_segments.is_empty() else global_position
	var seg := MoveSegment.new(from, target, 0, ticks, ein, eout, bnc, cb)
	_move_segments.append(seg)
	_move_active = true


func _move_to_y(target_y: float, secs: float, ein: bool = false, eout: bool = false,
		bnc: bool = false, cb: Callable = Callable()) -> void:
	var from : Vector2 = (_move_segments.back() as MoveSegment).to_pos \
		if not _move_segments.is_empty() else global_position
	var target := Vector2(from.x, target_y)
	var ticks := maxi(1, int(round(secs * 60.0)))
	var seg := MoveSegment.new(from, target, 2, ticks, ein, eout, bnc, cb)
	_move_segments.append(seg)
	_move_active = true


func _move_wait(secs: float, cb: Callable = Callable()) -> void:
	var ticks := maxi(1, int(round(secs * 60.0)))
	var seg := MoveSegment.new(global_position, global_position, 0, ticks, false, false, false, cb)
	_move_segments.append(seg)
	_move_active = true


func _move_cancel() -> void:
	_move_segments.clear()
	_move_active = false


func _tick_move() -> void:
	if not _move_active or _move_segments.is_empty(): return
	var seg : MoveSegment = _move_segments[0] as MoveSegment
	seg.elapsed += 1
	var t := float(seg.elapsed) / float(seg.total)
	t = clampf(t, 0.0, 1.0)
	var t_ease := _ease_t(t, seg.ease_in, seg.ease_out, seg.bounce)
	match seg.axis:
		0:
			global_position = seg.from_pos.lerp(seg.to_pos, t_ease)
		1:
			position.x = lerpf(seg.from_pos.x, seg.to_pos.x, t_ease)
		2:
			global_position.y = lerpf(seg.from_pos.y, seg.to_pos.y, t_ease)
	if seg.elapsed >= seg.total:
		_move_segments.remove_at(0)
		if _move_segments.is_empty():
			_move_active = false
		if seg.callback.is_valid():
			seg.callback.call()


func _ease_t(t: float, ein: bool, eout: bool, bounce: bool) -> float:
	if bounce:
		if t < 0.75:
			var s := t / 0.75
			return 1.0 - (1.0 - s) * (1.0 - s) * 0.55
		elif t < 0.9:
			var s := (t - 0.75) / 0.15
			return 0.9775 + s * 0.04
		else:
			var s := (t - 0.9) / 0.1
			return 1.0175 - s * 0.0175
	if ein and eout:
		return (1.0 - cos(t * PI)) * 0.5
	if ein:
		return t * t
	if eout:
		return 1.0 - (1.0 - t) * (1.0 - t)
	return t


func _start_patrol(speed_mult: float = 1.0, resume: bool = false) -> void:
	_start_patrol_from(global_position.x, speed_mult, resume)

# Patrol centered on `center_x` — use this after burst/chase to avoid teleporting back to spawn.
func _start_patrol_from(center_x: float, speed_mult: float = 1.0, resume: bool = false) -> void:
	var diff_mult := 1.0 + difficulty * 0.8
	var t := maxf(0.15, PATROL_TIME / (speed_mult * diff_mult))
	var right_x : float
	var left_x  : float
	if not can_fly and is_instance_valid(_platform):
		var plat_shape := _platform.get_node_or_null("CollisionShape2D")
		if plat_shape and plat_shape.shape:
			# Use to_global for correct world-space bounds regardless of parent scale
			var _le : Vector2 = plat_shape.to_global(Vector2(-plat_shape.shape.size.x * 0.5, 0.0))
			var _re : Vector2 = plat_shape.to_global(Vector2( plat_shape.shape.size.x * 0.5, 0.0))
			# 24=ALIEN_GREEN 25=ALIEN_BLUE 26=ALIEN_PINK 27=ALIEN_YELLOW
			var is_big_alien := enemy_type >= 24 and enemy_type <= 27
			var margin : float = (_re.x - _le.x) * (0.22 if is_big_alien else 0.06)
			right_x = minf(center_x + PATROL_RANGE, _re.x - margin)
			left_x  = maxf(center_x - PATROL_RANGE, _le.x + margin)
			_plat_left_x       = _le.x
			_plat_right_x      = _re.x
			_plat_bounds_valid = true
		else:
			right_x = minf(center_x + PATROL_RANGE, _vw * 0.95)
			left_x  = maxf(center_x - PATROL_RANGE, _vw * 0.05)
	else:
		# Flying enemies aren't bound to a platform, so give them a wider, clearly
		# horizontal patrol sweep (kept inside the screen) instead of the narrow
		# ground patrol range — otherwise they look like they only bob up/down.
		var fly_range : float = _vw * 0.28
		right_x = minf(center_x + fly_range, _vw * 0.92)
		left_x  = maxf(center_x - fly_range, _vw * 0.08)
		# If clamping collapsed the span (enemy spawned near a screen edge), recenter.
		if right_x - left_x < _vw * 0.12:
			left_x  = _vw * 0.08
			right_x = _vw * 0.92
	_patrol_left_x  = left_x
	_patrol_right_x = right_x
	_patrol_period  = t * 2.0
	if resume and right_x > left_x:
		# Resume the patrol phase from the enemy's CURRENT x so it doesn't jump.
		# _tick_patrol drives x = mid + cos(phase)*half, so we invert that. The
		# enemy's x is first snapped into the patrol span (it may have walked to
		# the very edge while chasing), then matched to the nearest phase — this
		# avoids the little backwards "teleport" when a chase ends.
		var mid_x := (left_x + right_x) * 0.5
		var half  := (right_x - left_x) * 0.5
		var cur_x := clampf(global_position.x, left_x, right_x)
		var cos_val := clampf((cur_x - mid_x) / half, -1.0, 1.0)
		_patrol_timer = acos(cos_val) / TAU * _patrol_period
		# Snap the enemy exactly onto the patrol path for THIS phase, so the first
		# tick after resuming produces no positional jump at all.
		var phase := (_patrol_timer / _patrol_period) * TAU
		global_position.x = mid_x + cos(phase) * half
	else:
		# Random phase offset — her düşman farklı noktadan başlasın
		_patrol_timer = _rng.randf() * _patrol_period
	_patrol_active  = true


func _stop_patrol() -> void:
	_patrol_active = false
	_patrol_controls_flip = false


func _start_vertical_bob(amplitude: float = 12.0, period: float = 1.6) -> void:
	_bob_amplitude = amplitude
	_bob_period    = period
	_bob_timer     = 0.0
	_bob_active    = true


func _stop_vertical_bob() -> void:
	_bob_active = false


# ── Animation helpers ────────────────────────────────────────────────────────────────────────────────
func _anim_play(anim_name: String) -> void:
	if not is_instance_valid(_anim): return
	if _anim.animation == anim_name and _anim.is_playing(): return
	_anim.play(anim_name)


func _anim_flip(dir_x: float) -> void:
	if _patrol_controls_flip: return
	if is_instance_valid(_anim): _anim.flip_h = dir_x > 0


# ── Tween helper ────────────────────────────────────────────────────────────────────────────────────
func _make_tween() -> Tween:
	# During seek_to_tick the GM sets _is_seeking=true — suppress all cosmetic tweens
	# so they don't fire in bulk after the silent simulation loop ends.
	if is_instance_valid(_gm_ref) and _gm_ref.get("_is_seeking"):
		return null
	var tw := create_tween()
	if tw:
		tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_active_tweens.append(tw)
		tw.finished.connect(func(): _active_tweens.erase(tw))
	return tw


# Called by GameManager after seek_to_tick — kills all pending tweens,
# cancels in-flight _move_to segments, and snaps enemy to correct position.
func seek_reset() -> void:
	# Kill every tracked tween
	for tw in _active_tweens:
		if tw and tw.is_valid():
			tw.kill()
	_active_tweens.clear()
	if _tween and _tween.is_valid():
		_tween.kill()
	# Cancel any in-flight _move_to chain — segments may have stale from_pos
	_move_cancel()
	# Force snap cache refresh so _snap_to_platform() recalculates correctly
	_snap_dirty = true
	# Re-snap immediately so the enemy is visually in the right place
	_snap_to_platform()
	# Resume patrol from current X so there's no positional jump
	if _patrol_active:
		_start_patrol(1.0, true)  # resume=true preserves current x phase
	# Restore idle animation — _die() plays "hurt" which may persist after seek reset
	if is_instance_valid(_anim) and _anim.sprite_frames:
		var sf := _anim.sprite_frames
		for anim_name in ["fly", "walk", "idle", "float"]:
			if sf.has_animation(anim_name):
				_anim.play(anim_name)
				break


func _start_spin(speed: float = 1.0) -> void:
	if _is_headless: return
	var spin := _make_tween()
	if not spin: return
	spin.set_loops()
	var duration := maxf(0.05, 0.3 / speed)
	spin.tween_property(_anim, "rotation_degrees", 360.0, duration).set_trans(Tween.TRANS_LINEAR)
	spin.tween_callback(func():
			if is_instance_valid(_anim): _anim.rotation_degrees = 0.0)


## Virtual hook — called right before this enemy is removed from play,
## whether by being stomped (_die) or by its platform breaking out from
## under it (_fall_off_platform). Subclasses (Enemy.gd) override this to
## clean up any extra scene-tree nodes they spawned as siblings (not
## children) of themselves — e.g. the spider's web Line2D — which would
## otherwise be orphaned forever since these two generic removal paths
## have no idea such nodes exist.
func _on_removed() -> void:
	pass

func _fall_off_platform() -> void:
	if can_fly: return
	if not _setup_done: return
	_on_removed()
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_setup_done = false
	if _tween and _tween.is_valid(): _tween.kill()
	if _is_headless:
		queue_free()
		return
	var tw := _make_tween()
	if tw:
		tw.tween_property(self, "position:y", position.y + _vh * 0.375, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(self, "modulate:a", 0.0, 0.4)
		var _self_ref := self
		tw.tween_callback(func():
			if is_instance_valid(_self_ref): _self_ref.queue_free())
	else:
		queue_free()

func _die() -> void:
	_on_removed()
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_setup_done = false
	if _tween and _tween.is_valid(): _tween.kill()
	var gm : Node = _gm_ref if is_instance_valid(_gm_ref) else get_parent()
	if is_instance_valid(gm) and gm.has_method("on_enemy_killed"):
		gm.call("on_enemy_killed", enemy_type)
	if _is_headless:
		if is_instance_valid(gm) and gm.has_method("_crash_debug_line"):
			gm.call("_crash_debug_line", "[DIE] tick=%s type=%s(%d) id=%d pos=(%.1f,%.1f)" % [
				gm.get("_replay_tick_count"),
				(Enemy.EnemyType.keys()[enemy_type] if enemy_type >= 0 and enemy_type < Enemy.EnemyType.size() else "?"),
				enemy_type, get_instance_id(), global_position.x, global_position.y
			])
		# [CRASH FIX] queue_free() defers via call_deferred, which never flushes
		# mid-replay since the whole synchronous tick loop never returns control
		# to the engine between ticks. Use immediate free() here too, same as
		# _discard_node() does elsewhere in GameManager — keeps behavior consistent
		# and guarantees this node (and its slot in _enemies) is actually gone
		# instead of lingering as a "zombie" node for the rest of the sim.
		if is_instance_valid(gm) and gm.has_method("_discard_node"):
			gm.call("_discard_node", self)
		else:
			queue_free()
		return
	if is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("hurt"):
			_anim.play("hurt")
		elif _anim.sprite_frames.has_animation("dead"):
			_anim.play("dead")
	if gm and gm.has_method("apply_camera_shake"):
		gm.apply_camera_shake(5.0, 0.22)
	var tw := _make_tween()
	if tw:
		tw.tween_property(self, "scale", Vector2(1.4, 1.4), 0.15).set_trans(Tween.TRANS_BACK)
		tw.tween_property(self, "modulate:a", 0.0, 0.25)
		var _self_ref := self
		tw.tween_callback(func():
			if is_instance_valid(_self_ref): _self_ref.queue_free())
	else:
		queue_free()

func _get_player() -> Node:
	if is_instance_valid(_player_ref):
		return _player_ref
	# Throttle: only retry get_nodes_in_group once per 60 ticks to avoid SceneTree scan every tick
	_player_cache_miss += 1
	if _player_cache_miss >= 60:
		_player_cache_miss = 0
		_cache_player_reference()
	return _player_ref


# Internal: safely fetches the reference once
func _cache_player_reference() -> void:
	# [CRASH FIX] In headless replay mode, _player_ref is always set directly
	# by GameManager._add_enemy() at spawn time. If it ever goes invalid here,
	# falling back to get_tree().get_nodes_in_group() is exactly the SceneTree
	# access pattern already identified as a 0xc0000005 crash source elsewhere
	# in this codebase (see the "direct player reference" fix in GameManager).
	# Skip the fallback entirely in headless mode — it's not needed there.
	if _is_headless:
		return
	var tree := get_tree()
	if not tree: return
	var players := tree.get_nodes_in_group("player")
	if players.size() > 0:
		_player_ref = players[0]


func _rng_range(a: float, b: float) -> float:
	return _rng.randf_range(a, b)



# Helper to stay within platform X bounds — margin optional (default: at edge)
# Always tries to build/refresh the cache if not valid, so ground enemies
# never escape the platform even if setup ran before the shape was ready.
func _clamp_x_to_platform(x: float, margin: float = 0.0) -> float:
	# Always read live from platform — use global_transform to account for node scale
	if is_instance_valid(_platform):
		var ps := _platform.get_node_or_null("CollisionShape2D")
		if ps and ps.shape:
			var _lec2 : Vector2 = ps.to_global(Vector2(-ps.shape.size.x * 0.5, 0.0))
			var _rec2 : Vector2 = ps.to_global(Vector2( ps.shape.size.x * 0.5, 0.0))
			_plat_left_x       = _lec2.x
			_plat_right_x      = _rec2.x
			_plat_bounds_valid = true
			return clampf(x, _lec2.x + margin, _rec2.x - margin)
	# Platform ref is stale — use last-known cached bounds if we have them,
	# otherwise fall back to the viewport so the enemy still can't run away.
	if _plat_bounds_valid and _plat_right_x > _plat_left_x:
		return clampf(x, _plat_left_x + margin, _plat_right_x - margin)
	return clampf(x, _vw * 0.04 + margin, _vw * 0.96 - margin)


# Returns the enemy's current platform edges as world-space x [left, right].
# Always valid: reads the live platform when possible, otherwise the cached
# bounds, otherwise the enemy's current position. Refreshes the cache too.
func _get_plat_bounds() -> Vector2:
	if is_instance_valid(_platform):
		var bounds := _bounds_of_platform(_platform)
		if bounds != Vector2.ZERO:
			_plat_left_x       = bounds.x
			_plat_right_x      = bounds.y
			_plat_bounds_valid = true
			return bounds
	if _plat_bounds_valid and _plat_right_x > _plat_left_x:
		return Vector2(_plat_left_x, _plat_right_x)
	return Vector2(global_position.x, global_position.x)


# World-space [left_x, right_x] of a platform's collision rectangle. Uses the
# rectangle's WORLD width (size * global_scale) centred on the shape's WORLD
# position — so it always returns the platform's own narrow span, never a wider
# region, regardless of node scale or child offset. Returns ZERO if unavailable.
func _bounds_of_platform(plat: Node) -> Vector2:
	if not is_instance_valid(plat): return Vector2.ZERO
	var cs := _find_collision_shape(plat)
	if not cs or not cs.shape or not (cs.shape is RectangleShape2D):
		return Vector2.ZERO
	var rect := cs.shape as RectangleShape2D
	var center_x : float = cs.global_position.x          # true world centre
	var half_w   : float = rect.size.x * 0.5 * absf(cs.global_scale.x)
	return Vector2(center_x - half_w, center_x + half_w)


# Finds a platform's CollisionShape2D by TYPE, not by node name. The platform
# creates its shape with .new() and never renames it, so get_node_or_null(
# "CollisionShape2D") can miss it — searching children by type always works.
func _find_collision_shape(n: Node) -> CollisionShape2D:
	if not is_instance_valid(n): return null
	for child in n.get_children():
		if child is CollisionShape2D:
			return child as CollisionShape2D
	return null


# ── DEBUG draw — shows the live bounds the AI is actually using ───────
func _draw() -> void:
	if not DEBUG_DRAW_BOUNDS: return
	if _is_headless: return
	var h : float = _vh * 0.05
	var gm : Node = _gm_ref if is_instance_valid(_gm_ref) else get_parent()
	if is_instance_valid(gm):
		var plats = gm.get("_platforms")
		if plats:
			for pl in plats:
				if not is_instance_valid(pl): continue
				var pcs := _find_collision_shape(pl)
				if pcs and pcs.shape and pcs.shape is RectangleShape2D:
					var psz : Vector2 = (pcs.shape as RectangleShape2D).size
					var pc  : Vector2 = pcs.global_position
					var ptl : Vector2 = to_local(pc - psz * 0.5)
					draw_rect(Rect2(ptl, psz), Color(1, 0.55, 0, 0.7), false, 2.0)
	if is_instance_valid(_platform):
		var ps := _find_collision_shape(_platform)
		if ps and ps.shape and ps.shape is RectangleShape2D:
			var sz : Vector2 = (ps.shape as RectangleShape2D).size
			var c  : Vector2 = ps.global_position
			var tl : Vector2 = to_local(c - sz * 0.5)
			draw_rect(Rect2(tl, sz), Color(1, 1, 0, 1.0), false, 4.0)
	var b : Vector2 = _get_plat_bounds()
	var lx : float = to_local(Vector2(b.x, global_position.y)).x
	var rx : float = to_local(Vector2(b.y, global_position.y)).x
	draw_line(Vector2(lx, -h), Vector2(lx, h), Color(0, 1, 1, 0.9), 3.0)
	draw_line(Vector2(rx, -h), Vector2(rx, h), Color(0, 1, 1, 0.9), 3.0)
	var m : float = _vw * 0.04
	var glx : float = to_local(Vector2(b.x + m, global_position.y)).x
	var grx : float = to_local(Vector2(b.y - m, global_position.y)).x
	draw_line(Vector2(glx, -h * 0.6), Vector2(glx, h * 0.6), Color(0, 1, 0, 0.9), 3.0)
	draw_line(Vector2(grx, -h * 0.6), Vector2(grx, h * 0.6), Color(0, 1, 0, 0.9), 3.0)
	draw_circle(Vector2.ZERO, 4.0, Color(1, 0, 0, 1))
	# MAGENTA circle = the real player-overlap hitbox (radius _vw*0.043), drawn at
	# the enemy's own origin. If this circle tracks the enemy horizontally, the
	# hitbox follows correctly; if it lags, the collision uses a stale position.
	draw_arc(Vector2.ZERO, _vw * 0.043, 0.0, TAU, 24, Color(1, 0, 1, 0.9), 2.0)
	# ── DIAGNOSTIC TEXT — tells us WHY bounds may be wrong ───────────────
	var font := ThemeDB.fallback_font
	if font:
		var plat_ok := is_instance_valid(_platform)
		var cs : CollisionShape2D = _find_collision_shape(_platform) if plat_ok else null
		var width : float = b.y - b.x   # how wide the bounds came out
		var info := "%s w=%.0f" % [("P" if plat_ok else "NULL"), width]
		# black outline for readability, then white text — big size
		for off in [Vector2(-1,-1), Vector2(1,-1), Vector2(-1,1), Vector2(1,1)]:
			draw_string(font, Vector2(-30, -h - 10) + off, info, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.BLACK)
		draw_string(font, Vector2(-30, -h - 10), info, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 0, 1))


func _show_effect(duration: float, is_sun: bool = false) -> void:
	if _is_headless: return
	if not is_instance_valid(_effect_spr) or not _effect_spr.texture: return
	_effect_spr.visible    = true
	_effect_spr.modulate.a = 1.0
	_effect_spr.position   = Vector2(0, -_vh * 0.0375)
	_effect_spr.scale      = Vector2(0.4, 0.4)
	if is_sun:
		_effect_spr.modulate = Color(1.5, 1.0, 0.3)
	else:
		_effect_spr.modulate = Color.WHITE
	var tw := _make_tween()
	if tw:
		tw.tween_property(_effect_spr, "scale",      Vector2(0.0, 0.0), duration * 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tw.tween_callback(func():
			if is_instance_valid(_effect_spr): _effect_spr.visible = false)
