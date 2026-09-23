extends CanvasLayer
## ProfileCardPanel.gd — clickable player profile card.
##
## Opened from LeaderboardPanel.gd (tap a row) and VSPanel.gd (tap the
## opponent avatar on a room card) — both emit the SAME signal
## (`profile_requested(player_id)`), Main.gd connects both to this single
## panel's open_profile(), so the schema/UI is identical no matter which
## screen it was opened from (this was the explicit ask: "same UI logic as
## the rest of the system, one schema").
##
## Requires auth: GET /backend/profile is a protected route (401 without a
## valid Bearer token) — if the viewer hasn't signed in with their wallet
## yet, this shows a "sign in to view profiles" placeholder instead of
## calling the backend at all.
##
## Shows: avatar, nickname, level + XP bar, daily-leaderboard rank, games
## played, kills, play time, login streak, last seen, and the 5 most recent
## matches (score/kills/date, flagged runs dimmed) — see
## backend/models/level.go's ProfileCard for the exact JSON shape this
## parses.

signal closed
## Same signature as LeaderboardPanel.replay_requested / VSPanel.replay_requested
## — a match row's "watch replay" button (shown only when has_replay is true,
## same rule the leaderboard already uses: no replay log stored -> no button)
## fetches GET /backend/replay/{session_id} and re-emits through this, so
## Main.gd can reuse its existing replay-playback wiring for a THIRD source
## unchanged (see GAME_INTEGRATION.md for the one new connect() call needed).
signal replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, nickname: String, player_seed: int, address: String, gyro_active: bool)
## Emitted when the user taps "Connect Wallet" from the not-signed-in state —
## same signal name/pattern as QuestPanel/StatsPanel/VSPanel's connect_requested,
## Main.gd routes it to the shared _request_wallet_connect() handler.
signal connect_requested

var BACKEND_URL : String = ApiConfig.base_url()
const UITheme := preload("res://scripts/UITheme.gd")

var _panel_ctrl : Control = null
var _scroll     : ScrollContainer = null
var _content    : VBoxContainer = null
var _anim_tween : Tween = null

# ── Dynamic panel-height system — same as StatsPanel's _pc/_content_mc/
# _hdr_mc/_sep_rect/_panel_pad/_panel_max_h/_panel_min_h + _fit_panel_height()/
# _animate_panel_height(), ported 1:1 so this panel resizes itself the same
# way instead of the old fixed-position/fixed-height layout (that's what was
# breaking the scroll: a non-anchored, non-clamped panel whose ScrollContainer
# height didn't track real content/viewport size).
var _pc          : PanelContainer = null
var _content_mc  : MarginContainer = null
var _hdr_mc      : MarginContainer = null
var _sep_rect    : Control = null
var _panel_pad   : float = 0.0
var _panel_max_h : float = 0.0
var _panel_min_h : float = 0.0
var _height_tween : Tween = null

var _auth_token : String = ""
var _own_address : String = ""  # set via set_own_address() — hides Send on your own profile
var _target_address : String = ""  # whoever this card is currently showing
var _send_row : Control = null  # rebuilt per open_profile() call
var _http       : HTTPRequest = null
var _avatar_tex_cache : Dictionary = {}

# ── Donate amount keypad sheet — same bottom-docked custom keypad system
# VSPanel uses for its entry-fee amount (VSPanel.gd's _entry_sheet_root/
# _entry_apply_key/_entry_close/_entry_sheet_open), local copy so this panel
# doesn't reach into VSPanel's script for it. See _build_send_ui's doc
# comment for why this replaces a plain LineEdit + the OS virtual keyboard.
var _donate_sheet_root : Control = null        # bottom-docked keypad overlay,
												 # lives directly under
												 # _panel_ctrl; torn down by
												 # _teardown_donate_sheet()
												 # wherever _content gets
												 # rebuilt below
var _donate_apply_key : Callable = Callable()   # keypad key handler; physical
												 # keyboard input routed here
var _donate_close     : Callable = Callable()   # closes the sheet (Enter key)
var _donate_sheet_open := false                 # true while the sheet is open

const _C_BG     := Color(0.957, 0.898, 0.800)
const _C_CARD   := Color(0.940, 0.878, 0.776)
const _C_BORDER := Color(0.700, 0.520, 0.340)
const _C_BROWN  := Color(0.220, 0.130, 0.060)
const _C_MID    := Color(0.480, 0.340, 0.200)
const _C_SEP    := Color(0.700, 0.560, 0.400, 0.5)
const _C_ORANGE := Color(0.780, 0.380, 0.120)
const _C_GREEN  := Color(0.240, 0.620, 0.220)
const _C_GOLD   := Color(0.820, 0.580, 0.100)
const _C_RED    := Color(0.820, 0.180, 0.120)


func setup() -> void:
	_build_ui()
	hide()


func set_auth_token(token: String) -> void:
	var had_token := _auth_token != ""
	_auth_token = token
	# Same live-refresh rule as StatsPanel.set_auth_token: if the card is
	# already open (e.g. showing the "sign in" prompt) and a token just
	# arrived, pick the fetch back up instead of leaving the connect
	# prompt stuck on screen until the user re-opens the card.
	if is_visible() and token != "" and not had_token and _target_address != "":
		_fetch_profile(_target_address)


## Called by Main.gd alongside set_auth_token — the connected wallet's own
## address, so the Send button doesn't show up on your own profile card.
func set_own_address(address: String) -> void:
	_own_address = address


# Physical-keyboard support for the donate amount keypad (desktop): while the
# sheet is open, number keys type into it, "." adds a decimal point,
# Backspace deletes, Enter confirms/closes — same pattern as VSPanel's own
# entry-fee keypad _input handler.
func _input(event: InputEvent) -> void:
	if not _donate_sheet_open or not _donate_apply_key.is_valid():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# This script extends CanvasLayer (not Control), so accept_event() — a
	# Control-only method — is unavailable. Mark the key handled via the
	# viewport instead so it doesn't leak through to the game underneath.
	var vp := get_viewport()
	var kc : int = event.keycode
	if kc == KEY_BACKSPACE or kc == KEY_DELETE:
		_donate_apply_key.call("back"); vp.set_input_as_handled()
	elif kc >= KEY_0 and kc <= KEY_9:
		_donate_apply_key.call(str(kc - KEY_0)); vp.set_input_as_handled()
	elif kc >= KEY_KP_0 and kc <= KEY_KP_9:
		_donate_apply_key.call(str(kc - KEY_KP_0)); vp.set_input_as_handled()
	elif kc == KEY_PERIOD or kc == KEY_KP_PERIOD:
		_donate_apply_key.call("."); vp.set_input_as_handled()
	elif (kc == KEY_ENTER or kc == KEY_KP_ENTER) and _donate_close.is_valid():
		_donate_close.call(); vp.set_input_as_handled()


## Tears down the donate keypad sheet (if built/open) — called wherever
## _content gets cleared/rebuilt below so the sheet, which lives outside
## _content (directly under _panel_ctrl), never leaks behind on the next
## rebuild or gets left dangling mid-animation.
func _teardown_donate_sheet() -> void:
	_donate_sheet_open = false
	_donate_apply_key = Callable()
	_donate_close = Callable()
	if is_instance_valid(_donate_sheet_root):
		_donate_sheet_root.queue_free()
		_donate_sheet_root = null


## Called by Main.gd from either LeaderboardPanel.profile_requested or
## VSPanel.profile_requested — same entry point either way.
func open_profile(player_id: String) -> void:
	if player_id == "":
		return
	show_panel()
	_target_address = player_id
	if _auth_token == "":
		_show_connect_prompt()
		return
	_fetch_profile(player_id)


func show_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	UITheme.refresh_mouse_hover(self)
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.pivot_offset = _panel_ctrl.size * 0.5
		_panel_ctrl.modulate.a = 0.0
		_panel_ctrl.scale      = Vector2(0.90, 0.90)
		_anim_tween = create_tween()
		_anim_tween.set_parallel(true)
		_anim_tween.tween_property(_panel_ctrl, "modulate:a", 1.0, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_anim_tween.tween_property(_panel_ctrl, "scale", Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func hide_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	if is_instance_valid(_http):
		_http.cancel_request()
	hide()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 1.0
		_panel_ctrl.scale      = Vector2.ONE


## Shrinks/grows the panel to fit whatever's currently in _content instead of
## always reserving the same tall fixed box — see the _pc/_panel_pad/etc.
## member doc comment above for why. Call this once after _content's children
## change (message state, connect prompt, rendered card, donate form toggle).
## Async: waits a frame so the freshly-added children have real minimum sizes
## before measuring — fire-and-forget from callers (`_fit_panel_height()`
## with no `await`). Ported 1:1 from StatsPanel.gd.
func _fit_panel_height() -> void:
	if not is_instance_valid(_pc) or not is_instance_valid(_content_mc):
		return
	await get_tree().process_frame
	# The panel may have been closed/torn down while we were waiting a frame.
	if not is_instance_valid(_pc) or not is_instance_valid(_content_mc) or not is_instance_valid(_hdr_mc) or not is_instance_valid(_sep_rect):
		return
	var content_h : float = _content_mc.get_combined_minimum_size().y
	var chrome_h  : float = _hdr_mc.size.y + _sep_rect.size.y + _panel_pad * 2.0
	var desired_h : float = clampf(content_h + chrome_h, _panel_min_h, _panel_max_h)
	_animate_panel_height(desired_h)


## Tweens _pc's offset_top/offset_bottom to the given target height instead of
## snapping instantly — shared by every _fit_panel_height() call. Ported 1:1
## from StatsPanel.gd.
func _animate_panel_height(target_h: float) -> void:
	if not is_instance_valid(_pc):
		return
	if is_instance_valid(_height_tween):
		_height_tween.kill()
	_height_tween = create_tween()
	_height_tween.set_parallel(true)
	_height_tween.tween_property(_pc, "offset_top",    -target_h * 0.5, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_height_tween.tween_property(_pc, "offset_bottom",  target_h * 0.5, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _build_ui() -> void:
	var vp  := get_viewport()
	var vw  := vp.get_visible_rect().size.x if vp else GameConstants.VW
	var vh  := vp.get_visible_rect().size.y if vp else GameConstants.VH
	var ref := minf(minf(vw, vh), GameConstants.VW)
	var pad := int(ref * 0.024)
	var pw  := ref * 0.88
	var ph  := minf(vh * 0.88, vh - pad * 2.0)

	# ── Dim ─────────────────────────────────────────────
	var dim_ctrl := Control.new()
	dim_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim_ctrl)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e):
		# Close on RELEASE not press — same as StatsPanel/LeaderboardPanel's
		# dim handler (press-triggered close lets the release half of the
		# same tap leak through onto whatever's now exposed underneath).
		if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			hide_panel(); closed.emit()
		# BUG FIX ("can't scroll on the profile card with the mouse wheel"):
		# dim is a full-rect MOUSE_FILTER_STOP ColorRect, and in some runtime
		# conditions a wheel event over the panel was being consumed here
		# instead of ever reaching the ScrollContainer underneath. Fix:
		# explicitly forward WHEEL_UP/WHEEL_DOWN to the panel's own scrollbar,
		# same fix as StatsPanel.gd.
		elif e is InputEventMouseButton and e.pressed and is_instance_valid(_scroll):
			if e.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll.scroll_vertical -= _scroll.get_v_scroll_bar().page * 0.25
			elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll.scroll_vertical += _scroll.get_v_scroll_bar().page * 0.25
	)
	dim_ctrl.add_child(dim)

	_panel_ctrl = Control.new()
	_panel_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# IGNORE so taps on the empty area around the panel fall THROUGH to the dim
	# below (which closes the panel). Its child panel `pc` keeps its own STOP,
	# so the panel itself still captures input — only the surrounding gap
	# passes. Same structure as StatsPanel.gd.
	_panel_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim_ctrl.add_child(_panel_ctrl)

	var pc := PanelContainer.new()
	pc.anchor_left   = 0.5; pc.anchor_right  = 0.5
	pc.anchor_top    = 0.5; pc.anchor_bottom = 0.5
	pc.offset_left   = -pw * 0.5; pc.offset_right  =  pw * 0.5
	pc.offset_top    = -ph * 0.5; pc.offset_bottom =  ph * 0.5
	var pc_st := StyleBoxFlat.new()
	pc_st.bg_color = _C_BG
	pc_st.border_color = _C_BORDER
	pc_st.set_border_width_all(3)
	pc_st.set_corner_radius_all(16)
	pc_st.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	pc_st.shadow_size  = 10
	pc.add_theme_stylebox_override("panel", pc_st)
	_panel_ctrl.add_child(pc)
	_pc = pc
	_panel_pad = pad
	_panel_max_h = ph
	_panel_min_h = vh * 0.34

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	pc.add_child(outer)

	# ── Header: icon + centered title + close button (same layout as
	# LeaderboardPanel/QuestPanel/StatsPanel headers) ────────────────
	var hdr_mc := _mpad(pad)
	outer.add_child(hdr_mc)
	_hdr_mc = hdr_mc
	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr_mc.add_child(hdr)
	hdr.add_child(UITheme.lucide_icon("user", int(ref * 0.038), _C_ORANGE))
	var title := Label.new()
	title.text = "PLAYER PROFILE"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, _C_BROWN, int(ref * 0.048))
	hdr.add_child(title)
	var x_btn := Button.new()
	var close_sz := int(ref * 0.090)
	var close_ic_sz := int(close_sz * 0.72)
	x_btn.custom_minimum_size = Vector2(close_sz, close_sz)
	x_btn.pressed.connect(func(): hide_panel(); closed.emit())
	_warm_btn(x_btn, 8)
	var close_center := CenterContainer.new()
	close_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	x_btn.add_child(close_center)
	var close_ic := TextureRect.new()
	close_ic.texture = preload("res://assets/hud/hudX.png")
	close_ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	close_ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	close_ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_ic.custom_minimum_size = Vector2(close_ic_sz, close_ic_sz)
	close_center.add_child(close_ic)
	hdr.add_child(x_btn)

	var sep_line0 := HSeparator.new()
	sep_line0.add_theme_color_override("color", _C_SEP)
	outer.add_child(sep_line0)
	_sep_rect = sep_line0

	# ── Scroll — same setup as StatsPanel.gd ─────────────
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone        = 0
	scroll.follow_focus           = false
	outer.add_child(scroll)
	_scroll = scroll

	var content_mc := _mpad(pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)
	_content_mc = content_mc

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", int(ref * 0.014))
	content_mc.add_child(_content)


func _show_message(msg: String, col: Color) -> void:
	_teardown_donate_sheet()
	for c in _content.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = msg
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	UITheme.apply_label(lbl, col, int(ref * 0.026))
	_content.add_child(lbl)
	_fit_panel_height()


## Not-signed-in state — same layout/copy pattern as QuestPanel._show_connect_
## prompt / StatsPanel's _no_auth_box: centered mid-brown label + the standard
## warm "Connect Wallet" button, wired to connect_requested so Main.gd can
## kick off the same wallet-connect flow every other panel uses.
func _show_connect_prompt() -> void:
	_teardown_donate_sheet()
	for c in _content.get_children():
		c.queue_free()
	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(ref * 0.018))
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Sign in with your wallet to view profiles."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, _C_MID, int(ref * 0.030))
	vbox.add_child(lbl)

	var btn := Button.new()
	btn.text = "Connect Wallet"
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.custom_minimum_size = Vector2(ref * 0.55, ref * 0.080)
	btn.add_theme_font_size_override("font_size", int(ref * 0.034))
	_warm_btn(btn, 8)
	btn.pressed.connect(func():
		emit_signal("connect_requested")
		hide_panel(); closed.emit()
	)
	vbox.add_child(btn)
	_fit_panel_height()


func _fetch_profile(player_id: String) -> void:
	_show_message("Loading...", _C_MID)
	if is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_profile_response)
	var url := BACKEND_URL + "/backend/profile?player_id=" + player_id.uri_encode()
	var headers := PackedStringArray(["Authorization: Bearer " + _auth_token])
	_http.request(ApiConfig.sign_url(url), headers)


func _on_profile_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not is_instance_valid(_http): return
	if response_code == 401:
		_show_connect_prompt()
		return
	if response_code != 200:
		_show_message("Couldn't load this profile. Try again.", _C_RED)
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		_show_message("Couldn't load this profile. Try again.", _C_RED)
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_show_message("Couldn't load this profile. Try again.", _C_RED)
		return
	_render_card(data)


func _render_card(data: Dictionary) -> void:
	_teardown_donate_sheet()
	for c in _content.get_children():
		c.queue_free()

	var ref := minf(minf(get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y), GameConstants.VW)

	var address  : String = str(data.get("player_id", ""))
	_target_address = address
	var nickname : String = UITheme.display_name(str(data.get("nickname", "")), address)
	var level    : int    = int(data.get("level", 1))
	var xp_into  : int    = int(data.get("xp_into_level", 0))
	var xp_next  : int    = int(data.get("xp_for_next_level", 0))
	var daily_rank  : int = int(data.get("daily_rank", 0))
	var weekly_rank : int = int(data.get("weekly_rank", 0))

	# ── Avatar + name + level badge ──────────────────────────────────
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", int(ref * 0.016))
	_content.add_child(head_row)

	var avatar_size := int(ref * 0.14)
	head_row.add_child(_make_nimiq_avatar(address, avatar_size))

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	name_col.add_theme_constant_override("separation", int(ref * 0.004))
	head_row.add_child(name_col)

	var name_lbl := Label.new()
	name_lbl.text = nickname
	name_lbl.clip_text = true
	UITheme.apply_label(name_lbl, _C_BROWN, int(ref * 0.034))
	name_col.add_child(name_lbl)

	# ── Full wallet address — NEVER shortened here (unlike the nickname
	# fallback / avatar-key/short_address() uses elsewhere), since this is
	# the one place a player actually wants to grab the complete address.
	# Tap to copy, same toast-confirmed clipboard pattern VSPanel's invite
	# link uses (see _copy_address below).
	if address != "":
		var addr_lbl := Label.new()
		addr_lbl.text = address
		addr_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		addr_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		addr_lbl.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		addr_lbl.tooltip_text = "Tap to copy"
		UITheme.apply_label(addr_lbl, _C_MID, int(ref * 0.020))
		name_col.add_child(addr_lbl)
		# Close on RELEASE, not press — same convention as every other tap
		# gesture in this codebase (dim overlay, leaderboard row taps, etc.)
		# so a scroll-drag ending over the label doesn't fire a false copy.
		addr_lbl.gui_input.connect(func(e):
			if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_copy_address(address)
		)

	# ── Donate / Send NIM ─────────────────────────────────────────────────
	# Direct wallet-to-wallet transfer — goes straight through the Nimiq
	# provider/Hub (NimiqJS.request_payment, same channel VSPanel's entry
	# fee uses), NEVER through our backend. There's nothing for the server
	# to confirm here (unlike a VS room entry fee, which the backend has to
	# verify happened before starting a match) — it's just a personal
	# transfer with a memo, so no /backend/* call is made at all.
	#
	# The toggle button sits in the blank space under the nickname/address
	# (name_col is taller than its labels because it's stretched to the
	# avatar's height) instead of floating as its own full-width row — a
	# spacer pushes it to the bottom of that leftover space. The expandable
	# amount/message form still opens as its own full-width block below the
	# header row.
	if address != "" and address != _own_address:
		var donate_ui := _build_send_ui(address, ref)
		var donate_spacer := Control.new()
		donate_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		name_col.add_child(donate_spacer)
		name_col.add_child(donate_ui["toggle"])
		_send_row = donate_ui["form"]
		_content.add_child(_send_row)

	# ── Level card — same bordered card + star icon + gold rounded-corner
	# progress bar as StatsPanel's Level card (_add_level_bar), instead of
	# a bare ColorRect bar floating with no card around it.
	var lvl_card := PanelContainer.new()
	lvl_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lvl_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lvl_st := StyleBoxFlat.new()
	lvl_st.bg_color = _C_CARD
	lvl_st.border_color = _C_BORDER
	lvl_st.set_border_width_all(2)
	lvl_st.set_corner_radius_all(10)
	lvl_card.add_theme_stylebox_override("panel", lvl_st)
	_content.add_child(lvl_card)

	var lvl_mc := _mpad(int(ref * 0.016))
	lvl_card.add_child(lvl_mc)
	var lvl_vbox := VBoxContainer.new()
	lvl_vbox.add_theme_constant_override("separation", int(ref * 0.006))
	lvl_mc.add_child(lvl_vbox)

	var lvl_title_row := HBoxContainer.new()
	lvl_title_row.add_theme_constant_override("separation", int(ref * 0.008))
	lvl_vbox.add_child(lvl_title_row)
	lvl_title_row.add_child(UITheme.lucide_icon("star", int(ref * 0.030), _C_GOLD))
	var lvl_title := Label.new()
	lvl_title.text = "Level"
	lvl_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(lvl_title, _C_MID, int(ref * 0.024))
	lvl_title_row.add_child(lvl_title)
	var lvl_val_lbl := Label.new()
	lvl_val_lbl.text = "Lv. %d" % level
	UITheme.apply_label(lvl_val_lbl, _C_BROWN, int(ref * 0.030))
	lvl_title_row.add_child(lvl_val_lbl)

	var lvl_xp_lbl := Label.new()
	lvl_xp_lbl.text = ("%d XP to next level" % (xp_next - xp_into)) if xp_next > 0 else "Max level"
	UITheme.apply_label(lvl_xp_lbl, _C_MID, int(ref * 0.020))
	lvl_vbox.add_child(lvl_xp_lbl)

	var xp_pct := 1.0 if xp_next <= 0 else clampf(float(xp_into) / float(xp_next), 0.0, 1.0)
	_add_level_bar(lvl_vbox, xp_pct, ref)

	# Daily/weekly rank, if any — shown as a small caption under the level
	# card rather than crammed into the name header.
	if daily_rank > 0 or weekly_rank > 0:
		var rank_row := HBoxContainer.new()
		rank_row.add_theme_constant_override("separation", int(ref * 0.008))
		_content.add_child(rank_row)
		if daily_rank > 0:
			var drank_lbl := Label.new()
			drank_lbl.text = "Daily #%d" % daily_rank
			UITheme.apply_label(drank_lbl, _C_MID, int(ref * 0.024))
			rank_row.add_child(drank_lbl)
		if weekly_rank > 0:
			var wrank_lbl := Label.new()
			wrank_lbl.text = "Weekly #%d" % weekly_rank
			UITheme.apply_label(wrank_lbl, _C_MID, int(ref * 0.024))
			rank_row.add_child(wrank_lbl)

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", _C_SEP)
	_content.add_child(sep2)

	# ── Stats grid: games played, kills, play time, login streak, last seen, best score ──
	# Same 2x2-card layout (icon+label row, big centered value below) and same
	# icon set as StatsPanel's stats_defs grid, so this reads identically.
	var stats := [
		{"icon": "gamepad-2", "label": "Games Played", "val": str(int(data.get("games_played", 0)))},
		{"icon": "zap",       "label": "Kills",         "val": str(int(data.get("total_kills", 0)))},
		{"icon": "clock",     "label": "Play Time",     "val": _fmt_ticks(int(data.get("play_time_ticks", 0)))},
		{"icon": "calendar",  "label": "Login Streak",  "val": "%d days" % int(data.get("login_streak", 0))},
		{"icon": "medal",     "label": "Best Score",    "val": str(int(data.get("best_score", 0)))},
		{"icon": "star",      "label": "Last Seen",     "val": _fmt_last_seen(int(data.get("last_seen", 0)))},
	]
	var ic_s := int(ref * 0.036)
	var fs_v := int(ref * 0.046)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", int(ref * 0.012))
	grid.add_theme_constant_override("v_separation", int(ref * 0.010))
	_content.add_child(grid)
	for s in stats:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.clip_contents = true
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
		icon_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		cv.add_child(icon_row)
		icon_row.add_child(UITheme.lucide_icon(s["icon"], int(ic_s * 1.35), _C_ORANGE))

		var lbl := Label.new()
		lbl.text = s["label"]
		lbl.clip_text = false
		lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
		UITheme.apply_label(lbl, _C_MID, int(ref * 0.026))
		icon_row.add_child(lbl)

		var val := Label.new()
		val.text = s["val"]
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(val, _C_ORANGE, fs_v)
		cv.add_child(val)

	# ── Recent matches ────────────────────────────────────────────────
	# Same bordered-card rows + column-header layout as StatsPanel's
	# "Recent Games" list (_build_recent), so this reads identically.
	var sep3 := HSeparator.new()
	sep3.add_theme_color_override("color", _C_SEP)
	_content.add_child(sep3)

	var rec_title := Label.new()
	rec_title.text = "Recent Matches"
	UITheme.apply_label(rec_title, _C_BROWN, int(ref * 0.034))
	_content.add_child(rec_title)

	var matches = data.get("recent_matches", [])
	if typeof(matches) != TYPE_ARRAY or matches.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "No matches yet."
		UITheme.apply_label(none_lbl, _C_MID, int(ref * 0.026))
		none_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_content.add_child(none_lbl)
	else:
		var col_hdr := HBoxContainer.new()
		col_hdr.add_theme_constant_override("separation", int(ref * 0.006))
		_content.add_child(col_hdr)
		col_hdr.add_child(_col_lbl("Date",  ref, 0.28, _C_MID, true))
		col_hdr.add_child(_col_lbl("Score", ref, 0.28, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))
		col_hdr.add_child(_col_lbl("Kills", ref, 0.22, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))
		col_hdr.add_child(_col_lbl("Status",ref, 0.22, _C_MID, true, HORIZONTAL_ALIGNMENT_RIGHT))

		var sep4 := HSeparator.new()
		sep4.add_theme_color_override("color", _C_SEP)
		_content.add_child(sep4)

		var rec_root := VBoxContainer.new()
		rec_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rec_root.add_theme_constant_override("separation", int(ref * 0.006))
		_content.add_child(rec_root)

		for m in matches:
			if typeof(m) != TYPE_DICTIONARY: continue
			var flagged : bool = bool(m.get("flagged", false))

			var row_pc := PanelContainer.new()
			row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var row_st := StyleBoxFlat.new()
			row_st.bg_color = _C_CARD
			row_st.border_color = _C_BORDER
			row_st.set_border_width_all(1)
			row_st.set_corner_radius_all(8)
			row_pc.add_theme_stylebox_override("panel", row_st)
			rec_root.add_child(row_pc)

			var row_mc := _mpad(int(ref * 0.010))
			row_pc.add_child(row_mc)

			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", int(ref * 0.006))
			row_mc.add_child(row)

			var ts := int(m.get("submitted_at", 0))
			var date_str := "--"
			if ts > 0:
				var dt := Time.get_datetime_dict_from_unix_time(ts + 3 * 3600)
				date_str = "%02d.%02d %02d.%02d" % [dt.day, dt.month, dt.hour, dt.minute]
			row.add_child(_col_lbl(date_str, ref, 0.28, _C_MID, false))

			var score_col := _C_RED if flagged else _C_BROWN
			row.add_child(_col_lbl(("F " if flagged else "") + str(int(m.get("score", 0))), ref, 0.28, score_col, true, HORIZONTAL_ALIGNMENT_RIGHT))

			row.add_child(_col_lbl(str(int(m.get("kills", 0))), ref, 0.22, _C_MID, false, HORIZONTAL_ALIGNMENT_RIGHT))

			var status_txt := "FLAG" if flagged else "OK"
			var status_col := _C_RED if flagged else _C_GREEN
			row.add_child(_col_lbl(status_txt, ref, 0.22, status_col, false, HORIZONTAL_ALIGNMENT_RIGHT))

			# Replay button only if this session actually has a stored replay
			# log — same rule LeaderboardPanel/StatsPanel use: no log means
			# no button at all (an equal-width spacer keeps columns aligned),
			# not a disabled one. Same circular outlined icon button as
			# StatsPanel's watch_btn (_replay_icon_btn) everywhere it appears.
			# Second button next to it shares/copies a direct link to the
			# replay (ApiConfig.replay_url) so the viewer can send it on
			# without having to watch-then-share.
			var has_replay : bool = bool(m.get("has_replay", false))
			var rp_size := int(ref * 0.056)
			if has_replay and not flagged:
				var session_id : String = str(m.get("session_id", ""))
				var rp_btn := Button.new()
				rp_btn.text = ""
				var _rp_ic : String = UITheme.get_theme_assets().get("icon_play", "")
				if ResourceLoader.exists(_rp_ic):
					rp_btn.icon = load(_rp_ic)
					rp_btn.expand_icon = true
					rp_btn.icon_alignment          = HORIZONTAL_ALIGNMENT_CENTER
					rp_btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
					rp_btn.add_theme_constant_override("icon_max_width", int(rp_size * 0.5))
				else:
					rp_btn.text = "▶"
					rp_btn.add_theme_font_size_override("font_size", int(ref * 0.020))
				rp_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
				_replay_icon_btn(rp_btn, rp_size)
				row.add_child(rp_btn)
				rp_btn.pressed.connect(func(): _fetch_replay(session_id, rp_btn))

				var link_btn := Button.new()
				link_btn.visible = false
				link_btn.text = ""
				# BUG FIX: "link-2.png" isn't actually present in the exported
				# lucide icon set, so this always fell through to the emoji
				# fallback below — and unlike the desktop editor (which
				# substitutes a system emoji font for missing glyphs), the
				# web/HTML5 export has no emoji glyph support at all, so "🔗"
				# rendered as a broken/missing glyph there specifically (this
				# is why it looked fine everywhere except web). Try a couple
				# of plausible lucide filenames, and if none exist, fall back
				# to a plain "LINK" text label instead of an emoji — that
				# always renders through the same font-fallback chain
				# UITheme._apply_pixel_font sets up for every other label.
				var _link_candidates : Array[String] = ["link-2", "link", "external-link"]
				var _link_ic := ""
				for _cand in _link_candidates:
					var _p : String = UITheme.LUCIDE_PATH + _cand + ".png"
					if ResourceLoader.exists(_p):
						_link_ic = _p
						break
				if _link_ic != "":
					link_btn.icon = load(_link_ic)
					link_btn.expand_icon = true
					link_btn.icon_alignment          = HORIZONTAL_ALIGNMENT_CENTER
					link_btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
					link_btn.add_theme_constant_override("icon_max_width", int(rp_size * 0.5))
				else:
					link_btn.text = "LINK"
					UITheme._apply_pixel_font(link_btn)
					link_btn.add_theme_font_size_override("font_size", int(ref * 0.016))
				link_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
				_replay_icon_btn(link_btn, rp_size)
				link_btn.tooltip_text = "Copy replay link"
				row.add_child(link_btn)
				# DISABLED: link_btn.pressed.connect(func(): _share_replay_link(session_id))
			else:
				var spacer := Control.new()
				spacer.custom_minimum_size = Vector2(int(rp_size * 2 + ref * 0.006), 0)
				spacer.size_flags_horizontal = Control.SIZE_SHRINK_END
				row.add_child(spacer)

	_fit_panel_height()


## Copies a wallet address to the clipboard (web-aware) and toasts a
## confirmation — same pattern as VSPanel._copy_invite_link, local copy so
## this panel doesn't reach into another panel's script for it.
func _copy_address(address: String) -> void:
	if address == "":
		return
	if OS.has_feature("web"):
		var js := "try{navigator.clipboard.writeText(%s);}catch(e){}" % JSON.stringify(address)
		JavaScriptBridge.eval(js, true)
	else:
		DisplayServer.clipboard_set(address)
	var t := Toast.get_instance()
	if t: t.show_toast("Address copied!", Toast.Kind.SUCCESS)


## Copies/shares a match's replay link (ApiConfig.replay_url) so the viewer
## can send it on directly — same Web Share API / clipboard-fallback path
## VSPanel's invite link and Main.gd's Share Score button already use, just
## called here per-match instead of per-run-just-played.
func _share_replay_link(session_id: String) -> void:
	if session_id == "":
		return
	var url := ApiConfig.replay_url(session_id)
	ApiConfig.share_link("Watch this replay:", url)


func _fetch_replay(session_id: String, btn: Button) -> void:
	if session_id == "": return
	btn.disabled = true
	var prev_icon := btn.icon
	var prev_text := btn.text
	btn.icon = null
	btn.text = "..."
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if not is_instance_valid(btn): return
		btn.disabled = false
		btn.icon = prev_icon
		btn.text = prev_text
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			Toast.network_error("profile_replay_fetch code=%d" % code)
			return
		var j := JSON.new()
		if j.parse(body.get_string_from_utf8()) != OK: return
		var d : Dictionary = j.get_data()
		var seed_str : String = str(d.get("seed", "0"))
		var seed     : int    = int(seed_str)
		var log_b64  : String = str(d.get("replay_log", ""))
		var char_idx : int    = int(d.get("char", 0))
		var gyro_active : bool = bool(d.get("gyro_active", false))
		var nickname : String = str(d.get("nickname", ""))
		var player_seed : int = int(str(d.get("player_seed", "0")))
		var address  : String = str(d.get("player_id", ""))
		if log_b64 == "" or seed == 0: return
		var log_bytes := Marshalls.base64_to_raw(log_b64)
		if log_bytes.is_empty(): return
		# Emit first, close deferred — same fix LeaderboardPanel applies
		# (see its own _fetch_replay comment) so Main.gd's visibility guard
		# on the panel doesn't see it already hidden when the signal lands.
		replay_requested.emit(seed, log_bytes, char_idx, nickname, player_seed, address, gyro_active)
		hide_panel.call_deferred()
		closed.emit.call_deferred()
	)
	var session_id_e := session_id.uri_encode()
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/replay/" + session_id_e))


## Builds the compact "Donate" toggle button (meant for the leftover space
## under the nickname) and the amount + message form it expands, returned
## separately as {"toggle": Button, "form": Control} so the caller can place
## them in different parts of the layout. Form stays collapsed by default so
## the profile card doesn't look like a payment screen until the viewer
## actually wants to send something.
const _MEMO_PREFIX := "nimjump donate : "

func _build_send_ui(target_address: String, ref: float) -> Dictionary:
	# Compact pill button — sized to sit in the leftover space under the
	# nickname next to the avatar, rather than stretching full-width.
	var toggle_btn := Button.new()
	toggle_btn.text = "Donate"
	toggle_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	toggle_btn.custom_minimum_size = Vector2(ref * 0.26, ref * 0.060)
	toggle_btn.add_theme_font_size_override("font_size", int(ref * 0.026))
	_warm_btn(toggle_btn, 8)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", int(ref * 0.008))
	form.visible = false

	# ── Amount field ─────────────────────────────────────────────────
	# Tapping this opens a bottom-docked custom keypad sheet — the same
	# system VSPanel uses for its entry-fee amount (see VSPanel.gd's
	# "Create room card" section) — instead of a plain LineEdit, which hands
	# focus to the OS and pops its native virtual keyboard over the game.
	# That's both visually out of place next to this panel's warm-bej theme
	# and the exact class of viewport-resize event VSPanel's own doc comment
	# calls out as a past crash source, so it gets the same treatment here.
	# Local copy of VSPanel's pattern (this panel doesn't reach into another
	# panel's script for it). One difference from VS's entry-fee pad: a "."
	# key instead of "00" — a donation is realistically a fractional NIM
	# amount, not a round hundred like an entry fee.
	var amount_buf := ["0"]   # boxed so the keypad closures below can
							   # mutate it by reference — same trick
							   # VSPanel's custom_buf uses
	var amount_val := [0.0]

	var amount_field := Button.new()
	amount_field.text = ""
	amount_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	amount_field.custom_minimum_size = Vector2(0, ref * 0.072)
	var afield_st := StyleBoxFlat.new()
	afield_st.bg_color = Color(1.0, 0.98, 0.94, 0.9)
	afield_st.border_color = Color(_C_ORANGE.r, _C_ORANGE.g, _C_ORANGE.b, 0.30)
	afield_st.set_border_width_all(2)
	afield_st.set_corner_radius_all(10)
	afield_st.content_margin_left   = ref * 0.020
	afield_st.content_margin_right  = ref * 0.020
	var afield_st_active := afield_st.duplicate()
	afield_st_active.border_color = _C_ORANGE
	amount_field.add_theme_stylebox_override("normal",  afield_st)
	amount_field.add_theme_stylebox_override("hover",   afield_st_active)
	amount_field.add_theme_stylebox_override("pressed", afield_st_active)
	amount_field.add_theme_stylebox_override("focus",   afield_st)
	form.add_child(amount_field)

	# BUG FIX (same as VSPanel's entry_field): a plain FULL_RECT anchor
	# ignores afield_st's content_margin entirely (that only applies to a
	# Button's own auto-laid-out text, not to manually added children) — a
	# MarginContainer with the same margins is what actually pads the icon
	# and label inside the rounded border.
	var afield_margin := _mpad(int(afield_st.content_margin_left))
	afield_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	afield_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	amount_field.add_child(afield_margin)

	var afield_row := HBoxContainer.new()
	afield_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	afield_row.add_theme_constant_override("separation", int(ref * 0.012))
	afield_margin.add_child(afield_row)

	var afield_icon_wrap := CenterContainer.new()
	afield_row.add_child(afield_icon_wrap)
	afield_icon_wrap.add_child(_make_nim_icon(int(ref * 0.036)))

	var afield_lbl := Label.new()
	afield_lbl.text = "Tap to enter an amount"
	afield_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	afield_lbl.clip_text = true
	UITheme.apply_label(afield_lbl, _C_MID, int(ref * 0.026))
	afield_row.add_child(afield_lbl)

	var refresh_amount_field := func():
		if amount_buf[0] == "" or amount_buf[0] == "0":
			afield_lbl.text = "Tap to enter an amount"
			afield_lbl.add_theme_color_override("font_color", _C_MID)
		else:
			afield_lbl.text = "%s NIM" % amount_buf[0]
			afield_lbl.add_theme_color_override("font_color", _C_BROWN)

	# Message field stays a real LineEdit — it's free text, and the custom
	# numeric keypad above doesn't make sense for arbitrary typing, so this
	# still opens the normal OS keyboard. Just reskinned to match the amount
	# field's exact colors/border/corner-radius (same afield_st/afield_st_
	# active resources, duplicated only to add vertical padding a LineEdit
	# needs that a Button doesn't) so the two fields read as one consistent
	# input style instead of two different-looking bars.
	var mfield_st := afield_st.duplicate()
	mfield_st.content_margin_top    = ref * 0.014
	mfield_st.content_margin_bottom = ref * 0.014
	var mfield_st_active := afield_st_active.duplicate()
	mfield_st_active.content_margin_top    = ref * 0.014
	mfield_st_active.content_margin_bottom = ref * 0.014

	var msg_edit := LineEdit.new()
	msg_edit.placeholder_text = "Message (optional)"
	msg_edit.custom_minimum_size = Vector2(0, ref * 0.072)
	msg_edit.add_theme_stylebox_override("normal", mfield_st)
	msg_edit.add_theme_stylebox_override("focus",  mfield_st_active)
	msg_edit.add_theme_font_size_override("font_size", int(ref * 0.026))
	msg_edit.add_theme_color_override("font_color",             _C_BROWN)
	msg_edit.add_theme_color_override("font_placeholder_color", _C_MID)
	msg_edit.add_theme_color_override("caret_color",            _C_ORANGE)
	UITheme._apply_pixel_font(msg_edit)
	form.add_child(msg_edit)

	var memo_preview := Label.new()
	memo_preview.text = _MEMO_PREFIX
	memo_preview.autowrap_mode = TextServer.AUTOWRAP_WORD
	UITheme.apply_label(memo_preview, _C_MID, int(ref * 0.020))
	form.add_child(memo_preview)

	# 64-byte UTF-8 memo hard limit (Nimiq extended-tx recipient_data — see
	# backend/game/nimiq.go's nimiqBuildAndSignTx doc comment, same limit
	# VSPanel's entry-fee memo respects). Prefix alone is fixed-cost; the
	# message gets whatever's left, truncated on the actual byte length
	# (not char count, so it's correct for non-ASCII input too).
	var prefix_bytes := _MEMO_PREFIX.to_utf8_buffer().size()
	msg_edit.text_changed.connect(func(t: String):
		var budget := 64 - prefix_bytes
		var trimmed := t
		while trimmed.to_utf8_buffer().size() > budget:
			trimmed = trimmed.substr(0, trimmed.length() - 1)
		if trimmed != t:
			msg_edit.text = trimmed
			msg_edit.caret_column = trimmed.length()
		memo_preview.text = _MEMO_PREFIX + trimmed
	)

	var send_btn := Button.new()
	send_btn.text = "Send"
	send_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	send_btn.custom_minimum_size = Vector2(0, ref * 0.080)
	send_btn.add_theme_font_size_override("font_size", int(ref * 0.034))
	_warm_btn(send_btn, 8)
	form.add_child(send_btn)

	# ── Bottom-docked keypad sheet ───────────────────────────────────
	# Built directly under _panel_ctrl (not inside `form`) so it docks to
	# the actual bottom edge of the profile card regardless of where `form`
	# has scrolled to — same reasoning as VSPanel's _entry_sheet_root.
	# _teardown_donate_sheet() (called wherever _content gets rebuilt, see
	# above) frees this so it never leaks behind on the next open_profile().
	if is_instance_valid(_donate_sheet_root):
		_donate_sheet_root.queue_free()
		_donate_sheet_root = null

	var sheet_wrap := Control.new()
	sheet_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_ctrl.add_child(sheet_wrap)
	_donate_sheet_root = sheet_wrap

	var sheet_dim := ColorRect.new()
	sheet_dim.color = Color(0, 0, 0, 0.45)
	sheet_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet_dim.modulate.a = 0.0
	sheet_wrap.add_child(sheet_dim)

	# The sheet stays visible=true always and is instead slid fully off the
	# bottom of the screen when "closed" (toggling .visible has no in-between
	# frames to animate) — same trick VSPanel's sheet uses.
	var sheet_hidden_off := ref * 3.0
	var sheet := PanelContainer.new()
	sheet.anchor_left = 0.0; sheet.anchor_right = 1.0
	sheet.anchor_top  = 1.0; sheet.anchor_bottom = 1.0
	sheet.grow_vertical = Control.GROW_DIRECTION_BEGIN
	sheet.offset_left = 0; sheet.offset_right = 0
	sheet.offset_top  = sheet_hidden_off; sheet.offset_bottom = sheet_hidden_off
	var sheet_st := StyleBoxFlat.new()
	sheet_st.bg_color     = _C_CARD
	sheet_st.border_color = _C_BORDER
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

	# Drag-handle bar — purely visual (nothing here is actually draggable),
	# same as VSPanel's, to read as "a keyboard sliding up."
	var handle_wrap := CenterContainer.new()
	sheet_vb.add_child(handle_wrap)
	var handle := ColorRect.new()
	handle.color = Color(_C_BORDER.r, _C_BORDER.g, _C_BORDER.b, 0.45)
	handle.custom_minimum_size = Vector2(ref * 0.11, ref * 0.010)
	handle_wrap.add_child(handle)

	var sheet_header := HBoxContainer.new()
	sheet_header.add_theme_constant_override("separation", int(ref * 0.012))
	sheet_vb.add_child(sheet_header)
	var sheet_title := Label.new()
	sheet_title.text = "Enter Amount"
	sheet_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(sheet_title, _C_BROWN, int(ref * 0.032))
	sheet_header.add_child(sheet_title)
	var done_btn := Button.new()
	done_btn.text = "Done"
	done_btn.custom_minimum_size = Vector2(int(ref * 0.16), int(ref * 0.056))
	_warm_btn(done_btn, 10)
	sheet_header.add_child(done_btn)

	# Display — reads like a real input even though nothing here is an
	# editable LineEdit; populated entirely by the keypad below.
	var display_card := PanelContainer.new()
	var display_st := StyleBoxFlat.new()
	display_st.bg_color = Color(1.0, 0.98, 0.94, 0.9)
	display_st.border_color = _C_ORANGE
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
	custom_display.text = "0"
	custom_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_display.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	custom_display.clip_text = true
	UITheme.apply_label(custom_display, _C_BROWN, int(ref * 0.052))
	display_row.add_child(custom_display)

	var nim_chip := PanelContainer.new()
	var nim_chip_st := StyleBoxFlat.new()
	nim_chip_st.bg_color = Color(_C_BORDER.r, _C_BORDER.g, _C_BORDER.b, 0.30)
	nim_chip_st.set_corner_radius_all(8)
	nim_chip_st.content_margin_left   = ref * 0.018
	nim_chip_st.content_margin_right  = ref * 0.018
	nim_chip_st.content_margin_top    = ref * 0.008
	nim_chip_st.content_margin_bottom = ref * 0.008
	nim_chip.add_theme_stylebox_override("panel", nim_chip_st)
	display_row.add_child(nim_chip)
	var nim_chip_lbl := Label.new()
	nim_chip_lbl.text = "NIM"
	UITheme.apply_label(nim_chip_lbl, _C_MID, int(ref * 0.022))
	nim_chip.add_child(nim_chip_lbl)

	var refresh_display := func():
		custom_display.text = amount_buf[0] if amount_buf[0] != "" else "0"

	# Shared key handler — used by BOTH the on-screen keypad buttons and the
	# physical keyboard (see _input). `k` is a digit "0".."9", ".", or "back".
	var apply_key := func(k: String):
		if k == "back":
			if amount_buf[0].length() > 0:
				amount_buf[0] = amount_buf[0].substr(0, amount_buf[0].length() - 1)
		elif k == ".":
			if amount_buf[0] == "":
				amount_buf[0] = "0."
			elif not amount_buf[0].contains("."):
				amount_buf[0] += "."
		else:
			# Avoid a useless leading "0" (typing 5 after 0 → "5" not "05").
			if amount_buf[0] == "0":
				amount_buf[0] = k
			else:
				amount_buf[0] += k
		amount_val[0] = maxf(amount_buf[0].to_float(), 0.0)
		refresh_display.call()
		refresh_amount_field.call()
	_donate_apply_key = apply_key   # let physical-keyboard _input reach it

	var keypad := GridContainer.new()
	keypad.columns = 3
	keypad.add_theme_constant_override("h_separation", int(ref * 0.014))
	keypad.add_theme_constant_override("v_separation", int(ref * 0.014))
	sheet_vb.add_child(keypad)

	var key_h := int(ref * 0.086)
	var keypad_keys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "back"]
	for key in keypad_keys:
		var kbtn := Button.new()
		kbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kbtn.custom_minimum_size.y = key_h
		keypad.add_child(kbtn)
		if key == "back":
			var back_st := StyleBoxFlat.new()
			back_st.bg_color = Color(_C_RED.r, _C_RED.g, _C_RED.b, 0.16)
			back_st.set_corner_radius_all(10)
			var back_st_h := back_st.duplicate()
			back_st_h.bg_color.a = 0.26
			kbtn.add_theme_stylebox_override("normal",  back_st)
			kbtn.add_theme_stylebox_override("hover",   back_st_h)
			kbtn.add_theme_stylebox_override("pressed", back_st_h)
			var bk_center := CenterContainer.new()
			bk_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			bk_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
			kbtn.add_child(bk_center)
			bk_center.add_child(UITheme.lucide_icon("x", int(ref * 0.034), _C_RED))
		else:
			_warm_btn(kbtn, 10)
			kbtn.text = key
			kbtn.add_theme_font_size_override("font_size", int(ref * 0.040))
		kbtn.pressed.connect(func(): apply_key.call(key))

	# Boxed Tween reference so open/close can kill an in-flight slide
	# animation before starting the next one.
	var sheet_tween := [null]
	var kill_sheet_tween := func():
		if sheet_tween[0] != null and is_instance_valid(sheet_tween[0]):
			sheet_tween[0].kill()
		sheet_tween[0] = null

	# BUG FIX: same class of bug as the main bottom bar / replay bar — this
	# sheet used to animate flush to offset_bottom=0.0 with no
	# _safe_area_bottom allowance. On an Android WebView with an on-screen
	# gesture/nav bar, any buttons near the sheet's bottom edge (donate
	# amount buttons, confirm button, etc.) could end up partly or fully
	# under the nav bar, unreachable. This panel is always instantiated as
	# a direct child of Main (see Main.gd: add_child(_profile_card_panel)),
	# so get_parent() reliably reaches it without assuming a node name —
	# if that relationship ever changes, or Main hasn't computed a value
	# yet, this safely falls back to 0 (no shift), same as every other
	# consumer of this value.
	var _sheet_sab := 0.0
	var _main_node := get_parent()
	if _main_node != null and "_safe_area_bottom" in _main_node:
		_sheet_sab = _main_node._safe_area_bottom

	var open_sheet := func():
		_donate_sheet_open = true
		kill_sheet_tween.call()
		sheet_dim.mouse_filter = Control.MOUSE_FILTER_STOP
		var t := create_tween()
		sheet_tween[0] = t
		t.set_parallel(true)
		t.tween_property(sheet_dim, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(sheet, "offset_top",    -_sheet_sab, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(sheet, "offset_bottom", -_sheet_sab, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var close_sheet := func():
		_donate_sheet_open = false
		sheet_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kill_sheet_tween.call()
		var t := create_tween()
		sheet_tween[0] = t
		t.set_parallel(true)
		t.tween_property(sheet_dim, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_QUAD)
		t.tween_property(sheet, "offset_top",    sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_property(sheet, "offset_bottom", sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_donate_close = close_sheet   # let the Enter key (see _input) close it

	done_btn.pressed.connect(func(): close_sheet.call())
	# Tapping the dim scrim dismisses it too, same as tapping outside a real
	# on-screen keyboard — it just closes, it doesn't discard the amount.
	sheet_dim.gui_input.connect(func(e):
		# Close on RELEASE not press — see LeaderboardPanel.gd's dim handler
		# for the full explanation (press-triggered close lets the release
		# half of the same tap leak through onto whatever's now exposed).
		if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			close_sheet.call()
	)

	amount_field.pressed.connect(func(): open_sheet.call())

	toggle_btn.pressed.connect(func():
		form.visible = not form.visible
		toggle_btn.text = "Cancel" if form.visible else "Donate"
		if not form.visible:
			close_sheet.call()
		_fit_panel_height()
	)

	send_btn.pressed.connect(func():
		_do_send_donation(target_address, amount_val, func():
			amount_buf[0] = "0"
			refresh_display.call()
			refresh_amount_field.call()
		, msg_edit, send_btn)
	)

	return {"toggle": toggle_btn, "form": form}


## Direct wallet-to-wallet send via the Nimiq provider/Hub — same
## NimiqJS.request_payment() channel VSPanel uses for entry fees, called
## here with no backend round-trip before or after. The memo IS the
## message; there's no separate "confirm" step because there's nothing
## server-side that needs to know this happened.
func _do_send_donation(target_address: String, amount_val: Array, reset_amount: Callable, msg_edit: LineEdit, btn: Button) -> void:
	var amount_nim : float = amount_val[0]
	if amount_nim <= 0.0:
		Toast.get_instance().show_toast("Enter an amount to send.", Toast.Kind.WARN)
		return
	if target_address == "":
		return

	var memo := _MEMO_PREFIX + msg_edit.text
	if memo.to_utf8_buffer().size() > 64:
		# Should already be impossible given the live-truncation above, but
		# never send something the wallet/backend would reject outright.
		memo = _MEMO_PREFIX
	var value_luna := int(round(amount_nim * 100000.0))  # NimLunaMultiplier — 1 NIM = 100000 luna

	var prev_text := btn.text
	btn.disabled = true
	btn.text = "Waiting for wallet..."

	var result : Dictionary = await NimiqJS.request_payment(target_address, value_luna, memo)

	if not is_instance_valid(btn): return  # panel may have closed mid-approval
	btn.disabled = false
	btn.text = prev_text

	if not bool(result.get("ok", false)):
		Toast.get_instance().show_toast("Send failed: " + str(result.get("err", "unknown")), Toast.Kind.ERROR)
		return

	reset_amount.call()
	msg_edit.text = ""
	Toast.get_instance().show_toast("Sent %.2f NIM!" % amount_nim, Toast.Kind.SUCCESS)


## Gold XP progress bar — same rounded-corner/resize-safe construction as
## StatsPanel's _add_level_bar, local copy so this panel doesn't reach into
## another panel's script for it. Fixed gold fill color; max level is
## handled by the caller passing pct=1.0.
func _add_level_bar(vbox: VBoxContainer, pct: float, ref: float) -> void:
	var fill_col := _C_GOLD
	var bar_h    := int(ref * 0.022)
	const CORNER := 3

	var bar_outer := Control.new()
	bar_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_outer.custom_minimum_size   = Vector2(0, bar_h)
	bar_outer.clip_contents         = true
	vbox.add_child(bar_outer)

	var bg := ColorRect.new()
	bg.color = Color(0.780, 0.650, 0.500)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar_outer.add_child(bg)

	var fill := ColorRect.new()
	fill.color    = fill_col
	fill.position = Vector2(CORNER, CORNER)
	fill.size     = Vector2(0, bar_h - CORNER * 2)
	bar_outer.add_child(fill)

	var c_tl := ColorRect.new(); c_tl.color = _C_CARD
	var c_tr := ColorRect.new(); c_tr.color = _C_CARD
	var c_bl := ColorRect.new(); c_bl.color = _C_CARD
	var c_br := ColorRect.new(); c_br.color = _C_CARD
	for c in [c_tl, c_tr, c_bl, c_br]:
		c.size = Vector2(CORNER, CORNER)
		bar_outer.add_child(c)

	var _apply := func():
		var w := bar_outer.size.x
		if w <= 0: return
		fill.size.x  = maxf((w - CORNER * 2) * pct, 0.0)
		c_tl.position = Vector2(0,          0)
		c_bl.position = Vector2(0,          bar_h - CORNER)
		c_tr.position = Vector2(w - CORNER, 0)
		c_br.position = Vector2(w - CORNER, bar_h - CORNER)

	bar_outer.resized.connect(_apply)
	bar_outer.draw.connect(func():
		if bar_outer.size.x > 0: _apply.call()
	)
	bar_outer.queue_redraw()


func _fmt_ticks(ticks: int) -> String:
	if ticks <= 0: return "0s"
	var secs := ticks / 60
	if secs >= 60:
		return "%dm %02ds" % [secs / 60, secs % 60]
	return "%ds" % secs


func _fmt_last_seen(ts: int) -> String:
	if ts <= 0: return "-"
	var now := int(Time.get_unix_time_from_system())
	var diff := now - ts
	if diff < 60: return "Just now"
	if diff < 3600: return "%dm ago" % (diff / 60)
	if diff < 86400: return "%dh ago" % (diff / 3600)
	return "%dd ago" % (diff / 86400)


## Deterministic colored-circle-with-initial avatar — same generation logic
## as LeaderboardPanel._make_fallback_avatar / VSPanel's own copy / Main.gd's
## own copy (this codebase already keeps one small copy per panel rather
## than a shared singleton — see Main.gd's doc comment near its own copy —
## so this follows the existing convention instead of introducing a new
## shared-dependency pattern on its own).
func _make_nimiq_avatar(address: String, size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode    = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode   = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = Control.TEXTURE_FILTER_LINEAR
	# Always draw fallback avatar (visible immediately)
	tr.texture = _make_fallback_avatar(address, size)
	# If on web, load real Nimiq avatar on top — same two-stage approach
	# (instant fallback letter-avatar, then swap to the real identicon once
	# it loads) as LeaderboardPanel/VSPanel's _make_nimiq_avatar.
	if OS.has_feature("web") and address != "" and address != "null" and address != "undefined":
		_load_nimiq_avatar_async(tr, address, size)
	return tr


func _make_fallback_avatar(address: String, size: int) -> ImageTexture:
	var cache_key := address + "@" + str(size)
	if _avatar_tex_cache.has(cache_key): return _avatar_tex_cache[cache_key]
	const PALETTE := [
		Color(0.13, 0.60, 0.90), Color(0.40, 0.78, 0.22), Color(0.96, 0.65, 0.14),
		Color(0.82, 0.28, 0.28), Color(0.60, 0.35, 0.85), Color(0.20, 0.72, 0.65),
		Color(0.95, 0.38, 0.60), Color(0.45, 0.55, 0.70),
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
	var ps := maxi(1, size / 8)
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


## Real Nimiq wallet avatar fetch — same JS bridge / polling approach as
## LeaderboardPanel._load_nimiq_avatar_async, local copy so this panel
## doesn't reach into another panel's script for it. Swaps the fallback
## letter-avatar for the real identicon once it loads (web only).
func _load_nimiq_avatar_async(target: Control, address: String, size: int) -> void:
	if not OS.has_feature("web"): return
	var key := "avatar_" + address.left(8).validate_node_name()

	# Wait if Identicons CDN not yet loaded (max 3 seconds)
	for _w in 30:
		var ready = JavaScriptBridge.eval("window._nimiqIconsReady === true", true)
		if ready: break
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(target): return

	# SECURITY: JSON.stringify()'d before splicing into the JS literal (same
	# pattern as LeaderboardPanel/NimiqJS.gd) instead of naive string concat.
	var js_addr := JSON.stringify(address)
	var js_key := JSON.stringify(key)
	var js_code := (
		"(function(){"
		+ "if(!window._nimiqPending) window._nimiqPending = {};"
		+ "window._nimiqPending[" + js_key + "] = null;"
		+ "if(typeof window.getNimiqAvatar !== 'function'){"
		+ "  console.warn('[Avatar] not ready');"
		+ "  window._nimiqPending[" + js_key + "] = ''; return;"
		+ "}"
		+ "window.getNimiqAvatar(" + js_addr + ")"
		+ "  .then(function(svgData){"
		+ "    if(!svgData){ window._nimiqPending[" + js_key + "] = ''; return; }"
		+ "    var img = new Image();"
		+ "    img.onload = function(){"
		+ "      try {"
		+ "        var c = document.createElement('canvas');"
		+ "        c.width = " + str(size) + "; c.height = " + str(size) + ";"
		+ "        c.getContext('2d').drawImage(img, 0, 0, " + str(size) + ", " + str(size) + ");"
		+ "        window._nimiqPending[" + js_key + "] = c.toDataURL('image/png');"
		+ "      } catch(e){ window._nimiqPending[" + js_key + "] = ''; }"
		+ "    };"
		+ "    img.onerror = function(){ window._nimiqPending[" + js_key + "] = ''; };"
		+ "    img.src = svgData;"
		+ "  })"
		+ "  .catch(function(e){ console.warn('[Avatar] err:',e); window._nimiqPending[" + js_key + "] = ''; });"
		+ "})();"
	)
	JavaScriptBridge.eval(js_code, true)
	for _i in 50:
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(target): return
		var raw = JavaScriptBridge.eval("window._nimiqPending[%s]" % js_key, true)
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


## ── Warm bej buton helper — same close-button visual language as
## LeaderboardPanel/VSPanel (_warm_btn / _close_btn_style), local copy so
## this panel doesn't need to reach into another panel script for it.
static func _warm_btn(btn: Button, r: float = 8.0) -> void:
	var ri := int(r)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new(); var sd := StyleBoxFlat.new()
	for s in [sn, sh, sp, sd]:
		s.corner_radius_top_left = ri; s.corner_radius_top_right = ri
		s.corner_radius_bottom_left = ri; s.corner_radius_bottom_right = ri
	sn.bg_color = Color(0.780, 0.380, 0.120)
	sh.bg_color = Color(0.820, 0.450, 0.160)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	sd.bg_color = Color(0.720, 0.660, 0.580)
	btn.add_theme_stylebox_override("normal",   sn)
	btn.add_theme_stylebox_override("hover",    sh)
	btn.add_theme_stylebox_override("pressed",  sp)
	btn.add_theme_stylebox_override("disabled", sd)
	btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
	btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
	btn.add_theme_color_override("font_disabled_color", Color(0.480, 0.420, 0.360))


## Small circular icon button for inline row actions ("watch replay") — same
## outlined-terracotta-at-rest, solid-fill-on-hover look as StatsPanel's
## _replay_icon_btn, local copy so this panel doesn't reach into another
## panel's script for it.
## Small NIM coin icon — same asset/construction as VSPanel's own
## _make_nim_icon, local copy so this panel doesn't reach into another
## panel's script for it.
static func _make_nim_icon(size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load("res://assets/items/nimiq_hexagon_item.png") as Texture2D
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tr.custom_minimum_size = Vector2(size, size)
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return tr


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
	btn.add_theme_color_override("icon_normal_color",  _C_ORANGE)
	btn.add_theme_color_override("icon_hover_color",   _C_BG)
	btn.add_theme_color_override("icon_pressed_color", _C_BG)
	btn.add_theme_color_override("font_color",         _C_ORANGE)
	btn.add_theme_color_override("font_hover_color",   _C_BG)
	btn.add_theme_color_override("font_pressed_color", _C_BG)
	btn.tooltip_text = "Watch replay"
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## Fixed-margin box, same helper StatsPanel uses (_mpad) for card/row padding.
func _mpad(m: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   m)
	mc.add_theme_constant_override("margin_right",  m)
	mc.add_theme_constant_override("margin_top",    m)
	mc.add_theme_constant_override("margin_bottom", m)
	return mc


## Column label for a table-style row, same helper/sizing as StatsPanel's
## _col_lbl so the Recent Matches columns line up exactly like Recent Games.
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
