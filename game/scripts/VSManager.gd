extends Node
## VSManager — Real-time 1v1 WebSocket client
##
## Usage:
##   VSManager.join(nickname, invite_room_id)  → emits matched(seed, slot, opponent_nick)
##   VSManager.send_input(tick, dir)           → RLE-encode + relay to opponent (every 8 ticks)
##   VSManager.send_done(tick, score)          → flush RLE + notify game over
##   VSManager.disconnect_room()               → clean disconnect
##
## Signals:
##   matched(seed:String, slot:int, opponent:String)
##   countdown(n:int)
##   opponent_input(tick:int, dir:int)
##   opponent_done(tick:int, score:int)
##   opponent_left()
##   match_timeout()
##   error(msg:String)

signal matched(seed: String, slot: int, opponent: String)
signal countdown(n: int)
signal opponent_input(tick: int, dir: int)
signal opponent_done(tick: int, score: int)
signal opponent_left()
signal match_timeout()
signal error(msg: String)

# BASE_URL computed at runtime from ApiConfig (https→wss, http→ws)
var _base_url : String = ""
func _get_ws_base() -> String:
	if _base_url != "":
		return _base_url
	var http_base := ApiConfig.base_url()
	_base_url = http_base.replace("https://", "wss://").replace("http://", "ws://")
	return _base_url

var _ws       : WebSocketPeer = null
var _room_id  : String = ""
var _slot     : int    = 0
var _seed     : String = ""
var _nickname : String = ""
var _connected : bool  = false
var _invite_url : String = ""

# Ghost input buffer: Array of {tick, dir}
var ghost_inputs : Array = []
var ghost_score  : int   = -1
var ghost_done   : bool  = false

# ── RLE encoder state (outgoing) ─────────────────────────────────────────────
# Format identical to replay_log: [val:2bit | count:6bit], val=0 neutral,1 right,2 left
# Flush every _VS_FLUSH_TICKS ticks — reduces WS messages ~8x
const _VS_FLUSH_TICKS := 8
var _rle_buf     : PackedByteArray = PackedByteArray()  # accumulator
var _rle_tick    : int = 0    # ticks buffered since last flush
var _rle_base_tick : int = 0  # tick index of first byte in _rle_buf

# ── RLE decoder state (incoming, for ghost) ───────────────────────────────────
var _ghost_rle_buf   : PackedByteArray = PackedByteArray()
var _ghost_rle_pos   : int = 0
var _ghost_rle_rem   : int = 0
var _ghost_rle_val   : int = 0


func _ready() -> void:
	set_process(false)


## Step 1 — HTTP join: get room_id + seed
func join(nickname: String, invite: String = "") -> void:
	_nickname = nickname
	if not OS.has_feature("web"):
		# Editor fallback: emit fake matched after 1s
		await get_tree().create_timer(1.0).timeout
		_seed    = "123456789"
		_slot    = 0
		_room_id = "testroom"
		matched.emit(_seed, _slot, "TestOpponent")
		return

	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)

	var body := JSON.stringify({
		"nickname": nickname,
		"invite":   invite,
	})
	var err := http.request(
		ApiConfig.base_url() + "/backend/vs/join",  # ApiConfig handles same-origin on web
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		http.queue_free()
		error.emit("join_request_failed")
		return

	http.request_completed.connect(func(result, code, _h, resp_body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			error.emit("join_failed_%d" % code)
			return
		var j := JSON.new()
		if j.parse(resp_body.get_string_from_utf8()) != OK:
			error.emit("join_parse_error")
			return
		var d : Dictionary = j.get_data()
		_room_id    = str(d.get("room_id", ""))
		_seed       = str(d.get("seed", ""))
		_slot       = int(d.get("slot", 0))
		_invite_url = str(d.get("invite_url", ""))
		print("[VS] joined room=%s slot=%d seed=%s" % [_room_id, _slot, _seed])
		_connect_ws()
	)


## Step 2 — WebSocket connect
func _connect_ws() -> void:
	_ws = WebSocketPeer.new()
	var url := "%s/backend/vs/ws/%s?slot=%d&nickname=%s" % [
		_get_ws_base(), _room_id, _slot, _nickname.uri_encode()
	]
	var err := _ws.connect_to_url(url)
	if err != OK:
		error.emit("ws_connect_failed")
		return
	set_process(true)
	print("[VS] WS connecting to %s" % url)


## Called every frame — polls WebSocket
func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			print("[VS] WS open")

		while _ws.get_available_packet_count() > 0:
			var pkt := _ws.get_packet()
			_handle_message(pkt.get_string_from_utf8())

	elif state == WebSocketPeer.STATE_CLOSING:
		pass

	elif state == WebSocketPeer.STATE_CLOSED:
		print("[VS] WS closed code=%d" % _ws.get_close_code())
		set_process(false)
		if _connected:
			opponent_left.emit()
		_ws = null


func _handle_message(raw: String) -> void:
	var j := JSON.new()
	if j.parse(raw) != OK:
		return
	var d : Dictionary = j.get_data()
	var t : String = str(d.get("t", ""))

	match t:
		"matched":
			_seed = str(d.get("seed", _seed))
			_slot = int(d.get("slot", _slot))
			var opp : String = str(d.get("opponent", "Opponent"))
			print("[VS] matched seed=%s slot=%d opp=%s" % [_seed, _slot, opp])
			matched.emit(_seed, _slot, opp)

		"countdown":
			var n : int = int(d.get("n", 0))
			print("[VS] countdown %d" % n)
			countdown.emit(n)

		"rle":
			# Decode incoming RLE chunk — val 0/1/2 = dir, val 3 = jump
			var base_tick : int = int(d.get("tick", 0))
			var raw_b64   : String = str(d.get("d", ""))
			if raw_b64 == "": return
			var bytes : PackedByteArray = Marshalls.base64_to_raw(raw_b64)
			var cur_tick := base_tick
			for i in bytes.size():
				var b   : int = bytes[i]
				var val : int = b & 0x03
				var cnt : int = (b >> 2) & 0x3F
				var dir : int = val - 1   # encoded as rdir+1, so decode: val-1
				for _t in cnt:
					ghost_inputs.append({"tick": cur_tick, "dir": dir})
					opponent_input.emit(cur_tick, dir)
					cur_tick += 1

		"done":
			var tick  : int = int(d.get("tick",  0))
			var score : int = int(d.get("score", 0))
			ghost_score = score
			ghost_done  = true
			opponent_done.emit(tick, score)

		"opponent_left":
			opponent_left.emit()

		"pong":
			pass   # keepalive response


# ── Send helpers ──────────────────────────────────────────────────────────────

## Encode one tick into the RLE buffer, flush every _VS_FLUSH_TICKS ticks.
## Same encoding as replay_log: val = (dir+1)&0x03, packed as [val|count<<2].
func send_input(tick: int, dir: int) -> void:
	var val : int = (dir + 1) & 0x03  # 0=neutral, 1=right, 2=left

	# Extend current run or start a new one
	if _rle_buf.size() > 0:
		var last  : int = _rle_buf[_rle_buf.size() - 1]
		var l_val : int = last & 0x03
		var l_cnt : int = (last >> 2) & 0x3F
		if l_val == val and l_cnt < 63:
			_rle_buf[_rle_buf.size() - 1] = val | ((l_cnt + 1) << 2)
		else:
			_rle_buf.append(val | (1 << 2))
	else:
		_rle_base_tick = tick
		_rle_buf.append(val | (1 << 2))

	_rle_tick += 1
	if _rle_tick >= _VS_FLUSH_TICKS:
		_flush_rle()


## Force-flush remaining RLE buffer (call on game over or jump)
func _flush_rle() -> void:
	if _rle_buf.size() == 0:
		return
	# Send as binary-safe base64 + base tick so receiver can decode
	_send({
		"t":    "rle",
		"tick": _rle_base_tick,
		"d":    Marshalls.raw_to_base64(_rle_buf),
	})
	_rle_buf.resize(0)
	_rle_tick    = 0
	_rle_base_tick = 0



func send_done(tick: int, score: int) -> void:
	_flush_rle()   # flush any remaining input
	_send({"t": "done", "tick": tick, "score": score})


func disconnect_room() -> void:
	_rle_buf.resize(0)
	_rle_tick      = 0
	_rle_base_tick = 0
	if _ws != null:
		_ws.close()
		_ws = null
	set_process(false)
	_connected = false
	_room_id   = ""
	ghost_inputs.clear()
	ghost_score = -1
	ghost_done  = false


func get_invite_url() -> String:
	return ApiConfig.tag_url(_invite_url)


func _send(d: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(d))
