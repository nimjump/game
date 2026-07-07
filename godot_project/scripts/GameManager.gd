@tool
extends Node2D

# ═══════════════════════════════════════════════════════════════════
#  GameManager.gd  —  Tüm oyun döngüsünü yönetir
# ═══════════════════════════════════════════════════════════════════

func _ready() -> void:
	if Engine.is_editor_hint():
		call_deferred("_editor_setup", _get_scene_camera())
		return


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_cleanup_editor_preview()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		call_deferred("_editor_setup", _get_scene_camera())


func _get_scene_camera() -> Camera2D:
	var parent := get_parent()
	if parent:
		return parent.get_node_or_null("Camera2D") as Camera2D
	return null

const SCREEN_W       := 600.0
const SCREEN_H       := 800.0
const PLATFORM_W     := 116.0
const PLATFORM_H     := 18.0
const SPAWN_ABOVE    := 1400.0
const DESPAWN_BELOW  := 900.0
const BASE_GAP        := 95.0
const MAX_GAP         := 150.0
const JETPACK_GAP     := 9999.0
const DIFFICULTY_RATE := 0.00012
const ENEMY_BASE_PROB  := 0.28
const ENEMY_MAX_PROB   := 0.60
const ITEM_BASE_PROB   := 0.22
const BROKEN_BASE_PROB := 0.05

# ── Referanslar ─────────────────────────────────────────────────────
var camera      : Camera2D
var player      : CharacterBody2D
var main_node    : Node   # Main.gd referansi (powerup HUD + go_panel icin)

# ── Oyun durumu ─────────────────────────────────────────────────────
var highest_y   := 0.0
var score       := 0
var best_score  := 0
var _game_over  := false

# ── Platform takip ─────────────────────────────────────────────────
var _platforms      : Array[Node2D] = []
var _enemies        : Array[Node2D] = []
var _highest_plat_y := 0.0

# ── Texture önbelleği ───────────────────────────────────────────────
var _ground_sets    : Array[Dictionary] = []
var _enemy_frames   : Dictionary = {}
var _item_frames    : Dictionary = {}


# ── Seed + RNG ──────────────────────────────────────────────────────
var _rng            : RandomNumberGenerator = RandomNumberGenerator.new()
var game_seed       : int = 0
var _seed_ready     := false
var _spawn_pending  := false

# ── Kamera shake ────────────────────────────────────────────────────
var _shake_timer    := 0.0
var _shake_strength := 0.0

# ── Input kayıt ─────────────────────────────────────────────────────
var session_id      : String = ""
var _input_log      : Array  = []
var _log_timer      : float  = 0.0
const LOG_INTERVAL  := 0.05

const BACKEND_URL   := "http://localhost:8080"


# ───────────────────────────────────────────────────────────────────
#  EDITOR LIVE PREVIEW KURULUMU
# ───────────────────────────────────────────────────────────────────
func _cleanup_editor_preview() -> void:
	_clear_spawned_world()
	for ch in get_children():
		remove_child(ch)
		ch.free()


func _clear_spawned_world() -> void:
	_platforms.clear()
	_enemies.clear()
	for ch in get_children():
		if ch is HTTPRequest:
			continue
		remove_child(ch)
		ch.free()
	_highest_plat_y = SCREEN_H * 0.72


func _editor_setup(cam: Camera2D) -> void:
	_cleanup_editor_preview()
	_load_all_textures()

	camera = cam
	if camera:
		camera.position = Vector2(SCREEN_W * 0.5, SCREEN_H * 0.5)

	# Sabit seed: her açılışta aynı dünya (oyun başlangıcıyla aynı mantık)
	game_seed = 12345
	_rng.seed = game_seed
	_highest_plat_y = SCREEN_H * 0.72

	_spawn_initial_platforms(true)


func _ensure_preview_player(pos: Vector2) -> void:
	var plr_spr := get_node_or_null("PreviewPlayer") as Sprite2D
	if plr_spr == null:
		plr_spr = Sprite2D.new()
		plr_spr.name = "PreviewPlayer"
		plr_spr.z_index = 5
		add_child(plr_spr)
	var plr_tex_path := "res://assets/players/bunny1_stand.png"
	if ResourceLoader.exists(plr_tex_path):
		plr_spr.texture = load(plr_tex_path)
	plr_spr.scale = Vector2(0.28, 0.28)
	plr_spr.position = pos


# ───────────────────────────────────────────────────────────────────
# init: eski score_label/best_label/final_label parametreleri kaldırıldı,
# yerlerini Main.gd'deki _DigitDisplay'ler aldı. İmza uyumluluğu için
# artık kullanılmayan 3 parametre yok sayılıyor.
# ───────────────────────────────────────────────────────────────────
func init(p_cam, p_player, _p_score, _p_best, _p_final, p_main) -> void:
	camera    = p_cam
	player    = p_player
	main_node = p_main

	game_seed  = randi()
	_rng.seed  = game_seed
	session_id = "%d_%d" % [game_seed, Time.get_unix_time_from_system()]

	if player:
		if not player.died.is_connected(_on_player_died):
			player.died.connect(_on_player_died)
		if not player.collected_item.is_connected(_on_item_event):
			player.collected_item.connect(_on_item_event)

	_load_all_textures()
	_clear_spawned_world()

	if camera:
		camera.make_current()
		camera.offset   = Vector2.ZERO
		camera.position = Vector2(SCREEN_W * 0.5, player.position.y if player else SCREEN_H * 0.5)

	_spawn_initial_platforms()
	_reset_player_start_pos()
	_fetch_seed_from_server()


func _reset_player_start_pos() -> void:
	if player == null:
		return
	var start_plat_y := SCREEN_H * 0.72 + 24.0
	player.position = Vector2(SCREEN_W * 0.5, start_plat_y - PLATFORM_H * 0.5 - 20.0)


# ───────────────────────────────────────────────────────────────────
#  TEXTURE YÜKLEME
# ───────────────────────────────────────────────────────────────────
func _t(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5))
	return ImageTexture.create_from_image(img)


func _load_all_textures() -> void:
	_ground_sets.clear()
	_enemy_frames.clear()
	_item_frames.clear()

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
		"fly":  [_t(en + "flyMan_fly.png"), _t(en + "flyMan_jump.png"),
				 _t(en + "flyMan_stand.png"), _t(en + "flyMan_jump.png")],
		"idle": [_t(en + "flyMan_still_stand.png"), _t(en + "flyMan_still_fly.png"),
				 _t(en + "flyMan_still_jump.png"), _t(en + "flyMan_still_fly.png")],
		"hurt": [_t(en + "flyMan_still_stand.png")],
	}
	_enemy_frames[Enemy.EnemyType.WINGMAN] = {
		"fly":  [_t(en + "wingMan1.png"), _t(en + "wingMan2.png"),
				 _t(en + "wingMan3.png"), _t(en + "wingMan4.png"),
				 _t(en + "wingMan5.png"), _t(en + "wingMan4.png"),
				 _t(en + "wingMan3.png"), _t(en + "wingMan2.png")],
		"idle": [_t(en + "wingMan1.png"), _t(en + "wingMan2.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPIKEMAN] = {
		"walk": [_t(en + "spikeMan_stand.png"), _t(en + "spikeMan_walk1.png"),
				 _t(en + "spikeMan_walk2.png"), _t(en + "spikeMan_walk1.png")],
		"idle": [_t(en + "spikeMan_stand.png")],
		"hurt": [_t(en + "spikeMan_jump.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPIKEBALL] = {
		"idle": [_t(en + "spikeBall1.png"), _t(en + "spikeBall_2.png")],
	}
	_enemy_frames[Enemy.EnemyType.SPRINGMAN] = {
		"idle": [_t(en + "springMan_stand.png"), _t(en + "springMan_hurt.png"),
				 _t(en + "springMan_stand.png")],
		"hurt": [_t(en + "springMan_hurt.png")],
	}
	_enemy_frames[Enemy.EnemyType.SUN] = {
		"idle": [_t(en + "sun1.png"), _t(en + "sun2.png")],
	}
	_enemy_frames[Enemy.EnemyType.CLOUD] = {
		"idle": [_t(en + "cloud.png")],
	}

	# ── YENİ YARATIKLAR ────────────────────────────────────────────────
	_enemy_frames[Enemy.EnemyType.BARNACLE] = {
		"idle":   [_t(en + "barnacle.png")],
		"attack": [_t(en + "barnacle_attack.png")],
		"hurt":   [_t(en + "barnacle_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.BEE] = {
		"fly":  [_t(en + "bee.png"), _t(en + "bee_move.png"), _t(en + "bee.png"), _t(en + "bee_move.png")],
		"hurt": [_t(en + "bee_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.FLY] = {
		"fly":  [_t(en + "fly.png"), _t(en + "fly_move.png"), _t(en + "fly.png"), _t(en + "fly_move.png")],
		"hurt": [_t(en + "fly_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.FROG] = {
		"idle": [_t(en + "frog.png")],
		"walk": [_t(en + "frog_move.png")],
		"hurt": [_t(en + "frog_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.MOUSE] = {
		"walk": [_t(en + "mouse.png"), _t(en + "mouse_move.png"), _t(en + "mouse.png"), _t(en + "mouse_move.png")],
		"hurt": [_t(en + "mouse_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_BLOCK] = {
		"idle": [_t(en + "slimeBlock.png"), _t(en + "slimeBlock_move.png")],
		"hurt": [_t(en + "slimeBlock_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_BLUE] = {
		"walk": [_t(en + "slimeBlue.png"), _t(en + "slimeBlue_move.png")],
		"hurt": [_t(en + "slimeBlue_hit.png"), _t(en + "slimeBlue_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_GREEN] = {
		"walk": [_t(en + "slimeGreen.png"), _t(en + "slimeGreen_move.png")],
		"hurt": [_t(en + "slimeGreen_hit.png"), _t(en + "slimeGreen_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_PURPLE] = {
		"walk": [_t(en + "slimePurple.png"), _t(en + "slimePurple_move.png")],
		"hurt": [_t(en + "slimePurple_hit.png"), _t(en + "slimePurple_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SNAIL] = {
		"walk":  [_t(en + "snail.png"), _t(en + "snail_move.png")],
		"shell": [_t(en + "snail_shell.png")],
	}
	_enemy_frames[Enemy.EnemyType.WORM_GREEN] = {
		"walk": [_t(en + "wormGreen.png"), _t(en + "wormGreen_move.png"), _t(en + "wormGreen.png"), _t(en + "wormGreen_move.png")],
		"hurt": [_t(en + "wormGreen_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.WORM_PINK] = {
		"walk": [_t(en + "wormPink.png"), _t(en + "wormPink_move.png"), _t(en + "wormPink.png"), _t(en + "wormPink_move.png")],
		"hurt": [_t(en + "wormPink_dead.png")],
	}
	_enemy_frames[Enemy.EnemyType.SLIME_FIRE] = {
		"walk": [_t(en + "slime_fire_walk_a.png"), _t(en + "slime_fire_walk_b.png"),
				 _t(en + "slime_fire_walk_a.png"), _t(en + "slime_fire_walk_b.png")],
		"idle": [_t(en + "slime_fire_rest.png")],
		"hurt": [_t(en + "slime_fire_flat.png")],
	}
	_enemy_frames[Enemy.EnemyType.LADYBUG] = {
		"fly":  [_t(en + "ladybug_fly.png"), _t(en + "ladybug_walk_a.png"),
				 _t(en + "ladybug_fly.png"), _t(en + "ladybug_walk_b.png")],
		"walk": [_t(en + "ladybug_walk_a.png"), _t(en + "ladybug_walk_b.png"),
				 _t(en + "ladybug_walk_a.png"), _t(en + "ladybug_walk_b.png")],
		"idle": [_t(en + "ladybug_rest.png")],
	}

	var it := "res://assets/items/"
	_item_frames[Item.ItemType.GOLD]          = [_t(it + "gold_1.png"),   _t(it + "gold_2.png"),   _t(it + "gold_3.png")]
	_item_frames[Item.ItemType.SILVER]        = [_t(it + "silver_1.png"), _t(it + "silver_2.png"), _t(it + "silver_3.png")]
	_item_frames[Item.ItemType.BRONZE]        = [_t(it + "bronze_1.png"), _t(it + "bronze_2.png"), _t(it + "bronze_3.png")]
	_item_frames[Item.ItemType.CARROT]        = [_t(it + "carrot.png")]
	_item_frames[Item.ItemType.GOLDEN_CARROT] = [_t(it + "carrot_gold.png")]
	_item_frames[Item.ItemType.JETPACK]       = [_t(it + "jetpack_item.png")]
	_item_frames[Item.ItemType.WINGS]         = [_t(it + "powerup_wings.png")]
	_item_frames[Item.ItemType.BUBBLE]        = [_t(it + "powerup_bubble.png")]


# ───────────────────────────────────────────────────────────────────
#  ANA DÖNGÜ
# ───────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	if _game_over: return
	if player == null or camera == null: return

	camera.position.x = SCREEN_W * 0.5
	var target_y := minf(camera.position.y, player.position.y)
	if target_y < camera.position.y:
		var new_y := lerpf(camera.position.y, target_y, minf(25.0 * delta, 1.0))
		camera.position.y = roundf(new_y)

	var height := (SCREEN_H * 0.72) - player.position.y
	if height > highest_y:
		highest_y = height
		score     = int(highest_y * 0.1)
		# Sadece main_node üzerinden güncelle — Label yok
		if is_instance_valid(main_node) and main_node.has_method("update_score_display"):
			main_node.call("update_score_display", score)
		if score > best_score:
			best_score = score
			if is_instance_valid(main_node) and main_node.has_method("update_best_display"):
				main_node.call("update_best_display", best_score)

	_update_powerup_hud()
	_manage_platforms()
	_apply_camera_shake(delta)

	_log_timer += delta
	if _log_timer >= LOG_INTERVAL:
		_log_timer = 0.0
		_input_log.append({
			"t":  snappedf(Time.get_unix_time_from_system(), 0.001),
			"x":  snappedf(player.position.x, 0.1),
			"y":  snappedf(player.position.y, 0.1),
			"vx": snappedf(player.velocity.x, 0.1),
			"vy": snappedf(player.velocity.y, 0.1),
			"l":  int(Input.is_action_pressed("ui_left") or Input.is_action_pressed("move_left")),
			"r":  int(Input.is_action_pressed("ui_right") or Input.is_action_pressed("move_right")),
		})

	if player.position.y > camera.position.y + SCREEN_H * 0.75:
		if player.has_shield:
			player.has_shield = false
			player.velocity.y = player.JUMP_SPEED * 1.7
			player._hurt_flash = 0.6
		else:
			player.die()

func _process(_delta: float) -> void:
	pass


# ───────────────────────────────────────────────────────────────────
#  PLATFORM YÖNETİMİ
# ───────────────────────────────────────────────────────────────────
func _manage_platforms() -> void:
	var cam_y      := camera.position.y
	var cam_top    := cam_y - SCREEN_H * 0.5
	var spawn_line := cam_top - SPAWN_ABOVE
	var kill_line  := cam_y + SCREEN_H * 0.5 + DESPAWN_BELOW

	while _highest_plat_y > spawn_line:
		_highest_plat_y -= _current_gap()
		var x         := _rng.randf_range(60.0, SCREEN_W - 60.0)
		var is_broken := _rng.randf() < lerpf(BROKEN_BASE_PROB, 0.28, _difficulty())
		_spawn_platform(Vector2(x, _highest_plat_y), is_broken)

	for i in range(_platforms.size() - 1, -1, -1):
		var plat := _platforms[i]
		if not is_instance_valid(plat):
			_platforms.remove_at(i)
			continue
		if plat.position.y > kill_line:
			plat.queue_free()
			_platforms.remove_at(i)

	for i in range(_enemies.size() - 1, -1, -1):
		var e := _enemies[i]
		if not is_instance_valid(e):
			_enemies.remove_at(i)
			continue
		if e.global_position.y > kill_line:
			e.queue_free()
			_enemies.remove_at(i)


func _spawn_initial_platforms(for_editor: bool = false) -> void:
	var start_plat_y := SCREEN_H * 0.72 + 24.0
	_spawn_platform(Vector2(SCREEN_W * 0.5, start_plat_y), false, true)
	var player_pos := Vector2(SCREEN_W * 0.5, start_plat_y - PLATFORM_H * 0.5 - 20.0)
	if for_editor:
		_ensure_preview_player(player_pos)
	elif player:
		player.position = player_pos
	for i in 6:
		_highest_plat_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(80.0, SCREEN_W - 80.0)
		_spawn_platform(Vector2(x, _highest_plat_y), false, true)
	for i in 14:
		_highest_plat_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(60.0, SCREEN_W - 60.0)
		_spawn_platform(Vector2(x, _highest_plat_y), false)


# ═══════════════════════════════════════════════════════════════════════
#  BURASI GameManager.gd'nin SONUNA eklenecek
#  (spawn_platform fonksiyonunun hemen altına yapıştır)
# ═══════════════════════════════════════════════════════════════════════

func _spawn_platform(pos: Vector2, is_broken: bool, is_start: bool = false) -> void:
	# Texture setini al (biome'a göre grass/stone/snow vs.)
	var gs      := _ground_set_for_height(pos.y)
	var tex     : Texture2D = gs["normal"]
	var tex_brk : Texture2D = gs["broken"]
	var gname   : String    = gs["name"]
	var diff    := _difficulty()

	# Platform node'unu koddan üret
	var plat := Platform.new()
	add_child(plat)

	var ptype := Platform.PlatformType.BROKEN if (is_broken and not is_start) \
			else Platform.PlatformType.NORMAL

	plat.setup(ptype, tex, Vector2(PLATFORM_W, PLATFORM_H), tex_brk, diff)
	plat.position    = pos
	plat.game_manager = self
	_platforms.append(plat)

	# Başlangıç platformlarına deko/düşman/item ekleme
	if is_start:
		return

	# Dekorasyon
	_add_deco(plat, gname)

	# Düşman veya item şansı
	var enemy_prob := lerpf(ENEMY_BASE_PROB, ENEMY_MAX_PROB, diff)
	var item_prob  := lerpf(ITEM_BASE_PROB, 0.35, diff)
	var roll       := _rng.randf()

	if roll < enemy_prob:
		_add_enemy(plat)
	elif roll < enemy_prob + item_prob:
		# Yüksek boşluklu platformlarda jetpack/wings zorla
		if _current_gap() >= JETPACK_GAP * 0.5:
			_add_forced_item(plat)
		else:
			_add_item(plat)

	# Spike şansı (zorlukla artar)
	if _rng.randf() < lerpf(0.05, 0.18, diff):
		if _rng.randf() < 0.5:
			_add_spikes(plat)
		else:
			_add_spike_bottom(plat)

	# Yay şansı (sabit düşük)
	if _rng.randf() < 0.08:
		_add_spring(plat)
		
func _add_deco(plat: StaticBody2D, gname: String) -> void:
	var env := "res://assets/environment/"
	var par := "res://assets/particles/"

	match gname:
		"grass":
			if _rng.randf() < 0.60:
				var grass := "grass1.png" if _rng.randf() < 0.5 else "grass2.png"
				var side  := -32.0 if _rng.randf() < 0.5 else 32.0
				_place_deco(plat, env + grass, side, 22)
			if _rng.randf() < 0.30:
				_place_deco(plat, par + "particle_green.png", _rng.randf_range(-40.0, 40.0), 8)
		"sand":
			if _rng.randf() < 0.70:
				var cx := -34.0 if _rng.randf() < 0.5 else 34.0
				_place_deco(plat, env + "cactus.png", cx, 26)
		"wood":
			var roll := _rng.randf()
			if roll < 0.25:
				_place_deco(plat, env + "mushroom_brown.png", -28.0, 22)
				_place_deco(plat, env + "mushroom_red.png",    28.0, 18)
			elif roll < 0.50:
				var mush := "mushroom_brown.png" if _rng.randf() < 0.5 else "mushroom_red.png"
				var side := -28.0 if _rng.randf() < 0.5 else 28.0
				_place_deco(plat, env + mush, side, 22)
		"snow":
			if _rng.randf() < 0.55:
				var gb   := "grass_brown1.png" if _rng.randf() < 0.5 else "grass_brown2.png"
				var side := -32.0 if _rng.randf() < 0.5 else 32.0
				_place_deco(plat, env + gb, side, 18)
		"stone":
			if _rng.randf() < 0.40:
				var side := -38.0 if _rng.randf() < 0.5 else 38.0
				_place_deco(plat, par + "particle_grey.png", side, 10)
		"cake":
			if _rng.randf() < 0.45:
				var mush := "mushroom_red.png" if _rng.randf() < 0.5 else "mushroom_brown.png"
				var side := -26.0 if _rng.randf() < 0.5 else 26.0
				_place_deco(plat, env + mush, side, 20)


func _place_deco(plat: StaticBody2D, path: String, x: float, target_h: int) -> void:
	if not ResourceLoader.exists(path): return
	var tex := load(path) as Texture2D
	if not tex: return
	var half_plat := PLATFORM_W * 0.5 - 6.0
	x = clampf(x, -half_plat, half_plat)
	var sc := float(target_h) / float(tex.get_height())
	var spr := Sprite2D.new()
	spr.texture  = tex
	spr.scale    = Vector2(sc, sc)
	spr.z_index  = 2
	spr.position = Vector2(x, -(PLATFORM_H * 0.5) - float(target_h) * 0.5)
	plat.add_child(spr)


func _add_spikes(plat: StaticBody2D) -> void:
	var use_wide := _rng.randf() < 0.4
	if use_wide:
		var tex := _t("res://assets/environment/spikes_top.png")
		var tw := float(tex.get_width());  var th := float(tex.get_height())
		if tw <= 4.0 or th <= 4.0: return   # placeholder — çizme
		# Hedef yükseklik: 18px — platforma taşmayacak şekilde genişlik
		const TARGET_H := 18.0
		var sc_y := TARGET_H / th
		var sc_x := minf(sc_y * (tw / th), PLATFORM_W / tw)
		var vis_w := tw * sc_x;  var vis_h := th * sc_y
		var area := Area2D.new()
		area.collision_layer = 4;  area.collision_mask = 1
		area.monitoring = true;    area.monitorable = true
		area.position = Vector2(0, -(PLATFORM_H * 0.5) - vis_h * 0.5)
		plat.add_child(area)
		var spr := Sprite2D.new()
		spr.texture = tex;  spr.scale = Vector2(sc_x, sc_y)
		area.add_child(spr)
		# Collision: sadece üst %40'lık diken ucu — tabanı değil
		var rb := RectangleShape2D.new()
		rb.size = Vector2(vis_w * 0.85, vis_h * 0.45)
		var col := CollisionShape2D.new()
		col.shape = rb;  col.position = Vector2(0, -vis_h * 0.25)
		area.add_child(col)
		area.body_entered.connect(func(body: Node):
			if body.is_in_group("player") and body.has_method("hit_enemy"):
				if not body.is_powered_up: body.hit_enemy()
		)
	else:
		var spike_tex := _t("res://assets/environment/spike_top.png")
		var tw := float(spike_tex.get_width());  var th := float(spike_tex.get_height())
		if tw <= 4.0 or th <= 4.0: return   # placeholder — çizme
		# Hedef yükseklik: 14px
		const TARGET_H := 14.0
		var sc := TARGET_H / th
		var vis_h := TARGET_H;  var vis_w := tw * sc
		var spike_count := _rng.randi_range(2, 4)
		var spacing := PLATFORM_W / float(spike_count + 1)
		for i in spike_count:
			var area := Area2D.new()
			area.collision_layer = 4;  area.collision_mask = 1
			area.monitoring = true;    area.monitorable = true
			area.position = Vector2(
				-PLATFORM_W * 0.5 + spacing * (i + 1),
				-(PLATFORM_H * 0.5) - vis_h * 0.5)
			plat.add_child(area)
			var spr := Sprite2D.new()
			spr.texture = spike_tex;  spr.scale = Vector2(sc, sc)
			area.add_child(spr)
			# Collision: sadece uç kısım (üst yarı)
			var cs := CircleShape2D.new()
			cs.radius = minf(vis_w, vis_h) * 0.35
			var col := CollisionShape2D.new()
			col.shape = cs;  col.position = Vector2(0, -vis_h * 0.2)
			area.add_child(col)
			area.body_entered.connect(func(body: Node):
				if body.is_in_group("player") and body.has_method("hit_enemy"):
					if not body.is_powered_up: body.hit_enemy()
			)


func _add_spike_bottom(plat: StaticBody2D) -> void:
	var tex := _t("res://assets/environment/spike_bottom.png")
	var sc    := 16.0 / 87.0
	var vis_h := 87.0 * sc
	var area := Area2D.new()
	area.collision_layer = 4
	area.collision_mask  = 1
	area.monitoring  = true
	area.monitorable = true
	area.position = Vector2(0, (PLATFORM_H * 0.5) + vis_h * 0.5)
	plat.add_child(area)
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.scale   = Vector2(sc, sc)
	area.add_child(spr)
	var rb := RectangleShape2D.new()
	rb.size = Vector2(PLATFORM_W * 0.6, vis_h * 0.6)
	var col := CollisionShape2D.new()
	col.shape = rb
	area.add_child(col)
	area.body_entered.connect(func(body: Node):
		if body.is_in_group("player") and body.has_method("hit_enemy"):
			if not body.is_powered_up:
				body.hit_enemy()
	)


func _add_spring(plat: StaticBody2D) -> void:
	var area := Area2D.new()
	area.collision_layer = 4
	area.collision_mask  = 1
	area.monitoring  = true
	area.monitorable = true
	area.position    = Vector2(0, 0)
	plat.add_child(area)

	var tex_in  := _t("res://assets/items/spring_in.png")
	var tex_mid := _t("res://assets/items/spring.png")
	var tex_out := _t("res://assets/items/spring_out.png")

	var sf := SpriteFrames.new()
	sf.add_animation("idle"); sf.set_animation_loop("idle", false); sf.set_animation_speed("idle", 1.0)
	sf.add_frame("idle", tex_out)
	sf.add_animation("press"); sf.set_animation_loop("press", false); sf.set_animation_speed("press", 8.0)
	sf.add_frame("press", tex_mid)
	sf.add_frame("press", tex_in)
	sf.add_animation("release"); sf.set_animation_loop("release", false); sf.set_animation_speed("release", 6.0)
	sf.add_frame("release", tex_in)
	sf.add_frame("release", tex_mid)
	sf.add_frame("release", tex_out)

	var anim := AnimatedSprite2D.new()
	anim.sprite_frames = sf
	var sc := 28.0 / float(tex_out.get_width())
	anim.scale = Vector2(sc, sc)
	var h_out := float(tex_out.get_height()) * sc
	anim.position = Vector2.ZERO
	anim.play("idle")
	area.add_child(anim)

	var cs := CircleShape2D.new()
	cs.radius = 14
	var col := CollisionShape2D.new()
	col.shape    = cs
	col.position = Vector2.ZERO
	area.add_child(col)

	var _used := false
	area.position = Vector2(0, -(PLATFORM_H * 0.5) - h_out * 0.5)
	area.body_entered.connect(func(body: Node):
		if not body.is_in_group("player"): return
		if _used: return
		_used = true
		anim.play("press")
		body.do_spring_jump()
		camera_shake(4.0, 0.15)
		var tw := area.create_tween()
		if tw:
			tw.tween_interval(0.18)
			tw.tween_callback(func():
				if is_instance_valid(anim): anim.play("release")
			)
			tw.tween_interval(0.35)
			tw.tween_callback(func():
				_used = false
				if is_instance_valid(anim): anim.play("idle")
			)
	)


func _enemies_for_biome() -> Array[Enemy.EnemyType]:
	var biome := _biome_name_for_score(score)
	var pool : Array[Enemy.EnemyType] = []

	match biome:
		"grass":
			pool = [
				Enemy.EnemyType.BEE,
				Enemy.EnemyType.FROG,
				Enemy.EnemyType.MOUSE,
				Enemy.EnemyType.SUN,
				Enemy.EnemyType.WORM_GREEN,
				Enemy.EnemyType.LADYBUG,
			]
		"stone":
			pool = [
				Enemy.EnemyType.FLY,
				Enemy.EnemyType.SPIKEBALL,
				Enemy.EnemyType.SPIKEMAN,
				Enemy.EnemyType.SPRINGMAN,
			]
		"snow":
			pool = [
				Enemy.EnemyType.SNAIL,
				Enemy.EnemyType.SLIME_BLUE,
				Enemy.EnemyType.SLIME_GREEN,
				Enemy.EnemyType.SLIME_PURPLE,
				Enemy.EnemyType.SLIME_BLOCK,
				Enemy.EnemyType.SLIME_FIRE,
			]
		"wood":
			pool = [
				Enemy.EnemyType.FLYMAN,
				Enemy.EnemyType.WINGMAN,
				Enemy.EnemyType.BARNACLE,
				Enemy.EnemyType.WORM_PINK,
			]
		_: # cake
			pool = [
				Enemy.EnemyType.CLOUD,
			]

	var available : Array[Enemy.EnemyType] = []
	for t in pool:
		if _enemy_frames.has(t):
			available.append(t)
	return available


func _add_enemy(plat: StaticBody2D) -> void:
	if _enemy_frames.is_empty(): return

	var available := _enemies_for_biome()
	if available.is_empty(): return

	var etype := available[_rng.randi() % available.size()]
	var frames : Dictionary = _enemy_frames.get(etype, {})
	if frames.is_empty(): return

	var enemy : EnemyBase = load("res://scripts/Enemy.gd").new()
	add_child(enemy)
	# Platform yarısı (9) + enemy radius (18) = 27 — tam platformun üstüne otur
	enemy.global_position = plat.global_position + Vector2(0, -(PLATFORM_H * 0.5 + 18.0))

	# Önce platform bağlantısını kur — _platform, setup/_special_setup'tan önce hazır olsun
	if plat.has_method("connect_enemy"):
		plat.connect_enemy(enemy)
	elif plat.has_signal("platform_broke"):
		plat.platform_broke.connect(func():
			if is_instance_valid(enemy) and enemy.has_method("_die"):
				enemy.call("_die")
		)

	enemy.setup(etype, frames, _difficulty())
	_enemies.append(enemy)


func _add_item(plat: StaticBody2D) -> void:
	var all_types: Array[Item.ItemType] = [
		Item.ItemType.GOLD, Item.ItemType.SILVER, Item.ItemType.BRONZE,
		Item.ItemType.CARROT, Item.ItemType.JETPACK, Item.ItemType.WINGS,
		Item.ItemType.BUBBLE, Item.ItemType.GOLDEN_CARROT
	]
	var d := _difficulty()
	var weights : Array[int] = [
		int(lerpf(3, 1, d)),
		int(lerpf(5, 3, d)),
		int(lerpf(7, 4, d)),
		int(lerpf(3, 6, d)),
		1,
		1,
		int(lerpf(2, 4, d)),
		1,
	]
	var total := 0
	for w in weights: total += w
	var roll := _rng.randi() % total
	var cumul := 0
	var chosen := 0
	for idx in weights.size():
		cumul += weights[idx]
		if roll < cumul: chosen = idx; break
	var itype : Item.ItemType = all_types[chosen]
	var item : Item = load("res://scripts/Item.gd").new()
	add_child(item)
	item.global_position = plat.global_position + Vector2(0, -48)
	item.setup(itype, _item_frames.get(itype, []))
	item.item_collected.connect(_on_item_collected)


func _add_forced_item(plat: StaticBody2D) -> void:
	var itype : Item.ItemType = Item.ItemType.JETPACK if _rng.randf() >= 0.6 else Item.ItemType.WINGS
	var item : Item = load("res://scripts/Item.gd").new()
	add_child(item)
	item.global_position = plat.global_position + Vector2(0, -48)
	item.setup(itype, _item_frames.get(itype, []))
	item.item_collected.connect(_on_item_collected)


func _biome_name_for_score(s: int) -> String:
	# Her 2500 skorluk döngü: grass→stone→snow→wood→cake
	const CYCLE := 2500
	var phase := s % CYCLE
	if phase < 500:    return "grass"
	elif phase < 1000: return "stone"
	elif phase < 1500: return "snow"
	elif phase < 2000: return "wood"
	else:              return "cake"


func _ground_set_for_height(_y: float) -> Dictionary:
	var name_filter := _biome_name_for_score(score)
	for gs in _ground_sets:
		if gs.get("name", "") == name_filter:
			return gs
	return _ground_sets[_rng.randi() % _ground_sets.size()]


func _difficulty() -> float:
	return clampf(highest_y * DIFFICULTY_RATE, 0.0, 1.0)


# ── Kamera shake ─────────────────────────────────────────────────────
func camera_shake(strength: float, duration: float) -> void:
	_shake_strength = strength
	_shake_timer    = duration

func _apply_camera_shake(delta: float) -> void:
	if _shake_timer <= 0.0:
		camera.offset = Vector2.ZERO
		return
	_shake_timer -= delta
	var s := _shake_strength * (_shake_timer / maxf(_shake_timer + delta, 0.001))
	camera.offset = Vector2(
		roundf(randf_range(-s, s)),
		roundf(randf_range(-s, s))
	)


func _current_gap() -> float:
	return lerpf(BASE_GAP, MAX_GAP, _difficulty())


func _on_item_collected(_itype: int, points: int) -> void:
	score += points
	if is_instance_valid(main_node) and main_node.has_method("update_score_display"):
		main_node.call("update_score_display", score)


func _on_item_event(type: String) -> void:
	if type == "shield_lost":
		if is_instance_valid(main_node):
			main_node.call("update_powerup_hud",
				player.is_powered_up, player.powerup_type,
				player.powerup_timer, 5.0 if player.powerup_type == "jetpack" else 4.0,
				false, 0.0, 1.0)


var _last_main_active   := false
var _last_main_type     := ""
var _last_shield_active := false

func _update_powerup_hud() -> void:
	if not is_instance_valid(player): return
	if not is_instance_valid(main_node): return

	var main_active : bool = player.is_powered_up
	var main_type : String = player.powerup_type
	var shield_active : bool = player.has_shield

	if main_active != _last_main_active or main_type != _last_main_type or shield_active != _last_shield_active:
		_last_main_active   = main_active
		_last_main_type     = main_type
		_last_shield_active = shield_active

		var main_tmax   := 5.0 if main_type == "jetpack" else 4.0
		var main_tcur : float = player.powerup_timer if main_active else 0.0
		var shield_tmax := 1.0
		var shield_tcur := 1.0
		main_node.call("update_powerup_hud",
			main_active, main_type, main_tcur, main_tmax,
			shield_active, shield_tcur, shield_tmax)

	if main_active and main_node._powerup_slots.size() > 0:
		main_node._powerup_slots[0]["t_cur_live"] = player.powerup_timer
		main_node._powerup_slots[0]["arc"].t_cur  = player.powerup_timer


func _on_player_died() -> void:
	if _game_over: return
	_game_over = true
	camera_shake(10.0, 0.45)
	# final_label artık yok — sadece _DigitDisplay üzerinden güncelle
	if is_instance_valid(main_node) and main_node.has_method("update_final_display"):
		main_node.call("update_final_display", score)
	if is_instance_valid(main_node) and main_node.has_method("_show_go_panel"):
		main_node.call("_show_go_panel")
	_submit_session()


func _submit_session() -> void:
	var payload := {
		"session_id": session_id,
		"seed":       game_seed,
		"score":      score,
		"inputs":     _input_log,
	}
	var json_str := JSON.stringify(payload)
	var req := HTTPRequest.new()
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json"])
	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var text : String = body.get_string_from_utf8()
			var parsed : Variant = JSON.parse_string(text)
			if parsed and parsed.has("flagged"):
				_on_submit_response(parsed)
	)
	req.request(BACKEND_URL + "/api/sessions", headers, HTTPClient.METHOD_POST, json_str)


func _on_submit_response(data: Dictionary) -> void:
	var flagged : bool = data.get("flagged", false)
	var owner := get_parent()
	if owner and owner.has_method("_on_session_submitted"):
		owner.call("_on_session_submitted", session_id, score, flagged)


func _fetch_seed_from_server() -> void:
	var local_seed := game_seed
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var text : String = body.get_string_from_utf8()
			var parsed : Variant = JSON.parse_string(text)
			if parsed and parsed.has("seed") and parsed.has("session_id"):
				var server_seed := int(parsed["seed"])
				session_id = str(parsed["session_id"])
				if server_seed != local_seed:
					game_seed = server_seed
					_rng.seed = game_seed
					_clear_spawned_world()
					_spawn_initial_platforms()
					_reset_player_start_pos()
		_seed_ready = true
		req.queue_free()
	)
	var err := req.request(BACKEND_URL + "/api/seed")
	if err != OK:
		_seed_ready = true
