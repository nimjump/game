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

# ═══════════════════════════════════════════════════════════════════
#  ★ PLATFORM YÜKSEKLİK AYARI — burayı düzenle ★
#  ---------------------------------------------------------------
#  Her yaratığın platformdan ne kadar yukarıda/gömülü duracağını
#  buradan test edebilirsin. Sayı _vw'nin bir yüzdesi (ekran genişliğinin
#  yüzdesi) olarak girilir. DİKKAT — yön kafa karıştırabilir, dikkatli oku:
#     0.0     → varsayılan boşluk (PLATFORM_STAND_GAP, EnemyBase.gd'de)
#     DAHA NEGATİF yap  → yaratık platforma daha YAKINLAŞIR / GÖMÜLÜR
#                          (yaratık havada duruyorsa, "float" fazlaysa BUNU yap — sayıyı küçült/eksi yap)
#     DAHA POZİTİF yap  → yaratık platformdan daha da UZAKLAŞIR / havada kalır
#                          (yaratık gömülü/platforma batmış görünüyorsa BUNU yap)
#  Yani "yaratık havada duruyor, platforma yapıştırmak istiyorum" dersen
#  değeri AZALT (daha negatif), ARTTIRMA — arttırmak onu platformdan daha
#  da uzaklaştırır (daha çok havada bırakır), tam tersi etki yapar.
#  Değeri değiştirip oyunu Godot editöründen çalıştırarak anında test
#  edebilirsin — build/deploy gerekmez, F5'e basman yeterli.
#  Uçan tipler (FLYMAN/WINGMAN/CLOUD/BEE/FLY/LADYBUG/GHOST/UFO) ve
#  yukarı-aşağı sallanan tipler (SPIKEBALL/SUN) bu ayardan etkilenmez,
#  çünkü onlar zaten platforma "oturmuyor" — havada süzülüyor/sallanıyor.
# ═══════════════════════════════════════════════════════════════════
const PLATFORM_GAP_FIX := {
	EnemyType.FLYMAN:       0.0,
	EnemyType.WINGMAN:      0.0,
	EnemyType.SPIKEMAN:     -0.012,
	EnemyType.SPIKEBALL:    0.0,
	EnemyType.SPRINGMAN:    -0.012,
	EnemyType.SUN:          0.0,
	EnemyType.CLOUD:        0.0,
	EnemyType.BARNACLE:     -0.016,
	EnemyType.BEE:          0.0,
	EnemyType.FLY:          0.0,
	EnemyType.FROG:         -0.016,
	EnemyType.MOUSE:        -0.012,
	EnemyType.SLIME_BLOCK:  -0.012,
	EnemyType.SLIME_BLUE:   -0.016,
	EnemyType.SLIME_GREEN:  -0.016,
	EnemyType.SLIME_PURPLE: -0.016,
	EnemyType.SLIME_FIRE:   -0.012,
	EnemyType.SNAIL:        -0.016,
	EnemyType.WORM_GREEN:   -0.016,
	EnemyType.WORM_PINK:    -0.016,
	EnemyType.LADYBUG:      -0.016,
	EnemyType.SPIDER:       -0.026,
	EnemyType.GHOST:        0.0,
	EnemyType.UFO:          0.0,
	# Alien sprites are scaled to 2.25x (about 9% VW half-height). The
	# override below is an OFFSET added to PLATFORM_STAND_GAP (0.055 VW),
	# so 0.035 produces the intended TOTAL 0.090 VW. Using 0.090 here made
	# the initial snap place aliens 0.145 VW above the platform, while their
	# jump landing code used 0.090 VW — a visible spawn/landing mismatch.
	EnemyType.ALIEN_GREEN:  0.035,
	EnemyType.ALIEN_BLUE:   0.035,
	EnemyType.ALIEN_PINK:   0.035,
	EnemyType.ALIEN_YELLOW: 0.035,
}

# ── FLYMAN ───────────────────────────────────────────────────────────
# Unkillable, damages on contact

# ── WINGMAN ──────────────────────────────────────────────────────────
# Chases the player in range, returns to static patrol when out of range
var WINGMAN_CHASE_RANGE : float = 0.0
var WINGMAN_CHASE_SPEED : float = 0.0
var WINGMAN_RETURN_SPEED : float = 0.0
var _wingman_chasing := false

# ── SPIKEMAN ─────────────────────────────────────────────────────────
# Patrols platform back and forth — unkillable (no longer tracks the player)

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

# Thrown/spat particle attacks stay locked until the score reaches 10,000.
# This is checked from the deterministic GameManager score directly rather
# than _difficulty(), because _difficulty() deliberately caps at 1.0 around
# score 3,000 and therefore cannot represent a 10,000-point threshold.
const RANGED_ATK_MIN_SCORE: int = 10000

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
var MOUSE_PATROL_SPEED := 1.35
var MOUSE_CHASE_SPEED  : float = 0.0
var _mouse_chasing := false
var _mouse_chase_cd := 0.0
# Ara sıra durup etrafı koklama/bakınma — sadece patrol halindeyken tetiklenir
var _mouse_sniff_timer  := 0.0   # bir sonraki bakınmaya kalan süre
var _mouse_sniffing     := false # şu an bakınıyor mu
var _mouse_sniff_dur    := 0.0   # bakınma ne kadar sürecek

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
# Web-climb: spider can shoot a web thread and climb to a platform above/below
# to chase the player across platforms, instead of being stuck on one.
var SPIDER_DETECT_X  : float = 0.0
var SPIDER_DETECT_Y  : float = 0.0
var _spider_climbing := false
var _spider_web_cd    := 0.0
var _spider_web_line  : Line2D = null
# BUG FIX: without this, the very next web-throw decision after landing could
# pick the platform the spider JUST CAME FROM as the new target (only the
# CURRENT platform was excluded, not the previous one) — looking exactly like
# "shoots a web, climbs, then immediately shoots ANOTHER web and climbs right
# back down" since that's often the closest/only reachable vertical neighbor
# right after a jump. Tracked so that platform is excluded for one hop.
var _spider_prev_platform : Node = null
# Web throw: ip önce hedefe tam ulaşır, ÖRÜMCEK O SIRADA HAREKET ETMEZ —
# ip ulaştıktan sonra tırmanma (_spider_climbing) başlar.
var _spider_web_throwing       := false
var _spider_web_throw_elapsed  := 0
var _spider_web_throw_total    := 1
var _spider_web_from           : Vector2 = Vector2.ZERO
var _spider_web_target         : Vector2 = Vector2.ZERO
var _spider_climb_land_pos     : Vector2 = Vector2.ZERO
var _spider_climb_time         : float = 0.0
var _spider_climb_target_plat  : Node = null

# ── GHOST ─────────────────────────────────────────────────────────────
# Flies left-right, chases when spotted, returns if it can't catch the player
var GHOST_DETECT_RANGE : float = 0.0
var GHOST_CHASE_SPEED  : float = 0.0
var GHOST_RETURN_SPEED : float = 0.0
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
var _ufo_damage_cd    := 0.0
var _ufo_laser_sprite: Sprite2D = null
var _ufo_muzzle_sprite: Sprite2D = null
var _ufo_ground_sprite: Sprite2D = null
var _ufo_impact_sprite: Sprite2D = null

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
const ALIEN_SHOOT_INTERVAL := 10.0   # pembe alien: 10 sn'de 1 atış, beam 2 sn kalır
const ALIEN_SHOOT_WARN := 0.4
const ALIEN_LASER_DURATION := 0.45
const ALIEN_LASER_RANGE := 0.42
const ALIEN_LASER_WIDTH := 0.055
var _alien_shooting := false
var _alien_laser_timer: float = 0.0
var _alien_laser_damage_cd: float = 0.0
var _alien_laser_hit := false
var _alien_laser_start := Vector2.ZERO
var _alien_laser_end := Vector2.ZERO
var _alien_laser_sprite: Sprite2D = null
var _alien_muzzle_sprite: Sprite2D = null
var _alien_impact_sprite: Sprite2D = null
const _ALIEN_LASER_TEX := preload("res://assets/particles/laser_beam.png")
const _TEX_LASER_BURST := preload("res://assets/particles/laser_burst.png")
const _TEX_LASER_GROUND := preload("res://assets/particles/laser_ground.png")
# ── Laser görsel ölçüleri (uzay biyomu) ──────────────────────────────
# Beam inceltildi: 0.035 VW (21px) → 0.014 VW (~8px).
const LASER_BEAM_W := 0.014
# Beam vuruş payı (px) — beam yarım-genişliği (~4px) + küçük affetme.
# Vuruş, oyuncu MERKEZİ ile değil, oyuncu HITBOX'ı (14.4 x 20) + bu pay ile
# beam segmentinin kesişimiyle test edilir (_laser_hits_player). Böylece
# beam vücuda değdiği an hasar işler; hızlı düşüşte tick-atlama (tunneling)
# da süpürme (swept) testiyle kapanır. Büyüt = daha affedici vuruş.
const LASER_HIT_PAD := 7.0
# Namlu çıkış noktaları — beam artık merkezden/yukarıdan değil, silahın
# ucundan çıkıyor (UFO göbeği / alien göğsü).
const UFO_MUZZLE_DOWN_VW := 0.035
const ALIEN_MUZZLE_DOWN_VW := 0.020
# Efekt boyutları (VW oranı).
const UFO_MUZZLE_SIZE_VW := 0.055
const UFO_GROUND_W_VW := 0.110
const UFO_IMPACT_BURST_VW := 0.050
# UFO beam eklem ölçüleri (px) — beam'in iki ucu da efektlerin içine gömülür,
# kesik kenar asla görünmez; beam tam olarak efektlerden çıkıyor gibi durur.
const UFO_BEAM_TOP_TUCK := 6.0   # üst uç namlu flash'ının içine gömülür
const UFO_BEAM_SINK := 5.0       # alt uç yer efektinin çekirdeğine gömülür
const UFO_GROUND_JOINT_Y := 60.0 # ground dokusunda çekirdek noktası (ölçüldü: beyaz 49-75)
const ALIEN_MUZZLE_SIZE_VW := 0.050
const ALIEN_IMPACT_SIZE_VW := 0.070
# Alien beam uçları bu kadar px burst'lerin içine gömülür (sadece görsel);
# kesik kenar görünmez, beam tam olarak flash'lardan çıkıyor gibi durur.
const ALIEN_BEAM_SINK := 5.0

# ── WORM ─────────────────────────────────────────────────────────────
const WORM_BABY_SCALE      := 0.8   # was 0.6 — too small per request, bumped up (still smaller than adult)
const WORM_BABY_PATROL_SPD := 0.6   # was 1.8 — /3 per request ("3 kat azalt")
const WORM_DIRT_COOLDOWN   := 3.0
var WORM_DIRT_RANGE   : float = 0.0
var WORM_DIRT_SPEED_X : float = 0.0
var WORM_DIRT_SPEED_Y : float = 0.0
var WORM_DIRT_GRAVITY : float = 0.0
var _worm_is_baby     := false
var _worm_baby_frames : Dictionary = {}
var _worm_dirt_timer  := 0.0
var _worm_dirt_nodes  : Array[Node] = []



# _xclamp_disabled now declared in EnemyBase.gd

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
	# BUG FIX (determinism/anti-cheat parity): dokular (texture) sadece görsel
	# olduğu için headless'ta atlanabilir, ama _init_projectile_pools() öyle
	# değil — o, solucanın toprak atışı ve slime'ların fırlattığı parçacıklar
	# gibi GERÇEK hasar veren interactable'ların (proj_damage) kaydedildiği
	# Area2D havuzlarını oluşturuyor. Bu çağrı "if not _is_headless" bloğunun
	# İÇİNE alınmıştı, yani headless modda (server/replay simülasyonu) bu
	# havuzlar hiç oluşmuyordu → _pool_acquire() her zaman boş dönüyordu →
	# _register_interactable() hiç çağrılmıyordu. Sonuç: client'ta oyuncuya
	# gerçekten çarpıp hasar veren bu atışlar, headless/server tarafında HİÇ
	# var olmuyordu (aynı bug sınıfı, _slime_green_death_cloud'daki yorumda
	# bahsedilen sorunun bir üst seviyesi). Şimdi havuzlar her modda kuruluyor,
	# sadece pahalı/gereksiz doku üretimi (_make_*_tex) headless'ta atlanıyor.
	if not _is_headless:
		_tex_rain      = _make_solid_tex(Color(0.4, 0.7, 1.0, 0.8),   int(_vw * 0.006) + 1, int(_vh * 0.02) + 1)
		_tex_ice       = _make_circle_tex(Color(0.4, 0.75, 1.0, 0.85),  int(_vw * 0.117))
		_tex_blob      = _make_circle_tex(Color(0.2, 0.85, 0.15, 0.95), int(_vw * 0.023))
		_tex_cloud_atk = _make_circle_tex(Color(0.15, 0.75, 0.1, 0.7),  int(_vw * 0.133))
		_tex_mini      = _make_circle_tex(Color(0.65, 0.2, 0.9, 0.95),  int(_vw * 0.033))
		_tex_puff      = _make_circle_tex(Color(0.6, 0.4, 0.15, 0.85),  int(_vw * 0.023))
		_tex_dirt      = _make_circle_tex(Color(0.55, 0.35, 0.12, 1.0), int(_vw * 0.040))
	_init_projectile_pools()   # her zaman çalışır — headless'ta tex parametreleri null olur, sorun değil (hiç çizilmiyor zaten)

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
		# DETERMINISM FIX: Area2D defaults to monitoring = true in Godot. This
		# pool used to leave that default in place and rely entirely on the
		# caller registering the node with GameManager._register_interactable()
		# (which sets monitoring = false) right after acquiring it. In every
		# current call site that happens synchronously, same frame — but that
		# was an assumption living in the CALLER's code, not a guarantee this
		# node itself enforces. Any future projectile type that acquires a pool
		# slot and does something (even briefly) before registering would have
		# a real, frame-based Area2D signal window — exactly the non-tick-based
		# collision path we don't want anywhere in this game. Disabling it right
		# here, at creation, means every pooled node is dead-signal from the
		# moment it exists, full stop, regardless of what any caller does.
		node.monitoring  = false
		node.monitorable = false
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

func _ranged_attacks_unlocked() -> bool:
	var gm: Node = _gm_ref if is_instance_valid(_gm_ref) else get_parent()
	if not is_instance_valid(gm):
		return false
	return int(gm.get("score")) >= RANGED_ATK_MIN_SCORE


func _biome_particle_tex() -> Texture2D:
	var s : int = int(_gm_ref.get("score")) if is_instance_valid(_gm_ref) else 0
	var slot := (maxi(s, 0) / 500) % 5
	match slot:
		0: return _TEX_PARTICLE_GREEN
		1: return _TEX_PARTICLE_GREY
		2: return _TEX_PARTICLE_BEIGE
		3: return _TEX_PARTICLE_BLUE
		_: return _TEX_PARTICLE_BLUE  # space: mevcut mavi parçacık fallback

# EN-11: free pool nodes when this enemy is removed from the tree
func _exit_tree() -> void:
	for pool in [_pool_rain, _pool_ice, _pool_blob, _pool_cloud_atk, _pool_mini, _pool_dirt]:
		for entry in pool:
			if is_instance_valid(entry.get("node")):
				entry["node"].queue_free()
	if is_instance_valid(_spider_web_line):
		_spider_web_line.queue_free()

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

	# ── Platform üstünde oturma — tip bazlı yükseklik fix ──────────────────
	# Değerler artık dosyanın en üstünde, PLATFORM_GAP_FIX sabitinde —
	# oraya bak, düzenle, F5. Buradaki kod sadece o sabiti uyguluyor.
	if PLATFORM_GAP_FIX.has(enemy_type):
		_platform_gap_override        = PLATFORM_STAND_GAP + (PLATFORM_GAP_FIX[enemy_type] as float) * _vw
		_platform_gap_override_active = true

	# ── Global height-based difficulty scaling ──────────────────────────
	# `difficulty` (0.0 → 1.0) comes from base_setup()/GameManager's score-
	# or-height curve. Every enemy type's chase/aggro numbers below are
	# scaled by these two multipliers so ALL enemies (not just Alien/Slime/
	# Worm) gradually get faster and more alert as the player climbs higher,
	# ramping smoothly up to the cap at max difficulty. Pure function of
	# `difficulty`, which is itself deterministic (score/height based), so
	# this stays bit-identical between client and server replay sims.
	var _diff_speed_mult : float = lerpf(1.0, 1.15, difficulty) * GameConstants.SPEED_BUFF  # up to +15% speed, plus global buff
	var _diff_range_mult : float = lerpf(1.0, 1.10, difficulty)  # up to +10% aggro/detect range

	# Cache computed constants (EN-04: avoid per-access multiplication)
	WINGMAN_CHASE_RANGE = _vw * 0.30 * _diff_range_mult
	WINGMAN_CHASE_SPEED = _vw * 0.55 * 0.5 * 1.2 * 1.3 * _diff_speed_mult   # -50%, +%20, sonra +%20 yerine +%30 (user request)
	WINGMAN_RETURN_SPEED = WINGMAN_CHASE_SPEED   # BUG FIX: see _wingman_ai — used to snap home in a fixed 0.5s regardless of distance, now returns at its own normal speed
	# SPIKEMAN_DETECT_X / SPIKEMAN_CHASE_SPEED removed — spikeman no longer
	# chases (see _spikeman_ai below), these were dead code left over from
	# before that behavior was cut.
	SPIKEBALL_AMPLITUDE = _vh * 0.07
	SUN_AMPLITUDE       = _vh * 0.08
	CLOUD_FOLLOW_SPEED  = _vw * 0.55 * 0.5 * 1.2 * 1.3 * _diff_speed_mult   # user request: diğer uçan tiplerle (wingman/bee/fly/ghost) aynı hız
	CLOUD_RAIN_RANGE_X  = _vw * 0.06
	BEE_AGGRO_RANGE     = _vw * 0.32 * _diff_range_mult   # was 0.25 — too low, barely chased, bumped up per request
	BEE_CHASE_SPEED     = _vw * 0.55 * 0.5 * 1.2 * 1.3 * _diff_speed_mult   # wingman/fly/ghost ile aynı hız (user request)
	BEE_RETURN_SPEED    = BEE_CHASE_SPEED   # per request: same as WINGMAN/GHOST — returns at its own normal speed, not a separate fixed value
	FLY_AGGRO_RANGE     = _vw * 0.28 * _diff_range_mult
	FLY_CHASE_SPEED     = _vw * 0.55 * 0.5 * 1.2 * 1.3 * _diff_speed_mult   # wingman/bee/ghost ile aynı hız (user request)
	MOUSE_AGGRO_RANGE   = _vw * 2.0   # user request: aynı platformdaysa (same_level) mesafeye bakmaksızın hep tepki versin — küçük adımlarla oyalanmayı önler
	MOUSE_CHASE_SPEED   = _vw * 0.42 * 0.9 * _diff_speed_mult   # user request: hafif yavaşlatıldı (-10%)
	MOUSE_PATROL_SPEED  = 0.65 * GameConstants.SPEED_BUFF   # user request: uçan gruple (wingman/bee/fly/ghost) tamamen aynı hız
	FROG_DETECT_X       = _vw * 0.20 * _diff_range_mult
	FROG_DETECT_Y       = _vh * 0.25 * _diff_range_mult
	FROG_JUMP_HEIGHT    = -_vh * 0.18
	FROG_JUMP_DIST      = _vw * 0.12
	SLIME_FIRE_DETECT   = _vw * 0.22 * _diff_range_mult
	SPIDER_AGGRO_RANGE  = _vw * 0.32 * _diff_range_mult   # was 0.20 — too short, spider let go of the chase almost immediately; bumped up to match BEE (user request, same complaint)
	SPIDER_DETECT_X     = _vw * 0.34 * _diff_range_mult
	SPIDER_DETECT_Y     = _vh * 0.32 * _diff_range_mult
	GHOST_DETECT_RANGE  = _vw * 0.28 * _diff_range_mult
	GHOST_CHASE_SPEED   = _vw * 0.55 * 0.5 * 1.2 * 1.3 * _diff_speed_mult  # user request: wingman/bee/fly ile tamamen aynı hız
	GHOST_RETURN_SPEED  = GHOST_CHASE_SPEED   # BUG FIX: see _ghost_ai — used to snap home in a fixed 0.5s regardless of distance, now returns at its own normal speed
	WORM_DIRT_RANGE     = _vw * 0.233 * _diff_range_mult
	WORM_DIRT_SPEED_X   = _vw * 0.15   # already scaled by difficulty at use-site (line ~1869), don't double-scale here — projectile speed, intentionally left out of SPEED_BUFF (see review notes)
	WORM_DIRT_SPEED_Y   = -_vh * 0.40
	WORM_DIRT_GRAVITY   = _vh * 0.75
	SPIDER_BURST_SPEED  = _vw * 0.55 * _diff_speed_mult   # FIX: was declared but never assigned/used — burst chase now scales with height-based difficulty like every other chase speed

	# Cache platform collision shape once (EN-01)
	if is_instance_valid(_platform):
		_platform_cs = _get_cs_of(_platform)

	# BUG FIX: bu artık her zaman çağrılıyor — _init_tex_cache() içinde
	# headless/görsel ayrımı zaten kendi içinde yapılıyor (bkz. yukarıdaki not).
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
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)              # user request: uçan herşeyle aynı hız
			_start_vertical_bob(12.0, 2.2)  # user request: uçan herşeyle aynı bob hızı

		EnemyType.WINGMAN:
			# Chases in range, patrols outside
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_wingman_chasing = false
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)              # -50%, +%20 yerine +%30 (user request)
			_start_vertical_bob(10.0, 2.2)  # user request: uçan herşeyle aynı bob hızı

		EnemyType.SPIKEMAN:
			# Patrols platform back and forth — unkillable (no longer tracks/chases the player)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(GameConstants.SPEED_BUFF)

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
				# scale.y = -1.0 already flips the whole node visually (and its
				# collision shape with it) — do NOT also set _anim.flip_v, that
				# flips the sprite texture a second time and cancels the visual
				# flip out, making the barnacle look upright even though it's
				# hanging upside-down underneath the platform.
				scale.y      = -1.0
				if is_instance_valid(_platform):
					var ps := _get_cs_of(_platform)
					if ps and ps.shape:
						global_position.y = _platform.global_position.y + ps.shape.size.y * 0.5 + _platform_gap()
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
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)   # user request: wingman/fly/ghost ile aynı hız
			_start_vertical_bob(8.0, 2.2)  # user request: uçan herşeyle aynı bob hızı

		EnemyType.FLY:
			# Chases until dead once player enters range
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_fly_home_pos = global_position
			_fly_aggro    = false
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)   # user request: wingman/bee/ghost ile aynı hız
			_start_vertical_bob(8.0, 2.2)  # user request: uçan herşeyle aynı bob hızı

		EnemyType.FROG:
			# Moves by jumping, leaps toward the player
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_frog_jumping       = false
			_frog_jump_cd       = _rng_range(1.7, 2.8)  # slightly longer rest between jumps
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
			_mouse_sniffing  = false
			_mouse_sniff_timer = _rng_range(1.5, 3.5)
			_start_patrol(MOUSE_PATROL_SPEED)

		EnemyType.SLIME_BLOCK:
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])

		EnemyType.SLIME_BLUE, EnemyType.SLIME_GREEN, EnemyType.SLIME_PURPLE, EnemyType.SLIME_FIRE:
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol_from(global_position.x, 0.6 * GameConstants.SPEED_BUFF)
			_slime_attack_cd = _rng_range(2.0, 4.0)

		EnemyType.SNAIL:
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(0.35 * GameConstants.SPEED_BUFF, true)

		EnemyType.WORM_GREEN, EnemyType.WORM_PINK:
			_worm_dirt_timer = _rng_range(1.0, WORM_DIRT_COOLDOWN)
			var spd := WORM_BABY_PATROL_SPD if _worm_is_baby else 0.8
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			if _worm_is_baby:
				if not headless and is_instance_valid(_anim):
					_anim.scale = _anim.scale * WORM_BABY_SCALE
					# Defensive: force full-opacity/no-tint so babies never look
					# "soluk" (faded/washed out) — same frames as the adult, so
					# any perceived paleness was coming from the tiny 0.6 scale
					# itself (small sprite + antialiasing reads as washed out),
					# not an actual color/alpha bug, but this rules it out for good.
					_anim.modulate = Color.WHITE
					_anim.self_modulate = Color.WHITE
				_col.scale = Vector2(WORM_BABY_SCALE, WORM_BABY_SCALE)
			_start_patrol_from(global_position.x, spd * GameConstants.SPEED_BUFF)

		EnemyType.LADYBUG:
			_ladybug_is_resting = false
			_ladybug_rest_timer = _rng_range(3.0, 5.0)
			can_fly = true
			if sf and sf.has_animation("fly"): _anim.play("fly")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)            # user request: uçan herşeyle aynı hız
			_start_vertical_bob(10.0, 2.2)  # user request: uçan herşeyle aynı bob hızı

		EnemyType.SPIDER:
			can_fly = false
			_spider_burst_active = false
			_spider_burst_timer  = 0.0
			_spider_burst_cd     = 0.0
			_spider_climbing     = false
			_spider_web_cd       = 0.0
			_spider_web_throwing = false
			_frog_cur_platform   = _platform   # reuse frog's platform-finding helpers
			_frog_gm             = get_parent()
			if sf and sf.has_animation("walk"): _anim.play("walk")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)   # user request: uçan gruple (wingman/bee/fly/ghost) tamamen aynı hız

		EnemyType.GHOST:
			can_fly = true
			_ghost_chasing     = false
			_ghost_chase_timer = 0.0
			_ghost_fade_timer  = 0.0
			_ghost_visible     = true
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			# user request: uçan herşeyle (wingman/bee/fly) tamamen aynı patrol hızı
			_start_patrol(0.65 * GameConstants.SPEED_BUFF)
			_start_vertical_bob(12.0, 2.2)

		EnemyType.UFO:
			UFO_HOVER_SPEED = _vw * 0.0009 * GameConstants.SPEED_BUFF
			UFO_HOVER_RANGE = _vw * 0.30
			if sf and sf.has_animation("idle"): _anim.play("idle")
			elif sf: _anim.play(sf.get_animation_names()[0])
			_start_patrol(UFO_HOVER_SPEED)
			_start_vertical_bob(_vh * 0.025, 3.5)
			_ufo_fire_timer = _rng.randf_range(UFO_FIRE_INTERVAL_MIN, UFO_FIRE_INTERVAL_MAX)
			_ufo_firing     = false
			_ufo_beam_timer = 0.0
			_ufo_damage_cd  = 0.0
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 1.3

		EnemyType.ALIEN_GREEN:
			# Green is one of the two simple aliens: only a calm left/right
			# patrol. It deliberately does not use the platform-jump engine.
			ALIEN_SPEED = _vw * lerpf(0.0008, 0.0015, difficulty) * GameConstants.SPEED_BUFF
			can_fly = false
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if is_instance_valid(_col): _col.position.y = _vw * 0.06
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25

		EnemyType.ALIEN_BLUE:
			# Blue is the platform-jumper. Reuse the tested frog jump engine
			# so landing, clamps and tick/replay behaviour stay consistent.
			ALIEN_SPEED = _vw * lerpf(0.0006, 0.0012, difficulty) * GameConstants.SPEED_BUFF
			can_fly             = false
			_frog_jumping       = false
			_frog_home_platform = _platform
			_frog_cur_platform  = _platform
			_frog_gm            = get_parent()
			_alien_jump_timer   = _rng.randf_range(2.6, 4.0)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if is_instance_valid(_col): _col.position.y = _vw * 0.06
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25

		EnemyType.ALIEN_PINK:
			ALIEN_SPEED = _vw * 0.0006 * GameConstants.SPEED_BUFF
			_alien_shoot_timer = _rng.randf_range(2.0, ALIEN_SHOOT_INTERVAL)
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if is_instance_valid(_col): _col.position.y = _vw * 0.06
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25

		EnemyType.ALIEN_YELLOW:
			ALIEN_SPEED = _vw * lerpf(0.0012, 0.002, difficulty) * GameConstants.SPEED_BUFF
			if sf and sf.has_animation("walk"): _anim.play("walk")
			_start_patrol(ALIEN_SPEED)
			if is_instance_valid(_col): _col.position.y = _vw * 0.06
			if not _is_headless and is_instance_valid(_anim):
				_anim.scale *= 2.25


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
					if is_instance_valid(_anim):
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
				# Per request: 0.2 weaker than the spring item's SPRING_SPEED
				# (SPRING_SPEED is negative, so +_vh*0.2 reduces the magnitude).
				body.velocity.y = body.SPRING_SPEED + _vh * 0.2
				if is_instance_valid(_anim):
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
				if is_instance_valid(_anim) and _anim.sprite_frames.has_animation("flat"):
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
				# Per request: 0.2 weaker than the spring item's SPRING_SPEED
				# (SPRING_SPEED is negative, so +_vh*0.2 reduces the magnitude).
				body.velocity.y = body.SPRING_SPEED + _vh * 0.2
				if is_instance_valid(_anim):
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
			# user request: alttan/yandan temasta hiçbir şey olmasın, sadece
			# üstten basılınca (stomped) zıplatsın — hasar verme kısmı kaldırıldı
			return true

		EnemyType.BARNACLE:
			if not powered:
				body.hit_enemy()
			return true

		EnemyType.CLOUD:
			# user request: touching the cloud's body itself is harmless —
			# only its rain drop (_cloud_spawn_rain -> "rain_damage"
			# interactable) should hurt the player. Stomping the top still
			# kills it, same as before.
			if stomped:
				body.velocity.y = -_vh * 0.50
				_die()
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
				if _worm_is_baby:
					# Babies don't split further — they just die.
					_die()
				else:
					# Head-stomp on an adult worm splits it into 2 babies
					# that patrol the same platform.
					_worm_split_and_die(body)
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
		EnemyType.ALIEN_BLUE:
			_alien_blue_ai(delta)
		EnemyType.ALIEN_YELLOW:
			pass  # ikinci basit alien: sadece sağ/sol patrol
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
			# BUG FIX: this used to be a fixed 0.5s move regardless of how far
			# the chase wandered from _start_y — the farther it chased, the
			# faster (and more unnatural) the snap back looked, since the same
			# distance covered in the same time = higher speed. Duration is
			# now distance / WINGMAN_RETURN_SPEED, so it always travels home
			# at its own normal speed no matter how far out it went.
			var return_dist : float = absf(global_position.y - _start_y)
			var return_secs : float = clampf(return_dist / maxf(WINGMAN_RETURN_SPEED, 1.0), 0.15, 2.0)
			_move_to(Vector2(global_position.x, _start_y), return_secs, false, true, false, func():
				_start_patrol_from(global_position.x, 0.65, true)   # user request: setup ile eşit (0.65)
				_start_vertical_bob(10.0, 2.2)  # user request: uçan herşeyle aynı bob hızı
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
	# Per-instance variance so a pack of the same enemy type chasing at once
	# doesn't all move in identical lockstep — see _speed_variance in EnemyBase.gd.
	chase_speed *= _speed_variance
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
		# BUG FIX: when the enemy is close enough that a single step would carry
		# it PAST the player's x, it used to still take the full chase_speed
		# step every tick — overshooting the player, flipping dx's sign next
		# tick, overshooting back the other way, flipping again, forever. That's
		# the "çok seri sağ sol" jitter once a fast chaser (spider especially,
		# high SPIDER_BURST_SPEED) catches up to the player. Fix: clamp the step
		# to the remaining distance so the enemy stops exactly at the player's x
		# instead of oscillating around it.
		var step : float = chase_speed * FIXED_DELTA
		var new_x : float
		if abs(dx) <= step:
			new_x = global_position.x + dx
		else:
			new_x = global_position.x + dir * step
		new_x = clampf(new_x, left_x, right_x)
		global_position.x = new_x
		if is_instance_valid(_anim):
			_anim_flip(dx)
			_play_idle_or_walk(abs(dx) <= step)
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
	# User request: SPIKEMAN no longer tracks/chases the player — just patrols
	# left/right forever. _tick_patrol() (EnemyBase.gd) already handles that
	# movement every tick on its own, since setup() already called
	# _start_patrol() for EnemyType.SPIKEMAN — nothing else needed here.
	# Was: _ground_chase_step(SPIKEMAN_DETECT_X, SPIKEMAN_CHASE_SPEED, 1.0, false) — vars removed, see setup()
	pass


# ══════════════════════════════════════════════════════════════════════
#  CLOUD AI — hover above the player, deal rain damage when below
# ══════════════════════════════════════════════════════════════════════
func _cloud_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	var p := _get_player()
	if not p: return

	var dx : float = p.global_position.x - global_position.x
	var dy : float = p.global_position.y - global_position.y

	# Per-instance variance — see _speed_variance in EnemyBase.gd.
	var follow_speed : float = CLOUD_FOLLOW_SPEED * _speed_variance

	# X: follow player slowly
	# user request: yatay hız %30, %25, %10 azaltıldı, sonra %10 arttırıldı
	var x_speed : float = follow_speed * 0.7 * 0.75 * 0.90 * 1.10
	var target_x : float = global_position.x + signf(dx) * minf(abs(dx), x_speed * FIXED_DELTA)
	global_position.x = target_x

	# Y: try to stay above player — target is player.y - hover_offset
	# Move upward slowly so player ends up below the cloud
	var hover_offset : float = _vh * 0.12   # how far above player to hover
	var target_y : float = p.global_position.y - hover_offset
	var y_speed  : float = follow_speed * 0.825 * 1.15 * 0.70 * 0.80 * 1.10 * FIXED_DELTA   # user request: dikey hız %15 arttırıldı, %30, %20 azaltıldı, sonra %10 arttırıldı
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
		# user request: rain-drop particle attack locked out below score 10000,
		# same as the other thrown-particle attacks — cooldown still rolls so
		# pacing stays identical whether or not it actually fires.
		if _ranged_attacks_unlocked():
			_cloud_spawn_rain()
		_cloud_rain_timer = CLOUD_RAIN_CD


func _cloud_spawn_rain() -> void:
	# NOTE: must run identically in headless/visual mode — this attack deals
	# real damage (rain_damage). _rng_range() must also be consumed in both
	# modes so the RNG state stays in sync with the recording.
	var drop_x_offset := _rng_range(-_vw * 0.02, _vw * 0.02)
	var parent := get_parent()
	if not parent: return

	# EN-11: pool acquire
	var entry := _pool_acquire(_pool_rain)
	if entry.is_empty():
		return  # pool exhausted (size=1, prev drop still flying) — skip this tick
	var drop : Area2D          = entry["node"]
	var cs   : CollisionShape2D = entry["cs"]
	var vis  : Sprite2D        = entry["vis"]

	(cs.shape as RectangleShape2D).size = Vector2(_vw * 0.006, _vh * 0.02)
	vis.texture = _tex_rain if _tex_rain else _make_solid_tex(Color(0.4, 0.7, 1.0, 0.8), int(_vw * 0.006) + 1, int(_vh * 0.02) + 1)
	var spawn_pos := global_position + Vector2(drop_x_offset, _vh * 0.02)
	drop.global_position = spawn_pos
	_cloud_rain_node = drop

	# Deterministic tick-based fall (replaces the old movement Tween, which
	# never advanced in headless mode and skipped damage registration there).
	_gm_ref.call("_register_interactable", drop, "rain_damage", {
		"one_shot": true,
		"traj": {
			"pos": spawn_pos, "vel": Vector2(0, _vh * 0.5), "accel": Vector2.ZERO,
			"dt": 1.0 / 60.0, "ticks_left": 30,
		},
		"on_expire": _pool_release.bind(entry),
	})


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
			var _self_ref := self
			tw.tween_callback(func():
					if is_instance_valid(_self_ref): _self_ref._anim_play("idle"))


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
			_start_patrol_from(global_position.x, 0.65, true)   # user request: setup ile eşit (0.65)
			_start_vertical_bob(8.0, 2.2)  # user request: uçan herşeyle aynı bob hızı
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
		if pl.get("platform_type") == Platform.PlatformType.BROKEN: continue
		if pl.get("_breaking") == true: continue
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


# Spider'a özel platform seçimi — frog'tan farklı olarak oyuncunun Y'sine değil,
# spider'ın KENDİ X konumuna en yakın (yani gerçekten dikey/dikeye yakın) platformu
# tercih eder. Böylece web yatay değil, dikey ya da dikeye çok yakın atılır.
func _spider_best_platform_vertical(candidates: Array) -> Node:
	var best   : Node  = null
	var best_d : float = INF
	for pl in candidates:
		if not is_instance_valid(pl): continue
		var dx : float = abs(pl.global_position.x - global_position.x)
		if dx < best_d:
			best_d = dx
			best   = pl
	return best


# Jump to target platform Y, choose a sensible X point on top of the platform
func _frog_jump_to_platform(target_plat: Node) -> void:
	# Platforms can be recycled while the enemy is deciding its target. Never
	# start a move segment from a stale platform reference; that was the source
	# of occasional mid-jump freezes/teleports.
	if not is_instance_valid(target_plat) or not target_plat.is_inside_tree():
		# Hedef geçersizleşmişse alien kendi platformuna zıplamaz — sadece
		# vazgeçip patrol'e devam eder (frog'un eski fallback'i korunur).
		if enemy_type >= EnemyType.ALIEN_GREEN and enemy_type <= EnemyType.ALIEN_YELLOW:
			_frog_jumping = false
			_snap_disabled = false
			_xclamp_disabled = false
			_snap_dirty = true
			if not _patrol_active:
				_start_patrol_from(global_position.x, ALIEN_SPEED, true)
			if is_instance_valid(_anim):
				var sf0 := _anim.sprite_frames
				if sf0 and sf0.has_animation("walk"): _anim.play("walk")
			return
		_frog_do_jump_same_platform(1.0 if _rng.randf() < 0.5 else -1.0)
		return
	_frog_jumping     = true
	_frog_jump_cd     = _rng_range(1.5, 2.6)  # slightly longer pause before next jump
	_snap_disabled    = true
	# Mid-air the frog is still on the OLD `_platform` (it's only reassigned in
	# the landing callback below), and simulate_tick() clamps global_position.x
	# to `_platform`'s bounds every tick. Without disabling that clamp here,
	# any jump landing outside the old platform's x-range gets yanked back to
	# that platform's edge every frame — looking like a teleport instead of an
	# arc. Same fix the spider web-climb already uses (_xclamp_disabled).
	_xclamp_disabled  = true
	_move_cancel()

	if is_instance_valid(_anim):
		var sf := _anim.sprite_frames
		if sf and sf.has_animation("walk"):
			_anim_play("walk")

	# X bounds of the target platform
	var ps := _get_cs_of(target_plat)
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
	# Use the same resolved gap as initial platform snapping. Previously alien
	# landing used a hard-coded 0.09 while initial spawn used the override on
	# top of PLATFORM_STAND_GAP, so aliens visibly changed height after a hop.
	var y_gap: float = _platform_gap()
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
	# Slightly slower overall pace (lower divisor), and a higher floor so a SHORT
	# hop (small dist_2d) doesn't snap to a near-instant minimum — close jumps now
	# take noticeably longer instead of looking twitchy.
	var jump_time : float = clampf(dist_2d / (_vw * 0.46) * 1.5, 0.51, 1.17)

	_move_to(peak_pos, jump_time * 0.5, false, true)
	_move_to(land_pos, jump_time * 0.5, true, false, false, func():
		_frog_cur_platform = target_plat
		_platform          = target_plat
		_snap_disabled     = false
		_xclamp_disabled   = false
		_frog_jumping      = false
		_snap_dirty        = false
		_snap_target_y     = land_y
		if is_instance_valid(_anim):
			var sf := _anim.sprite_frames
			if is_alien:
				if sf and sf.has_animation("walk"): _anim.play("walk")
				# resume=TRUE: indiği konumdan devam eder, patrol fazı rastgele
				# sıfırlanıp küçük bir ışınlanma yapmaz (önceki FALSE'tu).
				_start_patrol_from(global_position.x, ALIEN_SPEED, true)
			elif sf and sf.has_animation("idle"):
				_anim_play("idle")
	)


# Short jump on the same platform (fallback)
func _frog_platform_clamp(target_x: float) -> float:
	var frog_margin : float = _vw * 0.04
	return _clamp_x_to_platform(target_x, frog_margin)


func _frog_do_jump_same_platform(dir: float) -> void:
	_frog_jumping  = true
	_frog_jump_cd  = _rng_range(1.7, 3.0)  # slightly longer pause between hops
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
	# Same fix as the cross-platform jump: lower pace + higher floor so jumping
	# to a NEARBY spot doesn't snap to a near-instant hop.
	var sp_time  : float   = clampf(sp_dist / (_vw * 0.46) * 1.5, 0.45, 0.825)
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
#  MOUSE AI — fast patrol, walks toward the player, pauses to sniff around
# ══════════════════════════════════════════════════════════════════════
func _mouse_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0

	# ── Ara sıra durup koklama/bakınma — sadece chase etmiyorken ─────
	if _mouse_sniffing:
		_mouse_sniff_timer -= FIXED_DELTA
		if _mouse_sniff_timer <= 0.0:
			_mouse_sniffing = false
			_mouse_sniff_timer = _rng_range(2.5, 5.0)
			if not _patrol_active:
				_start_patrol_from(global_position.x, MOUSE_PATROL_SPEED, true)
			_play_idle_or_walk(false)
		return  # bakınırken patrol/chase tamamen durur

	if not _mouse_chasing:
		_mouse_sniff_timer -= FIXED_DELTA
		if _mouse_sniff_timer <= 0.0:
			_mouse_sniffing  = true
			_mouse_sniff_dur = _rng_range(0.6, 1.3)
			_mouse_sniff_timer = _mouse_sniff_dur
			_stop_patrol()
			_move_cancel()
			_play_idle_or_walk(true)
			return

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
	# with the recording.
	if not _is_headless:
		for _si in range(_slime_nodes.size() - 1, -1, -1):
			if not is_instance_valid(_slime_nodes[_si]): _slime_nodes.remove_at(_si)
	var p := _get_player()
	if not p: return
	if _slime_attack_cd > 0.0: return
	var dist_sq : float = global_position.distance_squared_to(p.global_position)
	match enemy_type:
		# user request: mavi slime artık efekt atmıyor, diğer slime'lar gibi
		# sadece temasla (dokunuşla) saldırıyor — SLIME_BLUE case'i kaldırıldı.
		EnemyType.SLIME_GREEN:
			var r := _vw * 0.117; if dist_sq < r * r:
				# BUG FIX: eskiden "if not _is_headless:" ile çağrılıyordu, yani
				# headless'ta bu saldırının kaydettiği gerçek proj_damage hiç
				# oluşmuyordu (bkz. _init_tex_cache'teki not). Artık her modda çağrılıyor.
				# user request: rock-spit particle attack locked out below score 10000
				# — cooldown still rolls every time so RNG stream/pacing stays identical
				# whether or not the spit itself fires.
				if _ranged_attacks_unlocked():
					_slime_green_spit(p)
				_slime_attack_cd = _rng_range(4.0, 6.0) * (1.0 - difficulty * 0.2)
		EnemyType.SLIME_PURPLE:
			var r := _vw * 0.167; if dist_sq < r * r:
				# user request: mini-spawn particle attack locked out below score 10000,
				# same as the other thrown-particle attacks.
				if _ranged_attacks_unlocked():
					_slime_purple_spawn_mini(p)   # BUG FIX: aynı şekilde artık her modda çalışıyor
				_slime_attack_cd = _rng_range(4.5, 7.0) * (1.0 - difficulty * 0.3)


func _slime_blue_ice_burst(target: Node) -> void:
	# NOTE: artık hiçbir yerden çağrılmıyor (user request: mavi slime efekt atmasın)
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
		var _self_ref := self
		tw.tween_callback(func():
			if is_instance_valid(_self_ref): _self_ref._pool_release(entry))
	var shake := _make_tween()
	if shake:
		shake.tween_property(_anim, "modulate", Color(0.5, 0.85, 1.5), 0.08)
		shake.tween_property(_anim, "modulate", Color.WHITE, 0.15)


func _slime_green_spit(target: Node) -> void:
	# NOTE: must run identically in headless/visual mode — this attack deals
	# real damage (proj_damage). Only the cosmetic spin tween is client-only.
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
	var spawn_pos := global_position + Vector2(0, -_vh * 0.010)
	blob.global_position = spawn_pos
	if not _is_headless:
		var _rtw := blob.create_tween().set_loops()
		_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_rtw.tween_property(vis, "rotation", TAU, 0.6).set_trans(Tween.TRANS_LINEAR)
		_pool_track_tween(entry, _rtw)
	_slime_nodes.append(blob)
	var speed := _vw * 0.25 * (1.0 + difficulty * 0.3)
	# Deterministic tick-based motion (replaces the old movement Tween, which
	# never advances in headless mode — see GameManager._check_interactables).
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", blob, "proj_damage", {
			"one_shot": true,
			"traj": {
				"pos": spawn_pos, "vel": dir * speed, "accel": Vector2.ZERO,
				"dt": 1.0 / 60.0, "ticks_left": 60,
			},
			"on_expire": _pool_release.bind(entry),
		})


func _slime_green_death_cloud() -> void:
	# NOTE: must run identically in headless/visual mode — this attack registers
	# a real, persistent damage zone (proj_damage, one_shot=false). The previous
	# version early-returned the WHOLE function on _is_headless, which skipped
	# the _register_interactable() call too — meaning this cloud only ever
	# existed on the client and the server replay never knew about it (same
	# bug class as the old Tween-driven projectiles elsewhere in this file,
	# just one level worse: here even the *registration* was client-only, not
	# just the movement). Currently unused/uncalled, fixed defensively so it's
	# safe the moment something calls it.
	var parent := get_parent()
	if not parent: return

	# EN-11: pool acquire — must happen in both modes, the Area2D + CollisionShape2D
	# is what _check_interactables() reads its cached radius from, headless included.
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

	if not _is_headless:
		var _rtw := cloud.create_tween().set_loops()
		_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_rtw.tween_property(vis, "rotation", TAU, 0.8).set_trans(Tween.TRANS_LINEAR)
		_pool_track_tween(entry, _rtw)
		var tw := cloud.create_tween()
		if tw:
			_pool_track_tween(entry, tw)
			tw.tween_property(vis, "scale", Vector2(1.3, 1.3), 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(cloud, "modulate:a", 0.0, 0.4).set_delay(1.5)

	# Register with GameManager AABB system — persistent (one_shot=false), player
	# invincibility prevents spam. Lifetime + cleanup are tick-based (landed=true
	# pre-set means the traj code never touches position, just counts ticks down),
	# identical in both modes — replaces relying on the cosmetic tween's interval
	# + tween_callback for _pool_release, which never fired in headless.
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", cloud, "proj_damage", {
			"one_shot": false,
			"traj": {
				"pos": cloud.global_position, "vel": Vector2.ZERO, "accel": Vector2.ZERO,
				"dt": 1.0 / 60.0, "landed": true, "ticks_left": 114,  # ≈1.9s at 60tps
			},
			"on_expire": _pool_release.bind(entry),
		})


func _slime_purple_spawn_mini(target: Node) -> void:
	# NOTE: must run identically in headless/visual mode — this attack deals
	# real damage (proj_damage). Only cosmetic spin/flash tweens are client-only.
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
	var spawn_pos := global_position + Vector2(dir * _vw * 0.017, -_vh * 0.00625)
	mini.global_position = spawn_pos
	if not _is_headless:
		var _rtw := mini.create_tween().set_loops()
		_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_rtw.tween_property(vis, "rotation", TAU, 0.5).set_trans(Tween.TRANS_LINEAR)
		_pool_track_tween(entry, _rtw)
	_slime_nodes.append(mini)

	# Deterministic tick-based arc (replaces the old movement Tween, which
	# never advanced in headless mode and skipped damage registration there).
	var vx  := dir * _vw * 0.183
	var vy  := -_vh * 0.225
	var grv := _vh * 0.475
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("_register_interactable"):
		_gm_ref.call("_register_interactable", mini, "proj_damage", {
			"one_shot": true,
			"traj": {
				"pos": spawn_pos, "vel": Vector2(vx, vy), "accel": Vector2(0, grv),
				"dt": 1.0 / 60.0, "ticks_left": 90,
				"land_y": global_position.y + _vh * 0.006, "land_extra_ticks": 180,
			},
			"on_expire": _pool_release.bind(entry),
		})
	if not _is_headless:
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
			# _patrol_active must always be restored, even if the anim node/frames
			# aren't available (e.g. headless sim) — otherwise the snail is stuck
			# forever. Do the state restore FIRST, animation is purely cosmetic.
			_patrol_active = true
			if is_instance_valid(_anim):
				var sf := _anim.sprite_frames
				if sf:
					if sf.has_animation("walk"):
						_anim_play("walk")
					elif sf.get_animation_names().size() > 0:
						_anim_play(sf.get_animation_names()[0])




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
		# user request: dirt-block particle throw locked out below score 10000,
		# same as the other thrown-particle attacks — cooldown still rolls so
		# pacing/RNG stream stays identical whether or not it actually fires.
		if _ranged_attacks_unlocked():
			_worm_throw_dirt(p)
		_worm_dirt_timer = WORM_DIRT_COOLDOWN * (1.0 - difficulty * 0.3)


func _worm_throw_dirt(target: Node) -> void:
	var parent := get_parent()
	if not parent: return
	var dir : float = signf(target.global_position.x - global_position.x)
	_anim_flip(dir)
	if is_instance_valid(_anim):
		var shake := _make_tween()
		if shake:
			shake.tween_property(_anim, "position", Vector2(0, -_vh * 0.005), 0.07)
			shake.tween_property(_anim, "position", Vector2.ZERO, 0.07)
	# user request: zorluk fark etmeksizin her zaman tek parçacık atsın (eski: zorluk 0.5 üstünde 2 taneydi)
	var count := 1
	for i in count:
		var offset_x := dir * _rng_range(_vw * 0.008, _vw * 0.033) * float(i + 1)
		_worm_spawn_dirt_block(parent, dir, offset_x)


func _worm_spawn_dirt_block(parent: Node, dir: float, offset_x: float) -> void:
	# NOTE: must run identically in headless/visual mode — this attack deals
	# real damage (dirt_damage). Only the cosmetic spin tween is client-only.

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
	var spawn_pos := global_position + Vector2(offset_x, -_vh * 0.010)
	dirt.global_position = spawn_pos
	if not _is_headless:
		var _rtw := dirt.create_tween().set_loops()
		_rtw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		_rtw.tween_property(vis, "rotation", TAU, 0.5).set_trans(Tween.TRANS_LINEAR)
		_pool_track_tween(entry, _rtw)
	_worm_dirt_nodes.append(dirt)
	dirt.set_meta("_pool_entry", entry)  # EN-11: stored for external destroy call

	# Deterministic tick-based arc (replaces the old movement Tween, which
	# never advanced in headless mode and skipped damage registration there).
	var vx      : float = dir * WORM_DIRT_SPEED_X * (1.0 + difficulty * 0.3)
	var vy      : float = WORM_DIRT_SPEED_Y
	var gravity : float = WORM_DIRT_GRAVITY
	_gm_ref.call("_register_interactable", dirt, "dirt_damage", {
		"one_shot": true, "enemy": self,
		"traj": {
			"pos": spawn_pos, "vel": Vector2(vx, vy), "accel": Vector2(0, gravity),
			"dt": 1.0 / 60.0, "ticks_left": 120,
			"land_y": global_position.y + _vh * 0.025, "land_extra_ticks": 0,
		},
		"on_expire": _worm_destroy_dirt.bind(dirt, false),
	})


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
	var gm0 : Node = _gm_ref if is_instance_valid(_gm_ref) else get_parent()
	if is_instance_valid(gm0) and gm0.has_method("on_enemy_killed"):
		gm0.call("on_enemy_killed", enemy_type)
	var flash_color := Color(0.4, 1.0, 0.3) if enemy_type == EnemyType.WORM_GREEN else Color(1.0, 0.5, 0.8)
	if is_instance_valid(_anim):
		var flash_tw := _make_tween()
		if flash_tw:
			flash_tw.tween_property(_anim, "modulate", flash_color * 2.0, 0.06)
			flash_tw.tween_property(_anim, "modulate", Color.WHITE, 0.1)
	var gm := get_parent()
	if gm and gm.has_method("apply_camera_shake"):
		gm.apply_camera_shake(4.0, 0.18)
	# Worms now die as a single enemy. Keep the split/baby implementation
	# below for compatibility and future tuning, but do not invoke it on death.
	const WORM_SPLIT_ON_DEATH: bool = false
	if WORM_SPLIT_ON_DEATH:
		for offset in [Vector2(-_vw * 0.037, 0), Vector2(_vw * 0.037, 0)]:
			_worm_spawn_baby(offset)
	if is_instance_valid(_anim) and _anim.sprite_frames:
		if _anim.sprite_frames.has_animation("hurt"):
			if is_instance_valid(_anim): _anim.play("hurt")
	var tw := _make_tween()
	if tw:
		tw.tween_property(self, "scale", Vector2(1.5, 0.3), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(self, "modulate:a", 0.0, 0.18)
		var _self_ref := self
		tw.tween_callback(func():
				if is_instance_valid(_self_ref): _self_ref.queue_free())
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
	baby.set("_player_ref", _player_ref)
	baby.setup(enemy_type, _worm_baby_frames, minf(difficulty + 0.15, 1.0), true)
	# BUG FIX: setup() -> base_setup() unconditionally resets _overlap_triggered
	# to false (EnemyBase.gd) — fine for a normal spawn, but a split baby is
	# born at ~this exact spot (offset is only ±_vw*0.037) at the exact moment
	# the player's stomp is still overlapping that position (that overlap is
	# what killed the parent one tick ago). With the flag reset to false, the
	# baby's very first _tick_player_overlap() call finds the player still in
	# range and fires _on_body_entered() immediately — since the player is
	# still mid-stomp (is_stomping() true), that's an instant, unearned kill
	# before the baby ever gets a frame to move away. Symptom reported: stomp
	# an adult worm, both babies are already dead the instant they appear.
	# Marking it as "already triggered" makes the overlap check require the
	# player to actually leave and come back into range — a genuine new
	# touch — before it can hit the baby again, exactly like it would for any
	# enemy the player is already standing on/next to.
	baby._overlap_triggered = true
	# BUG FIX: babies spawned here bypass GameManager._add_enemy(), so without
	# these two calls they never enter the platform's overlap-tracking list and
	# never enter _enemies (the array simulate_tick() loops over every physics
	# frame) — result: baby sits in the tree fully set up but frozen, no AI/move.
	if is_instance_valid(_platform) and _platform.has_method("connect_enemy"):
		_platform.call("connect_enemy", baby)
	if is_instance_valid(_gm_ref) and _gm_ref.has_method("register_split_enemy"):
		_gm_ref.call("register_split_enemy", baby)
	# Cosmetic spawn "pop" — animate only the sprite's local offset, never the
	# Area2D's own global_position. That position drives real collision in
	# _tick_player_overlap (checked every tick, both modes) — a Tween on it
	# never advances in headless, which would desync the baby's hitbox from
	# the client for the ~0.3s duration of the hop (same bug class as the
	# projectile-trajectory issue fixed elsewhere).
	if is_instance_valid(baby._anim):
		var jump_tw : Tween = baby._anim.create_tween()
		if jump_tw:
			jump_tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
			jump_tw.tween_property(baby._anim, "position:y", -_vh * 0.025, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			jump_tw.tween_property(baby._anim, "position:y", 0.0,           0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	baby.modulate = Color(1.0, 1.0, 1.0)



# ── LADYBUG AI ───────────────────────────────────────────────────────
# DEBUG: prints why the ladybug can/can't find a platform to land on.
# Flip to false once it's confirmed working — these print every land attempt.
const DEBUG_LADYBUG := false

## Platform node'undan CollisionShape2D'yi güvenli şekilde döndürür.
## Önce isimle dener, bulamazsa tüm child'ları tarar.
## Platform.gd dinamik add_child kullanıyorsa node adı farklı gelebilir.
func _get_cs_of(plat: Node) -> CollisionShape2D:
	if not is_instance_valid(plat): return null
	var cs := plat.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs: return cs
	for child in plat.get_children():
		if child is CollisionShape2D:
			return child as CollisionShape2D
	return null

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
			_start_patrol_from(global_position.x, 0.6525, true)  # 0.87 * 0.75 -> -25% (user request)
			_start_vertical_bob(10.0, 1.8)  # 1.2 * 1.5 → 1.5x slower bob
			if DEBUG_LADYBUG:
				print("[LADYBUG id=%d] waking up, taking off from (%.1f, %.1f)" %
					[get_instance_id(), global_position.x, global_position.y])
		else:
			# Sadece kendi platformuna iner — başka platforma asla konmaz.
			# Önce geçerlilik kontrolü yapılır — freed bir objeyi `as` ile cast
			# etmek "Trying to cast a freed object" uyarısına yol açıyordu.
			if not is_instance_valid(_platform):
				# Platform referansı geçersizse havada dinlenmeye devam et.
				_ladybug_is_resting = true
				_ladybug_rest_timer = _rng_range(2.0, 3.5)
				_stop_patrol()
				_stop_vertical_bob()
				_move_cancel()
				if sf and sf.has_animation("idle"): _anim_play("idle")
				elif sf and sf.has_animation("rest"): _anim_play("rest")
				elif is_instance_valid(_anim): _anim.stop()
				return
			var _lb_plat : Node2D = _platform as Node2D
			var ps2 : CollisionShape2D = _get_cs_of(_lb_plat)
			if not ps2 or not ps2.shape:
				_ladybug_rest_timer = _rng_range(1.0, 2.0)
				return
			_platform = _lb_plat
			_ladybug_is_resting = true
			_ladybug_rest_timer = _rng_range(2.0, 3.5)
			_stop_patrol()
			_stop_vertical_bob()
			_move_cancel()

			# ── Hedef noktasını hesapla ───────────────────────────────
			var land_y : float = _platform.global_position.y - ps2.shape.size.y * 0.5 - _platform_gap()
			var left_e  : Vector2 = ps2.to_global(Vector2(-ps2.shape.size.x * 0.5, 0.0))
			var right_e : Vector2 = ps2.to_global(Vector2( ps2.shape.size.x * 0.5, 0.0))
			var margin  : float   = _vw * 0.05
			var land_x  : float   = clampf(global_position.x, left_e.x + margin, right_e.x - margin)
			var land_pos : Vector2 = Vector2(land_x, land_y)
			var from_pos : Vector2 = global_position

			# ── Platforma doğru bak (iniş boyunca bu yönde kalır) ────
			var face_dir : float = signf(land_x - from_pos.x)
			if face_dir == 0.0: face_dir = 1.0
			if not _is_headless and is_instance_valid(_anim):
				_anim_flip(face_dir)
				if sf and sf.has_animation("fly"): _anim_play("fly")

			# ── İniş arkı: kuş gibi hafif yaylanarak süzülür ─────────
			var arc_h   : float   = _vh * 0.04
			var peak    : Vector2 = Vector2(
				lerpf(from_pos.x, land_x, 0.45),
				minf(from_pos.y, land_y) - arc_h
			)
			var _land_dist : float = from_pos.distance_to(land_pos)
			var _land_time : float = clampf(_land_dist / (_vw * 0.42), 0.40, 1.05)

			_snap_dirty = true

			# İlk yarı: tepeye çık (hız kazanır)
			_move_to(peak, _land_time * 0.38, false, true, false, func():
				if not _is_headless and is_instance_valid(_anim):
					_anim_flip(face_dir)
			)
			# İkinci yarı: platforma yavaşlayarak kon
			_move_to(land_pos, _land_time * 0.62, true, true, false, func():
				can_fly   = false
				_snap_dirty = true
				if not _is_headless and is_instance_valid(_anim):
					if sf and sf.has_animation("idle"):   _anim_play("idle")
					elif sf and sf.has_animation("rest"): _anim_play("rest")
					else: _anim.stop()
					# Thump squish — yere vurma hissi
					var settle := _make_tween()
					if settle:
						var base_scale := _anim.scale
						settle.tween_property(_anim, "scale",
							base_scale * Vector2(1.22, 0.72), 0.07
						).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
						settle.tween_property(_anim, "scale",
							base_scale, 0.18
						).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			)


# ── SPIDER AI ────────────────────────────────────────────────────────
# Fast patrol; sprints toward the player when spotted, never leaves the platform
# on foot — but can shoot a web thread and climb to a platform above/below to
# follow the player across platforms when they're not on the same level.
# Spider'a özel komşu platform bulucu — frog'unkinden farkı: yatayda çok dar bir
# pencereye bakar (sadece neredeyse aynı X'teki platformlar), böylece web hep
# dikey ya da dikeye çok yakın atılır, yatay uzak platformlara fırlatılmaz.
func _spider_get_vertical_neighbors() -> Array:
	if not is_instance_valid(_frog_gm): return []
	var plat_list = _frog_gm.get("_platforms")
	if plat_list == null or plat_list.size() == 0: return []

	var anchor : Vector2 = global_position
	if is_instance_valid(_frog_cur_platform):
		anchor = _frog_cur_platform.global_position

	var max_dx : float = _vw * 0.10    # dar pencere — gerçek dikey komşular
	var max_dy : float = SPIDER_DETECT_Y + _vh * 0.04

	var result : Array = []
	var best_up    : Node = null
	var best_down  : Node = null
	var best_up_d  : float = INF
	var best_down_d: float = INF
	for pl in plat_list:
		if not is_instance_valid(pl): continue
		# BUG FIX: kırık (BROKEN) tip platformlar ya da şu an kırılmakta/
		# çökmekte olan (_breaking) platformlar hedef alınmamalı — spider
		# oraya ağ atıp tırmanırsa platform anında yok oluyor/oynayamıyor.
		if pl.get("platform_type") == Platform.PlatformType.BROKEN: continue
		if pl.get("_breaking") == true: continue
		var pdx : float = abs(pl.global_position.x - anchor.x)
		var pdy : float = pl.global_position.y - anchor.y
		if pdx > max_dx: continue
		if abs(pdy) <= 2.0: continue   # kendi platformu, atlamaya gerek yok
		if pdy < 0.0 and -pdy <= max_dy and -pdy < best_up_d:
			best_up_d = -pdy; best_up = pl
		elif pdy > 0.0 and pdy <= max_dy and pdy < best_down_d:
			best_down_d = pdy; best_down = pl
	if is_instance_valid(best_up):   result.append(best_up)
	if is_instance_valid(best_down): result.append(best_down)
	return result


func _spider_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0

	if _spider_web_throwing:
		# İp henüz hedefe ulaşmadı — örümcek YERİNDE durur, sadece ip uzar.
		_spider_web_throw_elapsed += 1
		var tt : float = clampf(float(_spider_web_throw_elapsed) / float(_spider_web_throw_total), 0.0, 1.0)
		if is_instance_valid(_spider_web_line):
			var pts0 := _spider_web_line.points
			pts0[1] = _spider_web_from.lerp(_spider_web_target, tt)
			_spider_web_line.points = pts0
		if tt >= 1.0:
			# İp hedefe ulaştı — şimdi örümcek tırmanmaya (çıkmaya) başlar.
			_spider_web_throwing = false
			_spider_climbing     = true
			# Climb animation starts HERE, not when the throw began — see the
			# comment in _spider_web_jump_to for why.
			if is_instance_valid(_anim):
				var sf1 := _anim.sprite_frames
				if sf1 and sf1.has_animation("jump"): _anim_play("jump")
				elif sf1 and sf1.has_animation("walk"): _anim_play("walk")
			var target_plat : Node = _spider_climb_target_plat
			_move_to(_spider_climb_land_pos, _spider_climb_time, true, true, false, func():
				_frog_cur_platform = target_plat
				_platform           = target_plat
				_snap_disabled       = false
				_xclamp_disabled     = false
				_spider_climbing     = false
				_snap_dirty          = true
				if is_instance_valid(_anim):
					var sf2 := _anim.sprite_frames
					if sf2 and sf2.has_animation("walk"): _anim_play("walk")
				_spider_despawn_web()
				# resume=true: patrol fazı örümceğin İNDİĞİ konumdan başlar, ışınlanma olmaz.
				_start_patrol_from(global_position.x, 1.4, true)
			)
		return

	if _spider_climbing:
		# BUG FIX: this used to write pts[1] = global_position here — the exact
		# same index the throw phase used for the growing tip (pts[1] went
		# from_pos -> land_pos during the throw). The instant climbing starts,
		# global_position is still from_pos (spider hasn't moved yet), so pts[1]
		# snapped from the fully-extended land_pos straight back to from_pos —
		# the taut web collapsed to a zero-length (invisible) line in one frame,
		# then visibly "re-grew" as the spider actually climbed. That looked
		# exactly like the web vanishing and a second one being thrown.
		# Fix: pts[1] (the target end) stays fixed at land_pos — it was already
		# reached during the throw — and pts[0] (the launch end) now tracks the
		# spider instead, so the rope visibly shortens from below as it climbs,
		# with no snap/collapse.
		if is_instance_valid(_spider_web_line):
			var pts := _spider_web_line.points
			pts[0] = global_position
			_spider_web_line.points = pts
		return

	_spider_web_cd = maxf(0.0, _spider_web_cd - FIXED_DELTA)

	var p := _get_player()
	if p and _spider_web_cd <= 0.0:
		var dx : float = p.global_position.x - global_position.x
		var dy : float = p.global_position.y - global_position.y
		var same_level : bool = abs(dy) < _vh * 0.10
		var in_reach   : bool = abs(dx) < SPIDER_DETECT_X and abs(dy) < SPIDER_DETECT_Y
		if not same_level and in_reach:
			var neighbors : Array = _spider_get_vertical_neighbors()
			# Exclude the platform it just came from too, not just the current
			# one — otherwise the next web-throw right after landing can pick
			# the platform it left as the "new" target, looking like it
			# immediately shoots a second web and climbs straight back down.
			if is_instance_valid(_spider_prev_platform):
				neighbors = neighbors.filter(func(pl): return pl != _spider_prev_platform)
			if neighbors.size() > 0:
				var best_plat : Node = _spider_best_platform_vertical(neighbors)
				if best_plat != null and best_plat != _frog_cur_platform:
					_spider_web_jump_to(best_plat)
					return

	# Same platform as the player (or nothing reachable toward them) —
	# fastest grounder: quicker patrol and a higher chase speed give it that
	# "rushes at you" feel, but it's still hard-clamped on-platform.
	_spider_burst_active = _ground_chase_step(SPIDER_AGGRO_RANGE,
		SPIDER_BURST_SPEED, 1.6 * GameConstants.SPEED_BUFF, _spider_burst_active)


# Shoots a single taut web thread to `target_plat` FIRST (spider stays put while
# the thread extends), and only once the thread has fully reached the target
# does the spider start climbing along it, landing biased toward the player's
# current X so it actually closes the gap.
func _spider_web_jump_to(target_plat: Node) -> void:
	# Longer cooldown (was 2.0-3.2s) — the old range meant the FULL throw+climb
	# sequence (up to ~2.5s) could eat almost the whole cooldown, so a new
	# web-throw could legitimately fire within a second of landing. Combined
	# with the "don't re-target the platform just left" fix above, this gives
	# a real, noticeable pause between web-throws instead of feeling like two
	# webs back-to-back.
	_spider_web_cd        = _rng_range(4.0, 6.0)
	_spider_prev_platform = _frog_cur_platform
	_snap_disabled    = true
	_xclamp_disabled  = true   # mid-transit — don't get yanked back to the old platform
	_stop_patrol()
	_move_cancel()

	var ps := _get_cs_of(target_plat)
	var hw : float = 0.0
	if ps and ps.shape:
		hw = ps.shape.size.x * 0.5 * target_plat.scale.x
	var plat_cx : float = target_plat.global_position.x
	var margin  : float = _vw * 0.04

	# Spider'ın kendi X'ine en yakın noktaya iner — dikey tırmanma hissi için.
	# Oyuncuya doğru yatay çekilme YOK, web hep dikey/dikeye yakın kalır.
	var land_x : float = clampf(global_position.x, plat_cx - hw + margin, plat_cx + hw - margin)

	var y_gap  : float = _platform_gap()
	var land_y : float
	if ps and ps.shape:
		land_y = target_plat.global_position.y - ps.shape.size.y * 0.5 - y_gap
	else:
		land_y = target_plat.global_position.y - y_gap

	var from_pos : Vector2 = global_position
	var land_pos : Vector2 = Vector2(land_x, land_y)
	var dist     : float   = from_pos.distance_to(land_pos)
	# Yavaş, gerçek bir tırmanma hissi — eskisinden çok daha uzun süre web üstünde kalır.
	var climb_t  : float   = clampf(dist / (_vw * 0.22), 0.85, 2.2)
	# İp atma (throw) süresi — tırmanmadan belirgin şekilde daha hızlı, kısa bir "fırlatma" hissi.
	var throw_t  : float   = clampf(dist / (_vw * 1.1), 0.10, 0.28)

	_spider_climb_land_pos    = land_pos
	_spider_climb_time        = climb_t
	_spider_climb_target_plat = target_plat

	# BUG FIX: the web's VISUAL endpoint used to always be `land_pos` — i.e. the
	# spot the spider will end up STANDING on (the platform's TOP surface MINUS
	# the stand-gap, so slightly floating above the actual sprite surface).
	# Climbing UP to a platform ABOVE the spider had the worse version of this:
	# the top surface is the FAR side, so the web was drawn straight through
	# the platform's solid body to a point on the other side of it — looked
	# like the web was thrown "to wherever it's going" instead of landing on
	# the platform. But climbing DOWN had the same root problem too, just
	# smaller: the stand-gap offset still left the web stopping short of the
	# visible platform surface instead of touching it.
	# Fix: the web's visible attach point always touches the platform's actual
	# NEAR edge relative to the spider — bottom edge (no gap) when climbing
	# up, top edge (no gap) when climbing down — so it visually lands ON the
	# platform in both directions. The spider's real resting position
	# (`land_pos`, with the stand-gap, used by _move_to below) is unchanged —
	# it still ends up standing correctly on top, gap and all.
	var climbing_up : bool = land_y < from_pos.y
	var web_attach_y : float
	if ps and ps.shape:
		web_attach_y = target_plat.global_position.y + ps.shape.size.y * 0.5 if climbing_up \
			else target_plat.global_position.y - ps.shape.size.y * 0.5
	else:
		web_attach_y = target_plat.global_position.y
	var web_attach_pos : Vector2 = Vector2(land_x, web_attach_y)

	# FIX: the jump/walk animation used to start here — i.e. the instant the
	# throw begins, while the spider is still standing still and only the
	# thread is extending (see _spider_ai's "spider stays put" comment below).
	# A moving-looking animation playing on a stationary spider is exactly
	# what made it look like it had already jumped to the destination
	# platform before the web even finished traveling. Now it just faces the
	# target (no walk/jump cycle) during the throw, and the actual climb
	# animation only starts once climbing motion actually begins — see the
	# tt >= 1.0 branch in _spider_ai().
	if is_instance_valid(_anim):
		_anim_flip(signf(land_x - global_position.x))

	# Web thread visual — a single line from launch point that extends out to
	# the target during the throw phase, then (once climbing starts) its loose
	# end tracks the spider as it climbs (see _spider_ai).
	if not _is_headless:
		# Safety: this spider should never have a leftover web line here (the
		# throwing/climbing state guards in _spider_ai prevent re-entry while
		# one is active), but if anything ever slips through, don't leak a
		# second Line2D silently — instant-clear any stale one first so there
		# is only ever one web thread per spider at a time.
		if is_instance_valid(_spider_web_line):
			_spider_web_line.queue_free()
			_spider_web_line = null
		var web_parent := get_parent()
		if is_instance_valid(web_parent):
			var web := Line2D.new()
			web.width = maxf(3.0, _vw * 0.006)   # was maxf(1.5, vw*0.003) — too thin, per request
			web.default_color = Color(0.92, 0.92, 0.95, 0.85)
			# Was z_index=1 — platforms render at z_index=5, so the web thread was
			# drawn BEHIND every platform it passed through, making it vanish for
			# most of the climb (spider itself is z_index=10, so it stayed visible,
			# making it look like the web disappeared and a second one appeared).
			web.z_index = 6
			web.points = PackedVector2Array([from_pos, from_pos])
			web_parent.add_child(web)
			_spider_web_line = web

	_spider_web_from          = from_pos
	_spider_web_target        = web_attach_pos
	_spider_web_throw_elapsed = 0
	_spider_web_throw_total   = maxi(1, int(round(throw_t * 60.0)))
	_spider_web_throwing      = true


## Overrides EnemyBase's virtual hook — called right before this enemy is
## removed via _die() (stomped) or _fall_off_platform() (its platform broke).
## BUG FIX: if a spider is killed (or its platform breaks) WHILE it's mid
## web-throw or mid-climb, _spider_web_line was never cleaned up — neither
## _die() nor _fall_off_platform() knew it existed, since it's a sibling
## Line2D node, not a child of the spider. The spider itself would fade out
## normally, but the web thread was left dangling in the scene forever with
## no spider attached to it. This is almost certainly the "web sometimes
## just disappears/vanishes" symptom — really it's the SPIDER vanishing
## while an orphaned web thread stays frozen in place (or, depending on
## timing, gets silently overwritten/leaked on the next throw). Despawning
## it here (same fade-out used on a normal successful climb) fixes both.
func _on_removed() -> void:
	if enemy_type == EnemyType.SPIDER:
		_spider_despawn_web()
	if enemy_type == EnemyType.UFO or (enemy_type >= EnemyType.ALIEN_GREEN and enemy_type <= EnemyType.ALIEN_YELLOW):
		# Ölümde beam'ler anında gizlenir (ölüm tween'iyle büyüyüp sönmesinler).
		_hide_ufo_laser()
		_hide_alien_laser()


func _spider_despawn_web() -> void:
	if not is_instance_valid(_spider_web_line): return
	var web := _spider_web_line
	_spider_web_line = null
	if _is_headless:
		web.queue_free()
		return
	var tw := web.create_tween()
	if tw:
		tw.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		tw.tween_property(web, "modulate:a", 0.0, 0.15)
		tw.tween_callback(func():
			if is_instance_valid(web): web.queue_free())
	else:
		web.queue_free()


# ── GHOST AI ─────────────────────────────────────────────────────────
# Aerial patrol — chases for GHOST_CHASE_DURATION when player spotted.
# NOTE: used to fade in/out (with a brief "intangible" window while faded)
# — removed per request, ghost now stays a normal solid color and is
# always hittable. _ghost_visible is kept fixed at true (see EnemyBase.gd)
# so _special_hit's old fade-gate is a permanent no-op rather than deleting
# that branch and risking a behavior change if re-enabled later.
func _ghost_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0

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
			# BUG FIX: same class of bug as WINGMAN's return — a fixed 0.5s
			# move regardless of chase distance meant a long chase snapped
			# back unnaturally fast. Duration now scales with distance /
			# GHOST_RETURN_SPEED so it always returns at its own normal pace.
			var return_dist : float = absf(global_position.y - _start_y)
			var return_secs : float = clampf(return_dist / maxf(GHOST_RETURN_SPEED, 1.0), 0.15, 2.0)
			_move_to(Vector2(global_position.x, _start_y), return_secs, false, true, false, func():
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


func _ufo_ai(delta: float) -> void:
	# UFO beam — ince dikey laser + namlu parlaması (burst) + yer impact'i (ground).
	# FIX: beam artık UFO merkezinden (yukarından) değil, göbeğinden çıkıyor.
	# Beam ince (LASER_BEAM_W); vuruş hitbox+süpürme testiyle (_laser_hits_player).
	_ufo_fire_timer = maxf(0.0, _ufo_fire_timer - delta)
	_ufo_damage_cd = maxf(0.0, _ufo_damage_cd - delta)
	var muzzle: Vector2 = global_position + Vector2(0.0, _vw * UFO_MUZZLE_DOWN_VW)
	var beam_end: Vector2 = muzzle + Vector2(0.0, _vh * 0.30)
	if _ufo_firing:
		_ufo_beam_timer -= delta
		if not _is_headless:
			var beam_top: Vector2 = muzzle - Vector2(0.0, UFO_BEAM_TOP_TUCK)
			var beam_bot: Vector2 = beam_end + Vector2(0.0, UFO_BEAM_SINK)
			var beam_len: float = beam_bot.y - beam_top.y
			_ufo_laser_sprite = _ensure_laser_child(_ufo_laser_sprite, _ALIEN_LASER_TEX, 6)
			_ufo_laser_sprite.global_position = (beam_top + beam_bot) * 0.5
			_ufo_laser_sprite.rotation = 0.0
			_ufo_laser_sprite.scale = Vector2((_vw * LASER_BEAM_W) / 38.0, beam_len / 100.0)
			_ufo_laser_sprite.visible = true
			# Namlu parlaması — burst, UFO göbeğinde oturur; beam üst ucu içinde.
			_ufo_muzzle_sprite = _ensure_laser_child(_ufo_muzzle_sprite, _TEX_LASER_BURST, 7)
			_ufo_muzzle_sprite.global_position = muzzle
			var ms: float = (_vw * UFO_MUZZLE_SIZE_VW) / 188.0
			_ufo_muzzle_sprite.scale = Vector2(ms, ms)
			_ufo_muzzle_sprite.visible = true
			_ufo_muzzle_sprite.rotation += delta * 2.5
			# Yer impact'i — dokunun çekirdek noktası (UFO_GROUND_JOINT_Y) tam
			# beam_end'e oturur; taban çizgisi şok dalgası gibi altta kalır,
			# beam alt ucu çekirdeğin içinde gömülüdür.
			_ufo_ground_sprite = _ensure_laser_child(_ufo_ground_sprite, _TEX_LASER_GROUND, 7)
			var gs: float = (_vw * UFO_GROUND_W_VW) / 172.0
			var pulse: float = 1.0 + 0.06 * sin(float(Time.get_ticks_msec()) * 0.02)
			_ufo_ground_sprite.scale = Vector2(gs, gs) * pulse
			_ufo_ground_sprite.global_position = beam_end - Vector2(0.0, (UFO_GROUND_JOINT_Y - 39.0) * gs * pulse)
			_ufo_ground_sprite.visible = true
			# Eklem flaşı — beam ile yer efektinin birleşimini maskeler; beam
			# tam olarak buradan çıkıyor gibi görünür.
			_ufo_impact_sprite = _ensure_laser_child(_ufo_impact_sprite, _TEX_LASER_BURST, 8)
			_ufo_impact_sprite.global_position = beam_end
			var js: float = (_vw * UFO_IMPACT_BURST_VW) / 188.0
			_ufo_impact_sprite.scale = Vector2(js, js)
			_ufo_impact_sprite.visible = true
			_ufo_impact_sprite.rotation -= delta * 3.0
			# Hafif titreme — beam canlı dursun (sadece görsel, oyunu etkilemez).
			var flick: float = 0.92 + 0.08 * sin(float(Time.get_ticks_msec()) * 0.025)
			_ufo_laser_sprite.modulate = Color(1, 1, 1, flick)
			_ufo_muzzle_sprite.modulate = Color(1, 1, 1, 0.9 + 0.1 * sin(float(Time.get_ticks_msec()) * 0.03))
			_ufo_impact_sprite.modulate = Color(1, 1, 1, 0.85 + 0.15 * sin(float(Time.get_ticks_msec()) * 0.035))
		if _ufo_beam_timer <= 0.0:
			_ufo_firing = false
			_hide_ufo_laser()
			return
		var p: Node = _get_player()
		if is_instance_valid(p) and _ufo_damage_cd <= 0.0:
			if _laser_hits_player(p, muzzle, beam_end):
				if p.try_beam_hit():
					_ufo_damage_cd = 0.45
		return
	if _ufo_fire_timer <= 0.0:
		_ufo_firing = true
		_ufo_beam_timer = UFO_BEAM_DURATION
		_ufo_damage_cd = 0.0
		_ufo_fire_timer = _rng.randf_range(UFO_FIRE_INTERVAL_MIN, UFO_FIRE_INTERVAL_MAX)
		if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
			if _anim.sprite_frames.has_animation("idle"):
				_anim.play("idle")


func _alien_green_ai(_delta: float) -> void:
	# Intentionally empty: patrol is driven by EnemyBase._tick_patrol().
	# Keeping this explicit avoids accidentally adding per-tick movement here.
	pass


func _alien_blue_ai(_delta: float) -> void:
	const FIXED_DELTA := 1.0 / 60.0
	if _frog_jumping: return
	_alien_jump_timer -= FIXED_DELTA
	if _alien_jump_timer > 0.0: return
	_alien_jump_timer = _rng.randf_range(2.6, 4.0)
	var neighbors := _frog_get_neighbor_platforms()
	# Mavi alien SADECE başka platforma zıplar — üstünde durduğuna asla.
	# Kimlik (stale ref güvenliği için hem _frog_cur_platform hem _platform)
	# + seviye kontrolü (bulucunun "o platform" kuralı: |Δy| ≤ 2.0) ile elenir.
	var anchor_y: float = global_position.y
	if is_instance_valid(_frog_cur_platform):
		anchor_y = _frog_cur_platform.global_position.y
	elif is_instance_valid(_platform):
		anchor_y = _platform.global_position.y
	var candidates: Array = []
	for pl in neighbors:
		if not is_instance_valid(pl):
			continue
		if pl == _frog_cur_platform or pl == _platform:
			continue
		if absf(pl.global_position.y - anchor_y) <= 2.0:
			continue
		candidates.append(pl)
	if not candidates.is_empty():
		var target_plat : Node = candidates[_rng.randi() % candidates.size()]
		if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames:
			if _anim.sprite_frames.has_animation("jump"): _anim.play("jump")
		_frog_jump_to_platform(target_plat)
	else:
		# Ulaşılabilir başka platform yoksa kendi üstünde zıplama — sadece
		# patrol'e devam et, sonraki timer'da tekrar dene.
		if not _patrol_active:
			_start_patrol_from(global_position.x, ALIEN_SPEED, true)


func _alien_pink_ai(_delta: float) -> void:
	# Pink alien fires a fixed destination laser. It does not track the player
	# after firing: the endpoint is chosen once, stays for two seconds, then
	# the beam disappears. Gameplay uses the same segment in headless mode.
	# FIX: beam artık merkezden/yukarıdan değil, namludan (göğüs hizası) çıkar.
	# Beam inceltildi (0.035 → LASER_BEAM_W), hitbox da görselle tutarlı daraltıldı.
	# Namlu + uç noktalarında burst efektleri var.
	const FIXED_DELTA: float = 1.0 / 60.0
	_alien_shoot_timer = maxf(0.0, _alien_shoot_timer - FIXED_DELTA)
	if _alien_shooting:
		_alien_laser_timer = maxf(0.0, _alien_laser_timer - FIXED_DELTA)
		var player: Node = _get_player()
		if is_instance_valid(player) and not _alien_laser_hit:
			if _laser_hits_player(player, _alien_laser_start, _alien_laser_end):
				if player.try_beam_hit():
					_alien_laser_hit = true
		if not _is_headless:
			_alien_laser_flicker()
		if _alien_laser_timer <= 0.0:
			_alien_shooting = false
			_hide_alien_laser()
			_start_patrol_from(global_position.x, ALIEN_SPEED, true)
			if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames and _anim.sprite_frames.has_animation("walk"):
				_anim.play("walk")
		return
	if _alien_shoot_timer > 0.0:
		return
	_alien_shoot_timer = _rng.randf_range(ALIEN_SHOOT_INTERVAL * 0.9, ALIEN_SHOOT_INTERVAL * 1.1)
	_alien_shooting = true
	_alien_laser_timer = 2.0
	_alien_laser_hit = false
	_stop_patrol()
	# Namlu: göğüs/silah hizası — merkezin biraz altı. Nişan da namludan alınır,
	# böylece beam görsel çıkış noktasıyla aynı doğrultuda gider.
	var muzzle: Vector2 = global_position + Vector2(0.0, _vw * ALIEN_MUZZLE_DOWN_VW)
	var player: Node = _get_player()
	var direction := Vector2.UP
	if is_instance_valid(player):
		direction = (player.global_position - muzzle).normalized()
	# Only the upper 180-degree arc is allowed. If the player is below,
	# choose the nearest upward direction instead of firing downward.
	if direction.y > 0.0:
		direction.y = -0.05
		direction = direction.normalized()
	_alien_laser_start = muzzle
	_alien_laser_end = muzzle + direction * (_vw * 0.30)
	if not _is_headless:
		_alien_laser_sprite = _ensure_laser_child(_alien_laser_sprite, _ALIEN_LASER_TEX, 6)
		# Görsel beam vuruş segmentinden iki uçta da SINK kadar uzundur —
		# uçlar burst çekirdeklerinin içinde gömülü kalır (vuruş aynı).
		var beam_a: Vector2 = _alien_laser_start - direction * ALIEN_BEAM_SINK
		var beam_b: Vector2 = _alien_laser_end + direction * ALIEN_BEAM_SINK
		_alien_laser_sprite.global_position = (beam_a + beam_b) * 0.5
		_alien_laser_sprite.rotation = direction.angle() - PI * 0.5
		_alien_laser_sprite.scale = Vector2((_vw * LASER_BEAM_W) / 38.0, ((_vw * 0.30) + ALIEN_BEAM_SINK * 2.0) / 100.0)
		_alien_laser_sprite.visible = true
		_alien_laser_sprite.modulate = Color(1, 1, 1, 1)
		# Namlu parlaması — beam'in alien'den çıktığı noktayı net gösterir.
		_alien_muzzle_sprite = _ensure_laser_child(_alien_muzzle_sprite, _TEX_LASER_BURST, 7)
		_alien_muzzle_sprite.global_position = _alien_laser_start
		var mms: float = (_vw * ALIEN_MUZZLE_SIZE_VW) / 188.0
		_alien_muzzle_sprite.scale = Vector2(mms, mms)
		_alien_muzzle_sprite.visible = true
		_alien_muzzle_sprite.modulate = Color(1, 1, 1, 1)
		# Uç impact'i — beam'in bittiği noktada patlama parlaması.
		_alien_impact_sprite = _ensure_laser_child(_alien_impact_sprite, _TEX_LASER_BURST, 7)
		_alien_impact_sprite.global_position = _alien_laser_end
		var ims: float = (_vw * ALIEN_IMPACT_SIZE_VW) / 188.0
		_alien_impact_sprite.scale = Vector2(ims, ims)
		_alien_impact_sprite.visible = true
		_alien_impact_sprite.modulate = Color(1, 1, 1, 1)
	if not _is_headless and is_instance_valid(_anim) and _anim.sprite_frames and _anim.sprite_frames.has_animation("shoot"):
		_anim.play("shoot")


# ── Laser yardımcıları (uzay biyomu) ───────────────────────────────────
# Sadece görsel — headless oyunu etkilemez. Hepsi _is_headless guard'ı altında çağrılır.
func _ensure_laser_child(cur: Sprite2D, tex: Texture2D, z: int) -> Sprite2D:
	if is_instance_valid(cur):
		if cur.texture != tex:
			cur.texture = tex
		cur.z_index = z
		return cur
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.z_index = z
	spr.centered = true
	add_child(spr)
	return spr


func _hide_ufo_laser() -> void:
	if is_instance_valid(_ufo_laser_sprite):
		_ufo_laser_sprite.visible = false
	if is_instance_valid(_ufo_muzzle_sprite):
		_ufo_muzzle_sprite.visible = false
	if is_instance_valid(_ufo_ground_sprite):
		_ufo_ground_sprite.visible = false
	if is_instance_valid(_ufo_impact_sprite):
		_ufo_impact_sprite.visible = false


func _hide_alien_laser() -> void:
	if is_instance_valid(_alien_laser_sprite):
		_alien_laser_sprite.visible = false
	if is_instance_valid(_alien_muzzle_sprite):
		_alien_muzzle_sprite.visible = false
	if is_instance_valid(_alien_impact_sprite):
		_alien_impact_sprite.visible = false


func _alien_laser_flicker() -> void:
	var t: float = float(Time.get_ticks_msec()) * 0.025
	if is_instance_valid(_alien_laser_sprite) and _alien_laser_sprite.visible:
		_alien_laser_sprite.modulate = Color(1, 1, 1, 0.9 + 0.1 * sin(t))
	if is_instance_valid(_alien_muzzle_sprite) and _alien_muzzle_sprite.visible:
		_alien_muzzle_sprite.rotation += (1.0 / 60.0) * 3.0
		_alien_muzzle_sprite.modulate = Color(1, 1, 1, 0.85 + 0.15 * sin(t * 1.3))
		var mms: float = (_vw * ALIEN_MUZZLE_SIZE_VW) / 188.0 * (1.0 + 0.08 * sin(t * 1.3))
		_alien_muzzle_sprite.scale = Vector2(mms, mms)
	if is_instance_valid(_alien_impact_sprite) and _alien_impact_sprite.visible:
		_alien_impact_sprite.rotation -= (1.0 / 60.0) * 2.0
		var k: float = clampf(_alien_laser_timer / 2.0, 0.0, 1.0)
		_alien_impact_sprite.modulate = Color(1, 1, 1, 0.65 + 0.35 * k)
		var ims: float = (_vw * ALIEN_IMPACT_SIZE_VW) / 188.0 * (1.0 + 0.10 * sin(t * 0.9 + 1.0))
		_alien_impact_sprite.scale = Vector2(ims, ims)


# Beam vuruş testi — oyuncu hitbox'ının bu tick'teki SÜPÜRÜLMÜŞ kutusu
# (tick-giriş + şu-an konumu birleşimi) ile beam segmentinin kesişimi.
# Nokta-mesafe testinden farklı olarak hızlı harekette tick-atlama yapmaz
# ve beam vücuda değdiği an (merkez daha uzaktayken bile) hasarı işletir.
# Sadece +,-,*,/ ve karşılaştırma kullanır — determinizm güvenli (sin/cos yok).
func _laser_hits_player(p: Node, a: Vector2, b: Vector2) -> bool:
	if not is_instance_valid(p):
		return false
	var cur: Vector2 = p.global_position
	var ex0: float = cur.x
	var ey0: float = cur.y
	var entry: Variant = p.get("_tick_entry_position")
	if entry is Vector2:
		ex0 = (entry as Vector2).x
		ey0 = (entry as Vector2).y
		# WRAP FIX (_tick_player_overlap ile aynı): ekran-sarma ışınlanmasında
		# giriş→çıkış tüm ekranı kateder gibi görünür; o tick süpürme yapma.
		if absf(cur.x - ex0) > _vw * 0.5:
			ex0 = cur.x
			ey0 = cur.y
	# Oyuncu hitbox yarı-ölçüleri — Player.gd HITBOX_W/H_RATIO ile aynı değerler.
	var phw: float = _vw * 0.024
	var phh: float = _vh * 0.025
	var pad: float = LASER_HIT_PAD
	var minx: float = minf(ex0, cur.x) - phw - pad
	var maxx: float = maxf(ex0, cur.x) + phw + pad
	var miny: float = minf(ey0, cur.y) - phh - pad
	var maxy: float = maxf(ey0, cur.y) + phh + pad
	return _seg_intersects_aabb(a, b, minx, miny, maxx, maxy)


# Segment-vs-AABB kesişimi (slab yöntemi). Determinizm güvenli.
func _seg_intersects_aabb(a: Vector2, b: Vector2, minx: float, miny: float, maxx: float, maxy: float) -> bool:
	var tmin := 0.0
	var tmax := 1.0
	var dx: float = b.x - a.x
	var dy: float = b.y - a.y
	if absf(dx) < 0.000001:
		if a.x < minx or a.x > maxx:
			return false
	else:
		var t1: float = (minx - a.x) / dx
		var t2: float = (maxx - a.x) / dx
		if t1 > t2:
			var tt: float = t1
			t1 = t2
			t2 = tt
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return false
	if absf(dy) < 0.000001:
		if a.y < miny or a.y > maxy:
			return false
	else:
		var u1: float = (miny - a.y) / dy
		var u2: float = (maxy - a.y) / dy
		if u1 > u2:
			var uu: float = u1
			u1 = u2
			u2 = uu
		tmin = maxf(tmin, u1)
		tmax = minf(tmax, u2)
		if tmin > tmax:
			return false
	return true


func _distance_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment: Vector2 = finish - start
	var length_sq: float = segment.length_squared()
	if length_sq <= 0.0001:
		return point.distance_to(start)
	var t: float = clampf((point - start).dot(segment) / length_sq, 0.0, 1.0)
	return point.distance_to(start + segment * t)
