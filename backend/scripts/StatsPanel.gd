extends CanvasLayer
## StatsPanel.gd — Player statistics + last 10 games

signal closed
signal replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, nickname: String)
signal connect_requested   # emitted when user taps Connect inside stats panel

const UITheme := preload("res://scripts/UITheme.gd")
var BACKEND_URL : String = ApiConfig.base_url()

# Warm bej palette (referans UI'dan)
const _C_BG       := Color(0.957, 0.898, 0.800)   # panel arka planı
const _C_CARD     := Color(0.940, 0.878, 0.776)   # kart arka planı
const _C_BORDER   := Color(0.700, 0.520, 0.340)   # kart border
const _C_BROWN    := Color(0.220, 0.130, 0.060)   # koyu kahve yazı
const _C_MID      := Color(0.480, 0.340, 0.200)   # orta kahve (dim)
const _C_ORANGE   := Color(0.780, 0.380, 0.120)   # turuncu aksan
const _C_GOLD     := Color(0.820, 0.580, 0.100)   # altın
const _C_GREEN    := Color(0.240, 0.620, 0.220)   # yeşil (completed)
const _C_SEP      := Color(0.700, 0.560, 0.400, 0.5)  # separator

var _gm         : Node    = null
var _panel_ctrl : Control = null
var _anim_tween : Tween   = null
var _http       : HTTPRequest = null
var _player_id  : String = ""
var _auth_token : String = ""

var _stat_labels  : Dictionary = {}
var _recent_root  : VBoxContainer = null
var _reward_root  : VBoxContainer = null
var _outer_vbox   : VBoxContainer = null
var _no_auth_box  : VBoxContainer = null   # shown when not connected
var _http_rewards : HTTPRequest = null


func setup(gm: Node) -> void:
	_gm = gm
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_stats_response)
	_build_ui()
	hide()


func set_player_id(pid: String) -> void:
	_player_id = pid
	if is_visible() and _auth_token != "":
		_refresh()


func set_auth_token(token: String) -> void:
	_auth_token = token
	if is_visible() and token != "":
		_refresh()

func set_auth_attempted(_v: bool) -> void:
	pass


func record_game(_score: int) -> void:
	pass


# ---------------------------------------------------------------------------
# UI BUILD
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var vp  := get_viewport()
	var vw  := vp.get_visible_rect().size.x if vp else 600.0
	var vh  := vp.get_visible_rect().size.y if vp else 800.0
	var ref := minf(vw, vh)
	var pad := int(ref * 0.028)
	var sep := int(ref * 0.012)
	var pw  := ref * 0.92
	var ph  := minf(vh * 0.88, vh - pad * 2.0)

	# Dim
	var dim_ctrl := Control.new()
	dim_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim_ctrl)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			hide_panel(); closed.emit()
	)
	dim_ctrl.add_child(dim)

	_panel_ctrl = Control.new()
	_panel_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim_ctrl.add_child(_panel_ctrl)

	var pc := PanelContainer.new()
	pc.anchor_left   = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top    = 0.5; pc.anchor_bottom = 0.5
	pc.offset_left   = -pw * 0.5; pc.offset_right  =  pw * 0.5
	pc.offset_top    = -ph * 0.5; pc.offset_bottom =  ph * 0.5
	var pc_st := StyleBoxFlat.new()
	pc_st.bg_color     = _C_BG
	pc_st.border_color = _C_BORDER
	pc_st.set_border_width_all(3)
	pc_st.set_corner_radius_all(14)
	pc_st.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	pc_st.shadow_size  = 10
	pc.add_theme_stylebox_override("panel", pc_st)
	_panel_ctrl.add_child(pc)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	pc.add_child(outer)

	# ── Header ──────────────────────────────────────────
	var hdr_mc := _mpad(pad)
	outer.add_child(hdr_mc)
	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr_mc.add_child(hdr)

	hdr.add_child(UITheme.lucide_icon("bar-chart-2", int(ref * 0.038), _C_BROWN))

	var title := Label.new()
	title.text = "STATISTICS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, _C_BROWN, int(ref * 0.050))
	hdr.add_child(title)

	var close_btn := Button.new()
	close_btn.custom_minimum_size = Vector2(int(ref * 0.045), int(ref * 0.045))
	close_btn.pressed.connect(func(): hide_panel(); closed.emit())
	_warm_btn(close_btn, 8)
	var close_ic := TextureRect.new()
	close_ic.texture = preload("res://assets/hud/hudX.png")
	close_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_btn.add_child(close_ic)
	hdr.add_child(close_btn)

	var sep_line0 := HSeparator.new()
	sep_line0.add_theme_color_override("color", _C_SEP)
	outer.add_child(sep_line0)

	# ── Scroll ──────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone        = 0
	scroll.follow_focus           = false
	outer.add_child(scroll)

	var content_mc := _mpad(pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)

	_outer_vbox = VBoxContainer.new()
	_outer_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_outer_vbox.add_theme_constant_override("separation", sep)
	content_mc.add_child(_outer_vbox)

	# ── Not-connected state ─────────────────────────────
	_no_auth_box = VBoxContainer.new()
	_no_auth_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_no_auth_box.add_theme_constant_override("separation", int(ref * 0.020))
	_no_auth_box.visible = false
	_outer_vbox.add_child(_no_auth_box)

	var na_lbl := Label.new()
	na_lbl.text = "Connect your wallet to see your stats"
	na_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	na_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(na_lbl, _C_MID, int(ref * 0.030))
	_no_auth_box.add_child(na_lbl)

	var conn_btn := Button.new()
	conn_btn.text = "Connect Wallet"
	conn_btn.custom_minimum_size = Vector2(ref * 0.55, ref * 0.080)
	conn_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	conn_btn.add_theme_font_size_override("font_size", int(ref * 0.034))
	_warm_btn(conn_btn, 8)
	conn_btn.pressed.connect(func():
		emit_signal("connect_requested")
		hide_panel(); closed.emit()
	)
	_no_auth_box.add_child(conn_btn)

	# ── Stat cards ──────────────────────────────────────
	var fs_v := int(ref * 0.046)
	var ic_s := int(ref * 0.036)

	# Best score — large card, full width
	var best_card := PanelContainer.new()
	best_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var best_st := StyleBoxFlat.new()
	best_st.bg_color = _C_CARD
	best_st.border_color = _C_BORDER
	best_st.set_border_width_all(2)
	best_st.set_corner_radius_all(10)
	best_card.add_theme_stylebox_override("panel", best_st)
	_outer_vbox.add_child(best_card)

	var best_mc := _mpad(int(ref * 0.018))
	best_card.add_child(best_mc)
	var best_row := HBoxContainer.new()
	best_row.alignment = BoxContainer.ALIGNMENT_CENTER
	best_row.add_theme_constant_override("separation", int(ref * 0.012))
	best_mc.add_child(best_row)
	best_row.add_child(UITheme.lucide_icon("medal", int(ref * 0.048), _C_GOLD))
	var best_vbox := VBoxContainer.new()
	best_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	best_row.add_child(best_vbox)
	var best_title := Label.new()
	best_title.text = "Best Score"
	UITheme.apply_label(best_title, _C_MID, int(ref * 0.024))
	best_vbox.add_child(best_title)
	var best_val := Label.new()
	best_val.text = "0"
	UITheme.apply_label(best_val, _C_BROWN, int(ref * 0.058))
	best_vbox.add_child(best_val)
	_stat_labels["best"] = best_val

	var share_btn := Button.new()
	share_btn.text = "Share"
	share_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	share_btn.custom_minimum_size = Vector2(int(ref * 0.22), int(ref * 0.068))
	share_btn.add_theme_font_size_override("font_size", int(ref * 0.030))
	var share_st := StyleBoxFlat.new()
	share_st.bg_color = _C_ORANGE
	share_st.set_corner_radius_all(12)
	share_st.content_margin_left   = int(ref * 0.030)
	share_st.content_margin_right  = int(ref * 0.030)
	share_st.content_margin_top    = int(ref * 0.010)
	share_st.content_margin_bottom = int(ref * 0.010)
	var share_st_hover := share_st.duplicate() as StyleBoxFlat
	share_st_hover.bg_color = Color(_C_ORANGE.r + 0.08, _C_ORANGE.g + 0.04, _C_ORANGE.b, 1.0)
	var share_st_pressed := share_st.duplicate() as StyleBoxFlat
	share_st_pressed.bg_color = Color(_C_ORANGE.r - 0.08, _C_ORANGE.g - 0.04, _C_ORANGE.b, 1.0)
	share_btn.add_theme_stylebox_override("normal",  share_st)
	share_btn.add_theme_stylebox_override("hover",   share_st_hover)
	share_btn.add_theme_stylebox_override("pressed", share_st_pressed)
	share_btn.add_theme_color_override("font_color",          Color.WHITE)
	share_btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	share_btn.add_theme_color_override("font_pressed_color",  Color.WHITE)
	share_btn.pressed.connect(func():
		var sc := int(_stat_labels["best"].text) if _stat_labels["best"].text.is_valid_int() else 0
		ApiConfig.share_score(sc)
	)
	best_row.add_child(share_btn)

	# 2x2 grid + 1 wide card — stats with hud icons
	var stats_defs := [
		{"key": "games",     "icon": "res://assets/icons/lucide/gamepad-2.png", "label": "Games Played",  "col": _C_BROWN},
		{"key": "playtime",  "icon": "res://assets/icons/lucide/clock.png",     "label": "Play Time",     "col": _C_ORANGE},
		{"key": "kills",     "icon": "res://assets/icons/lucide/zap.png",       "label": "Kills",         "col": _C_BROWN},
		{"key": "platforms", "icon": "res://assets/icons/lucide/star.png",      "label": "Platforms",     "col": _C_ORANGE},
	]

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", int(ref * 0.012))
	grid.add_theme_constant_override("v_separation", int(ref * 0.010))
	_outer_vbox.add_child(grid)

	for s in stats_defs:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var card_st := StyleBoxFlat.new()
		card_st.bg_color = _C_CARD
		card_st.border_color = _C_BORDER
		card_st.set_border_width_all(2)
		card_st.set_corner_radius_all(10)
		card.add_theme_stylebox_override("panel", card_st)
		grid.add_child(card)

		var card_mc := _mpad(int(ref * 0.014))
		card.add_child(card_mc)

		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", int(ref * 0.004))
		card_mc.add_child(cv)

		var icon_row := HBoxContainer.new()
		icon_row.add_theme_constant_override("separation", int(ref * 0.008))
		cv.add_child(icon_row)

		# HUD texture icon
		var icon_tex := load(s["icon"]) as Texture2D
		if icon_tex:
			var icon_rect := TextureRect.new()
			icon_rect.texture = icon_tex
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.custom_minimum_size = Vector2(ic_s, ic_s)
			icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			icon_row.add_child(icon_rect)

		var lbl := Label.new()
		lbl.text = s["label"]
		lbl.clip_text = true
		UITheme.apply_label(lbl, _C_MID, int(ref * 0.022))
		icon_row.add_child(lbl)

		var val_lbl := Label.new()
		val_lbl.text = "0"
		UITheme.apply_label(val_lbl, s["col"], fs_v)
		cv.add_child(val_lbl)
		_stat_labels[s["key"]] = val_lbl

	# ── Recent Games ────────────────────────────────────
	var sep_line := HSeparator.new()
	sep_line.add_theme_color_override("color", _C_SEP)
	_outer_vbox.add_child(sep_line)

	var recent_hdr := Label.new()
	recent_hdr.text = "Recent Games"
	UITheme.apply_label(recent_hdr, _C_BROWN, int(ref * 0.034))
	_outer_vbox.add_child(recent_hdr)

	var col_hdr := HBoxContainer.new()
	col_hdr.add_theme_constant_override("separation", int(ref * 0.006))
	_outer_vbox.add_child(col_hdr)
	col_hdr.add_child(_col_lbl("Date",     ref, 0.28, _C_MID, true))
	col_hdr.add_child(_col_lbl("Score",    ref, 0.28, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))
	col_hdr.add_child(_col_lbl("Duration", ref, 0.22, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))
	col_hdr.add_child(_col_lbl("Status",   ref, 0.22, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", _C_SEP)
	_outer_vbox.add_child(sep2)

	_recent_root = VBoxContainer.new()
	_recent_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent_root.add_theme_constant_override("separation", int(ref * 0.006))
	_outer_vbox.add_child(_recent_root)

	var loading := Label.new()
	loading.text = "Loading..."
	UITheme.apply_label(loading, _C_MID, int(ref * 0.026))
	loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recent_root.add_child(loading)

	# ── Last Transactions ────────────────────────────────
	var sep_tx := HSeparator.new()
	sep_tx.add_theme_color_override("color", _C_SEP)
	_outer_vbox.add_child(sep_tx)

	var tx_hdr := Label.new()
	tx_hdr.text = "Last Transactions"
	UITheme.apply_label(tx_hdr, _C_BROWN, int(ref * 0.034))
	_outer_vbox.add_child(tx_hdr)

	_reward_root = VBoxContainer.new()
	_reward_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reward_root.add_theme_constant_override("separation", int(ref * 0.006))
	_outer_vbox.add_child(_reward_root)

	var tx_loading := Label.new()
	tx_loading.text = "Loading..."
	UITheme.apply_label(tx_loading, _C_MID, int(ref * 0.026))
	tx_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reward_root.add_child(tx_loading)


static func _warm_btn(btn: Button, r: float = 8.0) -> void:
	var ri := int(r)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.corner_radius_top_left = ri; s.corner_radius_top_right = ri
		s.corner_radius_bottom_left = ri; s.corner_radius_bottom_right = ri
	sn.bg_color = Color(0.780, 0.380, 0.120)
	sh.bg_color = Color(0.820, 0.450, 0.160)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
	btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))


static func _warm_ghost_btn(btn: Button, r: float = 8.0) -> void:
	var ri := int(r)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.corner_radius_top_left = ri; s.corner_radius_top_right = ri
		s.corner_radius_bottom_left = ri; s.corner_radius_bottom_right = ri
	sn.bg_color = Color(0, 0, 0, 0)
	sn.border_color = Color(0.700, 0.520, 0.340); sn.set_border_width_all(1)
	sh.bg_color = Color(0.700, 0.520, 0.340, 0.18)
	sh.border_color = Color(0.780, 0.380, 0.120); sh.set_border_width_all(1)
	sp.bg_color = Color(0.700, 0.520, 0.340, 0.28)
	sp.border_color = Color(0.780, 0.380, 0.120); sp.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	btn.add_theme_color_override("font_color",         Color(0.220, 0.130, 0.060))
	btn.add_theme_color_override("font_hover_color",   Color(0.780, 0.380, 0.120))
	btn.add_theme_color_override("font_pressed_color", Color(0.640, 0.300, 0.080))


func _mpad(m: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   m)
	mc.add_theme_constant_override("margin_right",  m)
	mc.add_theme_constant_override("margin_top",    m)
	mc.add_theme_constant_override("margin_bottom", m)
	return mc


func _col_lbl(txt: String, ref: float, ratio: float, col: Color, bold: bool,
			  align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	UITheme.apply_label(lbl, col, int(ref * (0.026 if bold else 0.024)))
	lbl.size_flags_horizontal    = Control.SIZE_EXPAND_FILL
	lbl.size_flags_stretch_ratio = ratio
	lbl.horizontal_alignment     = align
	lbl.clip_text = true
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


# ---------------------------------------------------------------------------
# DATA
# ---------------------------------------------------------------------------

func _refresh() -> void:
	print("[STATS] _refresh called — player_id=%s auth=%s" % [_player_id, ("set" if _auth_token != "" else "empty")])
	if _auth_token == "":
		# Not connected — show connect box, hide stat cards
		if is_instance_valid(_no_auth_box):
			_no_auth_box.visible = true
		for k in _stat_labels:
			_stat_labels[k].text = "0"
		if is_instance_valid(_recent_root):
			for c in _recent_root.get_children():
				c.queue_free()
		return

	# Connected — hide connect box
	if is_instance_valid(_no_auth_box):
		_no_auth_box.visible = false

	for k in _stat_labels:
		_stat_labels[k].text = "?"

	var url := BACKEND_URL + "/backend/stats"
	if _player_id != "" and _player_id != "Guest":
		url += "?player_id=" + _player_id.uri_encode()

	if is_instance_valid(_http) and _http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		var headers : PackedStringArray = []
		headers.append("Authorization: Bearer " + _auth_token)
		_http.request(url, headers)

	# Fetch reward history
	if _player_id != "" and _player_id != "Guest":
		if not is_instance_valid(_http_rewards):
			_http_rewards = HTTPRequest.new()
			add_child(_http_rewards)
			_http_rewards.request_completed.connect(_on_rewards_response)
		if _http_rewards.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			var rurl := BACKEND_URL + "/backend/rewards/history?player_id=" + _player_id.uri_encode()
			_http_rewards.request(rurl, PackedStringArray(["Authorization: Bearer " + _auth_token]))


func _on_stats_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	print("[STATS] response code=%d" % response_code)
	if response_code != 200:
		for k in _stat_labels:
			_stat_labels[k].text = "?"
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return

	if _stat_labels.has("best"):
		_stat_labels["best"].text = str(int(data.get("best_score", 0)))
	if _stat_labels.has("games"):
		_stat_labels["games"].text = str(int(data.get("total_games", 0)))
	if _stat_labels.has("kills"):
		_stat_labels["kills"].text = str(int(data.get("total_kills", 0)))
	if _stat_labels.has("platforms"):
		_stat_labels["platforms"].text = str(int(data.get("total_platforms", 0)))
	# Total play time: ticks → m/s
	var total_ticks : int = int(data.get("total_ticks", 0))
	if _stat_labels.has("playtime"):
		if total_ticks > 0:
			var ts2 := total_ticks / 60
			_stat_labels["playtime"].text = "%dm %02ds" % [ts2 / 60, ts2 % 60] if ts2 >= 60 else "%ds" % ts2
		else:
			_stat_labels["playtime"].text = "0"

	_build_recent(data.get("recent_games", []))


func _on_rewards_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not is_instance_valid(_reward_root):
		return
	for c in _reward_root.get_children():
		c.queue_free()
	if response_code != 200:
		var err_lbl := Label.new()
		err_lbl.text = "Failed to load transactions."
		UITheme.apply_label(err_lbl, _C_MID, int(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y) * 0.026))
		err_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_reward_root.add_child(err_lbl)
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var data : Dictionary = json.get_data() if json.get_data() is Dictionary else {}
	_build_rewards(data.get("rewards", []))


func _build_rewards(rewards: Array) -> void:
	if not is_instance_valid(_reward_root):
		return
	for c in _reward_root.get_children():
		c.queue_free()

	var ref := minf(
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y)

	if rewards.is_empty():
		var lbl := Label.new()
		lbl.text = "No transactions yet."
		UITheme.apply_label(lbl, _C_MID, int(ref * 0.026))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_reward_root.add_child(lbl)
		return

	for rw in rewards:
		var status : String = rw.get("status", "")
		var amount : float  = float(rw.get("amount_nim", 0.0))
		var reason : String = rw.get("reason", "")
		var tx_hash: String = rw.get("tx_hash", "")
		var ts     : int    = int(rw.get("sent_at", rw.get("created_at", 0)))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(ref * 0.008))
		_reward_root.add_child(row)

		# Status dot color
		var dot_col := _C_MID
		match status:
			"sent":    dot_col = _C_GREEN
			"pending": dot_col = Color(0.820, 0.680, 0.100)
			"failed":  dot_col = Color(0.820, 0.180, 0.120)

		var dot := ColorRect.new()
		dot.color = dot_col
		dot.custom_minimum_size = Vector2(int(ref * 0.014), int(ref * 0.014))
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)

		# Date
		var date_lbl := Label.new()
		var dt := Time.get_datetime_dict_from_unix_time(ts)
		date_lbl.text = "%02d.%02d %02d:%02d" % [dt.month, dt.day, dt.hour, dt.minute]
		UITheme.apply_label(date_lbl, _C_MID, int(ref * 0.024))
		date_lbl.custom_minimum_size.x = ref * 0.28
		date_lbl.clip_text = true
		row.add_child(date_lbl)

		# Amount
		var amt_lbl := Label.new()
		amt_lbl.text = "%.5f NIM" % amount
		UITheme.apply_label(amt_lbl, _C_ORANGE, int(ref * 0.026))
		amt_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(amt_lbl)

		# TX link or status
		if tx_hash != "":
			var tx_btn := Button.new()
			tx_btn.text = "TX"
			tx_btn.custom_minimum_size = Vector2(int(ref * 0.12), 0)
			_warm_btn(tx_btn, 6)
			tx_btn.add_theme_font_size_override("font_size", int(ref * 0.022))
			var h := tx_hash
			tx_btn.pressed.connect(func():
				OS.shell_open("https://nimiq.watch/#" + h)
			)
			row.add_child(tx_btn)
		else:
			var st_lbl := Label.new()
			st_lbl.text = status
			UITheme.apply_label(st_lbl, dot_col, int(ref * 0.022))
			st_lbl.custom_minimum_size.x = ref * 0.12
			st_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(st_lbl)

		var sep_r := HSeparator.new()
		sep_r.add_theme_color_override("color", _C_SEP)
		_reward_root.add_child(sep_r)


func _build_recent(games: Array) -> void:
	if not is_instance_valid(_recent_root):
		return
	for c in _recent_root.get_children():
		c.queue_free()

	var ref := minf(
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y)

	if games.is_empty():
		var lbl := Label.new()
		lbl.text = "No games played yet."
		UITheme.apply_label(lbl, _C_MID, int(ref * 0.026))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_recent_root.add_child(lbl)
		return

	for i in games.size():
		var g          : Dictionary = games[i]
		var score      : int        = int(g.get("server_score", 0))
		var ticks      : int        = int(g.get("ticks", 0))
		var ts         : int        = int(g.get("submitted_at", 0))
		var flagged    : bool       = bool(g.get("flagged", false))
		var session_id : String     = g.get("session_id", "")

		var row_pc := PanelContainer.new()
		row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_st := StyleBoxFlat.new()
		row_st.bg_color = _C_CARD
		row_st.border_color = _C_BORDER
		row_st.set_border_width_all(1)
		row_st.set_corner_radius_all(8)
		row_pc.add_theme_stylebox_override("panel", row_st)
		_recent_root.add_child(row_pc)

		var row_mc := _mpad(int(ref * 0.010))
		row_pc.add_child(row_mc)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(ref * 0.006))
		row_mc.add_child(row)

		var date_str := "--"
		if ts > 0:
			var dt := Time.get_datetime_dict_from_unix_time(ts)
			date_str = "%02d/%02d %02d:%02d" % [dt.day, dt.month, dt.hour, dt.minute]
		row.add_child(_col_lbl(date_str, ref, 0.28, _C_MID, false))

		var score_col := Color(0.820, 0.180, 0.120) if flagged else _C_BROWN
		var score_lbl := _col_lbl(("F " if flagged else "") + str(score), ref, 0.28, score_col, score == 0 or not flagged, HORIZONTAL_ALIGNMENT_RIGHT)
		if score > 0 and not flagged:
			UITheme.apply_label(score_lbl, _C_BROWN, int(ref * 0.026))
		row.add_child(score_lbl)

		var dur_str := "--"
		if ticks > 0:
			dur_str = "%ds" % (ticks / 60)
		row.add_child(_col_lbl(dur_str, ref, 0.22, _C_MID, false, HORIZONTAL_ALIGNMENT_RIGHT))

		var status_txt := "OK"
		var status_col := _C_GREEN
		if flagged:
			status_txt = "FLAG"
			status_col = Color(0.820, 0.180, 0.120)
		row.add_child(_col_lbl(status_txt, ref, 0.22, status_col, false, HORIZONTAL_ALIGNMENT_RIGHT))

		if session_id != "" and not flagged:
			var watch_btn := Button.new()
			watch_btn.text = ""
			var _wic_path : String = UITheme.get_theme_assets().get("icon_play", "")
			if ResourceLoader.exists(_wic_path):
				watch_btn.icon = load(_wic_path)
				watch_btn.expand_icon = true
				watch_btn.add_theme_constant_override("icon_max_width", int(ref * 0.032))
			else:
				watch_btn.text = "WATCH"
				watch_btn.add_theme_font_size_override("font_size", int(ref * 0.022))
			watch_btn.modulate = UITheme.COL_ORANGE
			watch_btn.custom_minimum_size = Vector2(int(ref * 0.055), int(ref * 0.048))
			watch_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
			_warm_ghost_btn(watch_btn, 6)
			row.add_child(watch_btn)
			var sid_cap := session_id
			watch_btn.pressed.connect(func(): _fetch_and_watch(sid_cap, watch_btn))
		else:
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(int(ref * 0.11), 0)
			spacer.size_flags_horizontal = Control.SIZE_SHRINK_END
			row.add_child(spacer)


# ---------------------------------------------------------------------------
# REPLAY FETCH
# ---------------------------------------------------------------------------

func _fetch_and_watch(session_id: String, btn: Button) -> void:
	if _auth_token == "":
		return
	btn.disabled = true
	btn.icon = null
	btn.text = ".."

	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)

	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if not is_instance_valid(btn):
			return
		btn.disabled = false
		btn.text = ""
		var _wip : String = UITheme.get_theme_assets().get("icon_play", "")
		if ResourceLoader.exists(_wip): btn.icon = load(_wip); btn.expand_icon = true
		else: btn.text = "PLAY"

		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return

		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK:
			return
		var data = j.get_data()
		if typeof(data) != TYPE_DICTIONARY:
			return

		var seed_str : String = str(data.get("seed", "0"))
		var seed     : int    = int(seed_str)
		var log_b64  : String = data.get("replay_log", "")
		var char_idx : int    = int(data.get("char", 0))
		var nickname : String = data.get("nickname", "")

		if log_b64 == "":
			return

		var log_bytes := Marshalls.base64_to_raw(log_b64)
		if log_bytes.is_empty():
			return

		hide_panel()
		emit_signal("replay_requested", seed, log_bytes, char_idx, nickname)
	)

	var url     := BACKEND_URL + "/backend/replay/" + session_id.uri_encode()
	var headers := PackedStringArray(["Authorization: Bearer " + _auth_token])
	http.request(url, headers)


# ---------------------------------------------------------------------------
# SHOW / HIDE
# ---------------------------------------------------------------------------

func show_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	_refresh()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 0.0
		_panel_ctrl.scale      = Vector2(0.90, 0.90)
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 1.0,        0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func hide_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	if is_instance_valid(_panel_ctrl):
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 0.0,                 0.15).set_trans(Tween.TRANS_QUAD)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2(0.90, 0.90), 0.15).set_trans(Tween.TRANS_QUAD)
			_anim_tween.chain().tween_callback(func(): hide())
			return
	hide()
