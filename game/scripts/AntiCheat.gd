extends Node
## AntiCheat.gd — Godot object tree traversal protection
##
## Attack model: JS injection via Godot's WebAssembly exports
## (gdobj, GodotRuntime, etc.) to traverse the scene tree and access
## GameManager/Player nodes and score/seed variables.
##
## Protections:
##  1. Node name obfuscation  — randomize predictable node names
##  2. XOR masked properties  — score/seed cannot be read directly
##  3. Engine.time_scale guard — speed hack → force back to 1.0
##  4. Decoy nodes            — fake nodes in the tree to mislead traversal

# ── Internal state ────────────────────────────────────────────────────────────
var _gm            : Node = null
var _player        : Node = null
var _mask          : int  = 0      # XOR mask — random each session
var _score_masked  : int  = 0      # score ^ _mask
var _seed_masked   : int  = 0      # seed  ^ _mask
var _decoys        : Array[Node] = []
var _orig_gm_name  : String = ""
var _orig_pl_name  : String = ""

const DECOY_COUNT  := 8
const DECOY_NAMES  := ["GameManager","Player","ScoreNode","SeedManager",
						"InputHandler","PhysicsBody","SessionData","RNGNode"]

# ── Public API ────────────────────────────────────────────────────────────────

func setup(gm: Node, player: Node) -> void:
	_gm     = gm
	_player = player
	_mask   = randi() | 1   # never 0  # determinism-ok: obfuscation-only, never sent to server / never replayed

	_obfuscate_node_names()
	_spawn_decoys()
	_mask_values()
	Engine.time_scale = 1.0  # enforce at startup

## Called every physics tick — lightweight, only checks time_scale.
func tick(current_score: int, current_seed: int) -> void:
	# time_scale guard — speed hack attempt is suppressed immediately
	if Engine.time_scale != 1.0:
		Engine.time_scale = 1.0

	# Update masked values
	_score_masked = current_score ^ _mask
	_seed_masked  = current_seed  ^ _mask

## Get the real score (remove mask).
func real_score() -> int:
	return _score_masked ^ _mask

## Get the real seed (remove mask).
func real_seed() -> int:
	return _seed_masked ^ _mask

## Restore node names and clean up decoys when the game ends.
func cleanup() -> void:
	if is_instance_valid(_player) and _orig_pl_name != "":
		_player.name = _orig_pl_name
	for d in _decoys:
		if is_instance_valid(d):
			d.queue_free()
	_decoys.clear()

# ── Protection layers ─────────────────────────────────────────────────────────

## Make node names unpredictable.
## Only Player is obfuscated — GameManager's name is not changed
## because Main.gd and other scripts may look it up by name.
func _obfuscate_node_names() -> void:
	if is_instance_valid(_player):
		_orig_pl_name = _player.name
		_player.name  = _random_name()

## Fake nodes — traversal code mistakes them for real ones and cannot find actual nodes.
## Each decoy is given fake properties with the same signatures as the real nodes.
func _spawn_decoys() -> void:
	var parent := _gm.get_parent()
	if not is_instance_valid(parent):
		return
	for i in range(DECOY_COUNT):
		var d := Node.new()
		d.name = DECOY_NAMES[i % DECOY_NAMES.size()]
		# Fake script on decoy — returns meaningless values when accessed externally
		d.set_meta("score", randi_range(0, 9999))  # determinism-ok: fake honeypot value, decoy node
		d.set_meta("seed",  randi_range(0, 2147483647))  # determinism-ok: fake honeypot value
		d.set_meta("session_id", "decoy_%d" % randi())  # determinism-ok: fake honeypot value
		parent.add_child(d)
		_decoys.append(d)

## Shuffle decoy values every frame — makes static analysis harder.
func _shuffle_decoys() -> void:
	for d in _decoys:
		if is_instance_valid(d):
			d.set_meta("score", randi_range(0, 9999))  # determinism-ok: fake honeypot value
			d.set_meta("seed",  randi_range(0, 2147483647))  # determinism-ok: fake honeypot value

## Initialize masked values.
func _mask_values() -> void:
	if is_instance_valid(_gm):
		_score_masked = (int(_gm.get("score")))    ^ _mask
		_seed_masked  = (int(_gm.get("game_seed"))) ^ _mask

func _random_name() -> String:
	const chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	var s := "_"
	for i in range(12):
		s += chars[randi() % chars.length()]  # determinism-ok: random decoy node name, cosmetic obfuscation
	return s

var _shuffle_frame : int = 0

func _process(_delta: float) -> void:
	# Shuffle decoys every 6 frames (~10fps) — anticheat doesn't need 60fps
	_shuffle_frame += 1
	if _shuffle_frame >= 6:
		_shuffle_frame = 0
		_shuffle_decoys()
