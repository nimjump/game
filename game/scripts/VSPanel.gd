extends CanvasLayer
## VSPanel.gd — Async 1v1 "VS" challenge rooms: create/join, optional NIM
## entry fee, pay → play → wait → settle. Reuses the same visual language as
## QuestPanel/StatsPanel (UITheme, warm-bej cards) per design direction.
##
## Flow reminder (see backend/game/vsroom.go for the authoritative state
## machine): create room (pay if entry>0) → play your round (fixed seed) →
## share invite link → opponent joins, pays, plays → whoever finishes last
## (or the 24h sweep) settles the pot. Everything here is just HTTP polling —
## there is no live/real-time connection, by design.

signal closed
signal play_requested(room_id: String, role: String, seed: String)
signal replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, nickname: String, player_seed: int)

var BACKEND_URL : String = ApiConfig.base_url()
const UITheme    := preload("res://scripts/UITheme.gd")
const _COL_ICON  := Color(0.780, 0.380, 0.120)
const _COL_TEXT_DARK := Color(0.220, 0.130, 0.060)
const _COL_TEXT_MID  := Color(0.480, 0.340, 0.200)
# Free (0 NIM) rooms are no longer allowed — every room needs a real stake.
# Enforced both here (so you can't even try to submit a sub-minimum amount)
# and server-side in handleVSRoomCreate (never trust the client alone).
const _MIN_ENTRY_NIM := 5.0

var _player_id      : String = ""
var _auth_token     : String = ""
var _auth_attempted : bool   = false
var _has_wallet     : bool   = false

var _panel_ctrl : Control
var _view_root  : Control       # swapped between list view and detail view
var _anim_tween : Tween = null
var _entry_sheet_root : Control = null  # bottom-docked custom-amount keypad
										 # overlay — lives directly under
										 # _panel_ctrl (not _view_root), so it
										 # sits on top of the whole panel
										 # instead of being scrolled away
										 # inside the create-room card. Rebuilt
										 # fresh each _show_room_list() call;
										 # freed explicitly in _clear_view()
										 # since it's outside _view_root's
										 # normal child-clearing sweep.

const _MINE_PAGE_SIZE := 20

var _rooms_cache : Array = []
var _current_room : Dictionary = {}
var _detail_timer : Timer = null
var _pending_open_room_id : String = ""   # deep-link target, applied once auth is ready
var _avatar_tex_cache : Dictionary = {}   # address+size key → ImageTexture (mirrors LeaderboardPanel)


## BUG FIX: Dictionary.get(key, default) only falls back to `default` when
## the key is MISSING — if the key exists but its JSON value was literally
## `null` (which is exactly what Go's encoding/json produces for a nil slice,
## e.g. "var out []T" that was never appended to), .get() still returns that
## null, not the default. Every place here that expects a rooms array from
## the backend must go through this instead of trusting .get(key, []) alone,
## or a room list that happens to be empty server-side crashes the callback
## with "Cannot convert argument 1 from Nil to Array".
func _as_array(v) -> Array:
	return v if v is Array else []


## Best-effort display name for a player: nickname if set, otherwise a
## shortened wallet address — same fallback convention as LeaderboardPanel.
func _display_name(nickname: String, address: String) -> String:
	if nickname != "" and nickname != "null":
		return nickname
	if address.length() > 9:
		return address.left(6) + ".." + address.right(3)
	return address if address != "" else "Player"


func setup(player_id: String) -> void:
	_player_id = player_id
	_build_ui()
	hide()


func set_auth_token(token: String) -> void:
	_auth_token = token
	if token != "" and _pending_open_room_id != "":
		var rid := _pending_open_room_id
		_pending_open_room_id = ""
		_show_room_detail(rid)

func set_auth_attempted(v: bool) -> void:
	_auth_attempted = v

func set_has_wallet(v: bool) -> void:
	_has_wallet = v

func set_player_id(player_id: String) -> void:
	_player_id = player_id


## Called by Main._check_vsroom_deeplink() — jump straight to a room's detail
## view once the panel is open (waits for auth if needed).
func open_room(room_id: String) -> void:
	if _auth_token == "":
		_pending_open_room_id = room_id
		return
	_show_room_detail(room_id)


# ── Panel open / close (same pattern as QuestPanel) ─────────────────────────
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
	if _pending_open_room_id == "":
		_show_room_list()


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


# ── UI shell ─────────────────────────────────────────────────────────────────
var _title_lbl : Label
var _back_btn  : Button

func _build_ui() -> void:
	var vp  := get_viewport()
	var vw  := vp.get_visible_rect().size.x if vp else GameConstants.VW
	var vh  := vp.get_visible_rect().size.y if vp else GameConstants.VH
	var ref := minf(minf(vw, vh), GameConstants.VW)
	var pad := int(ref * 0.025)
	var pw  := ref * 0.92
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

	_back_btn = Button.new()
	_back_btn.text = "<"
	_back_btn.custom_minimum_size = Vector2(int(ref * 0.06), int(ref * 0.06))
	_back_btn.visible = false
	_warm_btn(_back_btn, 8)
	_back_btn.pressed.connect(_show_room_list)
	hdr.add_child(_back_btn)

	hdr.add_child(UITheme.lucide_icon("target", int(ref * 0.038), _COL_ICON))

	_title_lbl = Label.new()
	_title_lbl.text = "VS"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_title_lbl, _COL_TEXT_DARK, int(ref * 0.048))
	hdr.add_child(_title_lbl)

	var close_sz    := int(ref * 0.092)
	var close_ic_sz := int(close_sz * 0.72)
	var close_btn := Button.new()
	close_btn.custom_minimum_size = Vector2(close_sz, close_sz)
	close_btn.pressed.connect(func(): hide_panel(); closed.emit())
	_close_btn_style(close_btn, 8)
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

	var sep := ColorRect.new()
	sep.color = Color(0.4, 0.4, 0.4, 0.3)
	sep.custom_minimum_size.y = 1
	outer.add_child(sep)

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

	_view_root = VBoxContainer.new()
	_view_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_root.add_theme_constant_override("separation", int(ref * 0.016))
	content_mc.add_child(_view_root)


func _mpad(h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   h)
	mc.add_theme_constant_override("margin_right",  h)
	mc.add_theme_constant_override("margin_top",    v)
	mc.add_theme_constant_override("margin_bottom", v)
	return mc


func _warm_btn(btn: Button, corner: int) -> void:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.700, 0.520, 0.340, 0.20)
	st.set_corner_radius_all(corner)
	var st_h := StyleBoxFlat.new()
	st_h.bg_color = Color(0.700, 0.520, 0.340, 0.35)
	st_h.set_corner_radius_all(corner)
	btn.add_theme_stylebox_override("normal", st)
	btn.add_theme_stylebox_override("hover",  st_h)
	btn.add_theme_stylebox_override("pressed", st_h)
	btn.flat = false


## Vivid orange close-button style — same palette as LeaderboardPanel's
## _warm_btn (used for its X close button), so the "X" reads the same way
## across panels instead of the paler translucent tone the back button uses.
func _close_btn_style(btn: Button, corner: int) -> void:
	var ri := int(corner)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.set_corner_radius_all(ri)
	sn.bg_color = Color(0.780, 0.380, 0.120)
	sh.bg_color = Color(0.820, 0.450, 0.160)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	btn.flat = false


func _ref() -> float:
	var vp := get_viewport()
	if not vp: return GameConstants.VW
	return minf(minf(vp.get_visible_rect().size.x, vp.get_visible_rect().size.y), GameConstants.VW)


func _clear_view() -> void:
	for c in _view_root.get_children():
		c.queue_free()
	if is_instance_valid(_detail_timer):
		_detail_timer.queue_free()
		_detail_timer = null
	# The custom-amount keypad sheet lives directly under _panel_ctrl (so it
	# can dock to the real bottom of the screen instead of scrolling away
	# inside the create-room card), which means it's outside _view_root's
	# child sweep above and needs its own explicit teardown here.
	if is_instance_valid(_entry_sheet_root):
		_entry_sheet_root.queue_free()
		_entry_sheet_root = null


## The real Nimiq hexagon icon (same asset StatsPanel's "Daily NIM Earned"
## card and the in-run HUD coin counter use) — used anywhere this panel shows
## a NIM amount, instead of a generic lucide icon or plain "NIM" text.
func _make_nim_icon(size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load("res://assets/items/nimiq_hexagon_item.png") as Texture2D
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tr.custom_minimum_size = Vector2(size, size)
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return tr


# ── LIST VIEW ────────────────────────────────────────────────────────────────
func _show_room_list() -> void:
	_current_room = {}
	_back_btn.visible = false
	_title_lbl.text = "VS"
	_clear_view()
	var ref := _ref()

	if _player_id == "":
		var lbl := Label.new()
		lbl.text = "Connect your wallet to use VS."
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(lbl, _COL_TEXT_MID, int(ref * 0.030))
		_view_root.add_child(lbl)
		return

	# ── Create room card ──
	var create_card := _make_card()
	_view_root.add_child(create_card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", int(ref * 0.014))
	create_card.add_child(cv)

	# Icon + title row, same treatment as the "Open Challenges"/"My VS
	# Matches" section headers below — this was just a small plain Label
	# before, which read as an afterthought next to those, instead of like
	# the card's actual header.
	var ct_row := HBoxContainer.new()
	ct_row.add_theme_constant_override("separation", int(ref * 0.010))
	cv.add_child(ct_row)
	ct_row.add_child(UITheme.lucide_icon("zap", int(ref * 0.034), _COL_ICON))
	var ct := Label.new()
	ct.text = "Create a challenge"
	UITheme.apply_label(ct, _COL_TEXT_DARK, int(ref * 0.036))
	ct_row.add_child(ct)

	var nim_lbl := Label.new()
	nim_lbl.text = "NIM entry fee"
	UITheme.apply_label(nim_lbl, _COL_TEXT_MID, int(ref * 0.024))
	cv.add_child(nim_lbl)

	# No presets, no "Custom" chip to tap first — tapping the amount field
	# below opens the keypad sheet directly, one tap instead of two.
	# Free (0 NIM) rooms are no longer allowed — every room needs a real
	# stake, minimum _MIN_ENTRY_NIM — so this starts at a sensible non-zero
	# default (100) instead of 0/"Free".
	var entry_val := [100.0]  # boxed in a 1-element array so the button
							   # callbacks below can mutate it by reference

	# Amount entry — a bottom-docked keypad sheet (like a real on-screen
	# keyboard sliding up and covering the bottom of the screen) rather than
	# the OS virtual keyboard AND rather than being embedded inline in this
	# scrollable card: it's built directly under _panel_ctrl so it docks to
	# the actual bottom edge of the panel regardless of where this card has
	# scrolled to. No native keyboard popup at all (which, on top of looking
	# completely out of place next to this panel's warm-bej theme, is exactly
	# the kind of viewport-resize event that caused the VS panel crash fixed
	# earlier in this project — see the keyboard-open viewport bug). Every
	# digit is just a themed Button tap; nothing ever asks the OS for a
	# keyboard.
	var custom_buf := ["100"]  # boxed like entry_val above — matches the
								# entry_val default so the keypad display and
								# the closed field agree before anything's
								# been typed

	# Wrapper so the scrim + sheet can be torn down together as a single unit
	# from _clear_view() (see _entry_sheet_root above) without either one
	# leaking behind on the next _show_room_list() rebuild.
	var sheet_wrap := Control.new()
	sheet_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_ctrl.add_child(sheet_wrap)
	_entry_sheet_root = sheet_wrap

	var sheet_dim := ColorRect.new()
	sheet_dim.color = Color(0, 0, 0, 0.45)
	sheet_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet_dim.modulate.a = 0.0
	sheet_wrap.add_child(sheet_dim)

	# The sheet itself stays visible=true at all times and is instead slid
	# fully off the bottom of the screen when "closed" — that's what makes a
	# real slide-up/slide-down animation possible (toggling .visible has no
	# in-between frames to animate). _sheet_hidden_off is comfortably larger
	# than any real sheet height, so it's guaranteed off-screen regardless of
	# device aspect ratio.
	var sheet_hidden_off := ref * 3.0
	var sheet := PanelContainer.new()
	sheet.anchor_left = 0.0; sheet.anchor_right = 1.0
	sheet.anchor_top  = 0.44; sheet.anchor_bottom = 1.0
	sheet.offset_left = 0; sheet.offset_right = 0
	sheet.offset_top  = sheet_hidden_off; sheet.offset_bottom = sheet_hidden_off
	var sheet_st := StyleBoxFlat.new()
	sheet_st.bg_color     = Color(0.957, 0.898, 0.800)
	sheet_st.border_color = Color(0.580, 0.380, 0.220)
	sheet_st.set_border_width_all(3)
	sheet_st.border_width_bottom = 0
	sheet_st.corner_radius_top_left  = 18
	sheet_st.corner_radius_top_right = 18
	sheet_st.shadow_color = Color(0, 0, 0, 0.30)
	sheet_st.shadow_size  = 14
	sheet_st.content_margin_left   = ref * 0.030
	sheet_st.content_margin_right  = ref * 0.030
	sheet_st.content_margin_top    = ref * 0.020
	sheet_st.content_margin_bottom = ref * 0.030
	sheet.add_theme_stylebox_override("panel", sheet_st)
	sheet_wrap.add_child(sheet)

	var sheet_vb := VBoxContainer.new()
	sheet_vb.add_theme_constant_override("separation", int(ref * 0.016))
	sheet.add_child(sheet_vb)

	# Drag-handle bar — the small centered pill real bottom sheets show at
	# their top edge, purely visual (nothing here is actually draggable) but
	# it's the single detail that makes this read as "a keyboard sliding up"
	# rather than "a panel that appeared."
	var handle_wrap := CenterContainer.new()
	sheet_vb.add_child(handle_wrap)
	var handle := ColorRect.new()
	handle.color = Color(0.580, 0.380, 0.220, 0.45)
	handle.custom_minimum_size = Vector2(ref * 0.11, ref * 0.010)
	handle_wrap.add_child(handle)

	var open_entry_sheet := func(): pass
	var close_entry_sheet := func(): pass

	var sheet_header := HBoxContainer.new()
	sheet_header.add_theme_constant_override("separation", int(ref * 0.012))
	sheet_vb.add_child(sheet_header)
	var sheet_icon_wrap := CenterContainer.new()
	sheet_header.add_child(sheet_icon_wrap)
	sheet_icon_wrap.add_child(_make_nim_icon(int(ref * 0.036)))
	var sheet_title := Label.new()
	sheet_title.text = "Set Entry Fee"
	sheet_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(sheet_title, _COL_TEXT_DARK, int(ref * 0.032))
	sheet_header.add_child(sheet_title)
	var done_btn := Button.new()
	done_btn.text = "Done"
	done_btn.custom_minimum_size = Vector2(int(ref * 0.16), int(ref * 0.056))
	_close_btn_style(done_btn, 10)
	done_btn.add_theme_color_override("font_color", Color(0.957, 0.898, 0.800))
	done_btn.add_theme_color_override("font_hover_color", Color(0.957, 0.898, 0.800))
	done_btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
	sheet_header.add_child(done_btn)

	var sheet_subtitle := Label.new()
	sheet_subtitle.text = "Choose how much players pay to join."
	UITheme.apply_label(sheet_subtitle, _COL_TEXT_MID, int(ref * 0.022))
	sheet_vb.add_child(sheet_subtitle)

	# Display — a bordered "field" so the typed amount reads like a real
	# input even though nothing here is an editable LineEdit; everything is
	# populated by the presets/keypad below.
	var display_card := PanelContainer.new()
	var display_st := StyleBoxFlat.new()
	display_st.bg_color = Color(1.0, 0.98, 0.94, 0.9)
	display_st.border_color = _COL_ICON
	display_st.set_border_width_all(2)
	display_st.set_corner_radius_all(12)
	display_st.content_margin_left   = ref * 0.026
	display_st.content_margin_right  = ref * 0.022
	display_st.content_margin_top    = ref * 0.018
	display_st.content_margin_bottom = ref * 0.018
	display_card.add_theme_stylebox_override("panel", display_st)
	sheet_vb.add_child(display_card)

	var display_row := HBoxContainer.new()
	display_row.add_theme_constant_override("separation", int(ref * 0.014))
	display_card.add_child(display_row)

	var display_icon_wrap := CenterContainer.new()
	display_icon_wrap.custom_minimum_size = Vector2(int(ref * 0.06), 0)
	display_icon_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	display_row.add_child(display_icon_wrap)
	display_icon_wrap.add_child(_make_nim_icon(int(ref * 0.046)))

	var custom_display := Label.new()
	custom_display.text = "100"
	custom_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_display.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	custom_display.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	custom_display.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	custom_display.clip_text = true
	UITheme.apply_label(custom_display, _COL_TEXT_DARK, int(ref * 0.052))
	display_row.add_child(custom_display)

	# "NIM" unit chip — a small rounded pill rather than plain text, so it
	# reads as a unit tag next to the number instead of floating text.
	var nim_chip := PanelContainer.new()
	var nim_chip_st := StyleBoxFlat.new()
	nim_chip_st.bg_color = Color(0.870, 0.800, 0.700, 0.55)
	nim_chip_st.set_corner_radius_all(8)
	nim_chip_st.content_margin_left   = ref * 0.018
	nim_chip_st.content_margin_right  = ref * 0.018
	nim_chip_st.content_margin_top    = ref * 0.008
	nim_chip_st.content_margin_bottom = ref * 0.008
	nim_chip.add_theme_stylebox_override("panel", nim_chip_st)
	var nim_chip_wrap := CenterContainer.new()
	nim_chip_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	display_row.add_child(nim_chip_wrap)
	nim_chip_wrap.add_child(nim_chip)
	var nim_chip_lbl := Label.new()
	nim_chip_lbl.text = "NIM"
	UITheme.apply_label(nim_chip_lbl, _COL_TEXT_MID, int(ref * 0.022))
	nim_chip.add_child(nim_chip_lbl)

	var entry_field := Button.new()  # declared here, built after the sheet's
									  # open/close closures below so its
									  # pressed callback captures the real
									  # implementations, not the placeholders
	var field_amount_lbl := Label.new()
	var field_hint_lbl := Label.new()

	var refresh_custom_display := func():
		custom_display.text = custom_buf[0] if custom_buf[0] != "" else "0"
		if entry_val[0] < _MIN_ENTRY_NIM:
			# No more "Free" — every room needs a real stake. This state only
			# shows up if you backspace the field down below the minimum;
			# Create Room itself refuses to submit until it's fixed.
			var need := ("%.2f" % _MIN_ENTRY_NIM).rstrip("0").rstrip(".")
			field_amount_lbl.text = "%s NIM min" % need
			field_hint_lbl.text = "Tap to set an entry fee"
		else:
			var trimmed := ("%.2f" % entry_val[0]).rstrip("0").rstrip(".")
			field_amount_lbl.text = "%s NIM" % trimmed
			field_hint_lbl.text = "Tap to change"

	# Keypad — square-ish keys via a fixed ref-relative size on both axes
	# (rather than only setting a height and letting the grid's column-fill
	# stretch width unevenly), consistent spacing. Plain dark font text for
	# the digits/00 (hud%d.png glyphs were tried here but read washed-out
	# and low-contrast against this cream card background — dark text is
	# clearer). Backspace gets its own distinct (soft red) cell with a
	# lucide "x" icon so it reads as a "destructive" key at a glance.
	var keypad := GridContainer.new()
	keypad.columns = 3
	keypad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	keypad.add_theme_constant_override("h_separation", int(ref * 0.014))
	keypad.add_theme_constant_override("v_separation", int(ref * 0.014))
	sheet_vb.add_child(keypad)

	var key_h := int(ref * 0.086)
	# "00" fills the slot the removed decimal-point key left empty (the grid
	# is 3 columns, and without it "0"/"back" would be stranded alone on a
	# lopsided last row) — and unlike ".", it's actually useful for a NIM
	# amount pad: one tap gets you to 100/500/1000 instead of two.
	var keypad_keys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "00", "0", "back"]
	for key in keypad_keys:
		var kbtn := Button.new()
		kbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kbtn.custom_minimum_size.y = key_h
		keypad.add_child(kbtn)
		if key == "back":
			var back_st := StyleBoxFlat.new()
			back_st.bg_color = Color(0.870, 0.360, 0.280, 0.16)
			back_st.set_corner_radius_all(10)
			var back_st_h := back_st.duplicate()
			back_st_h.bg_color = Color(0.870, 0.360, 0.280, 0.26)
			kbtn.add_theme_stylebox_override("normal",  back_st)
			kbtn.add_theme_stylebox_override("hover",   back_st_h)
			kbtn.add_theme_stylebox_override("pressed", back_st_h)
			var bk_center := CenterContainer.new()
			bk_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			bk_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
			kbtn.add_child(bk_center)
			bk_center.add_child(UITheme.lucide_icon("x", int(ref * 0.034), Color(0.780, 0.220, 0.140)))
		else:
			# Digit key (and "00") — plain text, but using the game's actual
			# pixel font (same one every other number/label in this panel
			# uses via UITheme.apply_label) instead of Godot's default UI
			# font, which is what _warm_btn alone leaves it as.
			_warm_btn(kbtn, 10)
			kbtn.text = key
			UITheme._apply_pixel_font(kbtn)
			kbtn.add_theme_font_size_override("font_size", int(ref * 0.040))
			kbtn.add_theme_color_override("font_color",         _COL_TEXT_DARK)
			kbtn.add_theme_color_override("font_hover_color",   _COL_TEXT_DARK)
			kbtn.add_theme_color_override("font_pressed_color", _COL_TEXT_DARK)
		kbtn.pressed.connect(func():
			if key == "back":
				if custom_buf[0].length() > 0:
					custom_buf[0] = custom_buf[0].substr(0, custom_buf[0].length() - 1)
			elif key == "00":
				# No-op on an empty/zero pad — "00" only makes sense once
				# there's already a nonzero leading digit typed.
				if custom_buf[0] != "" and custom_buf[0] != "0":
					custom_buf[0] += "00"
			else:
				# Avoid a useless leading "0" (e.g. tapping 5 after 0 → "5" not "05")
				if custom_buf[0] == "0":
					custom_buf[0] = key
				else:
					custom_buf[0] += key
			# BUG FIX: entry_val must be recomputed BEFORE refresh_custom_display
			# runs — the closed field's "X NIM" text is built from entry_val,
			# not from custom_buf directly, so calling refresh first read the
			# previous keystroke's value and always trailed one digit behind
			# the live keypad display (e.g. typing "223" showed "22 NIM" on
			# the field behind the sheet while the sheet itself already read
			# "223").
			entry_val[0] = maxf(custom_buf[0].to_float(), 0.0)
			refresh_custom_display.call()
		)

	# Boxed Tween reference (same boxed-array trick as entry_val/custom_buf
	# above) so open/close can kill an in-flight slide animation before
	# starting the next one, regardless of which closure last touched it.
	var sheet_tween := [null]
	var kill_sheet_tween := func():
		if sheet_tween[0] != null and is_instance_valid(sheet_tween[0]):
			sheet_tween[0].kill()
		sheet_tween[0] = null

	open_entry_sheet = func():
		kill_sheet_tween.call()
		sheet_dim.mouse_filter = Control.MOUSE_FILTER_STOP
		var t := create_tween()
		sheet_tween[0] = t
		t.set_parallel(true)
		t.tween_property(sheet_dim, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(sheet, "offset_top",    0.0, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(sheet, "offset_bottom", 0.0, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	close_entry_sheet = func():
		# BUG FIX (same pattern as the settings-popup input-blocking race
		# fixed earlier in this project): stop the scrim from blocking clicks
		# THE MOMENT close is requested, don't wait for the slide-down
		# animation to finish — otherwise a fast double-tap outside the sheet
		# could get eaten by a scrim that's still technically "closing."
		sheet_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kill_sheet_tween.call()
		var t := create_tween()
		sheet_tween[0] = t
		t.set_parallel(true)
		t.tween_property(sheet_dim, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_QUAD)
		t.tween_property(sheet, "offset_top",    sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_property(sheet, "offset_bottom", sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	done_btn.pressed.connect(func(): close_entry_sheet.call())
	# Tapping the dim scrim behind the sheet dismisses it too, same as tapping
	# outside a real on-screen keyboard — it just closes, it doesn't discard
	# whatever amount was already typed.
	sheet_dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close_entry_sheet.call()
	)

	# The tappable amount field that replaces the old preset-chip row — one
	# tap opens the keypad sheet directly, no intermediate "Custom" chip.
	# Built as a real row (coin icon + amount + hint + arrow) instead of a
	# plain bordered text button, so it reads as a proper settings-style row
	# rather than a stray outlined rectangle.
	var field_st := StyleBoxFlat.new()
	field_st.bg_color = Color(1.0, 0.98, 0.94, 0.95)
	field_st.border_color = Color(0.780, 0.380, 0.120, 0.30)
	field_st.set_border_width_all(2)
	field_st.set_corner_radius_all(14)
	field_st.content_margin_left   = ref * 0.026
	field_st.content_margin_right  = ref * 0.022
	field_st.content_margin_top    = ref * 0.018
	field_st.content_margin_bottom = ref * 0.018
	var field_st_active := field_st.duplicate()
	field_st_active.bg_color = Color(0.988, 0.930, 0.850, 1.0)
	field_st_active.border_color = Color(0.780, 0.380, 0.120, 0.55)

	entry_field.text = ""
	# BUG FIX: 0.104 was just barely tighter than the amount label + hint
	# label's actual stacked height once you subtract this stylebox's own
	# top/bottom content margins (0.036 combined) — "Tap to change"/"Tap to
	# set an entry fee" was spilling out past the card's rounded bottom edge
	# instead of sitting inside it. Bumped for real headroom.
	entry_field.custom_minimum_size.y = int(ref * 0.124)
	entry_field.add_theme_stylebox_override("normal",  field_st)
	entry_field.add_theme_stylebox_override("hover",   field_st_active)
	entry_field.add_theme_stylebox_override("pressed", field_st_active)
	entry_field.add_theme_stylebox_override("focus",   field_st)
	cv.add_child(entry_field)

	# BUG FIX: a plain FULL_RECT anchor on field_row ignores field_st's
	# content_margin entirely (that margin only applies to a Button's own
	# auto-laid-out text/icon, not to manually added children) — so the row
	# stretched all the way to the button's true edge, behind the rounded
	# border, and the hexagon icon ended up flush against the left edge
	# instead of padded inside the card like every other field in this panel.
	# A MarginContainer with the same margins as field_st fixes that.
	var field_margin := _mpad(int(field_st.content_margin_left), int(field_st.content_margin_top))
	field_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	field_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry_field.add_child(field_margin)

	var field_row := HBoxContainer.new()
	field_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field_row.add_theme_constant_override("separation", int(ref * 0.018))
	field_margin.add_child(field_row)

	# Icon and arrow columns get the SAME fixed square footprint (rather than
	# just shrink-wrapping their icon's own size, which left the two side
	# columns visibly different widths and made the row look lopsided/shifted
	# instead of symmetric) — every part of this row now centers around a
	# consistent frame, matching the reference layout.
	var side_col := int(ref * 0.072)

	var field_icon_wrap := CenterContainer.new()
	field_icon_wrap.custom_minimum_size = Vector2(side_col, 0)
	field_icon_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	field_row.add_child(field_icon_wrap)
	field_icon_wrap.add_child(_make_nim_icon(int(ref * 0.052)))

	var field_text_vb := VBoxContainer.new()
	field_text_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field_text_vb.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	field_text_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	field_text_vb.add_theme_constant_override("separation", int(ref * 0.004))
	field_row.add_child(field_text_vb)

	field_amount_lbl.text = "100 NIM"  # placeholder — overwritten by the
										# refresh_custom_display.call() below
										# right after this row is built
	UITheme.apply_label(field_amount_lbl, _COL_TEXT_DARK, int(ref * 0.036))
	field_text_vb.add_child(field_amount_lbl)

	field_hint_lbl.text = "Tap to set an entry fee"
	UITheme.apply_label(field_hint_lbl, _COL_TEXT_MID, int(ref * 0.020))
	field_text_vb.add_child(field_hint_lbl)

	# Arrow — a circular badge (matching the reference) instead of a bare
	# icon floating in empty space, and given the same fixed square footprint
	# as the icon column on the opposite side.
	var field_arrow_wrap := CenterContainer.new()
	field_arrow_wrap.custom_minimum_size = Vector2(side_col, 0)
	field_arrow_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	field_row.add_child(field_arrow_wrap)

	var arrow_badge := PanelContainer.new()
	var badge_d := int(ref * 0.060)
	arrow_badge.custom_minimum_size = Vector2(badge_d, badge_d)
	var badge_st := StyleBoxFlat.new()
	badge_st.bg_color = Color(0.780, 0.380, 0.120, 0.16)
	badge_st.set_corner_radius_all(badge_d)
	arrow_badge.add_theme_stylebox_override("panel", badge_st)
	field_arrow_wrap.add_child(arrow_badge)
	var arrow_center := CenterContainer.new()
	arrow_badge.add_child(arrow_center)
	arrow_center.add_child(UITheme.lucide_icon("arrow-right", int(ref * 0.026), _COL_ICON))

	entry_field.pressed.connect(func(): open_entry_sheet.call())
	refresh_custom_display.call()

	# Public/private toggle — private rooms never show up in the "Open
	# Challenges" browse list below, they only work via their invite link.
	var privacy_row := HBoxContainer.new()
	privacy_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	privacy_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	privacy_row.add_theme_constant_override("separation", int(ref * 0.010))
	cv.add_child(privacy_row)

	# Same toggle size Main.gd's Settings popup uses for its own switches
	# (e.g. the auto-download toggle, ref * 0.052) — this one used to be
	# ref * 0.040, noticeably smaller/off-scale next to every other on/off
	# switch in the app.
	var private_check := CheckButton.new()
	UITheme.apply_toggle_button(private_check, int(ref * 0.052))
	private_check.button_pressed = false
	private_check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	privacy_row.add_child(private_check)

	var privacy_lbl := Label.new()
	privacy_lbl.text = "Private (invite link only, hidden from Open Challenges)"
	privacy_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	privacy_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	privacy_lbl.custom_minimum_size.x = ref * 0.10
	privacy_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	UITheme.apply_label(privacy_lbl, _COL_TEXT_MID, int(ref * 0.022))
	privacy_row.add_child(privacy_lbl)

	# Same height as Main.gd's Settings/PLAY-family buttons (ref * 0.080),
	# instead of this panel's own slightly-off ref * 0.07.
	var create_btn := Button.new()
	create_btn.text = "Create Room"
	create_btn.custom_minimum_size.y = int(ref * 0.080)
	# Solid orange — same accent/style as the sheet's Done button and every
	# other primary action across the game (_close_btn_style), instead of
	# apply_play_button's yellow nine-patch, which didn't match this panel.
	_close_btn_style(create_btn, 12)
	UITheme._apply_pixel_font(create_btn)
	create_btn.add_theme_font_size_override("font_size", int(ref * 0.030))
	create_btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
	create_btn.add_theme_color_override("font_hover_color",   Color(0.957, 0.898, 0.800))
	create_btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
	cv.add_child(create_btn)
	create_btn.pressed.connect(func():
		var amt : float = entry_val[0]
		# No free rooms — refuse to even try below the minimum instead of
		# silently clamping it up (clamping would let a mis-tap create a
		# room for an amount the player never actually entered).
		if amt < _MIN_ENTRY_NIM:
			var need := ("%.2f" % _MIN_ENTRY_NIM).rstrip("0").rstrip(".")
			_show_toast_err("Entry fee must be at least %s NIM." % need)
			return
		create_btn.disabled = true
		create_btn.text = "Creating..."
		_create_room(amt, private_check.button_pressed, func(ok: bool):
			create_btn.disabled = false
			create_btn.text = "Create Room"
			if ok: _show_room_list()
		)
	)

	# ── Open challenges (public rooms anyone can join) ──
	var oc_spacer := Control.new()
	oc_spacer.custom_minimum_size = Vector2(0, int(ref * 0.016))
	_view_root.add_child(oc_spacer)
	var oc_row := HBoxContainer.new()
	oc_row.add_theme_constant_override("separation", int(ref * 0.010))
	_view_root.add_child(oc_row)
	oc_row.add_child(UITheme.lucide_icon("gamepad-2", int(ref * 0.030), _COL_ICON))
	var oc_lbl := Label.new()
	oc_lbl.text = "Open Challenges"
	UITheme.apply_label(oc_lbl, _COL_TEXT_DARK, int(ref * 0.030))
	oc_row.add_child(oc_lbl)

	var open_loading_lbl := Label.new()
	open_loading_lbl.text = "Loading..."
	open_loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(open_loading_lbl, _COL_TEXT_MID, int(ref * 0.026))
	_view_root.add_child(open_loading_lbl)

	_fetch_open(func(rooms: Array):
		if not is_instance_valid(open_loading_lbl): return
		open_loading_lbl.queue_free()
		if rooms.is_empty():
			var oe_lbl := Label.new()
			oe_lbl.text = "No open public challenges right now."
			oe_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(oe_lbl, _COL_TEXT_MID, int(ref * 0.024))
			_view_root.add_child(oe_lbl)
			UITheme.set_scroll_passthrough(_view_root)
			return
		for r in rooms:
			_view_root.add_child(_make_room_row(r, ref))
		UITheme.set_scroll_passthrough(_view_root)
	)

	# ── My matches ──
	var mm_spacer := Control.new()
	mm_spacer.custom_minimum_size = Vector2(0, int(ref * 0.020))
	_view_root.add_child(mm_spacer)
	var mm_row := HBoxContainer.new()
	mm_row.add_theme_constant_override("separation", int(ref * 0.010))
	_view_root.add_child(mm_row)
	mm_row.add_child(UITheme.lucide_icon("clock", int(ref * 0.030), _COL_ICON))
	var mm_lbl := Label.new()
	mm_lbl.text = "My VS Matches"
	UITheme.apply_label(mm_lbl, _COL_TEXT_DARK, int(ref * 0.030))
	mm_row.add_child(mm_lbl)

	var loading_lbl := Label.new()
	loading_lbl.text = "Loading..."
	loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(loading_lbl, _COL_TEXT_MID, int(ref * 0.026))
	_view_root.add_child(loading_lbl)

	var mine_rows_container := VBoxContainer.new()
	mine_rows_container.add_theme_constant_override("separation", int(ref * 0.012))
	_view_root.add_child(mine_rows_container)

	_fetch_mine(0, func(rooms: Array, total: int):
		if not is_instance_valid(loading_lbl): return
		loading_lbl.queue_free()
		_rooms_cache = rooms
		if rooms.is_empty():
			var empty_lbl := Label.new()
			empty_lbl.text = "No matches yet — create one above, or open an invite link."
			empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			UITheme.apply_label(empty_lbl, _COL_TEXT_MID, int(ref * 0.024))
			_view_root.add_child(empty_lbl)
			UITheme.set_scroll_passthrough(_view_root)
			return
		for r in rooms:
			mine_rows_container.add_child(_make_room_row(r, ref))
		if not is_instance_valid(mine_rows_container): return
		_add_load_more_if_needed(mine_rows_container, rooms.size(), total, ref)
		UITheme.set_scroll_passthrough(_view_root)
	)


func _make_card() -> PanelContainer:
	var card := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color     = Color(1.0, 0.98, 0.94, 0.9)
	st.border_color = Color(0.700, 0.520, 0.340, 0.5)
	st.set_border_width_all(2)
	st.set_corner_radius_all(10)
	st.content_margin_left = 14; st.content_margin_right = 14
	st.content_margin_top  = 12; st.content_margin_bottom = 12
	card.add_theme_stylebox_override("panel", st)
	return card


func _make_room_row(r: Dictionary, ref: float) -> Control:
	var card := _make_card()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_show_room_detail(str(r.get("id", "")))
	)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(ref * 0.012))
	card.add_child(row)

	var is_creator : bool = str(r.get("creator_id", "")) == _player_id
	var opp_addr : String = str(r.get("opponent_id", ""))
	var opp_nick : String = str(r.get("opponent_nickname", ""))
	var other_addr := opp_addr if is_creator else str(r.get("creator_id", ""))
	var other_name := _display_name(opp_nick, opp_addr) if is_creator else _display_name(str(r.get("creator_nickname", "")), str(r.get("creator_id", "")))
	var vs_label := "vs %s" % (other_name if (is_creator and opp_addr != "") or not is_creator else "(open)")

	if other_addr != "":
		row.add_child(_make_nimiq_avatar(other_addr, int(ref * 0.044)))

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", int(ref * 0.006))
	info.add_child(top_row)
	var entry : float = float(r.get("entry_nim", 0.0))
	var top_lbl := Label.new()
	top_lbl.text = vs_label + "  ·  "
	UITheme.apply_label(top_lbl, _COL_TEXT_DARK, int(ref * 0.026))
	top_row.add_child(top_lbl)
	if entry <= 0:
		var free_lbl := Label.new()
		free_lbl.text = "Free"
		UITheme.apply_label(free_lbl, _COL_TEXT_DARK, int(ref * 0.026))
		top_row.add_child(free_lbl)
	else:
		var entry_icon_wrap := CenterContainer.new()
		top_row.add_child(entry_icon_wrap)
		entry_icon_wrap.add_child(_make_nim_icon(int(ref * 0.028)))
		var entry_amt_lbl := Label.new()
		entry_amt_lbl.text = "%.2f" % entry
		UITheme.apply_label(entry_amt_lbl, _COL_TEXT_DARK, int(ref * 0.026))
		top_row.add_child(entry_amt_lbl)

	var status_lbl := Label.new()
	status_lbl.text = _status_text(r)
	UITheme.apply_label(status_lbl, _COL_TEXT_MID, int(ref * 0.022))
	info.add_child(status_lbl)

	row.add_child(UITheme.lucide_icon("arrow-right", int(ref * 0.024), _COL_TEXT_MID))
	return card


func _status_text(r: Dictionary) -> String:
	var status : String = str(r.get("status", ""))
	var is_creator : bool = str(r.get("creator_id", "")) == _player_id
	var is_opponent : bool = str(r.get("opponent_id", "")) == _player_id and _player_id != ""
	match status:
		"awaiting_creator_pay":  return "Your turn to pay" if is_creator else "Waiting for creator's payment"
		"awaiting_creator_play": return "Your turn to play" if is_creator else "Waiting for creator to play"
		"waiting_opponent":      return "Waiting for an opponent to join"
		"awaiting_opponent_pay": return "Your turn to pay" if is_opponent else "Waiting for opponent's payment"
		"awaiting_opponent_play":return "Your turn to play" if is_opponent else "Waiting for opponent to play"
		"completed":
			var winner : String = str(r.get("winner_id", ""))
			if winner == "": return "Completed — tie"
			return "Completed — you won!" if winner == _player_id else "Completed — opponent won"
		"expired_payout":
			var w2 : String = str(r.get("winner_id", ""))
			return "Expired — you won by forfeit" if w2 == _player_id else "Expired — opponent won by forfeit"
		"expired_refunded":      return "Expired — refunded"
		"cancelled":             return "Cancelled"
	return status


## Called every time the detail poll re-fetches a room — compares old vs new
## and surfaces a Toast for anything the player would actually want to know
## about right away (their payment got confirmed, the opponent showed up,
## the match is decided) instead of silently re-rendering the card.
func _notify_status_change(old_r: Dictionary, new_r: Dictionary) -> void:
	var t := Toast.get_instance()
	if t == null: return
	var old_status : String = str(old_r.get("status", ""))
	var new_status : String = str(new_r.get("status", ""))
	if old_status == new_status: return

	var is_creator : bool = str(new_r.get("creator_id", "")) == _player_id

	# My own payment got picked up (either my own confirm call, or the
	# backend's independent chain-scan reconciler finding it on its own).
	if (old_status == "awaiting_creator_pay" and new_status == "awaiting_creator_play" and is_creator) \
	or (old_status == "awaiting_opponent_pay" and new_status == "awaiting_opponent_play" and not is_creator):
		t.show_toast("Payment confirmed!", Toast.Kind.SUCCESS)
		return

	# Opponent joined the room.
	if old_status == "waiting_opponent" and new_status != "waiting_opponent":
		t.show_toast("An opponent joined your challenge!", Toast.Kind.INFO)
		return

	if _is_terminal(new_status):
		var winner : String = str(new_r.get("winner_id", ""))
		var payout : float = float(new_r.get("payout_nim", 0.0))
		match new_status:
			"completed":
				if winner == "":
					t.show_toast("Match tied — pot split, %.2f NIM each." % payout, Toast.Kind.INFO)
				elif winner == _player_id:
					t.show_toast("You won the match! +%.2f NIM" % payout, Toast.Kind.SUCCESS)
				else:
					t.show_toast("Match over — opponent won this one.", Toast.Kind.INFO)
			"expired_payout":
				if winner == _player_id:
					t.show_toast("Opponent didn't play in time — you win by forfeit! +%.2f NIM" % payout, Toast.Kind.SUCCESS)
				else:
					t.show_toast("You didn't play in time — opponent won by forfeit.", Toast.Kind.WARN)
			"expired_refunded":
				t.show_toast("Match expired — your payment was refunded.", Toast.Kind.INFO)


# ── DETAIL VIEW ──────────────────────────────────────────────────────────────
func _show_room_detail(room_id: String) -> void:
	_back_btn.visible = true
	_title_lbl.text = "Match"
	_clear_view()
	var ref := _ref()

	var loading_lbl := Label.new()
	loading_lbl.text = "Loading..."
	loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(loading_lbl, _COL_TEXT_MID, int(ref * 0.026))
	_view_root.add_child(loading_lbl)

	_fetch_room(room_id, func(ok: bool, room: Dictionary):
		if not is_instance_valid(loading_lbl): return
		loading_lbl.queue_free()
		if not ok:
			var err_lbl := Label.new()
			err_lbl.text = "Could not load this room (it may have expired)."
			err_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(err_lbl, _COL_TEXT_MID, int(ref * 0.026))
			_view_root.add_child(err_lbl)
			UITheme.set_scroll_passthrough(_view_root)
			return
		_current_room = room
		_render_room_detail(room, ref)
		UITheme.set_scroll_passthrough(_view_root)
		# Poll while anything is still pending — cheap HTTP GET every 4s.
		if not _is_terminal(str(room.get("status", ""))):
			_detail_timer = Timer.new()
			_detail_timer.wait_time = 4.0
			_detail_timer.autostart = true
			add_child(_detail_timer)
			_detail_timer.timeout.connect(func():
				_fetch_room(room_id, func(ok2: bool, room2: Dictionary):
					if ok2 and _current_room.get("id", "") == room_id:
						_notify_status_change(_current_room, room2)
						_current_room = room2
						_clear_view()
						_render_room_detail(room2, ref)
						UITheme.set_scroll_passthrough(_view_root)
				)
			)
	)


func _is_terminal(status: String) -> bool:
	return status in ["completed", "expired_payout", "expired_refunded", "cancelled"]


func _render_room_detail(r: Dictionary, ref: float) -> void:
	var room_id : String = str(r.get("id", ""))
	var is_creator : bool = str(r.get("creator_id", "")) == _player_id
	var is_opponent : bool = str(r.get("opponent_id", "")) == _player_id and _player_id != ""
	var entry : float = float(r.get("entry_nim", 0.0))

	# Neither participant yet — this is someone arriving via the invite link
	# who hasn't claimed the opponent slot. Show a join card instead of the
	# normal pay/play flow (which needs opponent_id set first).
	if not is_creator and not is_opponent:
		var open_for_join : bool = r.get("opponent_id", "") == "" and not _is_terminal(str(r.get("status", "")))
		var jcard := _make_card()
		_view_root.add_child(jcard)
		var jv := VBoxContainer.new()
		jv.add_theme_constant_override("separation", int(ref * 0.012))
		jcard.add_child(jv)
		var jhdr := HBoxContainer.new()
		jhdr.add_theme_constant_override("separation", int(ref * 0.012))
		jv.add_child(jhdr)
		var jcreator_addr := str(r.get("creator_id", ""))
		if jcreator_addr != "":
			jhdr.add_child(_make_nimiq_avatar(jcreator_addr, int(ref * 0.05)))
		var jt := Label.new()
		jt.text = "%s challenged you" % _display_name(str(r.get("creator_nickname", "")), jcreator_addr)
		UITheme.apply_label(jt, _COL_TEXT_DARK, int(ref * 0.028))
		jhdr.add_child(jt)
		var je_row := HBoxContainer.new()
		je_row.add_theme_constant_override("separation", int(ref * 0.006))
		jv.add_child(je_row)
		if entry <= 0:
			var je := Label.new()
			je.text = "Entry: Free"
			UITheme.apply_label(je, _COL_TEXT_MID, int(ref * 0.024))
			je_row.add_child(je)
		else:
			var je_pre := Label.new()
			je_pre.text = "Entry: "
			UITheme.apply_label(je_pre, _COL_ICON, int(ref * 0.024))
			je_row.add_child(je_pre)
			je_row.add_child(_make_nim_icon(int(ref * 0.026)))
			var je_amt := Label.new()
			je_amt.text = "%.2f (winner takes 95%% of the pot)" % entry
			je_amt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			UITheme.apply_label(je_amt, _COL_ICON, int(ref * 0.024))
			je_row.add_child(je_amt)
		if not open_for_join:
			var jf := Label.new()
			jf.text = "This challenge is no longer open."
			UITheme.apply_label(jf, _COL_TEXT_MID, int(ref * 0.024))
			jv.add_child(jf)
			return
		var join_btn := Button.new()
		join_btn.text = "Accept Challenge"
		join_btn.custom_minimum_size.y = int(ref * 0.07)
		UITheme.apply_play_button(join_btn)
		jv.add_child(join_btn)
		join_btn.pressed.connect(func():
			if _player_id == "":
				_show_toast_err("Connect your wallet first.")
				return
			join_btn.disabled = true
			join_btn.text = "Joining..."
			_join_room(room_id, func(ok: bool, room2: Dictionary):
				if ok:
					_current_room = room2
					_clear_view()
					_render_room_detail(room2, ref)
					UITheme.set_scroll_passthrough(_view_root)
				else:
					join_btn.disabled = false
					join_btn.text = "Accept Challenge"
					_show_toast_err("Could not join — the room may be full or expired.")
			)
		)
		return

	var my_role := "creator" if is_creator else "opponent"
	var my_paid : bool = bool(r.get("creator_paid" if is_creator else "opponent_paid", false))
	var my_score = r.get("creator_score" if is_creator else "opponent_score")
	var opp_score = r.get("opponent_score" if is_creator else "creator_score")
	var opp_nick : String = str(r.get("opponent_nickname" if is_creator else "creator_nickname", ""))

	var card := _make_card()
	_view_root.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", int(ref * 0.012))
	card.add_child(cv)

	var entry_row := HBoxContainer.new()
	entry_row.add_theme_constant_override("separation", int(ref * 0.006))
	cv.add_child(entry_row)
	if entry <= 0:
		var entry_lbl := Label.new()
		entry_lbl.text = "Entry: Free"
		UITheme.apply_label(entry_lbl, _COL_TEXT_DARK, int(ref * 0.026))
		entry_row.add_child(entry_lbl)
	else:
		var entry_pre := Label.new()
		entry_pre.text = "Entry: "
		UITheme.apply_label(entry_pre, _COL_ICON, int(ref * 0.026))
		entry_row.add_child(entry_pre)
		entry_row.add_child(_make_nim_icon(int(ref * 0.028)))
		var entry_amt := Label.new()
		entry_amt.text = "%.2f each (winner takes 95%% of the pot)" % entry
		entry_amt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(entry_amt, _COL_ICON, int(ref * 0.026))
		entry_row.add_child(entry_amt)

	var status_lbl := Label.new()
	status_lbl.text = _status_text(r)
	UITheme.apply_label(status_lbl, _COL_ICON, int(ref * 0.026))
	cv.add_child(status_lbl)

	var my_txt : String = str(my_score) if my_score != null else "—"
	var opp_txt : String = str(opp_score) if opp_score != null else "—"
	var opp_addr2 : String = str(r.get("opponent_id" if is_creator else "creator_id", ""))

	var scores_row := HBoxContainer.new()
	scores_row.add_theme_constant_override("separation", int(ref * 0.020))
	cv.add_child(scores_row)

	var me_box := HBoxContainer.new()
	me_box.add_theme_constant_override("separation", int(ref * 0.008))
	if _player_id != "":
		me_box.add_child(_make_nimiq_avatar(_player_id, int(ref * 0.04)))
	var me_lbl := Label.new()
	me_lbl.text = "You: %s" % my_txt
	UITheme.apply_label(me_lbl, _COL_TEXT_MID, int(ref * 0.024))
	me_box.add_child(me_lbl)
	scores_row.add_child(me_box)

	var opp_box := HBoxContainer.new()
	opp_box.add_theme_constant_override("separation", int(ref * 0.008))
	if opp_addr2 != "":
		opp_box.add_child(_make_nimiq_avatar(opp_addr2, int(ref * 0.04)))
	var opp_lbl := Label.new()
	opp_lbl.text = "%s: %s" % [_display_name(opp_nick, opp_addr2), opp_txt]
	UITheme.apply_label(opp_lbl, _COL_TEXT_MID, int(ref * 0.024))
	opp_box.add_child(opp_lbl)
	scores_row.add_child(opp_box)

	if not _is_terminal(str(r.get("status", ""))):
		var exp_lbl := Label.new()
		var still_waiting_for_join : bool = str(r.get("status", "")) == "waiting_opponent"
		var prefix := "Invite link valid for: " if still_waiting_for_join else "Time left to play: "
		exp_lbl.text = prefix + _time_left_text(int(r.get("expires_at", 0)))
		UITheme.apply_label(exp_lbl, _COL_TEXT_MID, int(ref * 0.022))
		cv.add_child(exp_lbl)

	# Invite link — only useful while still waiting for an opponent
	if is_creator and r.get("opponent_id", "") == "" and not _is_terminal(str(r.get("status", ""))):
		var invite_row := HBoxContainer.new()
		invite_row.add_theme_constant_override("separation", int(ref * 0.010))
		cv.add_child(invite_row)
		var invite_edit := LineEdit.new()
		invite_edit.text = str(r.get("invite_url", ""))
		invite_edit.editable = false
		invite_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		invite_row.add_child(invite_edit)
		var copy_btn := Button.new()
		copy_btn.text = "Copy"
		_warm_btn(copy_btn, 8)
		copy_btn.pressed.connect(func():
			DisplayServer.clipboard_set(str(r.get("invite_url", "")))
			var t := Toast.get_instance()
			if t: t.show_toast("Invite link copied", Toast.Kind.INFO)
		)
		invite_row.add_child(copy_btn)

	# ── Action button ──
	var already_played : bool = my_score != null
	if not already_played:
		var action_btn := Button.new()
		action_btn.custom_minimum_size.y = int(ref * 0.07)
		UITheme.apply_play_button(action_btn)
		cv.add_child(action_btn)
		if entry > 0 and not my_paid:
			action_btn.text = "Pay %.2f NIM" % entry
			action_btn.pressed.connect(func(): _do_pay(room_id, my_role, entry, action_btn))
		else:
			action_btn.text = "Play"
			action_btn.pressed.connect(func():
				hide_panel()
				play_requested.emit(room_id, my_role, str(r.get("seed", "")))
			)
	elif not _is_terminal(str(r.get("status", ""))):
		var waiting_lbl := Label.new()
		waiting_lbl.text = "Waiting for the other side..."
		waiting_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(waiting_lbl, _COL_TEXT_MID, int(ref * 0.024))
		cv.add_child(waiting_lbl)

	# ── Mutual forfeit — only once matched (opponent_id set) and not already
	# terminal. Requesting it doesn't end the match by itself; it only takes
	# effect once BOTH sides have asked to bail, so it's always safe to offer.
	if r.get("opponent_id", "") != "" and not _is_terminal(str(r.get("status", ""))):
		var my_forfeited : bool = bool(r.get("creator_forfeit_requested" if is_creator else "opponent_forfeit_requested", false))
		var opp_forfeited : bool = bool(r.get("opponent_forfeit_requested" if is_creator else "creator_forfeit_requested", false))
		if my_forfeited:
			var ff_wait_lbl := Label.new()
			ff_wait_lbl.text = "Waiting for %s to also agree to end this match early..." % _display_name(opp_nick, opp_addr2)
			ff_wait_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ff_wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(ff_wait_lbl, _COL_TEXT_MID, int(ref * 0.022))
			cv.add_child(ff_wait_lbl)
		else:
			var ff_btn := Button.new()
			ff_btn.text = "%s wants to end early — agree?" % _display_name(opp_nick, opp_addr2) if opp_forfeited else "Forfeit / End Match Early"
			ff_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_warm_btn(ff_btn, 8)
			cv.add_child(ff_btn)
			ff_btn.pressed.connect(func():
				var confirm_txt := "Both of you have to agree — this refunds any entry fee paid, no fee taken. Continue?"
				# Simple confirm-via-second-tap pattern would need extra UI; keep it
				# a single tap here (mirrors how Pay/Play are single-tap elsewhere in
				# this panel) but make the label itself carry the "this is mutual"
				# framing so it's never a surprise one-tap forfeit.
				ff_btn.disabled = true
				ff_btn.text = "..."
				_request_forfeit(room_id, func(ok: bool, room2: Dictionary):
					if ok:
						_current_room = room2
						_clear_view()
						_render_room_detail(room2, ref)
						UITheme.set_scroll_passthrough(_view_root)
						var t := Toast.get_instance()
						if t:
							if str(room2.get("status", "")) == "cancelled":
								t.show_toast("Match cancelled — refunded.", Toast.Kind.INFO)
							else:
								t.show_toast("Forfeit requested — waiting for the other side.", Toast.Kind.INFO)
					else:
						ff_btn.disabled = false
						ff_btn.text = "Forfeit / End Match Early"
						_show_toast_err("Could not request forfeit — try again.")
				)
			)

	# ── Watch Replay — only once both sides have actually played (see
	# backend replay lock in handleReplay: the server itself refuses to
	# serve either replay before that point, so there's no point offering
	# the button earlier). Both replays are watchable once unlocked.
	var my_session : String = str(r.get("creator_session" if is_creator else "opponent_session", ""))
	var opp_session : String = str(r.get("opponent_session" if is_creator else "creator_session", ""))
	if my_score != null and opp_score != null:
		var replay_row := HBoxContainer.new()
		replay_row.add_theme_constant_override("separation", int(ref * 0.012))
		cv.add_child(replay_row)
		if my_session != "":
			var my_replay_btn := Button.new()
			my_replay_btn.text = "▶ Your Replay"
			my_replay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_warm_btn(my_replay_btn, 8)
			replay_row.add_child(my_replay_btn)
			my_replay_btn.pressed.connect(func(): _fetch_and_emit_replay(my_session, my_replay_btn))
		if opp_session != "":
			var opp_replay_btn := Button.new()
			opp_replay_btn.text = "▶ %s's Replay" % _display_name(opp_nick, opp_addr2)
			opp_replay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_warm_btn(opp_replay_btn, 8)
			replay_row.add_child(opp_replay_btn)
			opp_replay_btn.pressed.connect(func(): _fetch_and_emit_replay(opp_session, opp_replay_btn))


func _time_left_text(expires_at: int) -> String:
	var remaining := expires_at - int(Time.get_unix_time_from_system())  # determinism-ok: UI-only countdown
	if remaining <= 0: return "Expired"
	var h := remaining / 3600
	var m := (remaining % 3600) / 60
	return "%dh %dm" % [h, m]


# ── Payment flow ─────────────────────────────────────────────────────────────
func _do_pay(room_id: String, role: String, amount_nim: float, btn: Button) -> void:
	btn.disabled = true
	btn.text = "Waiting for wallet..."
	var pay_to := str(_current_room.get("pay_to", ""))
	var pay_memo := str(_current_room.get("pay_memo", ""))
	if pay_to == "":
		# Room was fetched without pay_to (e.g. reloaded from /vsroom/{id}) —
		# join/create always return it fresh, so re-fetch via join for opponents
		# or just bail with a clear message for creators (shouldn't happen).
		_show_toast_err("Payment info unavailable — reopen this room and try again.")
		btn.disabled = false
		btn.text = "Pay %.2f NIM" % amount_nim
		return
	var value_luna := int(round(amount_nim * 100000.0))  # NimLunaMultiplier
	var result : Dictionary = await NimiqJS.request_payment(pay_to, value_luna, pay_memo)
	if not bool(result.get("ok", false)):
		_show_toast_err("Payment failed: " + str(result.get("err", "unknown")))
		btn.disabled = false
		btn.text = "Pay %.2f NIM" % amount_nim
		return
	btn.text = "Confirming..."
	var tx : String = str(result.get("tx", ""))
	_confirm_payment(room_id, tx, func(ok: bool):
		if ok:
			var t := Toast.get_instance()
			if t: t.show_toast("Payment confirmed!", Toast.Kind.SUCCESS)
			_show_room_detail(room_id)
		else:
			# The backend also independently re-scans the wallet's incoming
			# transactions every ~90s and will pick this payment up on its
			# own even if this confirm call keeps failing — it is not lost.
			_show_toast_err("Payment sent — confirming automatically, this can take up to a couple minutes. Reopen this room to check.")
			btn.disabled = false
			btn.text = "Pay %.2f NIM" % amount_nim
	)


func _show_toast_err(msg: String) -> void:
	var t := Toast.get_instance()
	if t: t.show_toast(msg, Toast.Kind.ERROR)


# ── HTTP helpers ─────────────────────────────────────────────────────────────
func _headers(json_body: bool = false) -> PackedStringArray:
	var h : PackedStringArray = []
	if json_body: h.append("Content-Type: application/json")
	if _auth_token != "": h.append("Authorization: Bearer " + _auth_token)
	return h


func _create_room(entry_nim: float, is_private: bool, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			cb.call(true)
		else:
			_show_toast_err("Could not create room (code %d)" % code)
			cb.call(false)
	)
	var body_str := JSON.stringify({"entry_nim": entry_nim, "is_private": is_private})
	http.request(BACKEND_URL + "/backend/vsroom/create", _headers(true), HTTPClient.METHOD_POST, body_str)


## Public browse list — open rooms anyone can join (private rooms never
## appear here, they only work via their direct invite link).
func _fetch_open(cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				cb.call(_as_array(j.get_data().get("rooms", [])))
				return
		cb.call([])
	)
	http.request(BACKEND_URL + "/backend/vsroom/open", _headers())


## Appends a "Load more" button to `container` if fewer than `total` rooms
## have been loaded so far. Pressing it fetches the next page, appends the
## new rows above the button, and re-evaluates whether another page remains.
func _add_load_more_if_needed(container: VBoxContainer, loaded_so_far: int, total: int, ref: float) -> void:
	if loaded_so_far >= total:
		return
	var more_btn := Button.new()
	more_btn.text = "Load more (%d of %d)" % [loaded_so_far, total]
	more_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_warm_btn(more_btn, 8)
	container.add_child(more_btn)
	more_btn.pressed.connect(func():
		more_btn.disabled = true
		more_btn.text = "Loading..."
		_fetch_mine(loaded_so_far, func(rooms: Array, total2: int):
			if not is_instance_valid(container): return
			more_btn.queue_free()
			_rooms_cache.append_array(rooms)
			for r in rooms:
				container.add_child(_make_room_row(r, ref))
			_add_load_more_if_needed(container, loaded_so_far + rooms.size(), total2, ref)
		)
	)


## Fetches one page of "my rooms". A single account can open unlimited paid
## rooms (there's no per-account cap), so this list can no longer just fetch
## a fixed first-N and call it done — cb receives (rooms, total) so the
## caller can page through everything via a "Load more" control.
func _fetch_mine(offset: int, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				cb.call(_as_array(d.get("rooms", [])), int(d.get("total", 0)))
				return
		cb.call([], 0)
	)
	http.request(BACKEND_URL + "/backend/vsroom/mine?limit=%d&offset=%d" % [_MINE_PAGE_SIZE, offset], _headers())


func _fetch_room(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				var room : Dictionary = d.get("room", {})
				# join/create responses nest pay_to/pay_memo alongside room —
				# flatten them onto the room dict for _do_pay() to read.
				if d.has("pay_to"):     room["pay_to"]     = d["pay_to"]
				if d.has("pay_memo"):   room["pay_memo"]   = d["pay_memo"]
				if d.has("invite_url"): room["invite_url"] = d["invite_url"]
				cb.call(true, room)
				return
		cb.call(false, {})
	)
	http.request(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode(), _headers())


func _join_room(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				var room2 : Dictionary = d.get("room", {})
				if d.has("pay_to"):   room2["pay_to"]   = d["pay_to"]
				if d.has("pay_memo"): room2["pay_memo"] = d["pay_memo"]
				cb.call(true, room2)
				return
		cb.call(false, {})
	)
	http.request(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/join", _headers(true), HTTPClient.METHOD_POST, "{}")


func _confirm_payment(room_id: String, tx_hash: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 20.0   # RPC lookup server-side can take a moment
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		cb.call(result == HTTPRequest.RESULT_SUCCESS and code == 200)
	)
	var body_str := JSON.stringify({"tx_hash": tx_hash})
	http.request(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/pay", _headers(true), HTTPClient.METHOD_POST, body_str)


# ── Mutual forfeit ───────────────────────────────────────────────────────────
# Lets a player who's matched into a room (opponent already joined) ask to
# bail out. Nothing actually happens until the OTHER side also requests it —
# see RequestVSForfeit in backend/game/vsroom.go — so this is safe to call
# freely: worst case the request just sits there recorded until the other
# side agrees (or the normal 24h expiry/settlement takes over regardless).
func _request_forfeit(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				cb.call(true, j.get_data().get("room", {}))
				return
		cb.call(false, {})
	)
	http.request(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/forfeit", _headers(true), HTTPClient.METHOD_POST, "{}")


# ── Watch replay ─────────────────────────────────────────────────────────────
# Same fetch pattern as LeaderboardPanel._fetch_and_emit_replay — GET the
# session's replay log and hand it off to Main via replay_requested. The
# backend itself enforces the "not until both sides finished" lock (see
# handleReplay in replay_handlers.go), so this button only ever appears once
# that's already true, but a stale/cached room dict could theoretically still
# show it a moment too early — the 403 from the server just fails quietly.
func _fetch_and_emit_replay(session_id_e: String, btn: Button) -> void:
	if not is_instance_valid(btn): return
	btn.disabled = true
	btn.text = "..."
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if not is_instance_valid(btn): return
		btn.disabled = false
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			btn.text = "▶ Replay"
			if code == 403:
				_show_toast_err("Replay isn't unlocked yet — both sides need to finish first.")
			else:
				Toast.network_error("vs_replay_fetch code=%d" % code)
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
		replay_requested.emit(seed, log_bytes, char_idx, nickname, player_seed)
		hide_panel.call_deferred()
		closed.emit.call_deferred()
	)
	http.request(BACKEND_URL + "/backend/replay/" + session_id_e, _headers())


# ── Nimiq avatars ────────────────────────────────────────────────────────────
# Same rendering approach as LeaderboardPanel._make_nimiq_avatar (duplicated
# here rather than shared, matching how QuestPanel/StatsPanel are each
# self-contained): draw a deterministic colored fallback immediately, then
# swap in the real Nimiq identicon once it loads on web.
func _make_nimiq_avatar(address: String, size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode    = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode   = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = Control.TEXTURE_FILTER_LINEAR
	tr.texture = _make_fallback_avatar(address, size)
	if OS.has_feature("web") and address != "" and address != "null" and address != "undefined":
		_load_nimiq_avatar_async(tr, address, size)
	return tr


func _make_fallback_avatar(address: String, size: int) -> ImageTexture:
	var cache_key := address + "@" + str(size)
	if _avatar_tex_cache.has(cache_key): return _avatar_tex_cache[cache_key]
	const PALETTE := [
		Color(0.13, 0.60, 0.90),
		Color(0.40, 0.78, 0.22),
		Color(0.96, 0.65, 0.14),
		Color(0.82, 0.28, 0.28),
		Color(0.60, 0.35, 0.85),
		Color(0.20, 0.72, 0.65),
		Color(0.95, 0.38, 0.60),
		Color(0.45, 0.55, 0.70),
	]
	var hash_val := 0
	for i in mini(address.length(), 12):
		hash_val = (hash_val * 31 + address.unicode_at(i)) & 0xFFFF
	var bg_col : Color = PALETTE[hash_val % PALETTE.size()]

	var letter := "?"
	for i in address.length():
		var c := address.unicode_at(i)
		if (c >= 65 and c <= 90) or (c >= 48 and c <= 57):
			letter = address[i]
			break

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx := size * 0.5
	var cy := size * 0.5
	var r  := size * 0.5
	for y in size:
		for x in size:
			var dx := x - cx + 0.5
			var dy := y - cy + 0.5
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, bg_col)

	var ps := maxi(1, size / 10)
	_draw_letter(img, letter, ps, Color.WHITE)

	var tex := ImageTexture.create_from_image(img)
	_avatar_tex_cache[cache_key] = tex
	return tex


func _draw_letter(img: Image, ch: String, ps: int, ink: Color) -> void:
	const GLYPHS := {
		"0": [0b111,0b101,0b101,0b101,0b111], "1": [0b010,0b110,0b010,0b010,0b111],
		"2": [0b111,0b001,0b111,0b100,0b111], "3": [0b111,0b001,0b111,0b001,0b111],
		"4": [0b101,0b101,0b111,0b001,0b001], "5": [0b111,0b100,0b111,0b001,0b111],
		"6": [0b111,0b100,0b111,0b101,0b111], "7": [0b111,0b001,0b001,0b001,0b001],
		"8": [0b111,0b101,0b111,0b101,0b111], "9": [0b111,0b101,0b111,0b001,0b111],
		"A": [0b010,0b101,0b111,0b101,0b101], "B": [0b110,0b101,0b110,0b101,0b110],
		"C": [0b111,0b100,0b100,0b100,0b111], "D": [0b110,0b101,0b101,0b101,0b110],
		"E": [0b111,0b100,0b110,0b100,0b111], "F": [0b111,0b100,0b110,0b100,0b100],
		"G": [0b111,0b100,0b101,0b101,0b111], "H": [0b101,0b101,0b111,0b101,0b101],
		"I": [0b111,0b010,0b010,0b010,0b111], "J": [0b001,0b001,0b001,0b101,0b111],
		"K": [0b101,0b101,0b110,0b101,0b101], "L": [0b100,0b100,0b100,0b100,0b111],
		"M": [0b101,0b111,0b101,0b101,0b101], "N": [0b101,0b111,0b111,0b101,0b101],
		"O": [0b111,0b101,0b101,0b101,0b111], "P": [0b110,0b101,0b110,0b100,0b100],
		"Q": [0b111,0b101,0b101,0b111,0b001], "R": [0b110,0b101,0b110,0b101,0b101],
		"S": [0b111,0b100,0b111,0b001,0b111], "T": [0b111,0b010,0b010,0b010,0b010],
		"U": [0b101,0b101,0b101,0b101,0b111], "V": [0b101,0b101,0b101,0b010,0b010],
		"W": [0b101,0b101,0b101,0b111,0b101], "X": [0b101,0b101,0b010,0b101,0b101],
		"Y": [0b101,0b101,0b010,0b010,0b010], "Z": [0b111,0b001,0b010,0b100,0b111],
		"?": [0b111,0b001,0b011,0b000,0b010],
	}
	var rows : Array = GLYPHS.get(ch, GLYPHS["?"])
	var w := img.get_width()
	var h := img.get_height()
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
	var key := "vsavatar_" + address.left(8).validate_node_name()

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
		+ "  window._nimiqPending['" + key + "'] = ''; return;"
		+ "}"
		+ "window.getNimiqAvatar('" + address + "')"
		+ "  .then(function(svgData){"
		+ "    if(!svgData){ window._nimiqPending['" + key + "'] = ''; return; }"
		+ "    var img = new Image();"
		+ "    img.onload = function(){"
		+ "      try {"
		+ "        var c = document.createElement('canvas');"
		+ "        c.width = " + str(size) + "; c.height = " + str(size) + ";"
		+ "        c.getContext('2d').drawImage(img, 0, 0, " + str(size) + ", " + str(size) + ");"
		+ "        window._nimiqPending['" + key + "'] = c.toDataURL('image/png');"
		+ "      } catch(e){ window._nimiqPending['" + key + "'] = ''; }"
		+ "    };"
		+ "    img.onerror = function(){ window._nimiqPending['" + key + "'] = ''; };"
		+ "    img.src = svgData;"
		+ "  })"
		+ "  .catch(function(e){ window._nimiqPending['" + key + "'] = ''; });"
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
