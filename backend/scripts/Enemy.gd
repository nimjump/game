extends EnemyBase
class_name Enemy

# ═══════════════════════════════════════════════════════════════════
#  Enemy.gd  —  All enemy types in a single file
# ═══════════════════════════════════════════════════════════════════

# EN-10: preloaded assets — avoid runtime load() at spawn time
const _TEX_LIGHTNING_Y := preload("res://assets/particles/lighting_yellow.png")
const _TEX_LIGHTNING_B := preload("res://assets/particles/lighting_blue.png")
const _TEX_SMOKE       := preload("res://assets/particles/smoke.png")
const _SCR_ENEMY       := preload("res://scripts/Enemy.gd")

const _TEX_PARTICLE_GREEN := preload("res://assets/particles/particle_green.png")
const _TEX_PARTICLE_GREY  := preload("res://assets/particles/particle_grey.png")
const _TEX_PARTICLE_BEIGE := preload("res://assets/particles/particle_beige.png")
const _TEX_PARTICLE_BLUE  := preload("res://assets/particles/particle_blue.png")

enum EnemyType {
	FLYMAN, WINGMAN, SPIKEMAN, SPIKEBALL, SPRINGMAN, SUN, CLOUD,
	BARNACLE, BEE, FLY, FROG, MOUSE,
	SLIME_BLOCK, SLIME_BLUE, SLIME_GREEN, SLIME_PURPLE, SLIME_FIRE,
	SNAIL, WORM_GREEN, WORM_PINK, LADYBUG,
	SPIDER, GHOST, UFO,
	ALIEN_GREEN, ALIEN_BLUE, ALIEN_PINK, ALIEN_YELLOW
}

# ── FLYMAN ───────────────────────────────────────────────────────────
# Unkillable, damages on contact

# ── WINGMAN ──────────────────────────────────────────────────────────
# Chases the player in range, returns to static patrol when out of range
var WINGMAN_CHASE_RANGE : float = 0.0
var WINGMAN_CHASE_SPEED : float = 0.0
var _wingman_chasing := false

# ── SPIKEMAN ─────────────────────────────────────────────────────────
# Patrols platform, tracks player on X axis when player is above — unkillable
var SPIKEMAN_DETECT_X    : float = 0.0
var SPIKEMAN_CHASE_SPEED : float = 0.0

# ── SPIKEBALL ────────────────────────────────────────────────────────
# Vertical up-down movement
var SPIKEBALL_AMPLITUDE : float = 0.0
const SPIKEBALL_PERIOD := 1.4

# ── SUN ──────────────────────────────────────────────────────────────
# Vertical up-down (like spikeball)
var SUN_AMPLITUDE : float = 0.0
const SUN_PERIOD := 1.6

# ── CLOUD ────────────────────────────────────────────────────────────
# Hovers above the player, deals rain damage when player is below
var CLOUD_FOLLOW_SPEED : float = 0.0  # slightly slower than the player
var CLOUD_RAIN_RANGE_X : float = 0.0
var CLOUD_RAIN_CD := 1.2
var _cloud_rain_timer := 0.0
var _cloud_rain_node : Node = null

# ── BARNACLE ─────────────────────────────────────────────────────────
var _barnacle_flipped := false  # true = hanging from the underside of a platform
var _barnacle_attack_cd := 0.0
const BARNACLE_ATTACK_INTERVAL := 1.5

# ── SLIME ────────────────────────────────────────────────────────────
var _slime_attack_cd := 0.0
var _slime_nodes     : Array[Node] = []

# ── SNAIL ────────────────────────────────────────────────────────────
var _in_shell    := false
var _shell_timer := 0.0

# ── BEE ──────────────────────────────────────────────────────────────
# Patrols its orbit, chases + stings when player enters range
var BEE_AGGRO_RANGE : float = 0.0
var BEE_CHASE_SPEED : float = 0.0
const BEE_STING_COOLDOWN := 1.8
const BEE_CHASE_DURATION := 2.5   # maximum chase duration
var _bee_chasing      := false
var _bee_chase_timer  := 0.0
var _bee_sting_timer  := 0.0
var _bee_home_pos     := Vector2.ZERO
var _bee_returning    := false
var BEE_RETURN_SPEED  : float = 0.0

# ── FLY ──────────────────────────────────────────────────────────────
# Chases and attacks until dead once the player enters range
var FLY_AGGRO_RANGE : float = 0.0
var FLY_CHASE_SPEED : float = 0.0
var _fly_aggro := false
var _fly_home_pos := Vector2.ZERO
var _fly_orbit_angle  := 0.0
var _fly_orbiting     := false
var _fly_orbit_turns  := 0.0
var _fly_diving       := false
var _fly_dive_cd      := 0.0

# ── MOUSE ────────────────────────────────────────────────────────────
# Fast patrol, walks toward the player, dies when stomped on the head
var MOUSE_AGGRO_RANGE : float = 0.0
var MOUSE_PATROL_SPEED := 1.5
var MOUSE_CHASE_SPEED  : float = 0.0
var _mouse_chasing := false
var _mouse_chase_cd := 0.0

# ── FROG ─────────────────────────────────────────────────────────────
# Moves by jumping, leaps toward the player
# Its own platform + 1 above + 1 below = roams across 3 platforms
var FROG_DETECT_X    : float = 0.0
var FROG_DETECT_Y    : float = 0.0
var FROG_JUMP_HEIGHT : float = 0.0
var FROG_JUMP_DIST   : float = 0.0
var _frog_jumping       := false
var _frog_jump_cd       := 0.0
var _frog_home_platform : Node = null
var _frog_cur_platform  : Node = null
var _frog_gm            : Node = null

# ── SLIME_FIRE ───────────────────────────────────────────────────────
# Walks, rests, walks again; targets the player when spotted
var SLIME_FIRE_DETECT : float = 0.0
var _slime_fire_resting    := false
var _slime_fire_rest_timer := 0.0
var _slime_fire_walk_timer := 0.0

# ── SPIDER ───────────────────────────────────────────────────────────
# Fast patrol, attacks when player is spotted
var SPIDER_AGGRO_RANGE : float = 0.0
var SPIDER_BURST_SPEED := 2.8
const SPIDER_BURST_DUR := 0.6
var _spider_burst_active := false
var _spider_burst_timer  := 0.0
var _spider_burst_cd     := 0.0

# ── GHOST ─────────────────────────────────────────────────────────────
# Flies left-right, chases when spotted, returns if it can't catch the player
var GHOST_DETECT_RANGE : float = 0.0
var GHOST_CHASE_SPEED  : float = 0.0
const GHOST_CHASE_DURATION := 3.0
var _ghost_chasing    := false
var _ghost_chase_timer := 0.0
var _ghost_visible    := true
var _ghost_fade_timer := 0.0
const GHOST_FADE_PERIOD := 2.0

# ── UFO ──────────────────────────────────────────────────────────────
var UFO_HOVER_SPEED  : float = 0.0
var UFO_HOVER_RANGE  : float = 0.0
const UFO_FIRE_INTERVAL_MIN := 2.5
const UFO_FIRE_INTERVAL_MAX := 5.0
const UFO_WARN_DURATION     := 1.2   # ışın öncesi uyarı süresi
const UFO_BEAM_DURATION     := 1.8   # ışının aktif olduğu süre
var _ufo_fire_timer   := 0.0         # bir sonraki atışa kadar kalan süre
var _ufo_firing       := false       # şu an ışın atiyor mu
var _ufo_beam_node    : Node  = null  # aktif ışın sprite
var _ufo_warn_node    : Node  = null  # uyarı (kırmızı nokta) sprite
var _ufo_beam_area    : Area2D = null  # ışın hasar alanı
var _ufo_beam_timer   := 0.0
var _ufo_warn_timer   := 0.0

# ── ALIEN ────────────────────────────────────────────────────────────
var ALIEN_SPEED      : float = 0.0
var _alien_jump_timer  := 0.0
var _alien_idle_timer  := 0.0
var _alien_idling      := false
const ALIEN_JUMP_INTERVAL    := 3.5
const ALIEN_PLAT_JUMP_CHANCE := 0.55
const ALIEN_IDLE_CHANCE      := 0.5
const ALIEN_IDLE_MIN         := 1.5
const ALIEN_IDLE_MAX         := 3.5
var _alien_shoot_timer := 0.0
const ALIEN_SHOOT_INTERVAL := 3.0
const ALIEN_SHOOT_WARN := 0.4
var _alien_shooting := false

# ── WORM ─────────────────────────────────────────────────────────────
const WORM_BABY_SCALE      := 0.6
const WORM_BABY_PATROL_SPD := 1.8
const WORM_DIRT_COOLDOWN   := 3.0
var WORM_DIRT_RANGE   : float = 0.0
var WORM_DIRT_SPEED_X : float = 0.0
var WORM_DIRT_SPEED_Y : float = 0.0
var WORM_DIRT_GRAVITY : float = 0.0
var _worm_is_baby     := false
var _worm_baby_frames : Dictionary = {}
var _worm_dirt_timer  := 0.0
var _worm_dirt_nodes  : Array[Node] = []

# ── PROJECTILE POOL (EN-11) ──────────────────────────────────────────
# Reuse Area2D+CollisionShape2D+Sprite2D instead of new() every spawn.
# Each pool entry: { "node": Area2D, "cs": CollisionShape2D, "vis": Sprite2D, "active": bool }
# Pool size = max simultaneous projectiles that enemy type ever needs:
#   rain:1  ice:1  blob:3  cloud_atk:1  mini:3  dirt:2
const _POOL_SIZE_RAIN      := 1
const _POOL_SIZE_ICE       := 1
const _POOL_SIZE_BLOB      := 3
const _POOL_SIZE_CLOUD_ATK := 1
const _POOL_SIZE_MINI      := 3
const _POOL_SIZE_DIRT      := 2

var _pool_rain      : Array = []
var _pool_ice       : Array = []
var _pool_blob      : Array = []
var _pool_cloud_atk : Array = []
var _pool_mini      : Array = []
var _pool_dirt      : Array = []

# ── LADYBUG ──────────────────────────────────────────────────────────
var _ladybug_rest_timer := 0.0
var _ladybug_is_resting := false

# Cached platform collision shape — avoids per-tick get_node_or_null (EN-01)
var _platform_cs : CollisionShape2D = null


# ══════════════════════════════════════════════════════════════════════
#  ENEMYBASE OVERRIDE — TYPE TABLES
# ══════════════════════════════════════════════════════════════════════

func _base_hp_for(etype: int) -> int:
	match etype:
		EnemyType.SUN, EnemyType.SNAIL: return 2
		EnemyType.SPIDER:               return 1
		EnemyType.GHOST:                return 1
		_:                              return 1


func _can_fly_for(etype: int) -> bool:
	match etype:
		EnemyType.FLYMAN, EnemyType.WINGMAN, EnemyType.CLOUD, EnemyType.BEE, EnemyType.FLY, EnemyType.LADYBUG, EnemyType.GHOST, EnemyType.UFO:
			return true
		_:
			return false


func _anim_fps_for(etype: int) -> float:
	match etype:
		EnemyType.FLYMAN:       return 7.0
		EnemyType.WINGMAN:      return 10.0
		EnemyType.SPIKEMAN:     return 6.0
		EnemyType.SPIKEBALL:    return 14.0
		EnemyType.SPRINGMAN:    return 3.0
		EnemyType.SUN:          return 5.0
		EnemyType.CLOUD:        return 3.0
		EnemyType.BARNACLE:     return 5.0
		EnemyType.BEE:          return 10.0
		EnemyType.FLY:          return 9.0
		EnemyType.FROG:         return 6.0
		EnemyType.MOUSE:        return 10.0
		EnemyType.SLIME_BLOCK:  return 4.0
		EnemyType.SLIME_BLUE:   return 6.0
		EnemyType.SLIME_GREEN:  return 6.0
		EnemyType.SLIME_PURPLE: return 6.0
		EnemyType.SLIME_FIRE:   return 6.5
		EnemyType.SNAIL:        return 4.0
		EnemyType.WORM_GREEN:   return 7.0
		EnemyType.WORM_PINK:    return 7.0
		EnemyType.LADYBUG:      return 8.0
		EnemyType.SPIDER:       return 9.0
		EnemyType.GHOST:        return 5.0
		EnemyType.UFO:          return 6.0
		EnemyType.ALIEN_GREEN:  return 8.0
		EnemyType.ALIEN_BLUE:   return 9.0
		EnemyType.ALIEN_PINK:   return 7.0
		EnemyType.ALIEN_YELLOW: return 10.0
		_:                      return 8.0


func _load_effect_texture(etype: int) -> void:
	if _is_headless: return
	match etype:
		EnemyType.SUN:
			if is_instance_valid(_effect_spr): _effect_spr.texture = _TEX_LIGHTNING_Y
		EnemyType.WINGMAN:
			if is_instance_valid(_effect_spr): _effect_spr.texture = _TEX_LIGHTNING_B
		EnemyType.CLOUD:
			if is_instance_valid(_effect_spr): _effect_spr.texture = _TEX_SMOKE


# ══════════════════════════════════════════════════════════════════════
#  SETUP
# ══════════════════════════════════════════════════════════════════════
# Cached solid-color textures — built once per enemy instance after _vw/_vh are known
var _tex_rain      : ImageTexture = null
var _tex_ice       : ImageTexture = null
var _tex_blob      : ImageTexture = null
var _tex_cloud_atk : ImageTexture = null
var _tex_mini      : ImageTexture = null
var _tex_puff      : ImageTexture = null
var _tex_dirt      : ImageTexture = null

func _make_solid_tex(color: Color, w: int, h: int) -> ImageTexture:
	var img := Image.create(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

func _make_circle_tex(color: Color, size: int) -> ImageTexture:
	var s    := maxi(size, 2)
	var img  := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx   := s * 0.5
	var cy   := s * 0.5
	var r    := s * 0.5 - 0.5
	var rim  := r - 1.5  # soft inner edge for anti-alias look
	var shine_color := Color(
		minf(color.r + 0.35, 1.0),
		minf(color.g + 0.35, 1.0),
		minf(color.b + 0.35, 1.0),
		color.a)
	for y in s:
		for x in s:
			var dx := x - cx + 0.5
			var dy := y - cy + 0.5
			var d  := sqrt(dx * dx + dy * dy)
			if d <= r:
				# Lerp between shine (top-left) and base color
				var t := clampf((dy + dx * 0.5) / (r * 1.5) * 0.5 + 0.5, 0.0, 1.0)
				var c := shine_color.lerp(color, t)
				# Soft edge
				if d > rim:
					c.a *= 1.0 - (d - rim) / (r - rim)
				img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

func _init_tex_cache() -> void:
	_tex_rain      = _make_solid_tex(Color(0.4, 0.7, 1.0, 0.8),   int(_vw * 0.006) + 1, int(_vh * 0.02) + 1)
	_tex_ice       = _make_circle_tex(Color(0.4, 0.75, 1.0, 0.85),  int(_vw * 0.117))
	_tex_blob      = _make_circle_tex(Color(0.2, 0.85, 0.15, 0.95), int(_vw * 0.023))
	_tex_cloud_atk = _make_circle_tex(Color(0.15, 0.75, 0.1, 0.7),  int(_vw * 0.133))
	_tex_mini      = _make_circle_tex(Color(0.65, 0.2, 0.9, 0.95),  int(_vw * 0.033))
	_tex_puff      = _make_circle_tex(Color(0.6, 0.4, 0.15, 0.85),  int(_vw * 0.023))
	_tex_dirt      = _make_circle_tex(Color(0.55, 0.35, 0.12, 1.0), int(_vw * 0.040))
	_init_projectile_pools()

# ── PROJECTILE POOL HELPERS (EN-11) ───────────────────────────────────────────

## Pre-allocates pool nodes and hides them. Called once from _init_tex_cache.
func _init_projectile_pools() -> void:
	var parent := get_parent()
	if not parent: return
	_pool_rain      = _build_pool(_POOL_SIZE_RAIN,      "rect",   _tex_rain,      8)
	_pool_ice       = _build_pool(_POOL_SIZE_ICE,       "circle", _tex_ice,       8)
	_pool_blob      = _build_pool(_POOL_SIZE_BLOB,      "circle", _tex_blob,      8)
	_pool_cloud_atk = _build_pool(_POOL_SIZE_CLOUD_ATK, "circle", _tex_cloud_atk, 8)
	_pool_mini      = _build_pool(_POOL_SIZE_MINI,      "circle", _tex_mini,      4)
	_pool_dirt      = _build_pool(_POOL_SIZE_DIRT,      "rect",   _tex_dirt,      8)

func _build_pool(count: int, shape_type: String, tex: Texture2D, layer: int) -> Array:
	var parent := get_parent()
	var result : Array = []
	for _i in count:
		var node := Area2D.new()
		node.collision_layer = layer
		node.collision_mask  = 1
		var cs := CollisionShape2D.new()
		if shape_type == "circle":
			cs.shape = CircleShape2D.new()
		else:
			cs.shape = RectangleShape2D.new()
		node.add_child(cs)
		var vis := Sprite2D.new()
		vis.texture = tex
		vis.z_index  = 2
		node.add_child(vis)
		node.visible = false
		cs.disabled  = true
		parent.add_child(node)
		result.append({"node": node, "cs": cs, "vis": vis, "active": false})
	return result

## Returns a free pool slot, or null if all slots are in use (caller falls back to new()).
func _pool_acquire(pool: Array) -> Dictionary:
	for entry in pool:
		if not entry["active"] and is_instance_valid(entry["node"]):
			entry["active"] = true
			entry["node"].visible  = true
			entry["cs"].disabled   = false
			entry["node"].modulate = Color.WHITE
			return entry
	return {}

## Returns a node to its pool — call instead of queue_free() on pooled projectiles.
func _pool_release(entry: Dictionary) -> void:
	if entry.is_empty(): return
	entry["active"] = false
	if is_instance_valid(entry["node"]):
		entry["node"].visible = false
		entry["cs"].disabled  = true
		for tw in entry["node"].get_meta("_tweens", []):
			if tw and tw.is_valid(): tw.kill()
		entry["node"].set_meta("_tweens", [])

## Helper — store a tween ref on a node so _pool_release can kill it.
func _pool_track_tween(entry: Dictionary, tw: Tween) -> void:
	if entry.is_empty() or not is_instance_valid(entry["node"]): return
	var list : Array = entry["node"].get_meta("_tweens", [])
	list.append(tw)
	entry["node"].set_meta("_tweens", list)

func _biome_particle_tex() -> Texture2D:
	var s : int = int(_gm_ref.get("score")) if is_instance_valid(_gm_ref) else 0
	var slot := (maxi(s, 0) / 500) % 4
	match slot:
		0: return _TEX_PARTICLE_GREEN
		1: return _TEX_PARTICLE_GREY
		2: return _TEX_PARTICLE_BEIGE
		_: return _TEX_PARTICLE_BLUE

# EN-11: free pool nodes when this enemy is removed from the tree
func _exit_tree() -> void:
	for pool in [_pool_rain, _pool_ice, _pool_blob, _pool_cloud_atk, _pool_mini, _pool_dirt]:
		for entry in pool:
			if is_instance_valid(entry.get("node")):
				entry["node"].queue_free()

func setup(etype: int, anim_frames: Dictionary, diff: float = 0.0, worm_is_baby: bool = false) -> void:
	if etype == EnemyType.WORM_GREEN or etype == EnemyType.WORM_PINK:
		_worm_is_baby     = worm_is_baby
		_worm_baby_frames = anim_frames

	can_fly = _can_fly_for(etype)  # ← FIX: floating-in-air bug resolved with this
	base_setup(etype, anim_frames, diff)


func _special_setup() -> void:
	# NOTE: headless early-return removed — all AI state must be initialized identically
	# in both graphical and headless modes so that simulate_tick() produces the same result.
	# Only _anim.* calls are guarded individually below.

	# Cache computed constants (EN-04: avoid per-access multiplication)
	WINGMAN_CHASE_RANGE = _vw * 0.30
	WINGMAN_CHASE_SPEED = _vw * 0.38
	SPIKEMAN_DETECT_X   = _vw * 0.20
	SPIKEMAN_CHASE_SPEED= _vw * 0.28
	SPIKEBALL_AMPLITUDE = _vh * 0.07
	SUN_AMPLITUDE       = _vh * 0.08
	CLOUD_FOLLOW_SPEED  = _vw * 0.46
	CLOUD_RAIN_RANGE_X  = _vw * 0.06
	BEE_AGGRO_RANGE     = _vw * 0.25
	BEE_CHASE_SPEED     = _vw * 0.55
	BEE_RETURN_SPEED    = _vw * 0.5
	FLY_AGGRO_RANGE     = _vw * 0.28
	FLY_CHASE_SPEED     = _vw * 0.48
	MOUSE_AGGRO_RANGE   = _vw * 0.22
	MOUSE_CHASE_SPEED   = _vw * 0.42
	FROG_DETECT_X       = _vw * 0.20
	FROG_DETECT_Y       = _vh * 0.25
	FROG_JUMP_HEIGHT    = -_vh * 0.18
	FROG_JUMP_DIST      = _vw * 0.12
	SLIME_FIRE_DETECT   = _vw * 0.22
	SPIDER_AGGRO_RANGE  = _vw * 0.20
	GHOST_DETECT_RANGE  = _vw * 0.28
	GHOST_CHASE_SPEED   = _vw * 0.30
	WORM_DIRT_RANGE     = _vw * 0.233
	WORM_DIRT_SPEED_X   = _vw * 0.15
	WORM_DIRT_SPEED_Y   = -_vh * 0.40
	WORM_DIRT_GRAVITY   = _vh * 0.75

	# Cache platform collision shape once (EN-01)
	if is_instance_valid(_platform):
		_platform_cs = _platform.get_node_or_null("CollisionShape2D")

	if not _is_headless:
		_init_tex_cache()
	var headless := _is_headless
	var sf : SpriteFrames = null
	if not headless and is_instance_valid(_anim):
		sf = _anim.sprite_frames

	match enemy_type:
		EnemyType.FLYMAN:
			# Unkillable — damages on contact. Patrols left-right in the air.
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol()
			_start_vertical_bob()

		EnemyType.WINGMAN:
			# Chases in range, patrols outside
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_wingman_chasing = false
			_start_patrol(0.9)
			_start_vertical_bob(10.0, 1.8)

		EnemyType.SPIKEMAN:
			# Patrol + X-tracks player when above — unkillable
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol()

		EnemyType.SPIKEBALL:
			# Vertical up-down
			if sf: _anim.play(sf.get_animation_names()[0])
			z_index = 5
			_start_y = global_position.y
			_start_vertical_bob(SPIKEBALL_AMPLITUDE, SPIKEBALL_PERIOD)

		EnemyType.SPRINGMAN:
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])

		EnemyType.SUN:
			# Vertical up-down (like spikeball)
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_y = global_position.y
			_start_vertical_bob(SUN_AMPLITUDE, SUN_PERIOD)

		EnemyType.CLOUD:
			# Hovers above the player, rain damage
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_cloud_rain_timer = _rng_range(1.0, CLOUD_RAIN_CD)
			can_fly = true

		EnemyType.BARNACLE:
			# 50% top, 50% bottom of platform
			_barnacle_flipped = _rng_range(0.0, 1.0) < 0.5
			if _barnacle_flipped:
				if not headless and is_instance_valid(_anim): _anim.flip_v = true
				scale.y      = -1.0
				if is_instance_valid(_platform):
					var ps := _platform.get_node_or_null("CollisionShape2D")
					if ps and ps.shape:
						global_position.y = _platform.global_position.y + ps.shape.size.y * 0.5 + _vw * 0.03
			if sf:
				var anim_name := "attack" if sf.has_animation("attack") else ("idle" if sf.has_animation("idle") else sf.get_animation_names()[0])
				_anim.play(anim_name)
			_snap_disabled      = true
			_barnacle_attack_cd = _rng_range(0.5, BARNACLE_ATTACK_INTERVAL)

		EnemyType.BEE:
			# Patrol + chases and stings when player enters range
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_bee_home_pos    = global_position
			_bee_chasing     = false
			_bee_returning   = false
			_bee_sting_timer = 0.0
			_start_patrol(1.0)
			_start_vertical_bob(8.0, 1.2)

		EnemyType.FLY:
			# Chases until dead once player enters range
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_fly_home_pos = global_position
			_fly_aggro    = false
			_start_patrol(1.0)
			_start_vertical_bob(8.0, 1.4)

		EnemyType.FROG:
			# Moves by jumping, leaps toward the player
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_frog_jumping       = false
			_frog_jump_cd       = _rng_range(1.5, 2.5)
			_frog_home_platform = _platform
			_frog_cur_platform  = _platform
			_frog_gm            = get_parent()   # GameManager
			if not headless and is_instance_valid(_anim): _anim.flip_h = _start_x > _vw * 0.5

		EnemyType.MOUSE:
			# Fast patrol, walks toward the player
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_mouse_chasing  = false
			_mouse_chase_cd = 0.0
			_start_patrol(MOUSE_PATROL_SPEED)

		EnemyType.SLIME_BLOCK:
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])

		EnemyType.SLIME_BLUE, EnemyType.SLIME_GREEN, EnemyType.SLIME_PURPLE, EnemyType.SLIME_FIRE:
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol_from(global_position.x, 0.6)
			_slime_attack_cd = _rng_range(2.0, 4.0)

		EnemyType.SNAIL:
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(0.35, true)

		EnemyType.WORM_GREEN, EnemyType.WORM_PINK:
			_worm_dirt_timer = _rng_range(1.0, WORM_DIRT_COOLDOWN)
			var spd := WORM_BABY_PATROL_SPD if _worm_is_baby else 0.8
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			if _worm_is_baby:
				if not headless and is_instance_valid(_anim): _anim.scale = _anim.scale * WORM_BABY_SCALE
				_col.scale = Vector2(WORM_BABY_SCALE, WORM_BABY_SCALE)
			_start_patrol_from(global_position.x, spd)

		EnemyType.LADYBUG:
			_ladybug_is_resting = false
			_ladybug_rest_timer = _rng_range(3.0, 5.0)
			can_fly = true
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(1.2)
			_start_vertical_bob(10.0, 1.3)

		EnemyType.SPIDER:
			can_fly = false
			_spider_burst_active = false
			_spider_burst_timer  = 0.0
			_spider_burst_cd     = 0.0
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(1.4)

		EnemyType.GHOST:
			can_fly = true
			_ghost_chasing     = false
			_ghost_chase_timer = 0.0
			_ghost_fade_timer  = 0.0
			_ghost_visible     = true
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(0.9)
			_start_vertical_bob(12.0, 2.2)

		EnemyType.UFO:
			UFO_HOVER_SPEED = _vw * 0.0027
			UFO_HOVER_RANGE = _vw * 0.30
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(UFO_HOVER_SPEED)
			_start_vertical_bob(_vh * 0.025, 3.5)
			_ufo_fire_timer = _rng.randf_range(UFO_FIRE_INTERVAL_MIN, UFO_FIRE_INTERVAL_MAX)
			_ufo_firing     = false
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 1.3

		EnemyType.ALIEN_GREEN:
			ALIEN_SPEED = _vw * lerpf(0.0008, 0.0015, difficulty)
			_frog_cur_platform = _platform
			_frog_gm           = get_parent()
			_alien_jump_timer  = _rng.randf_range(ALIEN_JUMP_INTERVAL, ALIEN_JUMP_INTERVAL * 1.5)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25
				if is_instance_valid(_col): _col.position.y = _vw * 0.06

		EnemyType.ALIEN_BLUE:
			ALIEN_SPEED = _vw * lerpf(0.0006, 0.0012, difficulty)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25
				if is_instance_valid(_col): _col.position.y = _vw * 0.06

		EnemyType.ALIEN_PINK:
			ALIEN_SPEED = _vw * 0.0006
			_alien_shoot_timer = _rng.randf_range(2.0, ALIEN_SHOOT_INTERVAL)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25
				if is_instance_valid(_col): _col.position.y = _vw * 0.06

		EnemyType.ALIEN_YELLOW:
			ALIEN_SPEED = _vw * lerpf(0.0012, 0.002, difficulty)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25
				if is_instance_valid(_col): _col.position.y = _vw * 0.06


# ══════════════════════════════════════════════════════════════════════
#  SPECIAL HIT — tüm tip çarpışmaları
# ══════════════════════════════════════════════════════════════════════
func _special_hit(body: Node, stomped: bool, powered: bool) -> bool:
	var has_wings : bool = powered and body.powerup_type == "wings"

	match enemy_type:
		EnemyType.GHOST:
			if not _ghost_visible:
				return true

		EnemyType.SNAIL:
			if _in_shell:
				# Kabuktayken dokunulamaz — stomp da yandan da sek
				if stomped:
					body.velocity.y = -_vh * 0.40
				return true
			if stomped:
				# Dışarıdayken üstüne zıplandı — 1 can git, kabuğa gir
				_hp -= 1
				body.velocity.y = -_vh * 0.40
				if _hp <= 0:
					_die()
				else:
					_in_shell = true
					_shell_timer = 3.0
					_move_cancel()
					_stop_patrol()
					var sf := _anim.sprite_frames
					if sf.has_animation("shell"):
						_anim.play("shell")
					elif sf.has_animation("idle"):
						_anim_play("idle")
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.FLYMAN:
			if not powered:
				body.hit_enemy()
			return true

		EnemyType.WINGMAN, EnemyType.BEE, EnemyType.FLY, EnemyType.LADYBUG:
			if has_wings:
				return true
			if stomped:
				body.velocity.y = -_vh * 0.525
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.SLIME_BLOCK:
			if stomped:
				body.velocity.y = -_vh * 2.025
				var squish := _make_tween()
				if squish:
					squish.tween_property(_anim, "scale", _anim.scale * Vector2(1.4, 0.6), 0.07)
					squish.tween_property(_anim, "scale", _anim.scale, 0.12).set_trans(Tween.TRANS_ELASTIC)
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.SPIKEMAN:
			if not powered:
				body.hit_enemy()
			return true

		EnemyType.SLIME_BLUE, EnemyType.SLIME_PURPLE:
			if stomped:
				body.velocity.y = -_vh * 0.475
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.SLIME_GREEN:
			if stomped:
				body.velocity.y = -380.0
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.SLIME_FIRE:
			if stomped:
				body.velocity.y = -380.0
				if _anim.sprite_frames.has_animation("flat"):
					_anim.play("flat")
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.SPIKEBALL, EnemyType.SUN:
			if not powered: body.hit_enemy()
			return true

		EnemyType.SPRINGMAN:
			if stomped:
				body.velocity.y = -_vh * 1.60
				var sf2 := _anim.sprite_frames
				if sf2 and sf2.has_animation("hurt"):
					_anim.play("hurt")
					var tw := _make_tween()
					if tw:
						tw.tween_interval(0.35)
						tw.tween_callback(func():
							if is_instance_valid(_anim):
								if sf2.has_animation("stand"):
									_anim.play("stand")
								elif sf2.has_animation("idle"):
									_anim_play("idle")
						)
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.BARNACLE:
			if not powered:
				body.hit_enemy()
			return true

		EnemyType.CLOUD:
			if stomped:
				body.velocity.y = -_vh * 0.50
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.FROG, EnemyType.MOUSE:
			if stomped or powered:
				body.velocity.y = -_vh * 0.50
				_die()
			else:
				body.hit_enemy()
			return true

		EnemyType.WORM_GREEN, EnemyType.WORM_PINK:
			if stomped:
				body.velocity.y = -_vh * 0.475
				_die()
			elif not powered:
				body.hit_enemy()
			return true

		EnemyType.ALIEN_GREEN, EnemyType.ALIEN_BLUE, EnemyType.ALIEN_PINK, EnemyType.ALIEN_YELLOW:
			if stomped:
				body.velocity.y = -_vh * 0.5
				_die()
				return true
			# Yan çarpışma: zararsız
			return true

	return false


# ══════════════════════════════════════════════════════════════════════
#  SPECIAL PROCESS — AI dispatch
# ══════════════════════════════════════════════════════════════════════
func _special_process(delta: float) -> void:
	# NOTE: headless early-return removed — AI must run identically in headless mode
	match enemy_type:
		EnemyType.FLYMAN:    _flyman_ai(delta)
		EnemyType.WINGMAN:   _wingman_ai(delta)
		EnemyType.SPIKEMAN:  _spikeman_ai(delta)   # clamp handled in simulate_tick
		EnemyType.SPIKEBALL: pass   # started in vertical bob setup, runs automatically
		EnemyType.SPRINGMAN: pass   # stands still and bounces, collision handled in _special_hit
		EnemyType.SUN:       pass   # started in vertical bob setup
		EnemyType.CLOUD:     _cloud_ai(delta)
		EnemyType.BARNACLE:  _barnacle_ai(delta)
		EnemyType.BEE:       _bee_ai(delta)
		EnemyType.FLY:       _fly_ai(delta)
		EnemyType.FROG:      _frog_ai(delta)
		EnemyType.MOUSE:     _mouse_ai(delta)      # clamp handled in simulate_tick
		EnemyType.SNAIL:     _snail_ai(delta)
		EnemyType.SLIME_BLUE, EnemyType.SLIME_GREEN, EnemyType.SLIME_PURPLE, EnemyType.SLIME_FIRE:
			_slime_ai(delta)
			if is_instance_valid(_platform_cs) and _platform_cs.shape:
				var _lec : Vector2 = _platform_cs.to_global(Vector2(-_platform_cs.shape.size.x * 0.5, 0.0))
				var _rec : Vector2 = _platform_cs.to_global(Vector2( _platform_cs.shape.size.x * 0.5, 0.0))
				global_position.x = clampf(global_position.x, _lec.x + 1.0, _rec.x - 1.0)
		EnemyType.WORM_GREEN, EnemyType.WORM_PINK:
			_worm_ai(delta)
		EnemyType.LADYBUG:
			_ladybug_ai(delta)
		EnemyType.SPIDER:    _spider_ai(delta)     # clamp handled in simulate_tick
		EnemyType.GHOST:
			_ghost_ai(delta)
		EnemyType.UFO:
			_ufo_ai(delta)
		EnemyType.ALIEN_GREEN:
			_alien_green_ai(delta)
		EnemyType.ALIEN_BLUE, EnemyType.ALIEN_YELLOW:
			pass  # sadece patrol
		EnemyType.ALIEN_PINK:
			_alien_pink_ai(delta)


# ══════════════════════════════════════════════════════════════════════
#  FLYMAN AI — aerial patrol + bob, unkillable
# ══════════════════════════════════════════════════════════════════════
func _flyman_ai(_delta: float) -> void:
	# Patrol and bob started in setup, tick_patrol and tick_bob are running
	# Nothing extra here — contact is handled in _special_hit
	pass


# ══════════════════════════════════════════════════════════════════════
#  WINGMAN AI — chases player in range, static patrol outside range
# ══════════════════════════════════════════════════════════════════════
func _wingman_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if not p: return
	var dist_sq : float = global_position.distance_squared_to(p.global_position)
	var chase_sq : float = WINGMAN_CHASE_RANGE * WINGMAN_CHASE_RANGE

	if not _wingman_chasing:
		if dist_sq < chase_sq:
			_wingman_chasing = true
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()
	else:
		# Full 2D chase — bob is stopped on aggro so no Y conflict
		var dir : Vector2 = (p.global_position - global_position).normalized()
		if is_instance_valid(_anim):
			_anim_flip(dir.x)
		global_position = global_position.move_toward(p.global_position, WINGMAN_CHASE_SPEED * FIXED_DELTA)
		# Out of range — return to start
		if dist_sq > chase_sq * 1.69:
			_wingman_chasing = false
			_move_cancel()
			_move_to(Vector2(global_position.x, _start_y), 0.5, false, true, false, func():
				_start_patrol_from(global_position.x, 0.9, true)
				_start_vertical_bob(10.0, 1.8)
			)


# ══════════════════════════════════════════════════════════════════════
#  GROUND CHASER — shared AI for spider / mouse / spikeman
# ══════════════════════════════════════════════════════════════════════
# Behaviour (identical for all three, only the numbers differ):
#   • Default: patrol left↔right across the platform forever.
#   • When the player is on the SAME level and within aggro_range, stop
#     patrolling and walk toward the player at chase_speed.
#   • The enemy is hard-clamped to its own platform every tick, so it can
#     NEVER leave the platform — at the edge it simply stops and waits.
#   • When the player leaves range (or moves to another level), resume patrol.
#
# Returns nothing; drives global_position directly. `chasing_flag` is the
# per-enemy bool that remembers whether we are currently chasing, passed by
# the caller via a small wrapper so each enemy keeps its own state var.
# Plays the right anim while chasing. `resting` = standing still at the edge:
# show "idle" if the enemy has one, otherwise just pause the walk animation on a
# single frame so it doesn't look like it's running on the spot.
func _play_idle_or_walk(resting: bool) -> void:
	if not is_instance_valid(_anim): return
	var sf := _anim.sprite_frames
	if not sf: return
	if resting:
		if sf.has_animation("idle"):
			_anim_play("idle")
		elif _anim.is_playing():
			_anim.pause()   # freeze the walk cycle in place
	else:
		if sf.has_animation("walk"):
			if _anim.animation != "walk" or not _anim.is_playing():
				_anim.play("walk")
		elif not _anim.is_playing():
			_anim.play()


func _ground_chase_step(aggro_range: float, chase_speed: float,
		patrol_speed: float, was_chasing: bool) -> bool:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	# Platform edges — always valid (live → cache → viewport).
	var b : Vector2 = _get_plat_bounds()
	var edge_margin : float = _vw * 0.04
	var left_x  : float = b.x + edge_margin
	var right_x : float = b.y - edge_margin

	if not p:
		if not _patrol_active:
			_start_patrol_from(global_position.x, patrol_speed, true)
		return false

	var dx : float = p.global_position.x - global_position.x
	var dy : float = p.global_position.y - global_position.y
	var dist : float = abs(dx)
	# "On the same platform level" — roughly the same height as the enemy.
	var same_level : bool = abs(dy) < _vh * 0.10
	# The player counts as reachable only if it's on our level AND in range.
	var in_aggro : bool = same_level and dist < aggro_range

	if in_aggro:
		# CHASE: step toward the player, clamped inside the platform.
		_stop_patrol()
		var dir : float = signf(dx)
		if dir == 0.0: dir = 1.0
		# At the platform edge in the player's direction? Then the enemy can't get
		# any closer — it just stands there (the player is out over the gap). Stop
		# moving and switch to idle instead of shuffling in place at the corner.
		var at_left_edge  : bool = dir < 0.0 and global_position.x <= left_x + 0.5
		var at_right_edge : bool = dir > 0.0 and global_position.x >= right_x - 0.5
		if at_left_edge or at_right_edge:
			global_position.x = clampf(global_position.x, left_x, right_x)
			if is_instance_valid(_anim):
				_anim_flip(dx)   # keep facing the player
				_play_idle_or_walk(true)
			return true
		var new_x : float = global_position.x + dir * chase_speed * FIXED_DELTA
		new_x = clampf(new_x, left_x, right_x)
		global_position.x = new_x
		if is_instance_valid(_anim):
			_anim_flip(dx)
			_play_idle_or_walk(false)
		return true

	# NOT in range — make sure we are patrolling. If we were chasing, resume
	# patrol from the current spot so the turn is smooth.
	if not _patrol_active:
		_start_patrol_from(global_position.x, patrol_speed, true)
		# Re-start the walk animation in case it was paused at an edge while chasing.
		if was_chasing:
			_play_idle_or_walk(false)
	return false


# ══════════════════════════════════════════════════════════════════════
#  SPIKEMAN AI — patrol + chase player on the same platform (unkillable)
# ══════════════════════════════════════════════════════════════════════
func _spikeman_ai(_delta: float) -> void:
	_ground_chase_step(SPIKEMAN_DETECT_X, SPIKEMAN_CHASE_SPEED, 1.0, false)


# ══════════════════════════════════════════════════════════════════════
#  CLOUD AI — hover above the player, deal rain damage when below
# ══════════════════════════════════════════════════════════════════════
func _cloud_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if not p: return

	var dx : float = p.global_position.x - global_position.x
	var dy : float = p.global_position.y - global_position.y

	# X: follow player slowly
	var target_x : float = global_position.x + signf(dx) * minf(abs(dx), CLOUD_FOLLOW_SPEED * FIXED_DELTA)
	global_position.x = target_x

	# Y: try to stay above player — target is player.y - hover_offset
	# Move upward slowly so player ends up below the cloud
	var hover_offset : float = _vh * 0.12   # how far above player to hover
	var target_y : float = p.global_position.y - hover_offset
	var y_speed  : float = CLOUD_FOLLOW_SPEED * 0.825 * FIXED_DELTA
	if global_position.y > target_y:
		# Cloud is below target — move up
		global_position.y = maxf(global_position.y - y_speed, target_y)
	elif global_position.y < target_y - _vh * 0.04:
		# Cloud drifted too far up — drift back down very slowly
		global_position.y = minf(global_position.y + y_speed * 0.3, target_y)

	# Direction animation
	if is_instance_valid(_anim) and abs(dx) > 2.0:
		_anim_flip(dx)

	# Rain: player is below us (dy > 0) and close on X
	_cloud_rain_timer = maxf(0.0, _cloud_rain_timer - FIXED_DELTA)
	if dy > 0.0 and abs(p.global_position.x - global_position.x) < CLOUD_RAIN_RANGE_X and _cloud_rain_timer <= 0.0:
		_cloud_spawn_rain()
		_cloud_rain_timer = CLOUD_RAIN_CD


func _cloud_spawn_rain() -> void:
	# NOTE: do NOT early-return on headless before this. _rng_range() must be
	# consumed in both modes so the RNG state stays in sync with the recording
	# (same bug class as _slime_ai — see note there). Only the visual raindrop
	# node creation below is skipped in headless.
	var drop_x_offset := _rng_range(-_vw * 0.02, _vw * 0.02)
	if _is_headless: return
	var parent := get_parent()
	if not parent: return

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_rain)
	if entry.is_empty():
		return  # pool exhausted (size=1, prev drop still flying) — skip this tick
	var drop : Area2D        = entry["node"]
	var cs   : CollisionShape2D = entry["cs"]
	var vis  : Sprite2D      = entry["vis"]

	(cs.shape as RectangleShape2D).size = Vector2(_vw * 0.006, _vh * 0.02)
	vis.texture = _tex_rain if _tex_rain else _make_solid_tex(Color(0.4, 0.7, 1.0, 0.8), int(_vw * 0.006) + 1, int(_vh * 0.02) + 1)
	drop.global_position = global_position + Vector2(drop_x_offset, _vh * 0.02)
	_cloud_rain_node = drop
	_gm_ref.call("_register_interactable", drop, "rain_damage", {"one_shot": true})
	var tw := drop.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if tw:
		_pool_track_tween(entry, tw)
		tw.tween_property(drop, "global_position:y",
			drop.global_position.y + _vh * 0.25, 0.5).set_trans(Tween.TRANS_LINEAR)
		tw.tween_callback(func(): _pool_release(entry))


# ══════════════════════════════════════════════════════════════════════
#  BARNACLE AI — periodic attack animation, contact damage
# ══════════════════════════════════════════════════════════════════════
func _barnacle_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	_barnacle_attack_cd = maxf(0.0, _barnacle_attack_cd - FIXED_DELTA)
	if _barnacle_attack_cd > 0.0: return
	_barnacle_attack_cd = BARNACLE_ATTACK_INTERVAL
	if _is_headless: return  # animation-only, no game state change
	var sf := _anim.sprite_frames
	if sf and sf.has_animation("attack"):
		_anim_play("attack")
		# Return to idle after attack animation ends
		var tw := _make_tween()
		if tw:
			tw.tween_interval(BARNACLE_ATTACK_INTERVAL * 0.6)
			tw.tween_callback(func():
					_anim_play("idle")
			)


# ══════════════════════════════════════════════════════════════════════
#  BEE AI — patrol, chases for BEE_CHASE_DURATION when in range, then returns
# ══════════════════════════════════════════════════════════════════════
func _bee_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	_bee_sting_timer = maxf(0.0, _bee_sting_timer - FIXED_DELTA)

	# RETURNING home — fly back at the bee's own speed (smooth, no teleport).
	if _bee_returning:
		var dir2 : Vector2 = (_bee_home_pos - global_position)
		if is_instance_valid(_anim):
			_anim_flip(dir2.x)
		global_position = global_position.move_toward(_bee_home_pos, BEE_RETURN_SPEED * FIXED_DELTA)
		# Arrived home → resume patrol from home position.
		if global_position.distance_squared_to(_bee_home_pos) < 1.0:
			global_position = _bee_home_pos
			_bee_returning   = false
			_bee_sting_timer = BEE_STING_COOLDOWN
			_start_patrol_from(global_position.x, 1.0, true)
			_start_vertical_bob(8.0, 1.2)
		return

	var p := _get_player()
	if not p: return
	var dist_sq : float = global_position.distance_squared_to(p.global_position)
	var aggro_sq : float = BEE_AGGRO_RANGE * BEE_AGGRO_RANGE

	if _bee_chasing:
		# Full 2D chase — bob is stopped on aggro so no Y conflict
		_bee_chase_timer -= FIXED_DELTA
		var dir : Vector2 = (p.global_position - global_position).normalized()
		if is_instance_valid(_anim):
			_anim_flip(dir.x)
		global_position = global_position.move_toward(p.global_position, BEE_CHASE_SPEED * FIXED_DELTA)
		# Time up or out of range → start flying back home at return speed.
		if _bee_chase_timer <= 0.0 or dist_sq > aggro_sq * 2.25:
			_bee_chasing    = false
			_bee_returning  = true
			_move_cancel()
	else:
		# Patrol — start chasing if player enters range
		if dist_sq <= aggro_sq and _bee_sting_timer <= 0.0:
			_bee_chasing     = true
			_bee_chase_timer = BEE_CHASE_DURATION
			_bee_home_pos    = global_position
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()


# ══════════════════════════════════════════════════════════════════════
#  FLY AI — chases until dead once in range, never returns
# ══════════════════════════════════════════════════════════════════════
func _fly_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if not p: return

	if not _fly_aggro:
		if global_position.distance_squared_to(p.global_position) < FLY_AGGRO_RANGE * FLY_AGGRO_RANGE:
			_fly_aggro = true
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()
			if is_instance_valid(_anim) and _anim.sprite_frames:
				if _anim.sprite_frames.has_animation("fly"):
					_anim.play("fly")
	else:
		# Full 2D chase — bob is stopped on aggro so no Y conflict
		var dir : Vector2 = (p.global_position - global_position).normalized()
		if is_instance_valid(_anim):
			_anim_flip(dir.x)
		global_position = global_position.move_toward(p.global_position, FLY_CHASE_SPEED * FIXED_DELTA)


# ══════════════════════════════════════════════════════════════════════
#  FROG AI — moves by jumping, leaps toward the player
#  Its own platform + 1 above + 1 below = roams across 3 platforms
# ══════════════════════════════════════════════════════════════════════
func _frog_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	if _frog_jumping: return
	_frog_jump_cd = maxf(0.0, _frog_jump_cd - FIXED_DELTA)
	if _frog_jump_cd > 0.0: return

	var p := _get_player()
	if not p: return
	var dx : float = p.global_position.x - global_position.x
	var dy : float = p.global_position.y - global_position.y
	var detected : bool = abs(dx) < FROG_DETECT_X and abs(dy) < FROG_DETECT_Y

	# Find neighbor platforms (home ± 1)
	var neighbors : Array = _frog_get_neighbor_platforms()

	if detected and neighbors.size() > 0:
		# Which platform is the player closest to? Jump there
		var best_plat : Node = _frog_best_platform_toward(p, neighbors)
		if best_plat != null and best_plat != _frog_cur_platform:
			_frog_jump_to_platform(best_plat)
			return
	# Player not detected or on the same platform — jump randomly to a neighbor
	if neighbors.size() > 0:
		var candidates : Array = neighbors.filter(func(pl): return pl != _frog_cur_platform)
		if candidates.is_empty():
			candidates = neighbors
		var target_plat : Node = candidates[_rng.randi() % candidates.size()]
		_frog_jump_to_platform(target_plat)
	else:
		# No neighbors — fall back to short jump on the same platform
		var jump_dir : float = 1.0 if _rng.randf() > 0.5 else -1.0
		if detected: jump_dir = signf(dx)
		_frog_do_jump_same_platform(jump_dir)


# Returns the platforms the frog may hop to: its current platform, plus the
# nearest real platform ABOVE it and the nearest real platform BELOW it that are
# within reach. Chosen by actual world position (not array index) and filtered by
# a max horizontal/vertical reach, so the frog never jumps off toward empty space.
func _frog_get_neighbor_platforms() -> Array:
	if not is_instance_valid(_frog_gm): return []
	var plat_list = _frog_gm.get("_platforms")
	if plat_list == null or plat_list.size() == 0: return []

	# Anchor on the frog's CURRENT platform position (falls back to its own pos).
	var anchor : Vector2 = global_position
	if is_instance_valid(_frog_cur_platform):
		anchor = _frog_cur_platform.global_position
	elif is_instance_valid(_frog_home_platform):
		anchor = _frog_home_platform.global_position

	var max_dx : float = FROG_JUMP_DIST + _vw * 0.30   # how far sideways it can reach
	var max_dy : float = FROG_DETECT_Y + _vh * 0.04    # roughly one platform gap up/down

	var result : Array = []
	var best_up    : Node = null
	var best_down  : Node = null
	var best_up_d  : float = INF
	var best_down_d: float = INF
	for pl in plat_list:
		if not is_instance_valid(pl): continue
		var pdx : float = abs(pl.global_position.x - anchor.x)
		var pdy : float = pl.global_position.y - anchor.y   # +down, -up
		if pdx > max_dx: continue          # too far sideways — unreachable
		if abs(pdy) <= 2.0:
			# This is (essentially) the current platform.
			if not result.has(pl): result.append(pl)
			continue
		if pdy < 0.0 and -pdy <= max_dy and -pdy < best_up_d:
			best_up_d = -pdy; best_up = pl       # nearest reachable platform above
		elif pdy > 0.0 and pdy <= max_dy and pdy < best_down_d:
			best_down_d = pdy; best_down = pl    # nearest reachable platform below
	if is_instance_valid(best_up):   result.append(best_up)
	if is_instance_valid(best_down): result.append(best_down)
	return result


# Select the platform closest to the player
func _frog_best_platform_toward(p: Node, candidates: Array) -> Node:
	var best   : Node  = null
	var best_d : float = 9999.0
	for pl in candidates:
		if not is_instance_valid(pl): continue
		var d : float = abs(pl.global_position.y - p.global_position.y)
		if d < best_d:
			best_d = d
			best   = pl
	return best


# Jump to target platform Y, choose a sensible X point on top of the platform
func _frog_jump_to_platform(target_plat: Node) -> void:
	_frog_jumping  = true
	_frog_jump_cd  = _rng_range(1.2, 2.2)
	_snap_disabled = true
	_move_cancel()

	if is_instance_valid(_anim):
		var sf := _anim.sprite_frames
		if sf and sf.has_animation("walk"):
			_anim_play("walk")

	# X bounds of the target platform
	var ps := target_plat.get_node_or_null("CollisionShape2D")
	var hw : float = 0.0
	if ps and ps.shape:
		hw = ps.shape.size.x * 0.5 * target_plat.scale.x
	var plat_cx : float = target_plat.global_position.x
	var margin  : float = _vw * 0.04
	var land_x  : float = clampf(
		global_position.x + signf(plat_cx - global_position.x) * _vw * 0.08,
		plat_cx - hw + margin,
		plat_cx + hw - margin
	)

	# Platform top Y
	var land_y  : float
	var is_alien := enemy_type in [EnemyType.ALIEN_GREEN, EnemyType.ALIEN_BLUE,
								   EnemyType.ALIEN_PINK, EnemyType.ALIEN_YELLOW]
	var y_gap := _vw * 0.09 if is_alien else _vw * 0.055
	if ps and ps.shape:
		land_y = target_plat.global_position.y - ps.shape.size.y * 0.5 - y_gap
	else:
		land_y = target_plat.global_position.y - y_gap

	_anim_flip(signf(land_x - global_position.x))

	var from_pos  : Vector2 = global_position
	var land_pos  : Vector2 = Vector2(land_x, land_y)
	# Larger platform height difference = higher arc
	var y_diff    : float   = abs(land_pos.y - from_pos.y)
	var arc_extra : float   = clampf(y_diff * 0.5, 0.0, _vh * 0.12)
	var peak_pos  : Vector2 = Vector2(
		(from_pos.x + land_x) * 0.5,
		minf(from_pos.y, land_y) + FROG_JUMP_HEIGHT - arc_extra
	)
	var dist_2d   : float = from_pos.distance_to(land_pos)
	var jump_time : float = clampf(dist_2d / (_vw * 0.55), 0.25, 0.70)

	_move_to(peak_pos, jump_time * 0.5, false, true)
	_move_to(land_pos, jump_time * 0.5, true, false, false, func():
		_frog_cur_platform = target_plat
		_platform          = target_plat
		_snap_disabled     = false
		_frog_jumping      = false
		_snap_dirty        = false
		_snap_target_y     = land_y
		if is_instance_valid(_anim):
			var sf := _anim.sprite_frames
			if is_alien:
				if sf and sf.has_animation("walk"): _anim.play("walk")
				_start_patrol_from(global_position.x, ALIEN_SPEED, false)
			elif sf and sf.has_animation("idle"):
				_anim_play("idle")
	)


# Short jump on the same platform (fallback)
func _frog_platform_clamp(target_x: float) -> float:
	var frog_margin : float = _vw * 0.04
	return _clamp_x_to_platform(target_x, frog_margin)


func _frog_do_jump_same_platform(dir: float) -> void:
	_frog_jumping  = true
	_frog_jump_cd  = _rng_range(1.5, 2.8)
	_snap_disabled = true
	_move_cancel()
	if is_instance_valid(_anim):
		_anim_flip(dir)
		var sf := _anim.sprite_frames
		if sf and sf.has_animation("walk"):
			_anim_play("walk")
	var gpos     : Vector2 = global_position
	var raw_gx   : float   = gpos.x + dir * FROG_JUMP_DIST
	var target_x : float   = _frog_platform_clamp(raw_gx)
	var land_pos : Vector2 = Vector2(target_x, gpos.y)
	var peak_pos : Vector2 = Vector2((gpos.x + target_x) * 0.5, gpos.y + FROG_JUMP_HEIGHT)
	var sp_dist  : float   = abs(target_x - gpos.x)
	var sp_time  : float   = clampf(sp_dist / (_vw * 0.55), 0.20, 0.45)
	_move_to(peak_pos, sp_time * 0.5, false, true)
	_move_to(land_pos, sp_time * 0.5, true, false, false, func():
		_snap_disabled = false
		_frog_jumping  = false
		_snap_dirty    = true
		if is_instance_valid(_anim):
			var sf := _anim.sprite_frames
			if sf and sf.has_animation("idle"):
				_anim_play("idle")
	)


# ══════════════════════════════════════════════════════════════════════
#  MOUSE AI — fast patrol, walks toward the player
# ══════════════════════════════════════════════════════════════════════
func _mouse_ai(_delta: float) -> void:
	# Fast patrol; runs toward the player when on the same platform, never leaves it.
	_mouse_chasing = _ground_chase_step(MOUSE_AGGRO_RANGE, MOUSE_CHASE_SPEED,
		MOUSE_PATROL_SPEED, _mouse_chasing)


# ══════════════════════════════════════════════════════════════════════
#  SLIME_FIRE AI — walk-rest cycle, targets player when spotted
# ══════════════════════════════════════════════════════════════════════
func _slime_fire_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if p:
		var dx : float = abs(p.global_position.x - global_position.x)
		if dx < SLIME_FIRE_DETECT:
			if _slime_fire_resting:
				_slime_fire_resting    = false
				_slime_fire_walk_timer = _rng_range(1.5, 2.5)
			_stop_patrol()
			_move_cancel()
			var dir : float = signf(p.global_position.x - global_position.x)
			var new_x : float = global_position.x + dir * _vw * 0.09 * FIXED_DELTA
			global_position.x = _clamp_x_to_platform(new_x, _vw * 0.02)
			if is_instance_valid(_anim):
				_anim_flip(dir)
			return

	if _slime_fire_resting:
		_slime_fire_rest_timer -= FIXED_DELTA
		if _slime_fire_rest_timer <= 0.0:
			_slime_fire_resting    = false
			_slime_fire_walk_timer = _rng_range(1.5, 2.5)
			_start_patrol_from(global_position.x, 0.5, true)
	else:
		_slime_fire_walk_timer -= FIXED_DELTA
		if _slime_fire_walk_timer <= 0.0:
			_slime_fire_resting    = true
			_slime_fire_rest_timer = _rng_range(1.0, 2.0)
			_stop_patrol()
			_move_cancel()


# ══════════════════════════════════════════════════════════════════════
#  SLIME AI (BLUE, GREEN, PURPLE) — patrol + special attack
# ══════════════════════════════════════════════════════════════════════
func _slime_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	_slime_attack_cd = maxf(0.0, _slime_attack_cd - FIXED_DELTA)
	# NOTE: do NOT early-return on headless here. The RNG calls that reset
	# _slime_attack_cd must run in both modes so the RNG state stays in sync
	# with the recording. Only the visual projectile spawning is skipped below.
	if not _is_headless:
		for _si in range(_slime_nodes.size() - 1, -1, -1):
			if not is_instance_valid(_slime_nodes[_si]): _slime_nodes.remove_at(_si)
	var p := _get_player()
	if not p: return
	if _slime_attack_cd > 0.0: return
	var dist_sq : float = global_position.distance_squared_to(p.global_position)
	match enemy_type:
		EnemyType.SLIME_BLUE:
			var r := _vw * 0.133; if dist_sq < r * r:
				if not _is_headless: _slime_blue_ice_burst(p)
				_slime_attack_cd = _rng_range(3.0, 5.0) * (1.0 - difficulty * 0.2)
		EnemyType.SLIME_GREEN:
			var r := _vw * 0.117; if dist_sq < r * r:
				if not _is_headless: _slime_green_spit(p)
				_slime_attack_cd = _rng_range(4.0, 6.0) * (1.0 - difficulty * 0.2)
		EnemyType.SLIME_PURPLE:
			var r := _vw * 0.167; if dist_sq < r * r:
				if not _is_headless: _slime_purple_spawn_mini(p)
				_slime_attack_cd = _rng_range(4.5, 7.0) * (1.0 - difficulty * 0.3)


func _slime_blue_ice_burst(target: Node) -> void:
	if _is_headless: return
	var parent := get_parent()
	if not parent: return

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_ice)
	if entry.is_empty(): return
	var ice : Area2D         = entry["node"]
	var cs  : CollisionShape2D = entry["cs"]
	var vis : Sprite2D       = entry["vis"]

	(cs.shape as CircleShape2D).radius = _vw * 0.058
	vis.texture = _tex_ice if _tex_ice else _make_solid_tex(Color(0.4, 0.75, 1.0, 0.5), int(_vw * 0.117), int(_vw * 0.117))
	vis.z_index = 1
	vis.scale   = Vector2(0.3, 0.3)
	ice.global_position = target.global_position
	_slime_nodes.append(ice)
	# Slime blue ice burst — visual only, no slow/damage effect
	var tw := ice.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if tw:
		_pool_track_tween(entry, tw)
		tw.tween_property(vis, "scale", Vector2(1.0, 1.0), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(ice, "modulate:a", 0.0, 0.3)
		tw.tween_callback(func(): _pool_release(entry))
	var shake := _make_tween()
	if shake:
		shake.tween_property(_anim, "modulate", Color(0.5, 0.85, 1.5), 0.08)
		shake.tween_property(_anim, "modulate", Color.WHITE, 0.15)


func _slime_green_spit(target: Node) -> void:
	if _is_headless: return
	var parent := get_parent()
	if not parent: return
	var dir: Vector2 = (target.global_position - global_position).normalized()

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_blob)
	if entry.is_empty(): return
	var blob : Area2D          = entry["node"]
	var cs   : CollisionShape2D = entry["cs"]
	var vis  : Sprite2D        = entry["vis"]

	(cs.shape as CircleShape2D).radius = _vw * 0.012
	vis.texture = _biome_particle_tex()
	vis.z_index = 2
	vis.scale   = Vector2(0.33, 0.33)
	blob.global_position = global_position + Vector2(0, -_vh * 0.010)
	var _rtw := blob.create_tween().set_loops()
	_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_rtw.tween_property(vis, "rotation", TAU, 0.6).set_trans(Tween.TRANS_LINEAR)
	_pool_track_tween(entry, _rtw)
	_slime_nodes.append(blob)
	# Register with GameManager AABB system instead of body_entered signal
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", blob, "proj_damage", {"one_shot": true})
	var speed := _vw * 0.25 * (1.0 + difficulty * 0.3)
	var tw := blob.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if tw:
		_pool_track_tween(entry, tw)
		tw.tween_property(blob, "global_position",
			blob.global_position + dir * speed * 1.0, 1.0).set_trans(Tween.TRANS_LINEAR)
		tw.tween_callback(func(): _pool_release(entry))


func _slime_green_death_cloud() -> void:
	if _is_headless: return
	var parent := get_parent()
	if not parent: return

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_cloud_atk)
	if entry.is_empty(): return
	var cloud : Area2D          = entry["node"]
	var cs    : CollisionShape2D = entry["cs"]
	var vis   : Sprite2D        = entry["vis"]

	(cs.shape as CircleShape2D).radius = _vw * 0.067
	vis.texture = _biome_particle_tex()
	vis.z_index = 1
	vis.scale   = Vector2(0.33, 0.33)
	cloud.global_position = global_position
	var _rtw := cloud.create_tween().set_loops()
	_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_rtw.tween_property(vis, "rotation", TAU, 0.8).set_trans(Tween.TRANS_LINEAR)
	_pool_track_tween(entry, _rtw)
	# Register with GameManager AABB system — persistent (one_shot=false), player invincibility prevents spam
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", cloud, "proj_damage", {"one_shot": false})
	var tw := cloud.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if tw:
		_pool_track_tween(entry, tw)
		tw.tween_property(vis, "scale", Vector2(1.3, 1.3), 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_interval(1.5)
		tw.tween_property(cloud, "modulate:a", 0.0, 0.4)
		tw.tween_callback(func(): _pool_release(entry))


func _slime_purple_spawn_mini(target: Node) -> void:
	if _is_headless: return
	var parent := get_parent()
	if not parent: return
	var dir : float = signf(target.global_position.x - global_position.x)

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_mini)
	if entry.is_empty(): return
	var mini : Area2D          = entry["node"]
	var cs   : CollisionShape2D = entry["cs"]
	var vis  : Sprite2D        = entry["vis"]

	(cs.shape as CircleShape2D).radius = _vw * 0.017
	mini.collision_layer = 4
	vis.texture = _biome_particle_tex()
	vis.z_index = 2
	vis.scale   = Vector2(0.33, 0.33)
	mini.global_position = global_position + Vector2(dir * _vw * 0.017, -_vh * 0.00625)
	var _rtw := mini.create_tween().set_loops()
	_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_rtw.tween_property(vis, "rotation", TAU, 0.5).set_trans(Tween.TRANS_LINEAR)
	_pool_track_tween(entry, _rtw)
	_slime_nodes.append(mini)
	# Register with GameManager AABB system
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", mini, "proj_damage", {"one_shot": true})
	var vx  := dir * _vw * 0.183
	var vy  := -_vh * 0.225
	var grv := _vh * 0.475
	var dt  := 0.06
	var tw  := mini.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if not tw:
		_pool_release(entry)
		return
	_pool_track_tween(entry, tw)
	var cur  : Vector2 = mini.global_position
	var cvy  : float   = vy
	for _i in 25:
		cvy += grv * dt
		cur += Vector2(vx * dt, cvy * dt)
		tw.tween_property(mini, "global_position", cur, dt).set_trans(Tween.TRANS_LINEAR)
		if cur.y > global_position.y + _vh * 0.006 and cvy > 0:
			break
	tw.tween_interval(3.0)
	tw.tween_property(mini, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func(): _pool_release(entry))
	var burst := _make_tween()
	if burst:
		burst.tween_property(_anim, "modulate", Color(1.3, 0.5, 1.8), 0.07)
		burst.tween_property(_anim, "modulate", Color.WHITE, 0.15)



# ══════════════════════════════════════════════════════════════════════
#  SNAIL AI
# ══════════════════════════════════════════════════════════════════════
func _snail_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	if _in_shell:
		_shell_timer -= FIXED_DELTA
		if _shell_timer <= 0.0:
			# 3 saniye doldu, kabuktan çık ve yürümeye devam et
			_in_shell = false
			var sf := _anim.sprite_frames
			_anim_play("walk" if sf.has_animation("walk") else sf.get_animation_names()[0])
			_patrol_active = true




# ══════════════════════════════════════════════════════════════════════
#  WORM AI
# ══════════════════════════════════════════════════════════════════════
func _worm_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	for _wi in range(_worm_dirt_nodes.size() - 1, -1, -1):
		if not is_instance_valid(_worm_dirt_nodes[_wi]): _worm_dirt_nodes.remove_at(_wi)
	if _worm_is_baby:
		_tick_patrol(FIXED_DELTA)
		return
	_worm_dirt_timer = maxf(0.0, _worm_dirt_timer - FIXED_DELTA)
	var p := _get_player()
	if not p: return
	if global_position.distance_squared_to(p.global_position) < WORM_DIRT_RANGE * WORM_DIRT_RANGE and _worm_dirt_timer <= 0.0:
		_worm_throw_dirt(p)
		_worm_dirt_timer = WORM_DIRT_COOLDOWN * (1.0 - difficulty * 0.3)


func _worm_throw_dirt(target: Node) -> void:
	var parent := get_parent()
	if not parent: return
	var dir : float = signf(target.global_position.x - global_position.x)
	_anim_flip(dir)
	var shake := _make_tween()
	if shake:
		shake.tween_property(_anim, "position", Vector2(0, -_vh * 0.005), 0.07)
		shake.tween_property(_anim, "position", Vector2.ZERO, 0.07)
	var count := 2 if difficulty > 0.5 else 1
	for i in count:
		var offset_x := dir * _rng_range(_vw * 0.008, _vw * 0.033) * float(i + 1)
		_worm_spawn_dirt_block(parent, dir, offset_x)


func _worm_spawn_dirt_block(parent: Node, dir: float, offset_x: float) -> void:
	if _is_headless: return

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_dirt)
	if entry.is_empty(): return
	var dirt : Area2D          = entry["node"]
	var cs   : CollisionShape2D = entry["cs"]
	var vis  : Sprite2D        = entry["vis"]

	var dsz := int(_vw * 0.020)
	(cs.shape as RectangleShape2D).size = Vector2(dsz, dsz)
	vis.texture = _biome_particle_tex()
	vis.z_index = 2
	vis.scale   = Vector2(0.33, 0.33)
	dirt.global_position = global_position + Vector2(offset_x, -_vh * 0.010)
	var _rtw := dirt.create_tween().set_loops()
	_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_rtw.tween_property(vis, "rotation", TAU, 0.5).set_trans(Tween.TRANS_LINEAR)
	_pool_track_tween(entry, _rtw)
	_worm_dirt_nodes.append(dirt)
	dirt.set_meta("_pool_entry", entry)  # EN-11: stored for external destroy call
	_gm_ref.call("_register_interactable", dirt, "dirt_damage", {"one_shot": true, "enemy": self})
	var vx      : float = dir * WORM_DIRT_SPEED_X * (1.0 + difficulty * 0.3)
	var vy      : float = WORM_DIRT_SPEED_Y
	var gravity : float = WORM_DIRT_GRAVITY
	var steps   : int   = 40
	var dt      : float = 0.05
	var tw := dirt.create_tween()
	if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if not tw:
		_pool_release(entry)
		return
	_pool_track_tween(entry, tw)
	var cur_pos : Vector2 = dirt.global_position
	var cur_vy  : float   = vy
	for _step in steps:
		cur_vy  += gravity * dt
		cur_pos += Vector2(vx * dt, cur_vy * dt)
		tw.tween_property(dirt, "global_position", cur_pos, dt).set_trans(Tween.TRANS_LINEAR)
		if cur_pos.y > global_position.y + _vh * 0.025 and cur_vy > 0:
			tw.tween_callback(func():
				if is_instance_valid(self): _worm_destroy_dirt(dirt, false)
				else: _pool_release(entry))
			break
	tw.tween_callback(func():
		if is_instance_valid(self): _worm_destroy_dirt(dirt, false)
		else: _pool_release(entry))


func _worm_destroy_dirt(dirt: Node, hit: bool) -> void:
	if not is_instance_valid(dirt): return
	var pool_entry : Dictionary = dirt.get_meta("_pool_entry", {})
	var parent := get_parent()
	if parent and hit and !_is_headless:
		var puff := Sprite2D.new()
		puff.texture = _biome_particle_tex()
		puff.z_index = 3
		puff.scale   = Vector2(0.33, 0.33)
		parent.add_child(puff)
		puff.global_position = dirt.global_position
		var tw := puff.create_tween()
		if tw: tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		if tw:
			tw.tween_property(puff, "scale",      Vector2(0.66, 0.66), 0.18)
			tw.parallel().tween_property(puff, "rotation",  TAU,       0.18).set_trans(Tween.TRANS_LINEAR)
			tw.parallel().tween_property(puff, "modulate:a", 0.0,      0.18)
			tw.tween_callback(func():
				if is_instance_valid(puff): puff.queue_free())
	_pool_release(pool_entry)


func _worm_split_and_die(_stomper: Node) -> void:
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	_setup_done = false
	_move_cancel()
	var flash_color := Color(0.4, 1.0, 0.3) if enemy_type == EnemyType.WORM_GREEN else Color(1.0, 0.5, 0.8)
	var flash_tw := _make_tween()
	if flash_tw:
		flash_tw.tween_property(_anim, "modulate", flash_color * 2.0, 0.06)
		flash_tw.tween_property(_anim, "modulate", Color.WHITE, 0.1)
	var gm := get_parent()
	if gm and gm.has_method("apply_camera_shake"):
		gm.apply_camera_shake(4.0, 0.18)
	for offset in [Vector2(-_vw * 0.037, 0), Vector2(_vw * 0.037, 0)]:
		_worm_spawn_baby(offset)
	if is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("hurt"):
			if is_instance_valid(_anim): _anim.play("hurt")
	var tw := _make_tween()
	if tw:
		tw.tween_property(self, "scale", Vector2(1.5, 0.3), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(self, "modulate:a", 0.0, 0.18)
		tw.tween_callback(func():
				queue_free())
	else:
		queue_free()


func _worm_spawn_baby(offset: Vector2) -> void:
	var parent := get_parent()
	if not parent: return
	var baby := Area2D.new()
	baby.set_script(_SCR_ENEMY)
	parent.add_child(baby)
	baby.global_position = global_position + offset
	baby._rng.seed = _rng.randi()
	# Platform ve GM referansını setup'tan ÖNCE ver
	if is_instance_valid(_platform):
		baby._platform = _platform
	baby._gm_ref = _gm_ref
	baby.setup(enemy_type, _worm_baby_frames, minf(difficulty + 0.15, 1.0), true)
	var jump_tw := baby.create_tween()
	if jump_tw: jump_tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if jump_tw:
		jump_tw.tween_property(baby, "global_position:y", baby.global_position.y - _vh * 0.025, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		jump_tw.tween_property(baby, "global_position:y", baby.global_position.y,               0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	baby.modulate = Color(1.0, 1.0, 1.0)



# ── LADYBUG AI ───────────────────────────────────────────────────────
func _ladybug_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if p and p.is_powered_up and p.powerup_type == "wings": return
	_ladybug_rest_timer -= FIXED_DELTA
	if _ladybug_rest_timer <= 0.0:
		var sf = _anim.sprite_frames if is_instance_valid(_anim) else null
		if _ladybug_is_resting:
			_ladybug_is_resting = false
			_ladybug_rest_timer = _rng_range(3.5, 6.0)
			can_fly = true
			if sf and sf.has_animation("fly"):
				_anim_play("fly")
			_start_patrol_from(global_position.x, 1.3, true)
			_start_vertical_bob(10.0, 1.2)
		else:
			# Pick the nearest platform to land on. Previously this required the
			# ladybug to already be horizontally over a platform, so if it bobbed
			# away from every platform's X-range nothing qualified and it never
			# rested. Now we always pick the closest platform by a weighted
			# distance (vertical distance matters more) and fly onto it.
			var _lb_plat : Node2D = null
			var _gm_node := get_parent()
			if is_instance_valid(_gm_node):
				var _plat_list = _gm_node.get("_platforms")
				if _plat_list:
					var best_score : float = INF
					for _pt in _plat_list:
						if not is_instance_valid(_pt): continue
						var _ptcs : CollisionShape2D = _pt.get_node_or_null("CollisionShape2D")
						if not _ptcs or not _ptcs.shape: continue
						var _ple : Vector2 = _ptcs.to_global(Vector2(-_ptcs.shape.size.x * 0.5, 0.0))
						var _pre : Vector2 = _ptcs.to_global(Vector2( _ptcs.shape.size.x * 0.5, 0.0))
						var _pty : float   = _pt.global_position.y - _ptcs.shape.size.y * 0.5
						# Horizontal distance to the platform span (0 if already over it)
						var _hx : float = 0.0
						if global_position.x < _ple.x:   _hx = _ple.x - global_position.x
						elif global_position.x > _pre.x: _hx = global_position.x - _pre.x
						# Weight vertical distance more so it prefers a platform near
						# its current height, but never rejects one outright.
						var score : float = abs(_pty - global_position.y) * 2.0 + _hx
						if score < best_score:
							best_score = score
							_lb_plat = _pt
			# Fall back to the current platform if the list was empty.
			if not is_instance_valid(_lb_plat) and is_instance_valid(_platform):
				_lb_plat = _platform
			if not is_instance_valid(_lb_plat):
				# No platforms at all (shouldn't normally happen) — rest in place
				# instead of spinning a short retry timer forever.
				_ladybug_is_resting = true
				_ladybug_rest_timer = _rng_range(2.0, 3.5)
				_stop_patrol()
				_stop_vertical_bob()
				_move_cancel()
				if sf and sf.has_animation("idle"): _anim_play("idle")
				elif sf and sf.has_animation("rest"): _anim_play("rest")
				return
			var ps2 : CollisionShape2D = _lb_plat.get_node_or_null("CollisionShape2D")
			if not ps2 or not ps2.shape:
				_ladybug_rest_timer = _rng_range(1.0, 2.0)
				return
			_platform = _lb_plat
			_ladybug_is_resting = true
			_ladybug_rest_timer = _rng_range(2.0, 3.5)
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()
			if sf and sf.has_animation("idle"):
				_anim_play("idle")
			elif sf and sf.has_animation("rest"):
				_anim_play("rest")
			# Land exactly on top of platform, clamped to platform bounds
			var land_y : float = _platform.global_position.y - ps2.shape.size.y * 0.5 - _vw * 0.03
			var left_e  : Vector2 = ps2.to_global(Vector2(-ps2.shape.size.x * 0.5, 0.0))
			var right_e : Vector2 = ps2.to_global(Vector2( ps2.shape.size.x * 0.5, 0.0))
			var margin  : float   = _vw * 0.05
			var land_x  : float   = clampf(global_position.x, left_e.x + margin, right_e.x - margin)
			_snap_dirty = true
			_move_to(Vector2(land_x, land_y), 0.25, false, true, false, func():
				can_fly = false
				_snap_dirty = true
			)


# ── SPIDER AI ────────────────────────────────────────────────────────
# Fast patrol; sprints toward the player when spotted, never leaves the platform.
func _spider_ai(_delta: float) -> void:
	# Spider is the fastest grounder: quicker patrol and a higher chase speed
	# give it that "rushes at you" feel, but it's still hard-clamped on-platform.
	_spider_burst_active = _ground_chase_step(SPIDER_AGGRO_RANGE,
		_vw * 0.55, 1.6, _spider_burst_active)


# ── GHOST AI ─────────────────────────────────────────────────────────
# Aerial patrol + fade — chases for GHOST_CHASE_DURATION when player spotted
func _ghost_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	# Fade effect — visual, tick-based counter
	_ghost_fade_timer += FIXED_DELTA
	var half := GHOST_FADE_PERIOD * 0.5
	if _ghost_fade_timer >= GHOST_FADE_PERIOD:
		_ghost_fade_timer = 0.0
		if not _ghost_visible:
			_ghost_visible = true
			var tw := _make_tween()
			if tw: tw.tween_property(self, "modulate:a", 1.0, half * 0.4)
	elif _ghost_fade_timer >= half and _ghost_visible:
		_ghost_visible = false
		var tw := _make_tween()
		if tw: tw.tween_property(self, "modulate:a", 0.15, half * 0.6)

	var p := _get_player()
	if not p: return

	if _ghost_chasing:
		_ghost_chase_timer -= FIXED_DELTA
		var dir : Vector2 = (p.global_position - global_position).normalized()
		_anim_flip(dir.x)
		global_position = global_position.move_toward(p.global_position, GHOST_CHASE_SPEED * FIXED_DELTA)
		# Time's up — return to patrol
		if _ghost_chase_timer <= 0.0:
			_ghost_chasing = false
			_move_cancel()
			_move_to(Vector2(global_position.x, _start_y), 0.5, false, true, false, func():
				_start_patrol_from(global_position.x, 0.9, true)
				_start_vertical_bob(12.0, 2.2)
			)
	else:
		if global_position.distance_squared_to(p.global_position) < GHOST_DETECT_RANGE * GHOST_DETECT_RANGE:
			_ghost_chasing     = true
			_ghost_chase_timer = GHOST_CHASE_DURATION
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()


func _ufo_ai(_delta: float) -> void:
	pass  # sadece patrol


func _alien_green_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	if _frog_jumping: return
	# %30 zıpla, %70 yürümeye devam et
	if _rng.randf() > 0.30: return
	var neighbors : Array = _frog_get_neighbor_platforms()
	if neighbors.is_empty(): return
	var candidates : Array = neighbors.filter(func(pl): return pl != _frog_cur_platform)
	if candidates.is_empty(): candidates = neighbors
	var target_plat : Node = candidates[_rng.randi() % candidates.size()]
	if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("jump"): _anim.play("jump")
	_frog_jump_to_platform(target_plat)


func _alien_blue_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	_alien_jump_timer -= FIXED_DELTA
	if _alien_jump_timer > 0.0: return
	_alien_jump_timer = _rng.randf_range(ALIEN_JUMP_INTERVAL * 0.6, ALIEN_JUMP_INTERVAL)
	var p := _get_player()
	var jump_dir := 1.0
	if is_instance_valid(p):
		jump_dir = signf(p.global_position.x - global_position.x)
		if jump_dir == 0.0: jump_dir = 1.0
	elif is_instance_valid(_anim):
		jump_dir = -1.0 if _anim.flip_h else 1.0
	if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("jump"): _anim.play("jump")
	_stop_patrol()
	var jump_dist := _vw * _rng.randf_range(0.12, 0.22)
	var land_x := global_position.x + jump_dir * jump_dist
	var peak   := Vector2(global_position.x + jump_dir * jump_dist * 0.5,
						  global_position.y - _vh * 0.10)
	var land   := Vector2(land_x, global_position.y)
	_move_to(peak, 0.22, false, true)
	_move_to(land, 0.22, true, false, false, func():
		if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
			if _anim.sprite_frames.has_animation("walk"): _anim.play("walk")
		_start_patrol(ALIEN_SPEED * 0.5)
	)
	_anim_flip(jump_dir)


func _alien_pink_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	if _alien_shooting: return
	_alien_shoot_timer -= FIXED_DELTA
	if _alien_shoot_timer > 0.0: return
	_alien_shoot_timer = _rng.randf_range(ALIEN_SHOOT_INTERVAL * 0.7, ALIEN_SHOOT_INTERVAL * 1.3)
	_alien_shooting = true
	_stop_patrol()
	if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("shoot"): _anim.play("shoot")
	var tw := _make_tween()
	if tw:
		tw.tween_interval(1.2)
		tw.tween_callback(func():
			if not is_instance_valid(self) or _state == "dead": return
			_alien_shooting = false
			if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
				if _anim.sprite_frames.has_animation("walk"): _anim.play("walk")
			_start_patrol_from(global_position.x, ALIEN_SPEED, true)
		)
