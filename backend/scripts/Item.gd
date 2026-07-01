extends Area2D
class_name Item

enum ItemType { NIMIQ, CARROT, JETPACK, WINGS, BUBBLE, GOLDEN_CARROT, MYSTERY_BOX }

const ITEM_POINTS := {
	0: 1, 1: 30, 2: 0, 3: 0, 4: 0, 5: 200, 6: 0,
}

var item_type  : ItemType
var _anim      : AnimatedSprite2D
var _collected := false
var _vw : float = GameConstants.VW
var _vh : float = GameConstants.VH
# Visual-only RNG — partiküller ve animasyon görselleri için.
# Game state'i etkilemez, ama replay'de aynı görünmesi için seed'leniyor.
var _visual_rng : RandomNumberGenerator = RandomNumberGenerator.new()

signal item_collected(type: int, points: int)

# [PERF] Small square texture for particle FX — generated once
static var _fx_pixel_cache  : Dictionary = {}  # Color.to_html() -> ImageTexture


func _ready() -> void:
	# Match GameManager's fixed virtual world — same space Player/Enemy
	# use, so item size/animation stays consistent across all real screen sizes.
	# Single source of truth: GameConstants.
	_vw = GameConstants.VW
	_vh = GameConstants.VH
	collision_layer = 4
	collision_mask  = 1
	monitoring  = true
	monitorable = true

	# CollisionShape2D is always added — required for mechanics in headless mode
	var cs := CircleShape2D.new()
	cs.radius = int(_vw * 0.027)
	var col := CollisionShape2D.new()
	col.shape = cs
	add_child(col)

	body_entered.connect(_on_body_entered)
	add_to_group("items")

	# Do not create any visual nodes in headless mode
	if DisplayServer.get_name() == "headless":
		visible = false
		return

	# ── EVERYTHING BELOW THIS LINE IS VISUAL MODE ONLY ──
	_anim = AnimatedSprite2D.new()
	add_child(_anim)


func setup(itype: ItemType, anim_frames: Array) -> void:
	item_type = itype

	# Skip all visual setup in headless mode
	if DisplayServer.get_name() == "headless":
		return

	if itype == ItemType.NIMIQ:
		if is_instance_valid(_anim):
			_anim.visible = false

		var spr := Sprite2D.new()
		if anim_frames.size() > 0 and anim_frames[0]:
			spr.texture = anim_frames[0]
		# nimiq_hexagon_item.png = 1024x922px
		var s := (_vw * 0.0656) / 1024.0
		spr.scale = Vector2(s, s)
		spr.z_index = 1
		add_child(spr)

		spr.position.y = 0.0  # Sabit başlangıç — random offset replay görselini bozuyordu
		var bob := create_tween()
		if bob:
			bob.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			bob.set_loops()
			bob.tween_property(spr, "position:y", -_vh * 0.005, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			bob.tween_property(spr, "position:y",  _vh * 0.005, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		_nimiq_spin_loop(spr, s, true)
		return

	if not is_instance_valid(_anim):
		return

	var sf := SpriteFrames.new()
	sf.add_animation("idle")
	sf.set_animation_loop("idle", true)
	var anim_speed := 12.0 if itype == ItemType.MYSTERY_BOX else 6.0
	sf.set_animation_speed("idle", anim_speed)
	for tex in anim_frames:
		if tex: sf.add_frame("idle", tex)
	_anim.sprite_frames = sf
	_anim.play("idle")
	if anim_frames.size() > 0 and anim_frames[0]:
		var tex : Texture2D = anim_frames[0]
		var md := maxf(float(tex.get_width()), float(tex.get_height()))
		if md > 0:
			_anim.scale = Vector2((_vw * 0.053) / md, (_vw * 0.053) / md)
	if itype == ItemType.GOLDEN_CARROT:
		_anim.scale *= 1.3
	var _bob_start := 0.0  # Sabit başlangıç — random offset replay görselini bozuyordu
	_anim.position.y = _bob_start
	var tw := create_tween()
	if tw:
		tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		tw.set_loops()
		tw.tween_property(_anim, "position:y", -_vh * 0.00625, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(_anim, "position:y",  _vh * 0.00625, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# ── FIX: self + spr validity check added ──────────────────────────────────
func _nimiq_spin_loop(spr: Sprite2D, s: float, first_call: bool = false) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if _collected or not is_instance_valid(self) or not is_instance_valid(spr):
		return
	var tw := create_tween()
	if not tw: return
	tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if first_call:
		tw.tween_interval(0.4)  # Sabit başlangıç gecikmesi — randf_range(0,1.5) replay görselini bozuyordu
	tw.tween_property(spr, "scale:x", 0.0, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(spr, "scale:x", s,   0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.55)
	tw.tween_callback(func():
		if not _collected and is_instance_valid(self) and is_instance_valid(spr):
			_nimiq_spin_loop(spr, s)
	)
# ───────────────────────────────────────────────────────────────────────────


func _on_body_entered(body: Node) -> void:
	if _collected or not body.is_in_group("player"): return
	_collected = true

	match item_type:
		ItemType.JETPACK:       body.activate_powerup("jetpack")
		ItemType.WINGS:         body.activate_powerup("wings")
		ItemType.BUBBLE:        body.apply_shield()
		ItemType.MYSTERY_BOX:   body.open_mystery_box()
		ItemType.CARROT:        body.add_life(1)
		ItemType.GOLDEN_CARROT: body.full_heal()
		_: pass
	var pts : int = ITEM_POINTS.get(int(item_type), 0)
	emit_signal("item_collected", int(item_type), pts)

	if DisplayServer.get_name() != "headless":
		_spawn_collect_fx(pts)

	queue_free()


func _spawn_collect_fx(pts: int) -> void:
	if DisplayServer.get_name() == "headless":
		return

	var parent := get_parent()
	if not parent: return

	var col : Color
	match item_type:
		ItemType.NIMIQ, ItemType.GOLDEN_CARROT: col = Color(1.0,  0.85, 0.1,  1.0)
		ItemType.JETPACK:                        col = Color(1.0,  0.5,  0.1,  1.0)
		ItemType.WINGS:                          col = Color(0.4,  0.8,  1.0,  1.0)
		ItemType.BUBBLE:                         col = Color(0.3,  0.9,  1.0,  1.0)
		_:                                       col = Color(0.5,  1.0,  0.4,  1.0)

	var px_tex := _get_fx_pixel(col)

	for i in 10:
		var p := Sprite2D.new()
		p.texture  = px_tex
		p.z_index  = 10
		parent.add_child(p)
		p.global_position = global_position
		var angle := (float(i) / 10.0) * TAU + _visual_rng.randf_range(-0.3, 0.3)
		var speed := _visual_rng.randf_range(_vw * 0.117, _vw * 0.267)
		var vel   := Vector2(cos(angle), sin(angle)) * speed
		var dur   := _visual_rng.randf_range(0.25, 0.45)
		var tw    := p.create_tween()
		if tw:
			tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			tw.tween_property(p, "global_position", p.global_position + vel * dur, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(p, "scale", Vector2(2.0, 2.0), dur * 0.6)
			tw.parallel().tween_property(p, "modulate:a", 0.0, dur)
			tw.tween_callback(func(): if is_instance_valid(p): p.queue_free())

	var ring := Sprite2D.new()
	var ring_sz := int(_vw * 0.08)
	ring.texture = _get_ring_tex(col, ring_sz)
	ring.z_index = 9
	ring.modulate = col
	parent.add_child(ring)
	ring.global_position = global_position
	var rtw := ring.create_tween()
	if rtw:
		rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		rtw.tween_property(ring, "scale", Vector2(2.8, 2.8), 0.30).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		rtw.parallel().tween_property(ring, "modulate:a", 0.0, 0.30)
		rtw.tween_callback(func(): if is_instance_valid(ring): ring.queue_free())

	if pts > 0:
		var lbl := Label.new()
		lbl.text = "+%d" % pts
		lbl.z_index = 15
		lbl.add_theme_font_size_override("font_size", int(_vw * 0.033))
		lbl.add_theme_color_override("font_color", col)
		parent.add_child(lbl)
		lbl.global_position = global_position + Vector2(-_vw * 0.027, -_vh * 0.03)
		var ltw := lbl.create_tween()
		if ltw:
			ltw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			ltw.tween_property(lbl, "global_position", lbl.global_position + Vector2(0, -_vh * 0.056), 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			ltw.parallel().tween_property(lbl, "modulate:a", 0.0, 0.55).set_delay(0.25)
			ltw.tween_callback(func(): if is_instance_valid(lbl): lbl.queue_free())


# [PERF] Single pixel FX texture — generated once per color
func _get_fx_pixel(col: Color) -> ImageTexture:
	if DisplayServer.get_name() == "headless":
		return null
	var key := col.to_html()
	if _fx_pixel_cache.has(key):
		return _fx_pixel_cache[key]
	var img := Image.create(6, 6, false, Image.FORMAT_RGBA8)
	img.fill(col)
	var t := ImageTexture.create_from_image(img)
	_fx_pixel_cache[key] = t
	return t


# [PERF] Ring texture cache — do not regenerate for the same color
static var _ring_tex_cache : Dictionary = {}

func _get_ring_tex(col: Color, ring_sz: int) -> ImageTexture:
	if DisplayServer.get_name() == "headless":
		return null
	var key := "%s_%d" % [col.to_html(), ring_sz]
	if _ring_tex_cache.has(key):
		return _ring_tex_cache[key]
	var ring_img := Image.create(ring_sz, ring_sz, false, Image.FORMAT_RGBA8)
	for rx in ring_sz:
		for ry in ring_sz:
			var dx := rx - ring_sz * 0.5
			var dy := ry - ring_sz * 0.5
			var d  := sqrt(dx*dx + dy*dy)
			var a  := clampf(1.0 - abs(d - ring_sz * 0.417) / (ring_sz * 0.083), 0.0, 1.0)
			ring_img.set_pixel(rx, ry, Color(col.r, col.g, col.b, a * 0.85))
	var t := ImageTexture.create_from_image(ring_img)
	_ring_tex_cache[key] = t
	return t
