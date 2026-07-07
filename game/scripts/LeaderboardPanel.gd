extends CanvasLayer
## LeaderboardPanel.gd — Daily/weekly leaderboard, top 3 with prizes
## Same UITheme style as settings popup.

signal closed
signal replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, nickname: String, player_seed: int)

var BACKEND_URL : String = ApiConfig.base_url()   # resolved at runtime (same origin on web)
const UITheme     := preload("res://scripts/UITheme.gd")
const _TEX_HUD_X  := preload("res://assets/hud/hudX.png")

var _panel_ctrl  : Control       = null
var _list_root   : VBoxContainer = null
var _tab_daily   : Button        = null
var _tab_weekly  : Button        = null
var _anim_tween  : Tween         = null
var _cur_period  : String        = "daily"   # "daily" | "weekly"
var _player_id   : String        = ""
var _auth_attempted : bool = false
var _has_wallet  : bool = false   # whether Nimiq Pay is connected (address present)
var _pending_replay_http : HTTPRequest = null  # for cancellation
var _replay_cancelled    : bool        = false

# LB-01: avatar texture cache — avoids re-rendering identical fallback avatars
var _avatar_tex_cache : Dictionary = {}   # address+size key → ImageTexture

# Prizes (loaded from backend)
var _daily_prizes  := [100.0, 50.0, 30.0]
var _weekly_prizes := [500.0, 300.0, 100.0]

const MEDAL_COLORS := [
	Color(0.960, 0.600, 0.100),   # 1st — turuncu parlak
	Color(0.820, 0.460, 0.060),   # 2nd — turuncu orta
	Color(0.700, 0.350, 0.040),   # 3rd — turuncu koyu
]
const MEDAL_EMOJIS := ["#1", "#2", "#3"]


func setup() -> void:
	_build_ui()
	hide()


func set_player_id(pid: String) -> void:
	_player_id = pid

func set_auth_attempted(v: bool) -> void:
	_auth_attempted = v

func set_has_wallet(v: bool) -> void:
	_has_wallet = v


func show_panel() -> void:
	_replay_cancelled = false
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 0.0
		_panel_ctrl.scale      = Vector2(0.90, 0.90)
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 1.0,        0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_fetch_prizes_then_lb()


func hide_panel() -> void:
	print("[LB] hide_panel called stack=%s" % str(get_stack()))
	# Cancel pending replay HTTP request
	_replay_cancelled = true
	if is_instance_valid(_pending_replay_http):
		var _h := _pending_replay_http
		_pending_replay_http = null
		_h.cancel_request()
		_h.queue_free()
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


const _C_BG     := Color(0.957, 0.898, 0.800)
const _C_CARD   := Color(0.910, 0.850, 0.750)
const _C_BORDER := Color(0.580, 0.380, 0.220)
const _C_BROWN  := Color(0.220, 0.130, 0.060)
const _C_MID    := Color(0.480, 0.340, 0.200)
const _C_SEP    := Color(0.580, 0.380, 0.220, 0.4)
const _C_ORANGE := Color(0.780, 0.380, 0.120)

func _build_ui() -> void:
	var vw  := get_viewport().get_visible_rect().size.x
	var vh  := get_viewport().get_visible_rect().size.y
	var ref := minf(minf(vw, vh), GameConstants.VW)

	_panel_ctrl = Control.new()
	_panel_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel_ctrl)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_ctrl.add_child(dim)

	var pw := ref * 0.92   # FIX: vw yerine ref — büyük ekranda genişlemeyi önler
	var ph := minf(vh * 0.88, vh - int(ref * 0.04) * 2.0)

	var pc := PanelContainer.new()
	pc.anchor_left   = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top    = 0.5; pc.anchor_bottom = 0.5
	pc.offset_left   = -pw * 0.5; pc.offset_right  = pw * 0.5
	pc.offset_top    = -ph * 0.5; pc.offset_bottom = ph * 0.5
	var pc_st := StyleBoxFlat.new()
	pc_st.bg_color     = _C_BG
	pc_st.border_color = _C_BORDER
	pc_st.set_border_width_all(3)
	pc_st.set_corner_radius_all(14)
	pc_st.shadow_color = Color(0.0, 0.0, 0.0, 0.20)
	pc_st.shadow_size  = 8
	pc.add_theme_stylebox_override("panel", pc_st)
	_panel_ctrl.add_child(pc)

	var pad := int(ref * 0.025)
	var sep := int(ref * 0.010)
	var ic  := int(ref * 0.045)
	# TOUCH-FIX: close button's tap target was only ~0.045*ref — far below the
	# ~44pt minimum recommended for touch. Bumped to a dedicated, larger size
	# (kept separate from `ic`, which other icons still use unchanged).
	var close_sz := int(ref * 0.090)
	var close_ic_sz := int(close_sz * 0.72)  # icon now fills the bigger button instead of floating tiny inside it

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	pc.add_child(outer)

	# ── Title ──
	var hdr_mc := _make_margin(pad, pad, pad / 2, pad)
	outer.add_child(hdr_mc)

	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr_mc.add_child(hdr)

	hdr.add_child(UITheme.lucide_icon("trophy", int(ref * 0.038), _C_ORANGE))

	var title_lbl := Label.new()
	title_lbl.text = "LEADERBOARD"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title_lbl, _C_BROWN, int(ref * 0.048))
	hdr.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.custom_minimum_size = Vector2(close_sz, close_sz)
	close_btn.pressed.connect(func(): hide_panel(); closed.emit())
	_warm_btn(close_btn, 8)
	var close_center := CenterContainer.new()
	close_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_btn.add_child(close_center)
	var close_ic := TextureRect.new()
	close_ic.texture = _TEX_HUD_X
	close_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_ic.custom_minimum_size = Vector2(close_ic_sz, close_ic_sz)
	close_center.add_child(close_ic)
	hdr.add_child(close_btn)

	# ── Tab bar: Daily | Weekly ──
	var tab_mc := _make_margin(pad, pad, sep, sep)
	outer.add_child(tab_mc)

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", int(ref * 0.012))
	tab_mc.add_child(tab_row)

	_tab_daily = _make_tab_btn("Daily", ref)
	_tab_daily.pressed.connect(func(): _switch_period("daily"))
	tab_row.add_child(_tab_daily)

	_tab_weekly = _make_tab_btn("Weekly", ref)
	_tab_weekly.pressed.connect(func(): _switch_period("weekly"))
	tab_row.add_child(_tab_weekly)

	_update_tabs()

	# ── Separator ──
	var sep_line := HSeparator.new()
	sep_line.add_theme_color_override("color", _C_SEP)
	outer.add_child(sep_line)

	# ── Scroll ──
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone        = 0
	scroll.follow_focus           = false
	outer.add_child(scroll)

	var content_mc := _make_margin(pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)

	_list_root = VBoxContainer.new()
	_list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_root.add_theme_constant_override("separation", sep)
	content_mc.add_child(_list_root)

	_set_loading()


func _make_tab_btn(txt: String, ref: float) -> Button:
	var btn := Button.new()
	btn.text = txt
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size   = Vector2(0, int(ref * 0.065))
	_warm_ghost_btn(btn, 8)
	btn.add_theme_font_size_override("font_size", int(ref * 0.030))
	return btn


func _update_tabs() -> void:
	if not is_instance_valid(_tab_daily) or not is_instance_valid(_tab_weekly):
		return
	var active_col   := Color(0.780, 0.380, 0.120)   # turuncu — aktif
	var inactive_col := Color(0.480, 0.340, 0.200)   # orta kahve — pasif
	# Aktif tab: turuncu dolgu; pasif tab: ghost
	if _cur_period == "daily":
		_warm_btn(_tab_daily, 8)
		_tab_daily.add_theme_color_override("font_color", Color(0.957, 0.898, 0.800))
		_warm_ghost_btn(_tab_weekly, 8)
		_tab_weekly.add_theme_color_override("font_color", inactive_col)
	else:
		_warm_btn(_tab_weekly, 8)
		_tab_weekly.add_theme_color_override("font_color", Color(0.957, 0.898, 0.800))
		_warm_ghost_btn(_tab_daily, 8)
		_tab_daily.add_theme_color_override("font_color", inactive_col)


func _switch_period(period: String) -> void:
	if _cur_period == period:
		return
	_cur_period = period
	_update_tabs()
	_fetch_lb()


# ── Data loading ──────────────────────────────────────────────────────────────

func _fetch_prizes_then_lb() -> void:
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				var dp = d.get("daily", {})
				var wp = d.get("weekly", {})
				_daily_prizes  = [dp.get("first", 100.0), dp.get("second", 50.0), dp.get("third", 30.0)]
				_weekly_prizes = [wp.get("first", 500.0), wp.get("second", 300.0), wp.get("third", 100.0)]
		_fetch_lb()
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/leaderboard/prizes"))


func _fetch_lb() -> void:
	_set_loading()
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				_build_list(j.get_data())
				return
		_show_error("Could not connect to server. Code: %d" % code)
		Toast.network_error("leaderboard code=%d" % code)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/leaderboard?period=%s&limit=10" % _cur_period))


## ── Warm bej buton helper'ları ─────────────────────────────────────────────

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


## Small circular icon button for inline row actions (e.g. "watch replay").
## Outlined terracotta at rest, fills solid on hover/press — reads as a
## secondary, in-row action rather than competing with the panel's primary
## filled buttons (close / tabs). Shared visual language with StatsPanel.
static func _replay_icon_btn(btn: Button, size: int) -> void:
	btn.custom_minimum_size = Vector2(size, size)
	var ri := size / 2
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.set_corner_radius_all(ri)
	sn.bg_color = Color(0, 0, 0, 0)
	sn.border_color = _C_ORANGE; sn.set_border_width_all(2)
	sh.bg_color = _C_ORANGE
	sh.border_color = _C_ORANGE; sh.set_border_width_all(2)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	sp.border_color = Color(0.640, 0.300, 0.080); sp.set_border_width_all(2)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	btn.add_theme_stylebox_override("focus",   sn)
	# Icon flips from terracotta (outline) to cream (filled) on hover/press.
	btn.add_theme_color_override("icon_normal_color",  _C_ORANGE)
	btn.add_theme_color_override("icon_hover_color",   _C_BG)
	btn.add_theme_color_override("icon_pressed_color", _C_BG)
	btn.add_theme_color_override("font_color",         _C_ORANGE)
	btn.add_theme_color_override("font_hover_color",   _C_BG)
	btn.add_theme_color_override("font_pressed_color", _C_BG)
	btn.tooltip_text = "Watch replay"
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _make_margin(l: int, r: int = -1, t: int = -1, b: int = -1) -> MarginContainer:
	if r < 0: r = l
	if t < 0: t = l
	if b < 0: b = l
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   l)
	mc.add_theme_constant_override("margin_right",  r)
	mc.add_theme_constant_override("margin_top",    t)
	mc.add_theme_constant_override("margin_bottom", b)
	return mc


func _set_loading() -> void:
	for c in _list_root.get_children():
		c.queue_free()
	var ref := minf(minf(
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var lbl := Label.new()
	lbl.text = "Loading leaderboard..."
	UITheme.apply_label(lbl, _C_MID, int(ref * 0.030))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list_root.add_child(lbl)


# ── List building ────────────────────────────────────────────────────────────

func _build_list(data: Variant) -> void:
	for c in _list_root.get_children():
		c.queue_free()

	var entries : Array = []
	if data is Dictionary:
		entries = data.get("entries", data.get("sessions", []))
	elif data is Array:
		entries = data

	var ref := minf(minf(
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y), GameConstants.VW)

	# Banner: show if player_id is missing (guest or sign rejected — same either way)
	# Hidden only once player_id is set after successful auth
	if _player_id == "" and OS.has_feature("web"):
		var banner := PanelContainer.new()
		banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var st := StyleBoxFlat.new()
		st.bg_color     = _C_CARD
		st.border_color = _C_BORDER
		st.set_border_width_all(2)
		st.set_corner_radius_all(8)
		banner.add_theme_stylebox_override("panel", st)
		_list_root.add_child(banner)

		var bmc := MarginContainer.new()
		for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
			bmc.add_theme_constant_override(side, int(ref * 0.018))
		banner.add_child(bmc)

		var brow := HBoxContainer.new()
		brow.add_theme_constant_override("separation", int(ref * 0.012))
		bmc.add_child(brow)

		brow.add_child(UITheme.lucide_icon("wallet", int(ref * 0.032), _C_ORANGE))

		var blbl := Label.new()
		blbl.text = "Connect wallet to save your scores"
		blbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		blbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UITheme.apply_label(blbl, _C_BROWN, int(ref * 0.026))
		brow.add_child(blbl)

		var bbtn := Button.new()
		bbtn.text = "Connect"
		bbtn.add_theme_font_size_override("font_size", int(ref * 0.026))
		bbtn.custom_minimum_size = Vector2(int(ref * 0.22), int(ref * 0.055))
		_warm_btn(bbtn, 8)
		bbtn.pressed.connect(func():
			bbtn.disabled = true
			bbtn.text = "..."
			_request_connect(bbtn, blbl)
		)
		brow.add_child(bbtn)

	if entries.is_empty():
		_show_error("No scores yet - be the first to play!")
		return

	var prizes := _daily_prizes if _cur_period == "daily" else _weekly_prizes
	var pad    := int(ref * 0.010)

	# ── Column headers ──
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", int(ref * 0.008))
	_list_root.add_child(hdr_row)
	hdr_row.add_child(_make_col_label("#",      ref, 0.10, _C_BROWN, true))
	hdr_row.add_child(_make_col_label("Player", ref, 0.45, _C_BROWN, true))
	var sc_h := _make_col_label("Score", ref, 0.22, _C_BROWN, true)
	sc_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hdr_row.add_child(sc_h)
	var pr_h := _make_col_label("Prize", ref, 0.13, _C_BROWN, true)
	pr_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hdr_row.add_child(pr_h)
	var dt_h := _make_col_label("Date", ref, 0.10, _C_BROWN, true)
	dt_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hdr_row.add_child(dt_h)
	# Reserve the same trailing width the replay-button column takes in each
	# data row below, so Score / Prize / Date line up with the numbers.
	var hdr_spacer := Control.new()
	hdr_spacer.custom_minimum_size = Vector2(int(ref * 0.056), 0)
	hdr_row.add_child(hdr_spacer)

	var sep_hdr := HSeparator.new()
	sep_hdr.add_theme_color_override("color", _C_SEP)
	_list_root.add_child(sep_hdr)

	# ── All rows (uniform style, medals for top 3) ──
	for i in entries.size():
		var e       : Dictionary = entries[i]
		var rank    : int        = e.get("rank", i + 1)
		var address : String     = str(e.get("player_id", e.get("address", "")))
		var _raw_nick : String   = str(e.get("nickname", ""))
		# Fallback: short wallet address if no nickname set
		var nick : String = _raw_nick if _raw_nick != "" and _raw_nick != "null" else \
			(address.left(6) + ".." + address.right(3) if address.length() > 9 else address)
		var score   : int        = e.get("server_score", e.get("client_score", 0))
		var ts      : int        = e.get("submitted_at", 0)
		var prize   : float      = prizes[i] if i < prizes.size() else 0.0

		# Top-3 get medal color, others get dim text
		var rank_col  : Color  = _C_MID
		var rank_text : String = "#%d" % rank
		if i < 3:
			rank_col  = MEDAL_COLORS[i]
			rank_text = MEDAL_EMOJIS[i]

		var row_pc := PanelContainer.new()
		row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_st := StyleBoxFlat.new()
		row_st.bg_color     = _C_CARD
		row_st.border_color = _C_BORDER
		row_st.set_border_width_all(1)
		row_st.set_corner_radius_all(8)
		row_pc.add_theme_stylebox_override("panel", row_st)
		_list_root.add_child(row_pc)

		var row_mc := _make_margin(pad)
		row_pc.add_child(row_mc)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(ref * 0.008))
		row_mc.add_child(row)

		var rank_lbl := _make_col_label(rank_text, ref, 0.10, rank_col, i < 3)
		row.add_child(rank_lbl)

		var player_cell := HBoxContainer.new()
		player_cell.size_flags_horizontal    = Control.SIZE_EXPAND_FILL
		player_cell.size_flags_stretch_ratio = 0.45
		player_cell.add_theme_constant_override("separation", int(ref * 0.010))
		player_cell.alignment = BoxContainer.ALIGNMENT_BEGIN
		row.add_child(player_cell)

		var avatar_size := int(ref * 0.040)
		var avatar := _make_nimiq_avatar(address, avatar_size)
		player_cell.add_child(avatar)

		var nick_col : Color = _C_BROWN
		var id_lbl := Label.new()
		id_lbl.text = nick
		id_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		id_lbl.clip_text = true
		id_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UITheme.apply_label(id_lbl, nick_col, int(ref * (0.028 if i < 3 else 0.026)))
		player_cell.add_child(id_lbl)

		var has_replay_e : bool   = e.get("has_replay", false)
		var session_id_e : String = str(e.get("session_id", ""))

		var score_lbl := _make_col_label(str(score), ref, 0.22, _C_ORANGE, i < 3)
		score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(score_lbl)

		var prize_str := (str(snappedf(float(prize), 0.0001))) if prize > 0 else "-"
		var prize_col := Color(0.820, 0.580, 0.100) if prize > 0 else _C_MID  # altın
		var prize_lbl := _make_col_label(prize_str, ref, 0.13, prize_col, prize > 0)
		prize_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(prize_lbl)

		var time_str := ""
		if ts > 0:
			var dt := Time.get_datetime_dict_from_unix_time(ts)
			time_str = "%02d.%02d" % [dt.day, dt.month]
		var time_lbl := _make_col_label(time_str, ref, 0.10, _C_MID, false)
		time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(time_lbl)

		if has_replay_e and session_id_e != "":
			var rp_btn := Button.new()
			rp_btn.text = ""
			var _rp_ic_path : String = UITheme.get_theme_assets().get("icon_play", "")
			var rp_size := int(ref * 0.056)
			if ResourceLoader.exists(_rp_ic_path):
				rp_btn.icon = load(_rp_ic_path)
				rp_btn.expand_icon = true
				rp_btn.icon_alignment          = HORIZONTAL_ALIGNMENT_CENTER
				rp_btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
				rp_btn.add_theme_constant_override("icon_max_width", int(rp_size * 0.5))
			else:
				rp_btn.text = "▶"
				rp_btn.add_theme_font_size_override("font_size", int(ref * 0.020))
			rp_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			rp_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
			_replay_icon_btn(rp_btn, rp_size)
			rp_btn.pressed.connect(_fetch_and_emit_replay.bind(session_id_e, rp_btn))
			row.add_child(rp_btn)
		else:
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(int(ref * 0.056), 0)
			row.add_child(spacer)

	UITheme.set_scroll_passthrough(_list_root)


func _make_col_label(txt: String, ref: float, w_ratio: float, col: Color, bold: bool) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	var sz := int(ref * (0.030 if bold else 0.026))
	UITheme.apply_label(lbl, col, sz)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_stretch_ratio = w_ratio
	lbl.clip_text = true
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _make_nimiq_avatar(address: String, size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode    = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode   = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = Control.TEXTURE_FILTER_LINEAR
	# Always draw fallback avatar (visible immediately)
	tr.texture = _make_fallback_avatar(address, size)
	# If on web, load real Nimiq avatar on top
	if OS.has_feature("web") and address != "" and address != "null" and address != "undefined":
		_load_nimiq_avatar_async(tr, address, size)
	return tr


## Generates a round avatar with deterministic color + initial letter from address hash.
## Used as fallback outside web and until loading completes on web.
func _make_fallback_avatar(address: String, size: int) -> ImageTexture:
	var cache_key := address + "@" + str(size)
	if _avatar_tex_cache.has(cache_key): return _avatar_tex_cache[cache_key]
	# Color palette — vivid colors close to Nimiq tones
	const PALETTE := [
		Color(0.13, 0.60, 0.90),  # mavi
		Color(0.40, 0.78, 0.22),  # green
		Color(0.96, 0.65, 0.14),  # turuncu
		Color(0.82, 0.28, 0.28),  # red
		Color(0.60, 0.35, 0.85),  # mor
		Color(0.20, 0.72, 0.65),  # teal
		Color(0.95, 0.38, 0.60),  # pembe
		Color(0.45, 0.55, 0.70),  # gri-mavi
	]

	# Pick deterministic color from address
	var hash_val := 0
	for i in mini(address.length(), 12):
		hash_val = (hash_val * 31 + address.unicode_at(i)) & 0xFFFF
	var bg_col : Color = PALETTE[hash_val % PALETTE.size()]

	# Initial letter
	var letter := "?"
	for i in address.length():
		var c := address.unicode_at(i)
		if (c >= 65 and c <= 90) or (c >= 48 and c <= 57):  # A-Z or 0-9
			letter = address[i]
			break

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx := size * 0.5
	var cy := size * 0.5
	var r  := size * 0.5

	# Draw filled circle
	for y in size:
		for x in size:
			var dx := x - cx + 0.5
			var dy := y - cy + 0.5
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, bg_col)

	var ps := maxi(1, size / 10)   # pixel size per glyph dot
	_draw_letter(img, letter, 0, 0, ps, Color.WHITE)

	var tex := ImageTexture.create_from_image(img)
	_avatar_tex_cache[address + "@" + str(size)] = tex
	return tex


## Draws a single character onto an image (simple bitmap font, uppercase + digits).
func _draw_letter(img: Image, ch: String, _ox: int, _oy: int, ps: int, ink: Color) -> void:
	# Each character is a 3-column × 5-row bitmask
	const GLYPHS := {
		"0": [0b111,0b101,0b101,0b101,0b111],
		"1": [0b010,0b110,0b010,0b010,0b111],
		"2": [0b111,0b001,0b111,0b100,0b111],
		"3": [0b111,0b001,0b111,0b001,0b111],
		"4": [0b101,0b101,0b111,0b001,0b001],
		"5": [0b111,0b100,0b111,0b001,0b111],
		"6": [0b111,0b100,0b111,0b101,0b111],
		"7": [0b111,0b001,0b001,0b001,0b001],
		"8": [0b111,0b101,0b111,0b101,0b111],
		"9": [0b111,0b101,0b111,0b001,0b111],
		"A": [0b010,0b101,0b111,0b101,0b101],
		"B": [0b110,0b101,0b110,0b101,0b110],
		"C": [0b111,0b100,0b100,0b100,0b111],
		"D": [0b110,0b101,0b101,0b101,0b110],
		"E": [0b111,0b100,0b110,0b100,0b111],
		"F": [0b111,0b100,0b110,0b100,0b100],
		"G": [0b111,0b100,0b101,0b101,0b111],
		"H": [0b101,0b101,0b111,0b101,0b101],
		"I": [0b111,0b010,0b010,0b010,0b111],
		"J": [0b001,0b001,0b001,0b101,0b111],
		"K": [0b101,0b101,0b110,0b101,0b101],
		"L": [0b100,0b100,0b100,0b100,0b111],
		"M": [0b101,0b111,0b101,0b101,0b101],
		"N": [0b101,0b111,0b111,0b101,0b101],
		"O": [0b111,0b101,0b101,0b101,0b111],
		"P": [0b110,0b101,0b110,0b100,0b100],
		"Q": [0b111,0b101,0b101,0b111,0b001],
		"R": [0b110,0b101,0b110,0b101,0b101],
		"S": [0b111,0b100,0b111,0b001,0b111],
		"T": [0b111,0b010,0b010,0b010,0b010],
		"U": [0b101,0b101,0b101,0b101,0b111],
		"V": [0b101,0b101,0b101,0b010,0b010],
		"W": [0b101,0b101,0b101,0b111,0b101],
		"X": [0b101,0b101,0b010,0b101,0b101],
		"Y": [0b101,0b101,0b010,0b010,0b010],
		"Z": [0b111,0b001,0b010,0b100,0b111],
		"?": [0b111,0b001,0b011,0b000,0b010],
	}
	var rows : Array = GLYPHS.get(ch, GLYPHS["?"])
	var w := img.get_width()
	var h := img.get_height()
	# Center: 3 columns × ps pixel width, 5 rows × ps pixel height
	var gw := 3 * ps
	var gh := 5 * ps
	var sx := (w - gw) / 2
	var sy := (h - gh) / 2
	for row in 5:
		var mask : int = rows[row]
		for bit in 3:
			if mask & (0b100 >> bit):
				for py in ps:
					for px in ps:
						var ix := sx + bit * ps + px
						var iy := sy + row * ps + py
						if ix >= 0 and ix < w and iy >= 0 and iy < h:
							img.set_pixel(ix, iy, ink)


func _load_nimiq_avatar_async(target: Control, address: String, size: int) -> void:
	if not OS.has_feature("web"): return
	var key := "avatar_" + address.left(8).validate_node_name()

	# Wait if Identicons CDN not yet loaded (max 3 seconds)
	for _w in 30:
		var ready = JavaScriptBridge.eval("window._nimiqIconsReady === true", true)
		if ready: break
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(target): return

	var js_code := (
		"(function(){"
		+ "if(!window._nimiqPending) window._nimiqPending = {};"
		+ "window._nimiqPending['" + key + "'] = null;"
		+ "if(typeof window.getNimiqAvatar !== 'function'){"
		+ "  console.warn('[Avatar] not ready');"
		+ "  window._nimiqPending['" + key + "'] = ''; return;"
		+ "}"
		+ "window.getNimiqAvatar('" + address + "')"
		+ "  .then(function(svgData){"
		+ "    if(!svgData){ window._nimiqPending['" + key + "'] = ''; return; }"
		+ "    console.log('[Avatar] got svg len=' + svgData.length);"
		+ "    var img = new Image();"
		+ "    img.onload = function(){"
		+ "      try {"
		+ "        var c = document.createElement('canvas');"
		+ "        c.width = " + str(size) + "; c.height = " + str(size) + ";"
		+ "        c.getContext('2d').drawImage(img, 0, 0, " + str(size) + ", " + str(size) + ");"
		+ "        window._nimiqPending['" + key + "'] = c.toDataURL('image/png');"
		+ "        console.log('[Avatar] png ready');"
		+ "      } catch(e){ window._nimiqPending['" + key + "'] = ''; }"
		+ "    };"
		+ "    img.onerror = function(){ window._nimiqPending['" + key + "'] = ''; };"
		+ "    img.src = svgData;"
		+ "  })"
		+ "  .catch(function(e){ console.warn('[Avatar] err:',e); window._nimiqPending['" + key + "'] = ''; });"
		+ "})();"
	)
	JavaScriptBridge.eval(js_code, true)
	for _i in 50:
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(target): return
		var raw = JavaScriptBridge.eval("window._nimiqPending['%s']" % key, true)
		if raw == null: continue
		var result := str(raw)
		if result == "" or result == "null" or result == "undefined":
			return
		_apply_png_base64(target as TextureRect, result)
		return


func _apply_png_base64(target: TextureRect, data_url: String) -> void:
	if DisplayServer.get_name() == "headless": return
	if not is_instance_valid(target): return
	if not data_url.begins_with("data:image/png;base64,"): return
	var b64   := data_url.substr(len("data:image/png;base64,")).strip_edges()
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.is_empty(): return
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK: return
	if is_instance_valid(target):
		target.texture = ImageTexture.create_from_image(img)


func _fetch_and_emit_replay(session_id_e: String, btn: Button) -> void:
	if not is_instance_valid(btn): return
	btn.disabled = true
	btn.text = "..."
	btn.icon = null
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	_replay_cancelled    = false
	_pending_replay_http = http
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		_pending_replay_http = null
		http.queue_free()
		if _replay_cancelled: return
		if not is_inside_tree(): return
		if not is_instance_valid(btn): return
		btn.disabled = false
		var _rp_ic_path2 : String = UITheme.get_theme_assets().get("icon_play", "")
		if ResourceLoader.exists(_rp_ic_path2):
			btn.text = ""
			btn.icon = load(_rp_ic_path2)
		else:
			btn.text = "▶"
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			Toast.network_error("replay_fetch code=%d" % code)
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK: return
		var d : Dictionary = j.get_data()
		var seed_str : String = str(d.get("seed", "0"))
		var seed     : int    = int(seed_str)
		var log_b64  : String = str(d.get("replay_log", ""))
		var char_idx : int    = int(d.get("char", 0))
		var nickname : String = str(d.get("nickname", ""))
		var player_seed : int = int(str(d.get("player_seed", "0")))
		if log_b64 == "" or seed == 0: return
		var log_bytes := Marshalls.base64_to_raw(log_b64)
		if log_bytes.is_empty(): return
		# FIX: hide_panel() + closed.emit() were called BEFORE replay_requested.emit(),
		# which made the signal dispatch run with _leaderboard_panel.visible == false.
		# Main._on_leaderboard_replay_requested guards `if not _leaderboard_panel.visible: return`
		# so the replay never started. Solution: emit first, then close deferred.
		replay_requested.emit(seed, log_bytes, char_idx, nickname, player_seed)
		# Deferred so the visibility guard has already been evaluated by the time
		# hide runs. closed.emit() is kept separate — hide_panel() does not emit it.
		hide_panel.call_deferred()
		closed.emit.call_deferred()
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/replay/" + session_id_e))


func _request_connect(btn: Button, _lbl: Label) -> void:
	var result := await NimiqJS.request_account(30.0)
	if result.get("ok", false):
		_player_id = str(result.get("address", ""))
		_fetch_lb()
	else:
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = "Connect"


func _show_error(msg: String) -> void:
	for c in _list_root.get_children():
		c.queue_free()
	var ref := minf(minf(
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var lbl := Label.new()
	lbl.text = "! " + msg
	UITheme.apply_label(lbl, Color(0.75, 0.15, 0.10), int(ref * 0.026))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list_root.add_child(lbl)
