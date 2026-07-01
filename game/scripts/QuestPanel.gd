extends CanvasLayer
## QuestPanel.gd — Daily quests: countdown, progress, claim button

signal closed

var BACKEND_URL : String = ApiConfig.base_url()   # resolved at runtime (same origin on web)
const UITheme     := preload("res://scripts/UITheme.gd")

var _player_id      : String  = ""
var _auth_token     : String  = ""
var _auth_attempted : bool    = false
var _has_wallet     : bool    = false   # whether Nimiq Pay is connected
var _panel_ctrl  : Control
var _list_root   : VBoxContainer
var _reset_lbl   : Label
var _timer       : Timer
var _quest_data  : Array = []
var _anim_tween  : Tween = null


func setup(player_id: String) -> void:
	_player_id = player_id
	_build_ui()
	_start_countdown_timer()
	hide()


func set_auth_token(token: String) -> void:
	_auth_token = token

func set_auth_attempted(v: bool) -> void:
	_auth_attempted = v

func set_has_wallet(v: bool) -> void:
	_has_wallet = v


func set_player_id(player_id: String) -> void:
	if _player_id == player_id:
		return
	_player_id = player_id
	_refresh()


# ── Panel Open / Close ───────────────────────────────────────────
func show_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 0.0
		_panel_ctrl.scale      = Vector2(0.92, 0.92)
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 1.0,        0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_refresh()


func hide_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	if is_instance_valid(_panel_ctrl):
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 0.0,                 0.15).set_trans(Tween.TRANS_QUAD)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2(0.92, 0.92), 0.15).set_trans(Tween.TRANS_QUAD)
			_anim_tween.chain().tween_callback(func(): hide())
			return
	hide()


# ── Countdown ────────────────────────────────────────────────────
func _start_countdown_timer() -> void:
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.autostart = true
	_timer.timeout.connect(_update_countdown)
	add_child(_timer)


func _update_countdown() -> void:
	if not is_instance_valid(_reset_lbl): return
	var t          := Time.get_datetime_dict_from_system()
	var secs_today := int(t["hour"]) * 3600 + int(t["minute"]) * 60 + int(t["second"])
	var remaining  := maxi(86400 - secs_today, 0)
	_reset_lbl.text = "Reset: %02d:%02d:%02d" % [remaining / 3600, (remaining % 3600) / 60, remaining % 60]


# ── UI ───────────────────────────────────────────────────────────
func _build_ui() -> void:
	var vp  := get_viewport()
	var vw  := vp.get_visible_rect().size.x if vp else GameConstants.VW
	var vh  := vp.get_visible_rect().size.y if vp else GameConstants.VH
	var ref := minf(minf(vw, vh), GameConstants.VW)
	var pad := int(ref * 0.025)
	var ic  := int(ref * 0.038)   # ikon boyutu
	var pw  := ref * 0.92   # FIX: vw yerine ref — büyük ekranda genişlemeyi önler
	var ph  := minf(vh * 0.88, vh - pad * 2.0)

	_panel_ctrl = Control.new()
	_panel_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel_ctrl)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.58)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			hide_panel(); closed.emit()
	)
	_panel_ctrl.add_child(dim)

	var pc := PanelContainer.new()
	pc.anchor_left   = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top    = 0.5; pc.anchor_bottom = 0.5
	pc.offset_left   = -pw * 0.5; pc.offset_right  =  pw * 0.5
	pc.offset_top    = -ph * 0.5; pc.offset_bottom =  ph * 0.5
	# Warm bej panel arka planı
	var pc_style := StyleBoxFlat.new()
	pc_style.bg_color     = Color(0.957, 0.898, 0.800)
	pc_style.border_color = Color(0.580, 0.380, 0.220)
	pc_style.set_border_width_all(3)
	pc_style.set_corner_radius_all(14)
	pc_style.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	pc_style.shadow_size  = 10
	pc.add_theme_stylebox_override("panel", pc_style)
	_panel_ctrl.add_child(pc)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	pc.add_child(outer)

	# ── Header ──
	var hdr_mc := _mpad(pad, int(pad * 0.6))
	outer.add_child(hdr_mc)
	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr.add_theme_constant_override("separation", int(ref * 0.012))
	hdr_mc.add_child(hdr)

	hdr.add_child(UITheme.lucide_icon("zap", ic, Color(0.220, 0.130, 0.060)))

	var title_lbl := Label.new()
	title_lbl.text = "DAILY QUESTS"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title_lbl, Color(0.220, 0.130, 0.060), int(ref * 0.048))
	hdr.add_child(title_lbl)

	# TOUCH-FIX: close button tap target was only ~0.048*ref (too small on
	# phones). Visual icon size unchanged; tappable area grows via a larger
	# button with the icon centered inside it.
	var close_sz    := int(ref * 0.092)
	var close_ic_sz := int(close_sz * 0.72)  # icon now fills the bigger button instead of floating tiny inside it
	var close_btn := Button.new()
	close_btn.custom_minimum_size = Vector2(close_sz, close_sz)
	close_btn.pressed.connect(func(): hide_panel(); closed.emit())
	_warm_btn(close_btn, 8)
	var close_center := CenterContainer.new()
	close_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_btn.add_child(close_center)
	var close_icon := TextureRect.new()
	close_icon.texture = preload("res://assets/hud/hudX.png")
	close_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_icon.custom_minimum_size = Vector2(close_ic_sz, close_ic_sz)
	close_center.add_child(close_icon)
	hdr.add_child(close_btn)

	# ── Countdown row ──
	var timer_mc := _mpad(int(pad * 0.6), int(pad * 0.25))
	outer.add_child(timer_mc)
	var timer_row := HBoxContainer.new()
	timer_row.alignment = BoxContainer.ALIGNMENT_CENTER
	timer_row.add_theme_constant_override("separation", int(ref * 0.010))
	timer_mc.add_child(timer_row)

	timer_row.add_child(UITheme.lucide_icon("rotate-ccw", int(ref * 0.028), Color(0.440, 0.300, 0.180)))

	_reset_lbl = Label.new()
	_reset_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_reset_lbl, Color(0.440, 0.300, 0.180), int(ref * 0.026))
	timer_row.add_child(_reset_lbl)
	_update_countdown()

	var sep := ColorRect.new()
	sep.color = Color(0.4, 0.4, 0.4, 0.3)
	sep.custom_minimum_size.y = 1
	outer.add_child(sep)

	# ── Scroll ──
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone        = 0
	scroll.follow_focus           = false
	outer.add_child(scroll)

	var content_mc := _mpad(pad, pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)

	_list_root = VBoxContainer.new()
	_list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_root.add_theme_constant_override("separation", int(ref * 0.016))
	content_mc.add_child(_list_root)

	_set_loading("Loading quests...")


# ── Backend ───────────────────────────────────────────────────────
func _refresh() -> void:
	if _player_id == "":
		_show_connect_prompt()
		return
	_set_loading("Loading quests...")
	_fetch_quests()


func _fetch_quests() -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				_quest_data = j.get_data().get("quests", [])
				_build_quest_list()
				return
		_show_error("Could not connect to server. Code: %d" % code)
		Toast.network_error("quests_fetch code=%d" % code)
	)
	var headers : PackedStringArray = []
	if _auth_token != "":
		headers.append("Authorization: Bearer " + _auth_token)
	http.request(BACKEND_URL + "/backend/quests?player_id=" + _player_id.uri_encode(), headers)


func _claim_quest(quest_id: String, claim_btn: Button) -> void:
	# Collect ALL claimable quests and send as one batch request
	var ids : Array[String] = []
	for q in _quest_data:
		if q.get("completed", false) and q.get("claimed_at", 0) == 0:
			ids.append(str(q.get("id", "")))
	# Make sure the pressed one is in there
	if not ids.has(quest_id):
		ids.append(quest_id)

	claim_btn.disabled = true
	claim_btn.text = "Claiming..."

	var body_dict := { "player_id": _player_id, "quest_ids": ids }
	var body_str  := JSON.stringify(body_dict)

	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			_fetch_quests()
		else:
			claim_btn.text = "Claim Reward"
			claim_btn.disabled = false
			if result != HTTPRequest.RESULT_SUCCESS:
				Toast.network_error("quests_claim result=%d" % result)
			else:
				var j := JSON.new()
				var err_msg: String = "Error (%d)" % code
				if j.parse(body.get_string_from_utf8()) == OK:
					err_msg = str(j.get_data().get("error", err_msg))
				Toast.get_instance().show_toast(err_msg, Toast.Kind.ERROR)
	)
	var headers : PackedStringArray = ["Content-Type: application/json"]
	if _auth_token != "":
		headers.append("Authorization: Bearer " + _auth_token)
	http.request(BACKEND_URL + "/backend/quests/claim_all", headers, HTTPClient.METHOD_POST, body_str)


# ── Quest listesi ─────────────────────────────────────────────────
func _build_quest_list() -> void:
	_clear_list()
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	if _quest_data.is_empty():
		_show_error("No quests found for today")
		return
	for q in _quest_data:
		_list_root.add_child(_make_quest_card(q, ref))
	var spacer := Control.new()
	spacer.custom_minimum_size.y = int(ref * 0.02)
	_list_root.add_child(spacer)


## Warm beige palette (matching screenshot)
const _COL_CARD_BG     := Color(0.957, 0.898, 0.800)   # warm bej kart arka planı
const _COL_CARD_BORDER := Color(0.580, 0.380, 0.220)   # kahverengi border
const _COL_TEXT_BROWN  := Color(0.220, 0.130, 0.060)   # koyu kahve yazı
const _COL_TEXT_MID    := Color(0.440, 0.300, 0.180)   # orta kahve (dim)
const _COL_BAR_BG      := Color(0.780, 0.650, 0.500)   # bar arka planı
const _COL_BAR_FILL    := Color(0.220, 0.620, 0.280)   # yeşil progress

func _make_quest_card(q: Dictionary, ref: float) -> Control:
	var completed  : bool   = q.get("completed", false)
	var claimed_at : int    = q.get("claimed_at", 0)
	var progress   : int    = q.get("progress", 0)
	var target     : int    = q.get("target", 1)
	var reward     : float  = q.get("reward_nim", 0.0)
	var desc       : String = q.get("description", "")
	var quest_id   : String = q.get("id", "")
	var pct        : float  = clampf(float(progress) / float(maxi(target, 1)), 0.0, 1.0)
	var is_claimed   := completed and claimed_at != 0
	var is_claimable := completed and claimed_at == 0
	var pad := int(ref * 0.022)
	var ic  := int(ref * 0.032)

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Warm bej kart stili
	var card_style := StyleBoxFlat.new()
	card_style.bg_color     = _COL_CARD_BG
	card_style.border_color = _COL_CARD_BORDER
	for s in ["border_width_left","border_width_right","border_width_top","border_width_bottom"]:
		card_style.set(s, 2)
	for s in ["corner_radius_top_left","corner_radius_top_right","corner_radius_bottom_left","corner_radius_bottom_right"]:
		card_style.set(s, 8)
	card.add_theme_stylebox_override("panel", card_style)
	if is_claimed:
		card.modulate.a = 0.55

	var card_mc := MarginContainer.new()
	for side in ["margin_left","margin_right","margin_top","margin_bottom"]:
		card_mc.add_theme_constant_override(side, pad)
	card.add_child(card_mc)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(ref * 0.010))
	card_mc.add_child(vbox)

	# ── Top row: icon + description | reward ──
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", int(ref * 0.012))
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(top)

	var q_icon_name := "check-circle" if is_claimed else "target"
	var q_icon_col  := _COL_BAR_FILL if is_claimed else _COL_TEXT_MID
	top.add_child(UITheme.lucide_icon(q_icon_name, ic, q_icon_col))

	var desc_lbl := Label.new()
	desc_lbl.text = desc
	desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var desc_col := _COL_BAR_FILL if is_claimed else _COL_TEXT_BROWN
	UITheme.apply_label(desc_lbl, desc_col, int(ref * 0.030))
	top.add_child(desc_lbl)

	var reward_box := VBoxContainer.new()
	reward_box.add_theme_constant_override("separation", 0)
	top.add_child(reward_box)
	var reward_lbl := Label.new()
	reward_lbl.text = "%.3f" % reward
	reward_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(reward_lbl, _COL_TEXT_BROWN, int(ref * 0.034))
	reward_box.add_child(reward_lbl)
	var nim_lbl := Label.new()
	nim_lbl.text = "NIM"
	nim_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(nim_lbl, _COL_TEXT_MID, int(ref * 0.022))
	reward_box.add_child(nim_lbl)

	# ── Bottom content ──
	if is_claimed:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(ref * 0.008))
		vbox.add_child(row)
		row.add_child(UITheme.lucide_icon("check", int(ref * 0.026), Color(0.240, 0.620, 0.220)))
		var lbl := Label.new()
		lbl.text = "Reward claimed"
		UITheme.apply_label(lbl, Color(0.240, 0.620, 0.220), int(ref * 0.024))
		row.add_child(lbl)

	elif is_claimable:
		var done_row := HBoxContainer.new()
		done_row.add_theme_constant_override("separation", int(ref * 0.008))
		vbox.add_child(done_row)
		done_row.add_child(UITheme.lucide_icon("sparkles", int(ref * 0.028), Color(0.820, 0.580, 0.100)))
		var done_lbl := Label.new()
		done_lbl.text = "Quest complete!"
		UITheme.apply_label(done_lbl, Color(0.820, 0.580, 0.100), int(ref * 0.026))
		done_row.add_child(done_lbl)

		var claim_btn := Button.new()
		claim_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		claim_btn.custom_minimum_size.y = int(ref * 0.060)
		claim_btn.text = "Claim Reward"
		claim_btn.add_theme_font_size_override("font_size", int(ref * 0.030))
		_warm_btn(claim_btn, 8)
		claim_btn.pressed.connect(func(): _claim_quest(quest_id, claim_btn))
		vbox.add_child(claim_btn)

	else:
		_add_progress_bar(vbox, pct, progress, target, ref)

	return card


func _add_progress_bar(vbox: VBoxContainer, pct: float, progress: int, target: int, ref: float) -> void:
	var bar_h := int(ref * 0.022)
	var bar_outer := Control.new()
	bar_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_outer.custom_minimum_size   = Vector2(0, bar_h)
	bar_outer.clip_contents         = true
	vbox.add_child(bar_outer)

	# Pixel art köşe efekti: 2px offset iç kare
	var CORNER := 3  # piksel art köşe boşluğu

	# Arka plan
	var bg := ColorRect.new()
	bg.color = _COL_BAR_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar_outer.add_child(bg)

	# Fill — tree'ye eklendikten sonra boyutlanır
	var fill := ColorRect.new()
	fill.color    = Color(0.318, 0.576, 0.224)
	fill.position = Vector2(CORNER, CORNER)
	fill.size     = Vector2(0, bar_h - CORNER * 2)
	bar_outer.add_child(fill)

	# Pixel art köşe maskeleri — 4 köşe (bg rengiyle örtülür)
	var c_tl := ColorRect.new(); c_tl.color = _COL_CARD_BG
	var c_tr := ColorRect.new(); c_tr.color = _COL_CARD_BG
	var c_bl := ColorRect.new(); c_bl.color = _COL_CARD_BG
	var c_br := ColorRect.new(); c_br.color = _COL_CARD_BG
	for c in [c_tl, c_tr, c_bl, c_br]:
		c.size = Vector2(CORNER, CORNER)
		bar_outer.add_child(c)

	var _apply := func():
		var w := bar_outer.size.x
		if w <= 0: return
		fill.size.x = maxf((w - CORNER * 2) * pct, 0.0)
		# Sol köşeler
		c_tl.position = Vector2(0, 0)
		c_bl.position = Vector2(0, bar_h - CORNER)
		# Sağ köşeler
		c_tr.position = Vector2(w - CORNER, 0)
		c_br.position = Vector2(w - CORNER, bar_h - CORNER)

	bar_outer.resized.connect(_apply)
	bar_outer.draw.connect(func():
		if bar_outer.size.x > 0: _apply.call()
	)
	bar_outer.queue_redraw()

	var prog_hbox := HBoxContainer.new()
	vbox.add_child(prog_hbox)
	var prog_lbl := Label.new()
	prog_lbl.text = "%d of %d" % [progress, target]
	prog_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(prog_lbl, _COL_TEXT_MID, int(ref * 0.024))
	prog_hbox.add_child(prog_lbl)
	var pct_lbl := Label.new()
	pct_lbl.text = "%d pct" % int(pct * 100)
	UITheme.apply_label(pct_lbl, _COL_TEXT_BROWN, int(ref * 0.024))
	prog_hbox.add_child(pct_lbl)


# ── Helpers ───────────────────────────────────────────────────────
func _set_loading(msg: String) -> void:
	_clear_list()
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(ref * 0.010))
	_list_root.add_child(row)
	row.add_child(UITheme.lucide_icon("clock", int(ref * 0.032), Color(0.480, 0.340, 0.200)))
	var lbl := Label.new()
	lbl.text = msg
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(lbl, Color(0.480, 0.340, 0.200), int(ref * 0.030))
	row.add_child(lbl)


func _show_connect_prompt() -> void:
	_clear_list()
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(ref * 0.018))
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_root.add_child(vbox)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(ref * 0.010))
	vbox.add_child(row)
	row.add_child(UITheme.lucide_icon("wallet", int(ref * 0.038), Color(0.480, 0.340, 0.200)))
	var lbl := Label.new()
	lbl.text = "Connect your Nimiq account\nto see daily quests"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, Color(0.480, 0.340, 0.200), int(ref * 0.028))
	vbox.add_child(lbl)

	if OS.has_feature("web"):
		var btn := Button.new()
		btn.text = "Connect Wallet"
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size.y = int(ref * 0.068)
		btn.add_theme_font_size_override("font_size", int(ref * 0.032))
		_warm_btn(btn, 8)
		btn.pressed.connect(func():
			btn.disabled = true
			btn.text = "Waiting..."
			_request_account_connect(btn)
		)
		vbox.add_child(btn)


func _request_account_connect(btn: Button) -> void:
	var result := await NimiqJS.request_account(30.0)
	if result.get("ok", false):
		_player_id = str(result.get("address", ""))
		_refresh()
	else:
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = "Connect Wallet"


func _show_error(msg: String) -> void:
	_clear_list()
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(ref * 0.010))
	_list_root.add_child(vbox)
	var icon_row := HBoxContainer.new()
	icon_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(icon_row)
	icon_row.add_child(UITheme.lucide_icon("alert-triangle", int(ref * 0.038), Color(0.480, 0.340, 0.200)))
	var lbl := Label.new()
	lbl.text = msg
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, Color(0.480, 0.340, 0.200), int(ref * 0.026))
	vbox.add_child(lbl)


func _clear_list() -> void:
	for c in _list_root.get_children(): c.queue_free()



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


func _mpad(h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   h)
	mc.add_theme_constant_override("margin_right",  h)
	mc.add_theme_constant_override("margin_top",    v)
	mc.add_theme_constant_override("margin_bottom", v)
	return mc
