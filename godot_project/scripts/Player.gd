extends CharacterBody2D

const SCREEN_W := 600.0

var GRAVITY      := 1800.0
var JUMP_SPEED   := -950.0
var SPRING_SPEED := -1650.0
var MOVE_SPEED   := 285.0
var JETPACK_LIFT := -420.0

const CHAR_STATS := [
	{ "gravity": 1700.0, "jump": -920.0,  "spring": -1600.0, "move": 320.0, "jetpack": -400.0 },
	{ "gravity": 1900.0, "jump": -1050.0, "spring": -1800.0, "move": 250.0, "jetpack": -460.0 },
]

var is_dead        := false
var _initialized   := false
var has_shield     := false
var is_powered_up  := false
var powerup_timer  := 0.0
var powerup_type   := ""
var lives          := 3
const MAX_LIVES    := 3

# ── GOD MODE DEĞİŞKENLERİ ────────────────────────────────
var is_god_mode    := false
const GOD_MOVE_SPEED := 350.0    # Sabit yüksek yatay hız
const GOD_JETPACK_LIFT := -1200.0 # Bayağı hızlı dikey roket gücü!

signal died
signal collected_item(type: String)
signal lives_changed(new_lives: int)

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

var _was_on_floor     := false
var _prev_velocity_y  := 0.0
var _trail_timer      := 0.0
const TRAIL_INTERVAL  := 0.04
var _base_scale       := Vector2(0.28, 0.28)
var _glow_spr         : Sprite2D

var _frames_stand     : Array[Texture2D] = []
var _frames_walk      : Array[Texture2D] = []
var _frames_jump      : Array[Texture2D] = []
var _frames_hurt      : Array[Texture2D] = []
var _frames_ready     : Array[Texture2D] = []

var _current_anim      := "stand"


func _ready() -> void:
	if Engine.is_editor_hint():
		visible = false
		return
	add_to_group("player")

	var cap := CapsuleShape2D.new()
	cap.radius = 8
	cap.height = 22
	var col := CollisionShape2D.new()
	col.shape    = cap
	col.position = Vector2(0, 3)
	add_child(col)

	collision_layer = 1
	collision_mask  = 2 | 4

	_load_frames(0)

	_anim_sprite = AnimatedSprite2D.new()
	_anim_sprite.sprite_frames = _build_sprite_frames()
	_anim_sprite.scale = Vector2(0.28, 0.28)
	_anim_sprite.play("stand")
	add_child(_anim_sprite)

	_overlay_jetpack = _make_overlay("res://assets/items/jetpack.png",    Vector2(2, 0),    Vector2(0.36, 0.36), -1)
	_overlay_wing_l  = _make_overlay("res://assets/items/wing_left.png",  Vector2(-30, 2),  Vector2(0.44, 0.44), 1)
	_overlay_wing_r  = _make_overlay("res://assets/items/wing_right.png", Vector2( 30, 2),  Vector2(0.44, 0.44), 1)
	_overlay_bubble  = _make_overlay("res://assets/items/bubble.png",      Vector2(0, -2),   Vector2(0.32, 0.32), 1)
	_overlay_flame   = _make_overlay("res://assets/particles/flame.png",  Vector2(-10, 38), Vector2(0.50, 0.50), -1)
	_overlay_flame_r = _make_overlay("res://assets/particles/flame.png",  Vector2( 10, 38), Vector2(0.50, 0.50), -1)

	_glow_spr = Sprite2D.new()
	_glow_spr.z_index = -1
	_glow_spr.visible = false
	var glow_img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for gx in 64:
		for gy in 64:
			var dx := gx - 32.0
			var dy := gy - 32.0
			var dist := sqrt(dx*dx + dy*dy) / 32.0
			var alpha := clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha * 0.55
			glow_img.set_pixel(gx, gy, Color(1.0, 1.0, 1.0, alpha))
	_glow_spr.texture = ImageTexture.create_from_image(glow_img)
	_glow_spr.scale   = Vector2(1.2, 1.2)
	add_child(_glow_spr)

	position = Vector2(SCREEN_W * 0.5, 560.0)
	_start_idle_anim()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			is_god_mode = not is_god_mode
			if is_god_mode:
				print("God Mode: AKTİF! (Süper Jetpack Dahil)")
				_anim_sprite.modulate = Color(1.5, 1.3, 0.5, 1.0)
			else:
				print("God Mode: DEVRE DIŞI!")
				_anim_sprite.modulate = Color.WHITE
				# Kapatıldığında jetpack gücü de normallere sıfırlansın
				if is_powered_up and powerup_type == "jetpack":
					is_powered_up = false
					powerup_type = ""
		
		# J Tuşu: Süper Jetpack Ateşleme
		if event.keycode == KEY_J and is_god_mode:
			activate_powerup("jetpack")
			print("Süper God Jetpack Aktif!")


func set_char(index: int) -> void:
	var s : Dictionary = CHAR_STATS[clamp(index, 0, CHAR_STATS.size() - 1)]
	GRAVITY      = s["gravity"]
	JUMP_SPEED   = s["jump"]
	SPRING_SPEED = s["spring"]
	MOVE_SPEED   = s["move"]
	JETPACK_LIFT = s["jetpack"]
	_load_frames(index)
	_anim_sprite.sprite_frames = _build_sprite_frames()
	_anim_sprite.play(_current_anim)


func _load_frames(index: int = 0) -> void:
	var prefix := "bunny%d" % (index + 1)
	var base   := "res://assets/players/"
	var _t     := func(n): return load(base + n) if ResourceLoader.exists(base + n) else _fallback_tex(Color(1, 0.8, 0.2))
	_frames_stand = [_t.call(prefix + "_stand.png")]
	_frames_ready = [_t.call(prefix + "_ready.png")]
	_frames_walk  = [_t.call(prefix + "_walk1.png"), _t.call(prefix + "_walk2.png")]
	_frames_jump  = [_t.call(prefix + "_jump.png")]
	_frames_hurt  = [_t.call(prefix + "_hurt.png")]


func _build_sprite_frames() -> SpriteFrames:
	var sf := SpriteFrames.new()
	sf.add_animation("stand"); sf.set_animation_loop("stand", true);  sf.set_animation_speed("stand", 4.0)
	for t in _frames_stand: sf.add_frame("stand", t)
	sf.add_animation("walk");  sf.set_animation_loop("walk", true);   sf.set_animation_speed("walk", 8.0)
	for t in _frames_walk:  sf.add_frame("walk", t)
	sf.add_animation("jump");  sf.set_animation_loop("jump", false);  sf.set_animation_speed("jump", 4.0)
	for t in _frames_jump:  sf.add_frame("jump", t)
	sf.add_animation("hurt");  sf.set_animation_loop("hurt", false);  sf.set_animation_speed("hurt", 6.0)
	for t in _frames_hurt:  sf.add_frame("hurt", t)
	sf.add_animation("ready"); sf.set_animation_loop("ready", false); sf.set_animation_speed("ready", 4.0)
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


func _fallback_tex(color: Color) -> ImageTexture:
	var img := Image.create(36, 48, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func _start_idle_anim() -> void:
	_run_idle_loop()

func _run_idle_loop() -> void:
	if _initialized or is_dead: return
	_anim_sprite.scale = Vector2(0.28, 0.28)
	_anim_sprite.play("stand")
	var tw := create_tween()
	if not tw: return
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
	_anim_sprite.scale = Vector2(0.28, 0.28)
	_anim_sprite.play("ready")
	await get_tree().create_timer(0.5).timeout
	velocity = Vector2(0, JUMP_SPEED)
	_initialized = true
	_anim_sprite.play("jump")


func _physics_process(delta: float) -> void:
	if is_dead or not _initialized: return

	if is_god_mode and position.y > 720.0:
		velocity.y = SPRING_SPEED
		_anim_sprite.play("jump")

	if is_powered_up:
		powerup_timer -= delta
		if powerup_timer <= 0.0:
			is_powered_up = false
			powerup_type  = ""

	if _invincible > 0:
		_invincible -= delta
	if _hurt_flash > 0:
		_hurt_flash -= delta
		_anim_sprite.modulate = Color(1, 0.3, 0.3, 1)
	else:
		if not is_god_mode:
			_anim_sprite.modulate = Color.WHITE

	if is_powered_up:
		# ── SÜPER JETPACK LIFT AYARI (GOD MODE) ──
		var target_lift = GOD_JETPACK_LIFT if (is_god_mode and powerup_type == "jetpack") else JETPACK_LIFT
		velocity.y = move_toward(velocity.y, target_lift, GRAVITY * delta * 1.5) # İvmelenmeyi de artırdık
	else:
		velocity.y += GRAVITY * delta

	var dir := 0.0
	if Input.is_action_pressed("ui_right") or Input.is_action_pressed("move_right"): dir = 1.0
	elif Input.is_action_pressed("ui_left") or Input.is_action_pressed("move_left"): dir = -1.0
	
	var current_speed = GOD_MOVE_SPEED if is_god_mode else MOVE_SPEED
	velocity.x = dir * current_speed

	set_collision_mask_value(2, velocity.y > 0 and not is_powered_up)
	set_collision_mask_value(4, not is_powered_up)

	var vel_y_before_slide := velocity.y
	move_and_slide()

	if not is_powered_up and is_on_floor() and velocity.y >= -1.0:
		if vel_y_before_slide > 0.0:
			velocity.y = JUMP_SPEED
			if _prev_velocity_y > 50.0:
				for i in get_slide_collision_count():
					var col      := get_slide_collision(i)
					var collider := col.get_collider()
					if collider and collider.has_method("on_player_landed"):
						if col.get_normal().y < -0.5 and not is_god_mode:
							collider.on_player_landed()

	if position.x > SCREEN_W + 20:  position.x = -20
	elif position.x < -20:          position.x = SCREEN_W + 20

	if velocity.x < 0:        _anim_sprite.flip_h = true
	elif velocity.x > 0:      _anim_sprite.flip_h = false

	var just_landed := is_on_floor() and not _was_on_floor and vel_y_before_slide > 0.0
	var just_jumped := not is_on_floor() and _was_on_floor and velocity.y < -200
	_was_on_floor = is_on_floor()

	if just_landed:
		_do_squash()
		_spawn_dust()
	elif just_jumped:
		_do_stretch()

	var fast_vertical := not is_on_floor() and velocity.y < -700.0
	if fast_vertical:
		_trail_timer += delta
		if _trail_timer >= TRAIL_INTERVAL:
			_trail_timer = 0.0
			_spawn_trail()
	else:
		_trail_timer = 0.0

	_prev_velocity_y = velocity.y
	_update_animation()
	_update_overlays(delta)
	_update_glow()


func _update_animation() -> void:
	var target := "stand"
	if velocity.y < -100:       target = "jump"
	elif abs(velocity.x) > 10: target = "walk"
	if target != _current_anim:
		_current_anim = target
		_anim_sprite.play(_current_anim)


func _update_overlays(delta: float) -> void:
	var jet := is_powered_up and powerup_type == "jetpack"
	var wings := is_powered_up and powerup_type == "wings"
	_overlay_jetpack.visible = jet
	_overlay_wing_l.visible  = wings
	_overlay_wing_r.visible  = wings
	_overlay_bubble.visible  = has_shield
	if wings:
		_overlay_wing_l.flip_h = _anim_sprite.flip_h
		_overlay_wing_r.flip_h = _anim_sprite.flip_h
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
		_overlay_flame.visible   = _flame_visible
		_overlay_flame_r.visible = _flame_visible
	else:
		_overlay_flame.visible   = false
		_overlay_flame_r.visible = false


func do_spring_jump() -> void:
	velocity.y = SPRING_SPEED
	_anim_sprite.play("jump")


func activate_powerup(type: String) -> void:
	is_powered_up = true
	powerup_type  = type
	
	# ── JETPACK SÜRESİ UZATMA (GOD MODE) ──
	if is_god_mode and type == "jetpack":
		powerup_timer = 999.9 # Neredeyse sınırsız süre (999 saniye)
		velocity.y    = GOD_JETPACK_LIFT
	else:
		powerup_timer = 5.0 if type == "jetpack" else 4.0
		velocity.y    = -600.0
		
	activate_powerup_flash()


func apply_shield() -> void:
	has_shield = true


func add_life(amount: int = 1) -> void:
	lives = min(lives + amount, MAX_LIVES)
	emit_signal("lives_changed", lives)


func full_heal() -> void:
	lives = MAX_LIVES
	has_shield = true
	emit_signal("lives_changed", lives)


func hit_enemy() -> void:
	if is_god_mode: return
	
	if is_powered_up: return
	if _invincible > 0: return
	if has_shield:
		has_shield = false
		emit_signal("collected_item", "shield_lost")
		_hurt_flash = 0.8
		_anim_sprite.play("hurt")
		return
	lives -= 1
	emit_signal("lives_changed", lives)
	if lives <= 0:
		die()
		return
	_invincible = 1.2
	_hurt_flash = 0.8
	_anim_sprite.play("hurt")
	var tw := create_tween()
	if tw:
		tw.tween_interval(0.5)
		tw.tween_callback(func():
			if not is_dead: _anim_sprite.play("stand")
		)


func die() -> void:
	if is_god_mode: return
	
	if is_dead: return
	is_dead = true
	_anim_sprite.play("hurt")
	var tw := create_tween()
	if tw:
		tw.tween_property(_anim_sprite, "modulate", Color(1.2, 0.2, 0.2, 1.0), 0.08)
		tw.tween_property(_anim_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.15)
	emit_signal("died")


func _do_squash() -> void:
	var tw := create_tween()
	if not tw: return
	tw.tween_property(_anim_sprite, "scale", Vector2(_base_scale.x * 1.4, _base_scale.y * 0.65), 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_anim_sprite, "scale", _base_scale, 0.12).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

func _do_stretch() -> void:
	var tw := create_tween()
	if not tw: return
	tw.tween_property(_anim_sprite, "scale", Vector2(_base_scale.x * 0.75, _base_scale.y * 1.35), 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_anim_sprite, "scale", _base_scale, 0.18).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _spawn_dust() -> void:
	var parent := get_parent()
	if not parent: return
	for i in 6:
		var p := Sprite2D.new()
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.85, 0.82, 0.75, 0.9))
		p.texture  = ImageTexture.create_from_image(img)
		p.z_index  = 3
		parent.add_child(p)
		p.global_position = global_position + Vector2(randf_range(-18, 18), 10)
		var angle  := randf_range(PI * 0.85, PI * 1.15) + (i - 3) * 0.22
		var speed  := randf_range(55.0, 120.0)
		var vel    := Vector2(cos(angle), sin(angle)) * speed
		var dur    := randf_range(0.22, 0.38)
		var tw     := p.create_tween()
		if tw:
			tw.tween_property(p, "global_position", p.global_position + vel * dur, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(p, "scale", Vector2(2.5, 2.5), dur * 0.7)
			tw.parallel().tween_property(p, "modulate:a", 0.0, dur)
			tw.tween_callback(func(): if is_instance_valid(p): p.queue_free())


func _spawn_trail() -> void:
	if not is_instance_valid(_anim_sprite): return
	var parent := get_parent()
	if not parent: return
	var ghost := Sprite2D.new()
	var sf := _anim_sprite.sprite_frames
	if not sf: return
	var anim_name := _anim_sprite.animation
	if not sf.has_animation(anim_name): return
	var frame_idx := _anim_sprite.frame
	if frame_idx >= sf.get_frame_count(anim_name): return
	ghost.texture  = sf.get_frame_texture(anim_name, frame_idx)
	ghost.scale    = _anim_sprite.scale * (1.0 / _anim_sprite.scale.x) * 0.26
	ghost.flip_h   = _anim_sprite.flip_h
	ghost.modulate = Color(0.5, 0.8, 1.0, 0.35)
	ghost.z_index  = -2
	parent.add_child(ghost)
	ghost.global_position = global_position
	var tw := ghost.create_tween()
	if tw:
		tw.tween_property(ghost, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_LINEAR)
		tw.tween_callback(func(): if is_instance_valid(ghost): ghost.queue_free())


func _update_glow() -> void:
	if not is_instance_valid(_glow_spr): return
	if is_powered_up:
		_glow_spr.visible = true
		var col : Color
		if powerup_type == "jetpack":
			col = Color(1.0, 0.5, 0.1, 0.7)
		else:
			col = Color(0.3, 0.7, 1.0, 0.7)
		if powerup_timer < 1.5:
			col.a = 0.7 * (0.4 + 0.6 * sin(Time.get_ticks_msec() * 0.015))
		_glow_spr.modulate = col
		_glow_spr.scale    = Vector2(1.4, 1.4)
	elif has_shield:
		_glow_spr.visible  = true
		_glow_spr.modulate = Color(0.2, 0.8, 1.0, 0.45)
		_glow_spr.scale    = Vector2(1.1, 1.1)
	else:
		_glow_spr.visible = false


func activate_powerup_flash() -> void:
	var tw := create_tween()
	if not tw: return
	tw.tween_property(_anim_sprite, "modulate", Color(2.0, 2.0, 2.0, 1.0), 0.07)
	tw.tween_property(_anim_sprite, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.25).set_trans(Tween.TRANS_QUAD)
