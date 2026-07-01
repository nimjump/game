## DumpPlatforms.gd — run headless, print platform X/Y list
## Usage: godot --headless --script scripts/DumpPlatforms.gd -- <seed>
## Trace modu: godot --headless --script scripts/DumpPlatforms.gd -- trace
##
## RNG tüketimi GameManager._spawn_platform ile BİREBİR eşleştirilmiştir.
## Her değişiklikte GM ile senkronu koruyun.
extends Node

const VW             := GameConstants.VW
const VH             := GameConstants.VH
const PLATFORM_W     := VW * 0.193
const PLATFORM_H     := VH * 0.0225
const BASE_GAP       := VH * 0.119
const MAX_GAP        := VH * 0.1875
const SPAWN_ABOVE    := VH * 1.75
const BROKEN_BASE_PROB := 0.05
const BROKEN_MAX     := 0.28
const DIFF_MAX       := 3000.0
const ENEMY_BASE_PROB  := 0.28
const ENEMY_MAX_PROB   := 0.60
const ITEM_BASE_PROB   := 0.22
const JETPACK_GAP    := VH * 0.22
const START_Y_RATIO  := 0.72

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var args := OS.get_cmdline_user_args()

	# --- trace mode: print first 30 randf() values ---
	if args.size() >= 1 and args[0] == "trace":
		_rng.seed = 12345678
		for i in 30:
			print("randf[%d] = %.10f" % [i, _rng.randf()])
		get_tree().quit(0)
		return

	var seed_val := 12345678
	if args.size() >= 1:
		seed_val = int(args[0])

	_rng.seed = seed_val

	var start_y := VH * START_Y_RATIO + VH * 0.03
	var top_y   := start_y

	print("PLATFORM 0 x=300.00 y=%.2f safe" % start_y)

	# Safe başlangıç platformları — sadece x RNG, _burn_platform_rng çağrılmaz
	# (safe=true → GM'de erken return, hiç deko/spike/enemy/item yok)
	for i in 6:
		top_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(VW * 0.13, VW * 0.87)
		print("PLATFORM %d x=%.2f y=%.2f safe" % [i+1, x, top_y])

	# Init platformları — safe değil, score=0, broken=false
	for i in 14:
		top_y -= BASE_GAP * 0.75
		var x := _rng.randf_range(VW * 0.10, VW * 0.90)
		print("PLATFORM %d x=%.2f y=%.2f init" % [i+7, x, top_y])
		_burn_platform_rng(0, false)

	# İlk 10 dinamik platform
	for _i in 10:
		var sc := 0
		var diff := minf(float(sc) / DIFF_MAX, 1.0)
		var gap  := lerpf(BASE_GAP, MAX_GAP, diff) + _rng.randf_range(0.0, BASE_GAP * 0.3)
		var nx   := _rng.randf_range(VW * 0.10, VW * 0.90)
		var broken := _rng.randf() < lerpf(BROKEN_BASE_PROB, BROKEN_MAX, diff)
		top_y -= gap
		print("PLATFORM %d x=%.2f y=%.2f broken=%s" % [21+_i, nx, top_y, str(broken)])
		_burn_platform_rng(sc, broken)

	print("DUMP_DONE")
	get_tree().quit(0)


## GameManager._spawn_platform ile AYNI sırada, AYNI koşulda RNG tüketir.
## Herhangi bir değişiklik GM ile senkronize tutulmalıdır.
func _burn_platform_rng(sc: int, broken: bool) -> void:
	var diff       := minf(float(sc) / DIFF_MAX, 1.0)
	var crumble_chance := clampf((float(sc) - 600.0) / 1400.0, 0.0, 0.35)
	# 1) Crumble check — her zaman tüketilir (safe olmayan tüm platformlar)
	var is_crumble := not broken and _rng.randf() < crumble_chance

	# 2) Deko — sadece broken değilse
	if not broken:
		_burn_deco(_ground_name_for_score(sc))

	# 3) Broken platformlar için pipeline biter
	if broken:
		return

	# 4) JETPACK_GAP kontrolü (RNG yok), sonra spring check
	var gap_check := lerpf(BASE_GAP, MAX_GAP, diff)
	if gap_check >= JETPACK_GAP:
		# _add_spring çağrılır (RNG yok) + return
		return

	# 5) Spring şansı
	if _rng.randf() < 0.05:
		# _add_spring (RNG yok) + return
		return

	# 6) Spike roll'ları — HER ZAMAN iki call, dallanmadan önce
	var spike_roll   := _rng.randf()
	var spike_b_roll := _rng.randf()
	var gname2 := _ground_name_for_score(sc)
	if not broken and gname2 in ["grass", "sand", "cake"] and spike_roll < 0.18:
		_burn_spikes()
	elif not broken and gname2 in ["stone", "wood", "snow"] and spike_b_roll < 0.12:
		_burn_spike_bottom()

	# 7) Enemy / item seçimi
	var enemy_prob := lerpf(ENEMY_BASE_PROB, ENEMY_MAX_PROB, diff)
	if _rng.randf() < enemy_prob:
		# _add_enemy: etype seçimi. enemy_seed = hash(game_seed ^ counter ^ etype) — GM bunu
		# _rng'den TÜKETMEZ (bkz. GameManager._add_enemy: "does not consume _rng").
		_rng.randi()  # etype = available[_rng.randi() % ...]
	elif _rng.randf() < ITEM_BASE_PROB:
		if _rng.randf() < 0.15:
			# _spawn_spinning_card: is_good + result_slot
			_rng.randf()  # is_good = _rng.randf() < 0.5
			_rng.randi()  # result_slot = [...][_rng.randi() % 3]
		else:
			# _add_item: roll
			_rng.randi()  # roll = _rng.randi() % total


## GameManager._add_deco ile AYNI: her zaman tam 5 RNG tüketir (r0..r4).
## r4 her zaman tüketilir (randf_range upfront), match branch'leri ek tüketim yapmaz.
func _burn_deco(gname: String) -> void:
	# r0, r1, r2, r3, r4 — GM'de upfront tüketilir, match branching yapmaz
	_rng.randf()          # r0
	_rng.randf()          # r1
	_rng.randf()          # r2
	_rng.randf()          # r3
	_rng.randf_range(-VW * 0.067, VW * 0.067)  # r4 — her zaman tüketilir


## _add_spikes: pattern (randi%3) + side (randi%2) = 2 calls
func _burn_spikes() -> void:
	_rng.randi()  # pattern = _rng.randi() % 3
	_rng.randi()  # side    = _rng.randi() % 2


## _add_spike_bottom: pattern (randi%2) = 1 call
func _burn_spike_bottom() -> void:
	_rng.randi()  # pattern = _rng.randi() % 2


## GameManager._ground_set_for_score(s)["name"] ile AYNI eşleme.
## DİKKAT: _biome_name_for_score() biome adını döndürür (grass/desert/fall/sky),
## ama _add_deco/_spawn_platform'daki spike branch kontrolü TOPRAK adını
## (grass/sand/snow/stone/wood/cake) kullanır — bunlar farklı string'lerdir!
## _BIOME_IDX = {"grass":0,"desert":1,"fall":4,"sky":2,"candy":5} ve
## ground_pairs sırası = [grass, sand, snow, stone, wood, cake] (idx 0..5).
const _GROUND_SET_NAME_BY_IDX := ["grass", "sand", "snow", "stone", "wood", "cake"]
const _BIOME_IDX_LOCAL : Dictionary = {"grass": 0, "desert": 1, "fall": 4, "sky": 2, "candy": 5}

func _ground_name_for_score(s: int) -> String:
	var bname := _biome_name_for_score(s)
	var idx   : int = _BIOME_IDX_LOCAL.get(bname, 0)
	if idx < _GROUND_SET_NAME_BY_IDX.size():
		return _GROUND_SET_NAME_BY_IDX[idx]
	return _GROUND_SET_NAME_BY_IDX[0]


## GameManager._biome_name_for_score ile AYNI — 4 biom, 500'er dilim, 2000'de döngü.
func _biome_name_for_score(s: int) -> String:
	var cycle : int = s % 2000
	if cycle < 0: cycle += 2000
	if cycle < 500:  return "grass"
	if cycle < 1000: return "desert"
	if cycle < 1500: return "fall"
	return "sky"
