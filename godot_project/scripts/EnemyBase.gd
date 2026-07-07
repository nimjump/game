# ═══════════════════════════════════════════════════════════════════
#  EnemyBase.gd  —  Tüm düşmanların extend ettiği base class
#
#  KULLANIM:
#    extends EnemyBase          ← alt sınıflarda
#    extends Area2D             ← Enemy.gd (eski kod) hâlâ çalışır
#
#  Alt sınıflar şu sanal metodları override edebilir:
#    _special_setup()           ← setup() sonunda çağrılır
#    _special_process(delta)    ← _physics_process içinde çağrılır
#    _special_hit(body, stomped, powered) → bool
#                               ← true dönerse base hit işlemi atlanır
# ═══════════════════════════════════════════════════════════════════

@tool
extends Area2D
class_name EnemyBase

# ── Sabitler ────────────────────────────────────────────────────────
const PATROL_RANGE := 65.0
const PATROL_TIME  := 1.3

# ── Durum değişkenleri ───────────────────────────────────────────────
var difficulty     := 0.0
var enemy_type     : int          # Enemy.EnemyType değeri
var can_fly        := false       # true ise platform kırılınca düşmez
var _platform      : Node = null  # Bağlı platform node'u
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

# ── Ortak yardımcılar ────────────────────────────────────────────────
func _ready() -> void:
	collision_layer = 4
	collision_mask  = 1
	monitoring  = true
	monitorable = true

	_anim = AnimatedSprite2D.new()
	add_child(_anim)

	var cs := CircleShape2D.new()
	cs.radius = 18
	_col = CollisionShape2D.new()
	_col.shape = cs
	add_child(_col)

	_effect_spr = Sprite2D.new()
	_effect_spr.visible = false
	_effect_spr.z_index = 2
	add_child(_effect_spr)

	body_entered.connect(_on_body_entered)


# ── Setup ────────────────────────────────────────────────────────────
func base_setup(etype: int, anim_frames: Dictionary, diff: float) -> void:
	difficulty = diff
	enemy_type = etype
	_start_x   = global_position.x
	# Platform varsa _start_y'yi oradan hesapla (spawn Y hataları için güvenli)
	if is_instance_valid(_platform):
		var ps := _platform.get_node_or_null("CollisionShape2D")
		if ps and ps.shape:
			_start_y = _platform.global_position.y - ps.shape.size.y * 0.5 - 18.0
		else:
			_start_y = global_position.y
	else:
		_start_y = global_position.y
	_hp        = _base_hp_for(etype)

	_build_anim(anim_frames)
	_special_setup()
	_setup_done = true


func _base_hp_for(etype: int) -> int:
	return 1   # Alt sınıflar override eder


func _build_anim(anim_frames: Dictionary) -> void:
	var anim_fps := 8.0
	var sf := SpriteFrames.new()
	for anim_name in anim_frames:
		sf.add_animation(anim_name)
		sf.set_animation_loop(anim_name, true)
		sf.set_animation_speed(anim_name, anim_fps)
		for tex in anim_frames[anim_name]:
			sf.add_frame(anim_name, tex)
	_anim.sprite_frames = sf

	if anim_frames.size() > 0:
		var first_key : String = anim_frames.keys()[0]
		var tex = sf.get_frame_texture(first_key, 0)
		if tex and tex.get_width() > 0:
			var mx := maxf(float(tex.get_width()), float(tex.get_height()))
			_anim.scale = Vector2(44.0 / mx, 44.0 / mx)


# ── Sanal metodlar (override edilebilir) ─────────────────────────────
func _special_setup() -> void:
	pass   # Alt sınıf dolduracak


func _special_process(_delta: float) -> void:
	pass   # Alt sınıf dolduracak


## true dönerse base _on_body_entered atlanır
func _special_hit(_body: Node, _stomped: bool, _powered: bool) -> bool:
	return false


# ── Fizik döngüsü ────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _setup_done: return
	if _stun_timer > 0:
		_stun_timer -= delta
		return
	_state_timer -= delta
	_snap_to_platform()
	_special_process(delta)


# Yerde yürüyen düşmanları platformun üstüne yapıştır
func _snap_to_platform() -> void:
	if can_fly: return
	if not is_instance_valid(_platform): return
	var plat_shape := _platform.get_node_or_null("CollisionShape2D")
	if not plat_shape or not plat_shape.shape: return
	var half_h : float = plat_shape.shape.size.y * 0.5
	var target_y : float = _platform.global_position.y - half_h - 18.0  # 18 = enemy circle radius
	# Sadece aktif tween yoksa snap yap (uçuş/patrol tweeni bozmasın)
	# Her zaman Y'yi platforma kilitle
	global_position.y = target_y


# ── Çarpışma ─────────────────────────────────────────────────────────
func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"): return
	var rel_y   : float = body.position.y - global_position.y
	var stomped : bool  = rel_y < -10
	var powered : bool  = body.is_powered_up
	if _special_hit(body, stomped, powered): return
	# Varsayılan: basit stomp/hasar
	if stomped:
		body.velocity.y = -400.0
		_die()
	elif not powered:
		body.hit_enemy()


# ── Ortak hareketler ─────────────────────────────────────────────────
func _start_patrol(speed_mult: float = 1.0) -> void:
	if _tween: _tween.kill()
	_tween = create_tween()
	if not _tween: return
	var diff_mult := 1.0 + difficulty * 0.8
	var t := maxf(0.15, PATROL_TIME / (speed_mult * diff_mult))
	var right_x : float
	var left_x  : float
	if not can_fly and is_instance_valid(_platform):
		var plat_shape := _platform.get_node_or_null("CollisionShape2D")
		if plat_shape and plat_shape.shape:
			var half_w : float = plat_shape.shape.size.x * 0.5 * _platform.scale.x
			var margin : float = half_w * 0.12
			right_x = minf(_start_x + PATROL_RANGE, _platform.global_position.x + half_w - margin)
			left_x  = maxf(_start_x - PATROL_RANGE, _platform.global_position.x - half_w + margin)
		else:
			right_x = _start_x + PATROL_RANGE
			left_x  = _start_x - PATROL_RANGE
	else:
		right_x = _start_x + PATROL_RANGE
		left_x  = _start_x - PATROL_RANGE
	_tween.set_loops()
	_tween.tween_property(self, "position:x", right_x, t).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(func(): if is_instance_valid(_anim): _anim.flip_h = false)
	_tween.tween_property(self, "position:x", left_x,  t).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(func(): if is_instance_valid(_anim): _anim.flip_h = true)


func _start_vertical_bob(amplitude: float = 12.0, period: float = 1.6) -> void:
	var bob := create_tween()
	if not bob: return
	bob.set_loops()
	bob.tween_property(self, "position:y", _start_y - amplitude, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	bob.tween_property(self, "position:y", _start_y + amplitude, period * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _start_spin(speed: float = 1.0) -> void:
	var spin := create_tween()
	if not spin: return
	spin.set_loops()
	var duration := maxf(0.05, 0.3 / speed)
	spin.tween_property(_anim, "rotation_degrees", 360.0, duration).set_trans(Tween.TRANS_LINEAR)
	spin.tween_callback(func(): if is_instance_valid(_anim): _anim.rotation_degrees = 0.0)


# ── Platform kırılması ───────────────────────────────────────────────
func _fall_off_platform() -> void:
	if can_fly: return   # Uçan düşmanlar etkilenmez
	if not _setup_done: return
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_setup_done = false
	if _tween: _tween.kill()
	var tw := create_tween()
	if tw:
		tw.tween_property(self, "position:y", position.y + 300.0, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(self, "modulate:a", 0.0, 0.4)
		tw.tween_callback(func(): queue_free())
	else:
		queue_free()


# ── Ölüm ─────────────────────────────────────────────────────────────
func _die() -> void:
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_setup_done = false
	if _tween: _tween.kill()
	if is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("hurt"):
			_anim.play("hurt")
		elif _anim.sprite_frames.has_animation("dead"):
			_anim.play("dead")
	var gm := get_parent()
	if gm and gm.has_method("camera_shake"):
		gm.camera_shake(5.0, 0.22)
	var tw := create_tween()
	if tw:
		tw.tween_property(self, "scale", Vector2(1.4, 1.4), 0.15).set_trans(Tween.TRANS_BACK)
		tw.tween_property(self, "modulate:a", 0.0, 0.25)
		tw.tween_callback(func(): queue_free())
	else:
		queue_free()


# ── Yardımcılar ──────────────────────────────────────────────────────
func _get_player() -> Node:
	var tree := get_tree()
	if not tree: return null
	var players := tree.get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null


func _rng_range(a: float, b: float) -> float:
	return a + randf() * (b - a)


func _show_effect(duration: float, is_sun: bool = false) -> void:
	if not _effect_spr.texture: return
	_effect_spr.visible    = true
	_effect_spr.modulate.a = 1.0
	_effect_spr.position   = Vector2(0, -30)
	_effect_spr.scale      = Vector2(0.4, 0.4)
	if is_sun:
		_effect_spr.modulate = Color(1.5, 1.0, 0.3)
	else:
		_effect_spr.modulate = Color.WHITE
	var tw := create_tween()
	if tw:
		tw.tween_property(_effect_spr, "scale",      Vector2(1.1, 1.1), duration * 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(_effect_spr, "modulate:a", 0.0,               duration * 0.6)
		tw.tween_callback(func():
			_effect_spr.visible    = false
			_effect_spr.modulate   = Color.WHITE
			_effect_spr.modulate.a = 1.0
		)
