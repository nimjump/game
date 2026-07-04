extends StaticBody2D
class_name Platform

# ═══════════════════════════════════════════════════════ #
#  Platform.gd — Break stages
#  NORMAL: cracks slowly under prolonged pressure → breaks
#  BROKEN: first contact = instant break
# ═══════════════════════════════════════════════════════

signal platform_broke

enum PlatformType { NORMAL, BROKEN, CRUMBLE }

const BREAK_TIME   := 0.45
var MAX_JUMPS      := 6   # decreases with difficulty (range 3-6)

var platform_type  : PlatformType = PlatformType.NORMAL
var _sprite        : Sprite2D
var _col_shape     : CollisionShape2D
var _break_tex     : Texture2D
var _normal_tex    : Texture2D

# Break state
var _breaking      := false
var _break_timer   := 0.0
var _crack_level   := 0     # 0=intact 1=light 2=medium 3=critical
var _jump_count    := 0     # number of times jumped on

# Crumble state (CRUMBLE type — falls after 2 steps)
var _crumble_count   := 0    # 0=pristine, 1=shaking, 2=falling
var _crumble_shaking := false
var _crumble_shake_t := 0.0
const CRUMBLE_SHAKE_TIME := 0.55  # seconds of shake before fall

var game_manager     : Node
var _rng             : RandomNumberGenerator = RandomNumberGenerator.new()  # independent — visual effects only
var _vw : float = GameConstants.VW
var _vh : float = GameConstants.VH


func _ready() -> void:
	# Match GameManager's fixed virtual world — same space Player/Enemy
	# use, so shake/crumble animation amplitude stays consistent across screens.
	# Single source of truth: GameConstants.
	_vw = GameConstants.VW
	_vh = GameConstants.VH
	collision_layer = 2
	collision_mask  = 0


func setup(ptype: PlatformType, texture: Texture2D, plat_size: Vector2, broken_tex: Texture2D = null, diff: float = 0.0) -> void:
	platform_type = ptype
	_normal_tex   = texture
	_break_tex    = broken_tex
	# Breaks with fewer jumps as difficulty increases: 6 → 3
	MAX_JUMPS = max(3, int(6 - diff * 3))

	var rect := RectangleShape2D.new()
	rect.size = plat_size
	_col_shape = CollisionShape2D.new()
	_col_shape.shape = rect
	# THE BUG: add_child()'s default force_readable_name is false, so without
	# an explicit name Godot assigns an internal placeholder like
	# "@CollisionShape2D@3" instead of the plain "CollisionShape2D". Every
	# enemy platform-gap lookup does get_node_or_null("CollisionShape2D") by
	# that exact string — with the placeholder name, EVERY one of those
	# lookups silently returns null, so the enemy falls back to "just keep
	# whatever Y it already happened to be at" instead of ever snapping to
	# the platform's real surface. This is why PLATFORM_GAP_FIX values (and
	# any other platform-relative Y calc) had ZERO effect for ground enemies
	# no matter what they were set to — the code that reads them never ran.
	_col_shape.name = "CollisionShape2D"
	add_child(_col_shape)

	# Visual setup — skip entirely in headless
	if DisplayServer.get_name() == "headless": return

	_sprite = Sprite2D.new()
	_sprite.texture = texture
	if texture and texture.get_width() > 0:
		_sprite.scale = Vector2(plat_size.x / texture.get_width(),
								plat_size.y / texture.get_height())
	add_child(_sprite)

	# BROKEN platform: appear slightly cracked from the start
	if ptype == PlatformType.BROKEN and broken_tex != null:
		_sprite.texture = broken_tex
		if broken_tex.get_width() > 0:
			_sprite.scale.x = plat_size.x / broken_tex.get_width()
		_sprite.modulate = Color(1.0, 0.85, 0.75)

	# CRUMBLE platform: orange tint + crack texture to signal danger
	if ptype == PlatformType.CRUMBLE:
		if broken_tex != null:
			_sprite.texture = broken_tex
			if broken_tex.get_width() > 0:
				_sprite.scale.x = plat_size.x / broken_tex.get_width()
		_sprite.modulate = Color(1.0, 0.75, 0.4)


func _physics_process(_delta: float) -> void:
	pass  # ticked by GM via simulate_tick() — Godot delta is not used


## GM calls this every tick — fixed delta, deterministic
func simulate_tick() -> bool:
	const delta := 1.0 / 60.0

	# Crumble shake countdown — before full fall
	if _crumble_shaking:
		_crumble_shake_t -= delta
		if not DisplayServer.get_name() == "headless" and is_instance_valid(_sprite):
			var intensity := clampf(_crumble_shake_t / CRUMBLE_SHAKE_TIME, 0.1, 1.0)
			_sprite.position.x = roundf(sin(_crumble_shake_t * 90.0) * (_vw * 0.010) * intensity)
			_sprite.modulate = Color(1.0, 0.4 + intensity * 0.35, 0.2 + intensity * 0.2)
		if _crumble_shake_t <= 0.0:
			_crumble_shaking = false
			_start_break()
		return false

	# Normal break fade
	if not _breaking: return false
	_break_timer -= delta
	if not DisplayServer.get_name() == "headless" and is_instance_valid(_sprite):
		_sprite.modulate.a = clampf(_break_timer / BREAK_TIME, 0.0, 1.0)
		_sprite.position.x = roundf(sin(_break_timer * 80.0) * (_vw * 0.008) * (_break_timer / BREAK_TIME))
	if _break_timer <= 0.0:
		return true  # remove
	return false


# Called on each jump
func on_player_landed() -> void:
	if _breaking: return
	# Quest counter
	if is_instance_valid(game_manager) and game_manager.has_method("on_platform_landed"):
		game_manager.call("on_platform_landed")

	if platform_type == PlatformType.BROKEN:
		_start_break()
		return

	if platform_type == PlatformType.CRUMBLE:
		_crumble_count += 1
		if _crumble_count == 1:
			# İlk adım — sallanmaya başla, collision hala var
			_crumble_shaking = true
			_crumble_shake_t = CRUMBLE_SHAKE_TIME
		elif _crumble_count >= 2 and not _crumble_shaking and not _breaking:
			# İkinci adım — anında düş
			_start_break()
		return

	# Accumulate damage each jump
	_jump_count += 1
	# Calculate stage: 0-1 → 0, 2 → 1, 3-4 → 2, 5+ → 3
	var new_level := 0
	if _jump_count >= 5:   new_level = 3
	elif _jump_count >= 3: new_level = 2
	elif _jump_count >= 2: new_level = 1

	if new_level != _crack_level:
		_crack_level = new_level
		if not DisplayServer.get_name() == "headless": _apply_crack_visual()

	if _jump_count >= MAX_JUMPS:
		_start_break()


func on_player_left() -> void:
	pass  # jump-based system — does not reset when player leaves


func _apply_crack_visual() -> void:
	if DisplayServer.get_name() == "headless": return
	if not is_instance_valid(_sprite): return
	match _crack_level:
		1:
			# Light vibration, slightly yellow
			_sprite.modulate = Color(1.0, 0.95, 0.8)
			var tw := create_tween()
			if tw:
				tw.tween_property(_sprite, "position:x", _vw * 0.003, 0.05)
				tw.tween_property(_sprite, "position:x", -_vw * 0.003, 0.05)
				tw.tween_property(_sprite, "position:x", 0.0, 0.05)
		2:
			# Switch to broken texture, orange
			if _break_tex:
				_sprite.texture = _break_tex
				if _break_tex.get_width() > 0 and _col_shape.shape:
					var sz : Vector2 = (_col_shape.shape as RectangleShape2D).size
					_sprite.scale.x = sz.x / _break_tex.get_width()
			_sprite.modulate = Color(1.0, 0.8, 0.6)
			# Medium vibration
			var tw := create_tween()
			if tw:
				tw.set_loops(3)
				tw.tween_property(_sprite, "position:x", _vw * 0.005, 0.04)
				tw.tween_property(_sprite, "position:x", -_vw * 0.005, 0.04)
				tw.tween_property(_sprite, "position:x", 0.0, 0.04)
			# Reset position after tween ends
			var reset_tw := create_tween()
			if reset_tw:
				reset_tw.tween_interval(3 * 0.04 * 3)
				reset_tw.tween_callback(func():
					if is_instance_valid(_sprite): _sprite.position.x = 0.0
				)
		3:
			# Critical — red, strong vibration
			_sprite.modulate = Color(1.0, 0.5, 0.4)
			var tw := create_tween()
			if tw:
				tw.set_loops(5)
				tw.tween_property(_sprite, "position:x", _vw * 0.008, 0.03)
				tw.tween_property(_sprite, "position:x", -_vw * 0.008, 0.03)
				tw.tween_property(_sprite, "position:x", 0.0, 0.03)
			var reset_tw := create_tween()
			if reset_tw:
				reset_tw.tween_interval(5 * 0.03 * 3)
				reset_tw.tween_callback(func():
					if is_instance_valid(_sprite): _sprite.position.x = 0.0
				)


func connect_enemy(enemy: Node) -> void:
	# Give the enemy a reference to this platform — needed for patrol boundary calculation
	# Use set() — safely assigns inherited properties too
	enemy.set("_platform", self)
	# BUG FIX: platform_broke can fire long after this enemy was spawned — the
	# platform lives until it scrolls off-screen or breaks, but the enemy can
	# be freed much earlier by an unrelated path (player stomp, projectile
	# damage, off-screen despawn). Capturing `enemy` (a Node) directly in this
	# lambda made Godot's engine log
	#   "ERROR: Lambda capture at index 0 was freed. Passed 'null' instead."
	# EVERY time platform_broke fired after the enemy was already gone — even
	# though the is_instance_valid() guard below already made this perfectly
	# safe at runtime. The engine logs that ERROR unconditionally whenever any
	# captured Object was freed before the lambda runs, regardless of what the
	# body does with it afterward — it's not a crash, just log noise, but it's
	# real production noise on every ordinary "stomp enemy, platform breaks
	# later" sequence, which is extremely common live gameplay.
	# Fix: capture the enemy's instance ID (a plain int, not an Object
	# reference) instead — Godot's lambda-capture-freed check only triggers
	# for captured Objects, not ints. Resolve back to the object at call time
	# via instance_from_id() + is_instance_valid(), which safely returns null
	# for an already-freed enemy with no ERROR logged at all.
	var enemy_id := enemy.get_instance_id()
	platform_broke.connect(func():
		var e := instance_from_id(enemy_id)
		if is_instance_valid(e):
			if e.has_method("_fall_off_platform"):
				e.call("_fall_off_platform")
			elif e.has_method("_die"):
				e.call("_die")
	)


func _start_break() -> void:
	if _breaking: return
	_breaking    = true
	_break_timer = BREAK_TIME
	collision_layer = 0
	emit_signal("platform_broke")
	_spawn_debris()


func _spawn_debris() -> void:
	if DisplayServer.get_name() == "headless": return
	if _rng == null:
		push_error("[Platform] _spawn_debris: _rng is null — debris atlandı, replay görselini bozardı")
		return
	# Choose rock color based on ground type
	var rock_textures : Array[String] = [
		"res://assets/particles/particle_brown.png",
		"res://assets/particles/particle_grey.png",
		"res://assets/particles/particle_darkBrown.png",
		"res://assets/particles/particle_darkGrey.png",
		"res://assets/particles/particle_beige.png",
		"res://assets/particles/smoke.png",
	]

	var rng_count := _rng.randi_range(5, 8)
	for i in rng_count:
		var tex_path : String = rock_textures[_rng.randi() % rock_textures.size()]
		if not ResourceLoader.exists(tex_path): continue
		var p := Sprite2D.new()
		p.texture = load(tex_path)
		var sc := _rng.randf_range(0.18, 0.45)
		p.scale   = Vector2(sc, sc)
		p.z_index = 5
		get_parent().add_child(p)
		p.global_position = global_position + Vector2(
			_rng.randf_range(-_vw * 0.075, _vw * 0.075),
			-_vh * 0.00625)

		var angle := _rng.randf_range(-PI * 0.95, -PI * 0.05)
		var speed := _rng.randf_range(_vw * 0.133, _vw * 0.333)
		var vel   := Vector2(cos(angle), sin(angle)) * speed
		var dur   := _rng.randf_range(0.3, 0.55)
		var tw    := p.create_tween()
		if tw:
			tw.tween_property(p, "position", p.position + vel * dur, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(p, "rotation_degrees",
				_rng.randf_range(-270.0, 270.0), dur)
			tw.parallel().tween_property(p, "modulate:a", 0.0, dur * 0.85)
			tw.tween_callback(func(): if is_instance_valid(p): p.queue_free())
