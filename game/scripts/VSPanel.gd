extends CanvasLayer
## VSPanel.gd — Async 1v1 "VS" challenge rooms: create/join, optional NIM
## entry fee, pay → play → wait → settle. Reuses the same visual language as
## QuestPanel/StatsPanel (UITheme, warm-bej cards) per design direction.
##
## Flow reminder (see backend/game/vsroom.go for the authoritative state
## machine): create room (pay if entry>0) → play your round (fixed seed) →
## share invite link → opponent joins, pays, plays → whoever finishes last
## (or the 24h sweep) settles the pot. The room list/detail views here are
## just HTTP polling.

signal closed
signal connect_requested   # emitted when user taps Connect in the not-signed-in state
signal play_requested(room_id: String, role: String, seed: String)
signal replay_requested(seed: int, replay_log: PackedByteArray, char_idx: int, nickname: String, player_seed: int, address: String, gyro_active: bool)

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
var _entry_apply_key : Callable = Callable()  # keypad key handler; physical
                                              # keyboard input is routed here too
var _entry_close     : Callable = Callable()  # closes the keypad sheet (Enter key)
var _entry_sheet_open := false                # true while the keypad sheet is open


# Physical-keyboard support for the entry-fee keypad (desktop): while the sheet
# is open, number keys type into it, Backspace deletes, Enter confirms/closes —
# exactly like tapping the on-screen keys.
func _input(event: InputEvent) -> void:
	if not _entry_sheet_open or not _entry_apply_key.is_valid():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# NOTE: this script extends CanvasLayer (not Control), so accept_event() —
	# a Control-only method — is unavailable. Mark the key handled via the
	# viewport instead so it doesn't leak to the game underneath.
	var vp := get_viewport()
	var kc : int = event.keycode
	if kc == KEY_BACKSPACE or kc == KEY_DELETE:
		_entry_apply_key.call("back"); vp.set_input_as_handled()
	elif kc >= KEY_0 and kc <= KEY_9:
		_entry_apply_key.call(str(kc - KEY_0)); vp.set_input_as_handled()
	elif kc >= KEY_KP_0 and kc <= KEY_KP_9:
		_entry_apply_key.call(str(kc - KEY_KP_0)); vp.set_input_as_handled()
	elif (kc == KEY_ENTER or kc == KEY_KP_ENTER) and _entry_close.is_valid():
		_entry_close.call(); vp.set_input_as_handled()
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

const _MINE_PAGE_SIZE := 5
const _OPEN_PAGE_SIZE := 5   # public "Open Challenges" browse list — 5 per page

var _rooms_cache : Array = []
var _current_room : Dictionary = {}
var _detail_timer : Timer = null
var _pending_open_room_id : String = ""   # deep-link target, applied once auth is ready
var _viewing_room_id : String = ""        # room whose detail is on screen (set BEFORE its
                                          # fetch resolves) so late auth/player-id syncs don't
                                          # re-render the list on top of an opening detail view
var _avatar_tex_cache : Dictionary = {}   # address+size key → fallback ImageTexture
var _nimiq_avatar_cache : Dictionary = {} # address+size key → REAL loaded identicon ImageTexture
                                          # (so a poll-driven re-render reuses it instead of
                                          # flashing the fallback + re-loading it every 4s)


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
	# Single source of truth — see UITheme.display_name (nickname if real, else
	# the shared short-address form). Kept as a thin wrapper so existing call
	# sites in this panel don't all have to change.
	return UITheme.display_name(nickname, address)


## Shareable invite link built from the CLIENT's own resolved game URL
## (ApiConfig.game_url — window.NJ_GAME_URL_BASE or the compiled prod URL), so
## it always points at wherever the game is ACTUALLY served, obeying the same
## global game-URL rule everything else uses — instead of the backend's
## possibly-stale GAME_URL env fallback (which was hard-defaulting to nimjump.io).
## Falls back to the backend's invite_url only if the short code is missing.
func _room_invite_url(r: Dictionary) -> String:
	var base := ApiConfig.game_url().strip_edges()
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	var short_code := str(r.get("short_code", ""))
	if base != "" and short_code != "":
		return base + "?vs=" + short_code
	# Fallback: the backend invite_url carries the correct "?vs=CODE" query, but
	# its HOST is the backend's GAME_URL env default (nimjump.io) — swap that host
	# for the client's own resolved game URL so the link never leaks nimjump.io.
	var backend_url := str(r.get("invite_url", ""))
	if base != "":
		var q := backend_url.find("?")
		if q >= 0:
			return base + backend_url.substr(q)
		return base
	return backend_url


## Copy the invite URL to the clipboard (web-aware) and toast a confirmation.
func _copy_invite_link(url: String) -> void:
	if url == "":
		return
	if OS.has_feature("web"):
		var js := "try{navigator.clipboard.writeText(%s);}catch(e){}" % JSON.stringify(url)
		JavaScriptBridge.eval(js, true)
	else:
		DisplayServer.clipboard_set(url)
	var t := Toast.get_instance()
	if t: t.show_toast("Invite link copied!", Toast.Kind.SUCCESS)


func setup(player_id: String) -> void:
	_player_id = player_id
	_build_ui()
	hide()


func set_auth_token(token: String) -> void:
	var got_token := _auth_token == "" and token != ""
	_auth_token = token
	if token != "" and _pending_open_room_id != "":
		var rid := _pending_open_room_id
		_pending_open_room_id = ""
		print("[VSDEEPLINK] set_auth_token consuming pending id=%s visible=%s" % [rid, str(visible)])
		_show_room_detail(rid)
		return
	# Just became authed while the panel is open on the "connect" prompt — swap
	# it out for the real list NOW. This is the right moment (not set_player_id):
	# _sync_panels calls set_player_id first, THEN set_auth_token, and the "my
	# matches" fetch needs the token — so re-rendering here guarantees it's
	# present. Guarded to the list view (_current_room empty) so a mid-session
	# token refresh while viewing a room detail never kicks the user out.
	if got_token and _player_id != "" and is_instance_valid(_view_root) and visible and _current_room.is_empty() and _viewing_room_id == "":
		_show_room_list()

func set_auth_attempted(v: bool) -> void:
	_auth_attempted = v

func set_has_wallet(v: bool) -> void:
	_has_wallet = v

func set_player_id(player_id: String) -> void:
	var became_connected := _player_id == "" and player_id != ""
	_player_id = player_id
	# Only re-render here if we ALREADY have a token (account switch mid-session);
	# the normal connect case re-renders in set_auth_token once the token lands
	# (see there for why that's the correct moment).
	if became_connected and _auth_token != "" and is_instance_valid(_view_root) and visible and _current_room.is_empty() and _viewing_room_id == "":
		_show_room_list()


## Called by Main._check_vsroom_deeplink() — jump straight to a room's detail
## view once the panel is open (waits for auth if needed).
func open_room(room_id: String) -> void:
	print("[VSDEEPLINK] open_room id=%s auth=%s player=%s visible=%s" % [room_id, str(_auth_token != ""), str(_player_id != ""), str(visible)])
	if _auth_token == "":
		_pending_open_room_id = room_id
		return
	_show_room_detail(room_id)


# ── Panel open / close (same pattern as QuestPanel) ─────────────────────────
func show_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	if is_instance_valid(_panel_ctrl):
		# BUG FIX ("panel pops in from the top-left corner"): _panel_ctrl is a
		# PRESET_FULL_RECT node (spans the whole screen — the actual visible
		# dialog is a centered child of it), and Control scale animates around
		# pivot_offset, which defaults to (0,0) — the top-left of that
		# full-screen rect, not the center of the visible dialog sitting
		# inside it. Scaling from 0.92→1.0 around that corner makes the
		# on-screen dialog visibly grow from/shrink toward the top-left of
		# the SCREEN instead of its own center. Setting pivot_offset to the
		# rect's own center fixes this — same fix applied identically in
		# QuestPanel/LeaderboardPanel/StatsPanel/StreakPanel/CustomizePanel.
		_panel_ctrl.pivot_offset = _panel_ctrl.size * 0.5
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
	# BUG FIX: hide() used to only run inside a tween.chain().tween_callback()
	# fired after the fade-out finished. If hide_panel() got called again
	# before that fired, .kill() above stops the tween WITHOUT running its
	# chained callback, so hide() never ran — this CanvasLayer (with its
	# full-rect, input-blocking dim layer) stayed stuck on top of the lobby.
	# Fix: hide immediately/synchronously, treat the fade as pure decoration.
	hide()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 1.0
		_panel_ctrl.scale      = Vector2.ONE


# ── UI shell ─────────────────────────────────────────────────────────────────
var _title_lbl : Label
var _back_btn  : Button
var _header_icon : Control   # the "target" icon; hidden in detail view (back btn takes its place)

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
		# Close only on a real LEFT click on the backdrop — NOT on wheel scroll.
		# On desktop the mouse wheel fires InputEventMouseButton (WHEEL_UP/DOWN,
		# pressed=true) too, so the old "any button pressed" check slammed the
		# panel shut the moment the user tried to scroll ("scrolladım UI kapandı").
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
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

	# Back button — was a faint translucent "<" that read as barely-there.
	# Now a solid, properly-sized button with a real chevron icon so it's an
	# obvious tap target, sitting symmetrically opposite the close X.
	var back_sz    := int(ref * 0.092)
	var back_ic_sz := int(back_sz * 0.70)   # match the close X's icon weight
	_back_btn = Button.new()
	_back_btn.custom_minimum_size = Vector2(back_sz, back_sz)
	_back_btn.visible = false
	# Match the close (X) button's vivid-orange style so the two header controls
	# read as a clean symmetric pair, instead of the muddy dull-brown square the
	# back button used to be.
	_close_btn_style(_back_btn, 8)
	_back_btn.pressed.connect(_show_room_list)
	var back_center := CenterContainer.new()
	back_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back_btn.add_child(back_center)
	var back_icon := UITheme.lucide_icon("arrow-left", back_ic_sz, Color(0.980, 0.955, 0.910))
	back_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back_center.add_child(back_icon)
	hdr.add_child(_back_btn)

	_header_icon = UITheme.lucide_icon("target", int(ref * 0.038), _COL_ICON)
	hdr.add_child(_header_icon)

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


## Secondary "Load more" / small-action style — on-theme: the game's pixel font
## (like every other button), a soft warm-cream fill with a thin warm border,
## and dark-brown text. Reads as a real, tidy secondary button that matches the
## panel's cards instead of the off-theme default-font outline it was before.
func _load_more_btn_style(btn: Button) -> void:
	var _border := Color(0.700, 0.520, 0.340, 0.55)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.set_corner_radius_all(10)
		s.set_border_width_all(1)
		s.border_color = _border
	sn.bg_color = Color(0.968, 0.930, 0.858)
	sh.bg_color = Color(0.940, 0.892, 0.808)
	sp.bg_color = Color(0.905, 0.850, 0.760)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	UITheme._apply_pixel_font(btn)
	btn.add_theme_color_override("font_color",         _COL_TEXT_DARK)
	btn.add_theme_color_override("font_hover_color",   _COL_TEXT_DARK)
	btn.add_theme_color_override("font_pressed_color", _COL_TEXT_DARK)
	btn.flat = false


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


## Solid warm-brown back-button style — clearly visible (unlike the old
## translucent _warm_btn tone) but calmer than the vivid orange close X, so
## the two header buttons read as "secondary back" vs "primary close".
func _back_btn_style(btn: Button, corner: int) -> void:
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]:
		s.set_corner_radius_all(corner)
	sn.bg_color = Color(0.700, 0.520, 0.340)
	sh.bg_color = Color(0.760, 0.580, 0.400)
	sp.bg_color = Color(0.620, 0.450, 0.290)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
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
	# The keypad sheet (and its key handlers) belong to the view being torn down.
	_entry_sheet_open = false
	_entry_apply_key = Callable()
	_entry_close = Callable()
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
	_viewing_room_id = ""
	_back_btn.visible = false
	if is_instance_valid(_header_icon): _header_icon.visible = true
	_title_lbl.text = "VS"
	_clear_view()
	var ref := _ref()

	if _player_id == "":
		# Same "not signed in" scheme as the Statistics panel: a single centered
		# line in mid-brown + the standard warm Connect Wallet button (no icon).
		var box := VBoxContainer.new()
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", int(ref * 0.020))
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_view_root.add_child(box)

		var lbl := Label.new()
		lbl.text = "Connect your wallet to play VS matches"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(lbl, _COL_TEXT_MID, int(ref * 0.030))
		box.add_child(lbl)

		var conn_btn := Button.new()
		conn_btn.text = "Connect Wallet"
		conn_btn.custom_minimum_size = Vector2(ref * 0.55, ref * 0.080)
		conn_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		conn_btn.add_theme_font_size_override("font_size", int(ref * 0.034))
		# Solid-orange primary button, IDENTICAL to the Statistics/Quests panels'
		# Connect Wallet button (VSPanel's own _warm_btn is a faint translucent
		# tan tone used for secondary controls, which is why this one looked
		# washed-out and different before — inline the shared orange scheme).
		var _cn := StyleBoxFlat.new(); var _ch := StyleBoxFlat.new(); var _cp := StyleBoxFlat.new()
		for _s in [_cn, _ch, _cp]:
			_s.set_corner_radius_all(8)
		_cn.bg_color = Color(0.780, 0.380, 0.120)
		_ch.bg_color = Color(0.820, 0.450, 0.160)
		_cp.bg_color = Color(0.640, 0.300, 0.080)
		conn_btn.add_theme_stylebox_override("normal",  _cn)
		conn_btn.add_theme_stylebox_override("hover",   _ch)
		conn_btn.add_theme_stylebox_override("pressed", _cp)
		conn_btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
		conn_btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
		conn_btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
		conn_btn.pressed.connect(func(): emit_signal("connect_requested"))
		box.add_child(conn_btn)
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
	# Boxed reference to the "Pay X NIM" button so refresh_custom_display (defined
	# before the button is built) can keep its amount in sync live — this is what
	# fixes the button trailing a keystroke behind / stuck on the old value.
	var pay_btn_box := [null]

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
	# Bottom-anchored AUTO-HEIGHT: the sheet hugs its own content and sits flush
	# on the bottom edge, instead of being stretched to a fixed 56% of the screen
	# (which left a big empty gap under the keypad on tall screens, since the
	# content is sized from `ref`, not screen height). grow BEGIN makes it extend
	# upward from the bottom by exactly the content height. The slide animation
	# (offset_top/offset_bottom → 0 open, sheet_hidden_off closed) is unchanged.
	sheet.anchor_left = 0.0; sheet.anchor_right = 1.0
	sheet.anchor_top  = 1.0; sheet.anchor_bottom = 1.0
	sheet.grow_vertical = Control.GROW_DIRECTION_BEGIN
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
		# Keep the primary "Pay X NIM" button's amount in sync with what's typed.
		if pay_btn_box[0] != null and is_instance_valid(pay_btn_box[0]) and not pay_btn_box[0].disabled:
			pay_btn_box[0].text = "Pay %.2f NIM" % entry_val[0]

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
	# Shared key handler — used by BOTH the on-screen keypad buttons and the
	# physical keyboard (see _input). `k` is a digit "0".."9", "00", or "back".
	var apply_key := func(k: String):
		if k == "back":
			if custom_buf[0].length() > 0:
				custom_buf[0] = custom_buf[0].substr(0, custom_buf[0].length() - 1)
		elif k == "00":
			# "00" only makes sense once there's already a nonzero leading digit.
			if custom_buf[0] != "" and custom_buf[0] != "0":
				custom_buf[0] += "00"
		else:
			# Avoid a useless leading "0" (typing 5 after 0 → "5" not "05").
			if custom_buf[0] == "0":
				custom_buf[0] = k
			else:
				custom_buf[0] += k
		# entry_val must be recomputed BEFORE refresh — the field's "X NIM" text
		# is built from entry_val, so refreshing first would trail one keystroke.
		entry_val[0] = maxf(custom_buf[0].to_float(), 0.0)
		refresh_custom_display.call()
	_entry_apply_key = apply_key   # let physical-keyboard _input reach it

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
		kbtn.pressed.connect(func(): apply_key.call(key))

	# Boxed Tween reference (same boxed-array trick as entry_val/custom_buf
	# above) so open/close can kill an in-flight slide animation before
	# starting the next one, regardless of which closure last touched it.
	var sheet_tween := [null]
	var kill_sheet_tween := func():
		if sheet_tween[0] != null and is_instance_valid(sheet_tween[0]):
			sheet_tween[0].kill()
		sheet_tween[0] = null

	open_entry_sheet = func():
		_entry_sheet_open = true
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
		_entry_sheet_open = false
		sheet_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kill_sheet_tween.call()
		var t := create_tween()
		sheet_tween[0] = t
		t.set_parallel(true)
		t.tween_property(sheet_dim, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_QUAD)
		t.tween_property(sheet, "offset_top",    sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		t.tween_property(sheet, "offset_bottom", sheet_hidden_off, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_entry_close = close_entry_sheet   # let the Enter key (see _input) close it
	done_btn.pressed.connect(func(): close_entry_sheet.call())
	# Tapping the dim scrim behind the sheet dismisses it too, same as tapping
	# outside a real on-screen keyboard — it just closes, it doesn't discard
	# whatever amount was already typed.
	sheet_dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
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
	create_btn.text = "Pay %.2f NIM" % entry_val[0]
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
	pay_btn_box[0] = create_btn
	refresh_custom_display.call()   # sync the button's amount to the live value now
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
		_create_room(amt, private_check.button_pressed, func(ok: bool, room: Dictionary):
			if not ok:
				create_btn.disabled = false
				create_btn.text = "Pay %.2f NIM" % entry_val[0]
				return
			var room_id := str(room.get("id", ""))
			# "Create takes the payment right away" flow: instead of dropping the
			# player back on the room list to hunt for a Pay button later, open
			# the wallet payment IMMEDIATELY here. _create_room's HTTP round trip
			# (~300ms) is well within the browser's ~5s transient-activation
			# window from this Create tap, so the Hub-checkout popup on web still
			# opens correctly (same as the web sign-in flow, which also fetches a
			# challenge async and THEN opens its popup). _do_pay reads pay_to /
			# pay_memo from _current_room, so seed it from the create response.
			_current_room = room
			if room_id != "" and room.get("pay_to", "") != "":
				_do_pay(room_id, "creator", amt, create_btn)
			else:
				# Couldn't get pay info for some reason — fall back to the detail
				# screen (its own Pay button) rather than silently doing nothing.
				create_btn.disabled = false
				create_btn.text = "Pay %.2f NIM" % entry_val[0]
				if room_id != "":
					_show_room_detail(room_id)
				else:
					_show_room_list()
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

	# BUG FIX ("empty/rows appeared at the very bottom, under My Matches"): the
	# open-challenges list is fetched async, but the "My VS Matches" section
	# below is added SYNCHRONOUSLY right after this — so by the time the fetch
	# resolved, appending straight to _view_root landed AFTER My Matches. Put
	# the results in their own container placed here (right under this header),
	# exactly like the mine_rows_container pattern below, so they always land
	# in the correct spot regardless of fetch timing.
	var open_rows_container := VBoxContainer.new()
	open_rows_container.add_theme_constant_override("separation", int(ref * 0.010))
	_view_root.add_child(open_rows_container)

	var open_loading_lbl := Label.new()
	open_loading_lbl.text = "Loading..."
	open_loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(open_loading_lbl, _COL_TEXT_MID, int(ref * 0.026))
	open_rows_container.add_child(open_loading_lbl)

	# Capture a WEAKREF of the container (not the node itself): a ?vs= deeplink
	# can tear this list view down (via _clear_view) while the fetch is still in
	# flight, and a lambda that directly captured the now-freed container would
	# error "Lambda capture was freed" the moment the response lands.
	var _open_c_ref: WeakRef = weakref(open_rows_container)
	_fetch_open(0, func(rooms: Array, total: int):
		var oc = _open_c_ref.get_ref()
		if oc == null: return
		for c in oc.get_children():
			c.queue_free()
		if rooms.is_empty():
			var oe_lbl := Label.new()
			oe_lbl.text = "No open public challenges right now."
			oe_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(oe_lbl, _COL_TEXT_MID, int(ref * 0.024))
			oc.add_child(oe_lbl)
			UITheme.set_scroll_passthrough(_view_root)
			return
		for r in rooms:
			oc.add_child(_make_room_row(r, ref))
		_add_open_load_more_if_needed(oc, rooms.size(), total, ref)
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

	# Weakref captures — same deeplink teardown race as _fetch_open above.
	var _load_ref: WeakRef = weakref(loading_lbl)
	var _mine_c_ref: WeakRef = weakref(mine_rows_container)
	_fetch_mine(0, func(rooms: Array, total: int):
		var ll = _load_ref.get_ref()
		var mc = _mine_c_ref.get_ref()
		if mc == null: return
		if ll != null: ll.queue_free()
		# Re-order so matches waiting on ME ("Your turn to play/pay") sit above
		# ones waiting on the opponent, finished matches last. Decorate with the
		# server index so same-rank matches keep the server's order (sort_custom
		# isn't stable on its own).
		var _decorated : Array = []
		for _i in rooms.size():
			_decorated.append({"r": rooms[_i], "i": _i})
		_decorated.sort_custom(func(a, b):
			var ra : int = _mine_sort_rank(a["r"])
			var rb : int = _mine_sort_rank(b["r"])
			if ra != rb: return ra < rb
			return a["i"] < b["i"]
		)
		var _sorted : Array = []
		for _d in _decorated:
			_sorted.append(_d["r"])
		rooms = _sorted
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
			mc.add_child(_make_room_row(r, ref))
		_add_load_more_if_needed(mc, rooms.size(), total, ref)
		UITheme.set_scroll_passthrough(_view_root)
	)


func _make_card() -> PanelContainer:
	var card := PanelContainer.new()
	var st := StyleBoxFlat.new()
	# Same card scheme as the Statistics panel (bg + solid warm border).
	st.bg_color     = Color(0.940, 0.878, 0.776)
	st.border_color = Color(0.700, 0.520, 0.340)
	st.set_border_width_all(2)
	st.set_corner_radius_all(10)
	st.content_margin_left = 14; st.content_margin_right = 14
	st.content_margin_top  = 12; st.content_margin_bottom = 12
	card.add_theme_stylebox_override("panel", st)
	return card


## Small rounded "chip" showing a room's status — used in list rows (and the
## detail view) so statuses read as tidy badges instead of loose gray text.
## Terminal states stay muted; anything still in progress gets the warm accent.
func _make_status_pill(r: Dictionary, ref: float) -> Control:
	var status := str(r.get("status", ""))
	var bg : Color
	var col : Color
	if _is_terminal(status):
		# Colour the finished pill by OUTCOME (like the rest of the UI uses real
		# colour) instead of a washed-out grey: green when you won, soft red when
		# you lost, neutral for a tie / refund / cancel.
		var winner := str(r.get("winner_id", ""))
		if winner != "" and winner == _player_id:
			bg  = Color(0.800, 0.905, 0.740)   # win — soft green
			col = Color(0.150, 0.420, 0.160)
		elif winner != "" and winner != _player_id and _player_id != "":
			bg  = Color(0.955, 0.840, 0.800)   # loss — soft red
			col = Color(0.620, 0.240, 0.180)
		else:
			bg  = Color(0.905, 0.865, 0.785)   # tie / refunded / cancelled
			col = _COL_TEXT_DARK
	else:
		bg  = Color(0.980, 0.910, 0.820)
		col = _COL_ICON
	var pill := PanelContainer.new()
	pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.set_corner_radius_all(int(ref * 0.024))
	st.content_margin_left  = int(ref * 0.020); st.content_margin_right  = int(ref * 0.020)
	st.content_margin_top   = int(ref * 0.006); st.content_margin_bottom = int(ref * 0.006)
	pill.add_theme_stylebox_override("panel", st)
	var lbl := Label.new()
	lbl.text = _status_text(r)
	UITheme.apply_label(lbl, col, int(ref * 0.020))
	pill.add_child(lbl)
	return pill


## A muted flat-top hexagon (matching the Nimiq avatar silhouette) with a "?"
## in the centre — the empty opponent-slot placeholder. Drawn rather than a
## rounded square so it reads as "a player will go here", same shape as avatars.
func _make_hex_placeholder(size: int) -> TextureRect:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var cx := size * 0.5
	var cy := size * 0.5
	var r  := size * 0.5
	var hh := r * 0.8660254            # r * sqrt(3)/2 (flat top/bottom edge)
	var k  := 1.7320508                 # sqrt(3)
	var fill := Color(0.885, 0.840, 0.760)
	for y in size:
		for x in size:
			var dx : float = abs(x - cx + 0.5)
			var dy : float = abs(y - cy + 0.5)
			if dy <= hh and (k * dx + dy) <= (k * r):
				img.set_pixel(x, y, fill)
	_draw_letter(img, "?", maxi(2, size / 8), Color(0.480, 0.340, 0.200))
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return tr


## One player's card in the detail "You  VS  Opponent" row. `waiting` renders
## the empty-slot placeholder (? hexagon + "Waiting for player" + dots).
func _make_vs_player_card(ref: float, addr: String, display: String, badge: String, score, waiting: bool, border_col: Color = Color(0.700, 0.520, 0.340, 0.35)) -> Control:
	# ~0.8× the previous size (cards were too big) — all inner dimensions scaled.
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var outcome := border_col != Color(0.700, 0.520, 0.340, 0.35)   # a real win/loss/tie tint
	var st := StyleBoxFlat.new()
	# Faintly tint the card bg toward the outcome colour so the whole card reads
	# green/red/gold, not just the border. Subtle.
	st.bg_color = Color(0.968, 0.930, 0.858).lerp(Color(border_col.r, border_col.g, border_col.b), 0.10) if outcome else Color(0.968, 0.930, 0.858)
	st.border_color = border_col
	st.set_border_width_all(2 if outcome else 1)
	st.set_corner_radius_all(int(ref * 0.026))
	st.content_margin_left = int(ref * 0.012);  st.content_margin_right  = int(ref * 0.012)
	st.content_margin_top  = int(ref * 0.017);  st.content_margin_bottom = int(ref * 0.017)
	card.add_theme_stylebox_override("panel", st)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", int(ref * 0.008))
	card.add_child(vb)

	var av_center := CenterContainer.new()
	av_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(av_center)
	var av_sz := int(ref * 0.108)
	if waiting:
		av_center.add_child(_make_hex_placeholder(av_sz))
	else:
		av_center.add_child(_make_nimiq_avatar(addr, av_sz))

	var name_lbl := Label.new()
	name_lbl.text = display
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	UITheme.apply_label(name_lbl, _COL_TEXT_DARK, int(ref * 0.024))
	vb.add_child(name_lbl)

	# Third line: score (if played) > HOST/badge pill > waiting dots.
	if score != null:
		var sc := Label.new()
		sc.text = "%d" % int(score)
		sc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(sc, _COL_ICON, int(ref * 0.026))
		vb.add_child(sc)
	elif waiting:
		var dots := Label.new()
		dots.text = "•  •  •"
		dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(dots, Color(0.760, 0.660, 0.540), int(ref * 0.018))
		vb.add_child(dots)
	elif badge != "":
		var bc := CenterContainer.new()
		bc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_child(bc)
		var bp := PanelContainer.new()
		var bst := StyleBoxFlat.new()
		bst.bg_color = Color(0.980, 0.910, 0.820)
		bst.set_corner_radius_all(int(ref * 0.016))
		bst.content_margin_left = int(ref * 0.012); bst.content_margin_right = int(ref * 0.012)
		bst.content_margin_top  = int(ref * 0.002); bst.content_margin_bottom = int(ref * 0.002)
		bp.add_theme_stylebox_override("panel", bst)
		var bl := Label.new()
		bl.text = badge
		UITheme.apply_label(bl, _COL_ICON, int(ref * 0.016))
		bp.add_child(bl)
		bc.add_child(bp)
	return card


## Outcome-based border colour for a player's card: green if this player won,
## red if they lost, gold on a tie / refund / cancel, and the neutral warm
## border while the match is still unresolved.
func _card_outcome_border(r: Dictionary, pid: String) -> Color:
	var status := str(r.get("status", ""))
	match status:
		"completed", "expired_payout":
			var winner := str(r.get("winner_id", ""))
			if winner == "":
				return Color(0.850, 0.620, 0.150)   # tie — gold
			if pid != "" and winner == pid:
				return Color(0.300, 0.620, 0.280)   # win — green
			return Color(0.800, 0.320, 0.260)       # loss — red
		"expired_refunded", "cancelled":
			return Color(0.850, 0.620, 0.150)        # gold
	return Color(0.700, 0.520, 0.340, 0.35)          # unresolved — neutral


## The three-up prize breakdown strip (Prize pool / Winner gets / Entry fee).
func _make_prize_row(ref: float, entry: float) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.960, 0.918, 0.838)
	st.set_corner_radius_all(int(ref * 0.024))
	st.content_margin_left = int(ref * 0.006); st.content_margin_right = int(ref * 0.006)
	st.content_margin_top  = int(ref * 0.016); st.content_margin_bottom = int(ref * 0.016)
	card.add_theme_stylebox_override("panel", st)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_child(row)
	var pot := entry * 2.0
	var win := pot * 0.95
	var cells := [
		["hexagon", "PRIZE POOL",  "%.2f NIM" % pot, _COL_TEXT_DARK],
		["trophy",  "WINNER GETS", "%.2f NIM" % win, Color(0.150, 0.520, 0.180)],
		["hexagon", "ENTRY FEE",   "%.2f NIM" % entry, _COL_TEXT_DARK],
	]
	for i in cells.size():
		var c = cells[i]
		var cell := VBoxContainer.new()
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", int(ref * 0.004))
		row.add_child(cell)
		var ic_row := HBoxContainer.new()
		ic_row.alignment = BoxContainer.ALIGNMENT_CENTER
		ic_row.add_theme_constant_override("separation", int(ref * 0.006))
		cell.add_child(ic_row)
		if c[0] == "hexagon":
			ic_row.add_child(_make_nim_icon(int(ref * 0.026)))
		else:
			ic_row.add_child(UITheme.lucide_icon(c[0], int(ref * 0.026), _COL_ICON))
		var t := Label.new()
		t.text = c[1]
		UITheme.apply_label(t, _COL_TEXT_MID, int(ref * 0.017))
		ic_row.add_child(t)
		var v := Label.new()
		v.text = c[2]
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(v, c[3], int(ref * 0.026))
		cell.add_child(v)
		if i < cells.size() - 1:
			var divider := ColorRect.new()
			divider.color = Color(0.700, 0.560, 0.400, 0.35)
			divider.custom_minimum_size = Vector2(1, int(ref * 0.05))
			divider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(divider)
	return card


func _make_room_row(r: Dictionary, ref: float) -> Control:
	var card := _make_card()
	# PASS (not STOP) so a drag STARTING on a row still scrolls the list — the
	# event also reaches the ScrollContainer. We only open the room on a real
	# TAP: press + release at (almost) the same spot. If the finger moved, it was
	# a scroll gesture, so we DON'T open anything. (Screen-space distance via
	# global_position, so list scrolling under the finger doesn't fool it.)
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	var press_gpos := [Vector2.ZERO]
	var armed := [false]
	card.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				press_gpos[0] = e.global_position
				armed[0] = true
			elif armed[0]:
				armed[0] = false
				if e.global_position.distance_to(press_gpos[0]) < ref * 0.045:
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

	# Always show an avatar: the other player's if there is one, otherwise the
	# creator's own (an open room I made still shows a face, not a blank gap).
	var avatar_addr := other_addr if other_addr != "" else str(r.get("creator_id", ""))
	if avatar_addr != "":
		row.add_child(_make_nimiq_avatar(avatar_addr, int(ref * 0.052)))

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
		UITheme.apply_label(free_lbl, _COL_ICON, int(ref * 0.026))
		top_row.add_child(free_lbl)
	else:
		var entry_icon_wrap := CenterContainer.new()
		top_row.add_child(entry_icon_wrap)
		entry_icon_wrap.add_child(_make_nim_icon(int(ref * 0.028)))
		var entry_amt_lbl := Label.new()
		entry_amt_lbl.text = "%.2f" % entry
		# Accent the amount so the stake pops out of the row at a glance.
		UITheme.apply_label(entry_amt_lbl, _COL_ICON, int(ref * 0.026))
		top_row.add_child(entry_amt_lbl)

	# Status as a rounded chip (left-aligned) instead of loose gray text.
	var status_wrap := HBoxContainer.new()
	status_wrap.add_child(_make_status_pill(r, ref))
	info.add_child(status_wrap)

	row.add_child(UITheme.lucide_icon("arrow-right", int(ref * 0.024), _COL_TEXT_MID))
	return card


## Sort rank for the "My VS Matches" list — lower floats to the top. Anything
## that needs ME to act ("Your turn…") ranks above matches that are waiting on
## the other player, which in turn rank above finished/terminal matches. Derived
## from _status_text so it always matches the label the player actually sees.
func _mine_sort_rank(r: Dictionary) -> int:
	var t := _status_text(r)
	if t.begins_with("Your turn"):      return 0   # my move (pay or play)
	if t.begins_with("Finishing"):      return 1   # both played, settling
	if t == "Match in progress":        return 2
	if t.begins_with("Waiting"):        return 3   # on the opponent
	return 4                                        # completed / expired / cancelled / review


func _status_text(r: Dictionary) -> String:
	var status : String = str(r.get("status", ""))
	var is_creator : bool = str(r.get("creator_id", "")) == _player_id
	var is_opponent : bool = str(r.get("opponent_id", "")) == _player_id and _player_id != ""
	# Pay-to-join pending payer's own view: they must still pay to commit.
	if bool(r.get("viewer_is_pending_opponent", false)):
		return "Your turn to pay"
	match status:
		"awaiting_creator_pay":  return "Your turn to pay" if is_creator else "Waiting for an opponent to join"
		"waiting_opponent":      return "Waiting for an opponent to join"
		# An opponent who hasn't paid yet is NOT considered joined — paying IS
		# joining. So the creator just sees "waiting for an opponent" (never a
		# "waiting for opponent's payment" limbo). Only the opponent themselves
		# sees their own "your turn to pay" action.
		"awaiting_opponent_pay": return "Your turn to pay" if is_opponent else "Waiting for an opponent to join"
		"awaiting_creator_play", "awaiting_opponent_play":
			# NEW FLOW: nobody plays until the opponent has joined AND (paid
			# rooms) both have paid. So FIRST check the match is actually ready;
			# only then does "your turn to play" make sense. This also keeps the
			# label correct against an older backend that might still leave a
			# freshly-paid room in awaiting_creator_play with no opponent yet.
			if is_creator or is_opponent:
				var opp_id := str(r.get("opponent_id", ""))
				var entry := float(r.get("entry_nim", 0.0))
				var my_paid := bool(r.get("creator_paid" if is_creator else "opponent_paid", false))
				var other_paid := bool(r.get("opponent_paid" if is_creator else "creator_paid", false))
				if opp_id == "":
					return "Waiting for an opponent to join"
				if entry > 0 and not (my_paid and other_paid):
					# Unpaid opponent = not really joined; creator keeps seeing the
					# neutral "waiting for an opponent to join" (no pay-limbo).
					return "Waiting for an opponent to join" if my_paid else "Your turn to pay"
				var mine = r.get("creator_score" if is_creator else "opponent_score")
				var theirs = r.get("opponent_score" if is_creator else "creator_score")
				# Count a side as "played" from the moment it SUBMITTED (played_at),
				# not only once the server has finished verifying + recording the
				# score — otherwise my own run, mid server-side replay check, still
				# reads as "Your turn to play".
				var i_played : bool = mine != null or int(r.get("creator_played_at" if is_creator else "opponent_played_at", 0)) > 0
				var they_played : bool = theirs != null or int(r.get("opponent_played_at" if is_creator else "creator_played_at", 0)) > 0
				if not i_played:
					return "Your turn to play"
				elif not they_played:
					return "Waiting for opponent to play"
				return "Finishing up…"
			return "Match in progress"
		"completed":
			var winner : String = str(r.get("winner_id", ""))
			if winner == "": return "Completed — tie"
			return "Completed — you won!" if winner == _player_id else "Completed — opponent won"
		"expired_payout":
			var w2 : String = str(r.get("winner_id", ""))
			return "Expired — you won by forfeit" if w2 == _player_id else "Expired — opponent won by forfeit"
		"expired_refunded":      return "Expired — refunded"
		"cancelled":             return "Cancelled"
		"manual_review":         return "Under review — an admin is checking this match"
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
	_viewing_room_id = room_id   # mark BEFORE the async fetch so a late auth/player
	                             # sync can't re-render the list over this view
	_back_btn.visible = true
	if is_instance_valid(_header_icon): _header_icon.visible = false  # back btn replaces it — no clutter
	_title_lbl.text = "Match"
	_clear_view()
	var ref := _ref()

	var loading_lbl := Label.new()
	loading_lbl.text = "Loading..."
	loading_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(loading_lbl, _COL_TEXT_MID, int(ref * 0.026))
	_view_root.add_child(loading_lbl)

	# Weakref the loading label so a fast navigate-away (or deeplink teardown)
	# mid-fetch can't trigger "Lambda capture was freed".
	var _load_ref: WeakRef = weakref(loading_lbl)
	_fetch_room(room_id, func(ok: bool, room: Dictionary):
		print("[VSDEEPLINK] _show_room_detail fetch id=%s ok=%s status=%s" % [room_id, str(ok), str(room.get("status", "?"))])
		var ll = _load_ref.get_ref()
		if ll == null: return
		ll.queue_free()
		if not ok:
			var err_lbl := Label.new()
			err_lbl.text = "Could not load this room (it may have expired)."
			err_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(err_lbl, _COL_TEXT_MID, int(ref * 0.026))
			_view_root.add_child(err_lbl)
			UITheme.set_scroll_passthrough(_view_root)
			return
		_current_room = room
		# room_id may have been a short ?vs= code (invite deeplink); from here on
		# use the room's resolved internal id so the poll's re-fetch + identity
		# check work regardless of which one we opened with.
		var canonical_id := str(room.get("id", room_id))
		_render_room_detail(room, ref)
		UITheme.set_scroll_passthrough(_view_root)
		# Poll while anything is still pending — cheap HTTP GET every 4s.
		if not _is_terminal(str(room.get("status", ""))):
			_detail_timer = Timer.new()
			_detail_timer.wait_time = 4.0
			_detail_timer.autostart = true
			add_child(_detail_timer)
			_detail_timer.timeout.connect(func():
				_fetch_room(canonical_id, func(ok2: bool, room2: Dictionary):
					if ok2 and _current_room.get("id", "") == canonical_id:
						_notify_status_change(_current_room, room2)
						_current_room = room2
						_clear_view()
						_render_room_detail(room2, ref)
						UITheme.set_scroll_passthrough(_view_root)
				)
			)
	)


func _is_terminal(status: String) -> bool:
	# manual_review is treated as terminal on the client (no play/pay/cancel
	# actions) — it's frozen until an admin resolves it, nothing the player can do.
	return status in ["completed", "expired_payout", "expired_refunded", "cancelled", "manual_review"]


func _render_room_detail(r: Dictionary, ref: float) -> void:
	var room_id : String = str(r.get("id", ""))
	var is_creator : bool = str(r.get("creator_id", "")) == _player_id
	# Pay-to-join: a paid room's opponent isn't committed (opponent_id set) until
	# they've paid. The server flags the pending payer's OWN view with
	# viewer_is_pending_opponent so they still see their Pay button here, even
	# though opponent_id is still empty and nobody else sees them as joined.
	var is_pending_opp : bool = bool(r.get("viewer_is_pending_opponent", false))
	var is_opponent : bool = (str(r.get("opponent_id", "")) == _player_id and _player_id != "") or is_pending_opp
	var entry : float = float(r.get("entry_nim", 0.0))

	# Neither participant yet — this is someone arriving via the invite link
	# who hasn't claimed the opponent slot. Show a join card instead of the
	# normal pay/play flow (which needs opponent_id set first).
	if not is_creator and not is_opponent:
		var open_for_join : bool = r.get("opponent_id", "") == "" and not _is_terminal(str(r.get("status", "")))
		var jcreator_addr := str(r.get("creator_id", ""))
		var jcard := _make_card()
		_view_root.add_child(jcard)
		var jv := VBoxContainer.new()
		jv.add_theme_constant_override("separation", int(ref * 0.018))
		jcard.add_child(jv)

		# ── Pot / entry header (same as the match detail) ─────────────────
		var jpot := VBoxContainer.new()
		jpot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		jpot.add_theme_constant_override("separation", int(ref * 0.004))
		jv.add_child(jpot)
		if entry <= 0:
			var jfree := Label.new()
			jfree.text = "Free match"
			jfree.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(jfree, _COL_TEXT_DARK, int(ref * 0.038))
			jpot.add_child(jfree)
		else:
			var jamt_row := HBoxContainer.new()
			jamt_row.alignment = BoxContainer.ALIGNMENT_CENTER
			jamt_row.add_theme_constant_override("separation", int(ref * 0.008))
			jpot.add_child(jamt_row)
			jamt_row.add_child(_make_nim_icon(int(ref * 0.044)))
			var jamt := Label.new()
			jamt.text = "%.2f NIM" % entry
			UITheme.apply_label(jamt, _COL_TEXT_DARK, int(ref * 0.046))
			jamt_row.add_child(jamt)
			var jsub := Label.new()
			jsub.text = "Entry fee: %d NIM  ·  Winner takes 95%% of the %.2f NIM pot" % [int(entry), entry * 2.0]
			jsub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			jsub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			UITheme.apply_label(jsub, _COL_TEXT_MID, int(ref * 0.022))
			jpot.add_child(jsub)

		# ── "X challenged you" (centered) ─────────────────────────────────
		var jchal := Label.new()
		jchal.text = "%s challenged you" % _display_name(str(r.get("creator_nickname", "")), jcreator_addr)
		jchal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		jchal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		jchal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(jchal, _COL_ICON, int(ref * 0.024))
		jv.add_child(jchal)

		# ── Player cards: You  VS  Challenger(HOST) ───────────────────────
		var jcards := HBoxContainer.new()
		jcards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		jcards.alignment = BoxContainer.ALIGNMENT_CENTER
		jcards.add_theme_constant_override("separation", int(ref * 0.014))
		jv.add_child(jcards)
		jcards.add_child(_make_vs_player_card(ref, _player_id, "You", "", null, _player_id == ""))
		var jvs := Label.new()
		jvs.text = "VS"
		jvs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		UITheme.apply_label(jvs, _COL_ICON, int(ref * 0.042))
		jcards.add_child(jvs)
		jcards.add_child(_make_vs_player_card(ref, jcreator_addr, _display_name(str(r.get("creator_nickname", "")), jcreator_addr), "HOST", null, jcreator_addr == ""))

		# ── Prize breakdown ───────────────────────────────────────────────
		if entry > 0:
			jv.add_child(_make_prize_row(ref, entry))

		if not open_for_join:
			var jf := Label.new()
			jf.text = "This challenge is no longer open."
			jf.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			UITheme.apply_label(jf, _COL_TEXT_MID, int(ref * 0.024))
			jv.add_child(jf)
			return

		# Pay-to-join: there is NO separate "accept then pay" step and no free
		# match — joining a challenge IS paying for it. One tap joins (reserves the
		# slot + returns pay_to/pay_memo) and immediately opens the wallet for the
		# entry fee.
		var join_btn := Button.new()
		var _join_label : String = "Pay %.2f NIM" % entry
		join_btn.text = _join_label
		join_btn.custom_minimum_size.y = int(ref * 0.078)
		UITheme.apply_play_button(join_btn)
		jv.add_child(join_btn)
		join_btn.pressed.connect(func():
			if _player_id == "":
				_show_toast_err("Connect your wallet first.")
				return
			join_btn.disabled = true
			join_btn.text = "Joining..."
			_join_room(room_id, func(ok: bool, room2: Dictionary):
				if not ok:
					join_btn.disabled = false
					join_btn.text = _join_label
					_show_toast_err("Could not join — the room may be full or expired.")
					return
				# Slot reserved + pay_to/pay_memo in hand → straight to the wallet.
				# _do_pay re-renders the room on confirm (or refunds and bounces us
				# back to the list if someone else paid first).
				_current_room = room2
				join_btn.text = "Waiting for wallet..."
				_do_pay(room_id, "opponent", entry, join_btn)
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
	cv.add_theme_constant_override("separation", int(ref * 0.018))
	card.add_child(cv)

	# ── Pot / entry (centered, prominent) ──────────────────────────────────
	var pot_box := VBoxContainer.new()
	pot_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pot_box.add_theme_constant_override("separation", int(ref * 0.004))
	cv.add_child(pot_box)
	if entry <= 0:
		var free_lbl := Label.new()
		free_lbl.text = "Free match"
		free_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(free_lbl, _COL_TEXT_DARK, int(ref * 0.038))
		pot_box.add_child(free_lbl)
	else:
		var amt_row := HBoxContainer.new()
		amt_row.alignment = BoxContainer.ALIGNMENT_CENTER
		amt_row.add_theme_constant_override("separation", int(ref * 0.008))
		pot_box.add_child(amt_row)
		amt_row.add_child(_make_nim_icon(int(ref * 0.044)))
		var amt_lbl := Label.new()
		amt_lbl.text = "%.2f NIM" % entry
		UITheme.apply_label(amt_lbl, _COL_TEXT_DARK, int(ref * 0.046))
		amt_row.add_child(amt_lbl)
		var pot_sub := Label.new()
		pot_sub.text = "Entry fee: %d NIM  ·  Winner takes 95%% of the %.2f NIM pot" % [int(entry), entry * 2.0]
		pot_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pot_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(pot_sub, _COL_TEXT_MID, int(ref * 0.022))
		pot_box.add_child(pot_sub)

	# ── Status chip (centered) ─────────────────────────────────────────────
	var status_center := HBoxContainer.new()
	status_center.alignment = BoxContainer.ALIGNMENT_CENTER
	status_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_center.add_child(_make_status_pill(r, ref))
	cv.add_child(status_center)

	# ── Public / Private ───────────────────────────────────────────────────
	# Private rooms are invite-link-only (never in the public browse list);
	# public rooms are open for anyone to join. Show which this is.
	var vis_lbl := Label.new()
	var _is_priv : bool = bool(r.get("is_private", false))
	# Only advertise "invite-only / anyone can join" while the room is actually
	# still open to join; on a matched or finished room that hint is stale, so
	# just label it Private/Public.
	var _still_open : bool = str(r.get("status", "")) == "waiting_opponent" and str(r.get("opponent_id", "")) == ""
	if _still_open:
		vis_lbl.text = "Private room · invite-only" if _is_priv else "Public room · anyone can join"
	else:
		vis_lbl.text = "Private room" if _is_priv else "Public room"
	vis_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vis_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(vis_lbl, _COL_TEXT_MID, int(ref * 0.020))
	cv.add_child(vis_lbl)

	# ── Player cards: You  VS  Opponent ───────────────────────────────────
	var opp_addr2 : String = str(r.get("opponent_id" if is_creator else "creator_id", ""))

	var cards_row := HBoxContainer.new()
	cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	cards_row.add_theme_constant_override("separation", int(ref * 0.014))
	cv.add_child(cards_row)

	var you_badge := "HOST" if is_creator else ""
	cards_row.add_child(_make_vs_player_card(ref, _player_id, "You", you_badge, my_score, false, _card_outcome_border(r, _player_id)))

	var vs_lbl := Label.new()
	vs_lbl.text = "VS"
	vs_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UITheme.apply_label(vs_lbl, _COL_ICON, int(ref * 0.042))
	cards_row.add_child(vs_lbl)

	var opp_waiting : bool = opp_addr2 == ""
	var opp_disp := _display_name(opp_nick, opp_addr2) if not opp_waiting else "Waiting for player"
	# The opponent card's outcome uses the OTHER side's win/loss (an empty slot
	# stays neutral).
	var opp_border := _card_outcome_border(r, opp_addr2) if not opp_waiting else Color(0.700, 0.520, 0.340, 0.35)
	cards_row.add_child(_make_vs_player_card(ref, opp_addr2, opp_disp, "", opp_score, opp_waiting, opp_border))

	# ── Prize breakdown strip (paid rooms only) ────────────────────────────
	if entry > 0:
		cv.add_child(_make_prize_row(ref, entry))

	if not _is_terminal(str(r.get("status", ""))):
		var exp_lbl := Label.new()
		var still_waiting_for_join : bool = str(r.get("status", "")) == "waiting_opponent"
		var prefix := "Invite link valid for: " if still_waiting_for_join else "Time left to play: "
		exp_lbl.text = prefix + _time_left_text(int(r.get("expires_at", 0)))
		exp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		exp_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(exp_lbl, _COL_TEXT_MID, int(ref * 0.020))
		cv.add_child(exp_lbl)

	# Invite link — only useful while still waiting for an opponent
	if is_creator and r.get("opponent_id", "") == "" and not _is_terminal(str(r.get("status", ""))):
		var inv_hdr := Label.new()
		inv_hdr.text = "Invite a friend"
		UITheme.apply_label(inv_hdr, _COL_TEXT_DARK, int(ref * 0.028))
		cv.add_child(inv_hdr)
		var inv_desc := Label.new()
		inv_desc.text = "Share the link below to invite players to your room."
		inv_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		inv_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_label(inv_desc, _COL_TEXT_MID, int(ref * 0.020))
		cv.add_child(inv_desc)
		var invite_row := HBoxContainer.new()
		invite_row.add_theme_constant_override("separation", int(ref * 0.010))
		cv.add_child(invite_row)
		var invite_edit := LineEdit.new()
		invite_edit.text = _room_invite_url(r)
		invite_edit.editable = false
		invite_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		invite_edit.size_flags_vertical = Control.SIZE_FILL
		invite_edit.custom_minimum_size.y = int(ref * 0.062)
		invite_edit.add_theme_font_size_override("font_size", int(ref * 0.022))
		# A non-editable LineEdit renders its text in the faded "uneditable"
		# colour by default — force a readable dark tone (this was the "URL is
		# all washed out" complaint), and give it a clear white field so it
		# doesn't look disabled.
		invite_edit.add_theme_color_override("font_uneditable_color", _COL_TEXT_DARK)
		invite_edit.add_theme_color_override("font_color", _COL_TEXT_DARK)
		var edit_st := StyleBoxFlat.new()
		edit_st.bg_color = Color(1.0, 1.0, 1.0, 0.9)
		edit_st.border_color = Color(0.700, 0.520, 0.340, 0.6)
		edit_st.set_border_width_all(1)
		edit_st.set_corner_radius_all(8)
		edit_st.content_margin_left = int(ref * 0.014); edit_st.content_margin_right = int(ref * 0.014)
		invite_edit.add_theme_stylebox_override("normal",   edit_st)
		invite_edit.add_theme_stylebox_override("read_only", edit_st)
		invite_row.add_child(invite_edit)
		# Small "Copy" button (outlined) sitting on the link row — copies the URL
		# to the clipboard. The big orange "Share Invite Link" below is the
		# primary action (native share sheet on mobile).
		var copy_btn := Button.new()
		copy_btn.text = "Copy"
		copy_btn.add_theme_font_size_override("font_size", int(ref * 0.024))
		copy_btn.custom_minimum_size = Vector2(int(ref * 0.20), int(ref * 0.062))
		_load_more_btn_style(copy_btn)
		copy_btn.pressed.connect(func():
			_copy_invite_link(_room_invite_url(r))
		)
		invite_row.add_child(copy_btn)

		# "or" divider between the copy row and the primary Share button.
		var or_row := HBoxContainer.new()
		or_row.alignment = BoxContainer.ALIGNMENT_CENTER
		or_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		or_row.add_theme_constant_override("separation", int(ref * 0.012))
		cv.add_child(or_row)
		var line_l := ColorRect.new()
		line_l.color = Color(0.700, 0.560, 0.400, 0.35)
		line_l.custom_minimum_size.y = 1
		line_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		or_row.add_child(line_l)
		var or_lbl := Label.new()
		or_lbl.text = "or"
		UITheme.apply_label(or_lbl, _COL_TEXT_MID, int(ref * 0.020))
		or_row.add_child(or_lbl)
		var line_r := ColorRect.new()
		line_r.color = Color(0.700, 0.560, 0.400, 0.35)
		line_r.custom_minimum_size.y = 1
		line_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line_r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		or_row.add_child(line_r)

		var share_btn := Button.new()
		share_btn.text = "Share Invite Link"
		share_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		share_btn.custom_minimum_size.y = int(ref * 0.072)
		UITheme.apply_play_button(share_btn)
		share_btn.pressed.connect(func():
			# Native share sheet first (mobile), clipboard fallback (desktop / no
			# Web Share support) — see ApiConfig.share_link.
			ApiConfig.share_link("Join my NimJump VS match!", _room_invite_url(r))
		)
		cv.add_child(share_btn)

		# Cancel — only offered while the backend will actually allow it: no
		# opponent yet AND the creator hasn't paid (a paid room is committed and
		# refunds via expiry, not cancel — see backend CancelVSRoom). Asks for
		# confirmation via the same dialog the "open tx" flow uses.
		# Always offered while you're alone in the room (no opponent has joined) —
		# whether or not you've paid. If you paid, cancelling refunds your entry
		# (backend CancelVSRoom); if not, it just closes the room.
		var _creator_paid : bool = bool(r.get("creator_paid", false))
		if true:
			var cancel_btn := Button.new()
			cancel_btn.text = "Cancel match & refund" if (entry > 0 and _creator_paid) else "Cancel match"
			cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cancel_btn.custom_minimum_size.y = int(ref * 0.058)
			# Solid button in the same weight/shape as our other primary buttons
			# (Share / Pay), just tinted red to signal it's destructive — cream
			# text, real fill, not the washed-out ghost outline it was before.
			var _cn := StyleBoxFlat.new(); var _ch := StyleBoxFlat.new(); var _cp := StyleBoxFlat.new()
			for s in [_cn, _ch, _cp]:
				s.set_corner_radius_all(8)
			_cn.bg_color = Color(0.780, 0.300, 0.230)
			_ch.bg_color = Color(0.840, 0.360, 0.280)
			_cp.bg_color = Color(0.660, 0.240, 0.180)
			cancel_btn.add_theme_stylebox_override("normal",  _cn)
			cancel_btn.add_theme_stylebox_override("hover",   _ch)
			cancel_btn.add_theme_stylebox_override("pressed", _cp)
			cancel_btn.add_theme_color_override("font_color",         Color(0.980, 0.955, 0.910))
			cancel_btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
			cancel_btn.add_theme_color_override("font_pressed_color", Color(0.980, 0.955, 0.910))
			cv.add_child(cancel_btn)
			var _cancel_body := ("This closes the match before anyone joins and refunds your %d NIM entry. This can't be undone." % int(entry)) if (entry > 0 and _creator_paid) else "This closes the match before anyone joins. This can't be undone."
			cancel_btn.pressed.connect(func():
				UITheme.confirm_action(self, "Cancel match?",
					_cancel_body,
					"Yes, cancel", ref, func():
						_cancel_room(room_id, func(ok: bool):
							if ok:
								var t := Toast.get_instance()
								if t: t.show_toast("Match cancelled — refunded" if (entry > 0 and _creator_paid) else "Match cancelled", Toast.Kind.INFO)
								_show_room_list()
							else:
								_show_toast_err("Could not cancel — someone may be joining right now.")
						)
				)
			)

	# ── Action button ──
	# NEW FLOW: nobody can play until the opponent has joined AND (paid rooms)
	# both sides have paid — mirrors the backend readiness gate in
	# UpdateVSRoomScore. So after paying, the creator sees a "waiting for
	# opponent" message (not Play) until a real opponent is locked in.
	# Paying IS joining: an opponent who hasn't paid is NOT a real participant
	# yet, so from the creator's side the slot still counts as empty. `opp_id`
	# here is the *effective* (committed) opponent — present only once they've
	# actually paid (or it's a free room). This is what removes the entire
	# "waiting for your opponent to pay" limbo.
	var opp_id_raw : String = str(r.get("opponent_id", ""))
	var other_paid : bool = bool(r.get("opponent_paid" if is_creator else "creator_paid", false))
	var opp_committed : bool = opp_id_raw != "" and (entry <= 0 or other_paid)
	var opp_id : String = opp_id_raw if opp_committed else ""
	var match_ready : bool = opp_committed and (entry <= 0 or (my_paid and other_paid))
	# "Already played" must NOT rely on my_score alone: the server only records
	# the VS score AFTER it re-simulates the replay (and never, if the match got
	# flagged into manual review). During that window my_score is still null, so
	# gate on the played-at marker the backend now stamps the instant a run is
	# submitted — otherwise the room would offer "Play" again on a match I already
	# played (and could let me play it twice).
	var my_played_at : int = int(r.get("creator_played_at" if is_creator else "opponent_played_at", 0))
	var already_played : bool = my_score != null or my_played_at > 0
	if not already_played:
		if entry > 0 and not my_paid:
			var pay_btn := Button.new()
			pay_btn.custom_minimum_size.y = int(ref * 0.07)
			UITheme.apply_play_button(pay_btn)
			cv.add_child(pay_btn)
			pay_btn.text = "Pay %.2f NIM" % entry
			pay_btn.pressed.connect(func(): _do_pay(room_id, my_role, entry, pay_btn))
		elif match_ready:
			var play_btn := Button.new()
			play_btn.custom_minimum_size.y = int(ref * 0.07)
			UITheme.apply_play_button(play_btn)
			cv.add_child(play_btn)
			play_btn.text = "Play"
			play_btn.pressed.connect(func():
				# CLAIM the single play attempt on the server FIRST. Only once the
				# server confirms (200) — locking this side as played — does the
				# round start. If the claim can't reach the server (offline), the
				# round simply never begins, so nothing is lost and you can retry
				# when back online. This is what makes replaying impossible: after a
				# successful claim, even a later dropped score-submit can't hand you
				# a fresh attempt, because "played" is already committed server-side.
				play_btn.disabled = true
				play_btn.text = "Starting…"
				_start_play(room_id, func(ok: bool, room2: Dictionary, code: int, err: String):
					if ok:
						# Use the seed the server just returned (authoritative).
						var srv_seed : String = str(room2.get("seed", r.get("seed", "")))
						hide_panel()
						play_requested.emit(room_id, my_role, srv_seed)
						return
					if code == 409 and err == "already_played":
						# We already used our attempt (double-tap, or a retry after a
						# lost response). Never start a second run — just refresh to
						# the result/waiting view.
						_show_toast_err("You've already played this match.")
						_show_room_detail(room_id)
						return
					# Transport failure or anything else — do NOT start the round.
					play_btn.disabled = false
					play_btn.text = "Play"
					_show_toast_err("Couldn't start the match — check your connection and try again.")
				)
			)
		elif not _is_terminal(str(r.get("status", ""))):
			# Paid, waiting for a real (paid) opponent to join. There is no
			# "waiting for opponent to pay" state — an unpaid opponent doesn't
			# count as joined, so this is always just "waiting to join".
			var wait_lbl := Label.new()
			wait_lbl.text = "Waiting for an opponent to join…"
			wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			wait_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			wait_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UITheme.apply_label(wait_lbl, _COL_TEXT_MID, int(ref * 0.024))
			cv.add_child(wait_lbl)
	elif not _is_terminal(str(r.get("status", ""))):
		var waiting_lbl := Label.new()
		waiting_lbl.text = "Waiting for the other side…"
		waiting_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(waiting_lbl, _COL_TEXT_MID, int(ref * 0.024))
		cv.add_child(waiting_lbl)

	# (Removed the "Forfeit / End Match Early" button. Once both sides are in a
	# real match there's no bail-out mid-play — the match resolves by scores or
	# by the play-time expiry/forfeit-on-timeout that the backend already
	# handles. Single-player no-opponent rooms are still cancellable via the
	# separate Cancel button above.)

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
			my_replay_btn.text = "Your Replay"
			my_replay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			my_replay_btn.custom_minimum_size.y = int(ref * 0.062)
			UITheme.apply_play_button(my_replay_btn)
			replay_row.add_child(my_replay_btn)
			my_replay_btn.pressed.connect(func(): _fetch_and_emit_replay(my_session, my_replay_btn))
		if opp_session != "":
			var opp_replay_btn := Button.new()
			opp_replay_btn.text = "%s's Replay" % _display_name(opp_nick, opp_addr2)
			opp_replay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			opp_replay_btn.custom_minimum_size.y = int(ref * 0.062)
			UITheme.apply_play_button(opp_replay_btn)
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
	# BUG FIX ("Invalid assignment ... on a base object of type 'previously
	# freed'"): the web Hub-checkout popup can take many seconds of user
	# interaction, during which this panel may rebuild (viewport resize, a
	# poll-driven detail refresh, tab switch...) and free `btn` out from under
	# us. Every `btn` touch AFTER the await must therefore be guarded — the
	# payment itself already succeeded/failed regardless of the button's fate.
	if not bool(result.get("ok", false)):
		_show_toast_err("Payment failed: " + str(result.get("err", "unknown")))
		if is_instance_valid(btn):
			btn.disabled = false
			btn.text = "Pay %.2f NIM" % amount_nim
		return
	if is_instance_valid(btn):
		btn.text = "Confirming..."
	var tx : String = str(result.get("tx", ""))
	_confirm_payment(room_id, tx, func(ok: bool, err_reason: String):
		if ok:
			var t := Toast.get_instance()
			if t: t.show_toast("Payment confirmed!", Toast.Kind.SUCCESS)
			_show_room_detail(room_id)
		elif err_reason == "slot_taken_refunded":
			# Someone else paid and grabbed this room first. Our (real) payment
			# was refunded automatically by the backend — this isn't a pending
			# confirm, so don't tell them to wait; send them back to the list.
			var t := Toast.get_instance()
			if t: t.show_toast("Someone joined first — your entry was refunded.", Toast.Kind.INFO)
			_show_room_list()
		else:
			# The backend also independently re-scans the wallet's incoming
			# transactions every ~90s and will pick this payment up on its
			# own even if this confirm call keeps failing — it is not lost.
			_show_toast_err("Payment sent — confirming automatically, this can take up to a couple minutes. Reopen this room to check.")
			if is_instance_valid(btn):
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
	# BUG FIX: "Lambda capture at index 0 was freed" — VSPanel (self) or this
	# http node can be freed mid-flight (panel closed/queue_free'd, or a
	# window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			# Parse + flatten the new room (id + pay_to/pay_memo) so the caller
			# can trigger its payment IMMEDIATELY — "create takes the payment
			# right away" flow. Same flattening _fetch_room() does.
			var room : Dictionary = {}
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d = j.get_data()
				if d is Dictionary:
					var r = d.get("room", {})
					if r is Dictionary:
						room = r
					if d.has("pay_to"):     room["pay_to"]     = d["pay_to"]
					if d.has("pay_memo"):   room["pay_memo"]   = d["pay_memo"]
					if d.has("invite_url"): room["invite_url"] = d["invite_url"]
			cb.call(true, room)
		else:
			_show_toast_err("Could not create room (code %d)" % code)
			cb.call(false, {})
	)
	var body_str := JSON.stringify({"entry_nim": entry_nim, "is_private": is_private})
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/create"), _headers(true), HTTPClient.METHOD_POST, body_str)


## Cancels a room the player created before anyone joined. The backend only
## allows this when there's no opponent AND the creator hasn't paid (a paid
## room is committed — it refunds via expiry instead). cb(ok).
func _cancel_room(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, _body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		cb.call(result == HTTPRequest.RESULT_SUCCESS and code == 200)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/%s/cancel" % room_id), _headers(), HTTPClient.METHOD_POST)


## Public browse list — open rooms anyone can join (private rooms never
## appear here, they only work via their direct invite link). Paginated
## (highest entry fee first, server-side) — cb receives (rooms, total) so the
## caller can page through via a "Load more" control, _OPEN_PAGE_SIZE at a time.
func _fetch_open(offset: int, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	# "Lambda capture at index 0 was freed": Godot validates a lambda's captures
	# BEFORE running its body, so directly capturing the `http` node errors the
	# instant it's freed (panel rebuilt on a ?vs= deeplink / resize) — the
	# is_instance_valid guard never even gets a chance. Capture WEAKREFS instead
	# (never themselves freed) and also verify `cb` is still valid before calling
	# it (its target — a torn-down list view — may be gone).
	var _alive : WeakRef = weakref(self)
	var _http_ref : WeakRef = weakref(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		var h = _http_ref.get_ref()
		if h == null or _alive.get_ref() == null: return
		h.queue_free()
		if not cb.is_valid(): return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				cb.call(_as_array(d.get("rooms", [])), int(d.get("total", 0)))
				return
		cb.call([], 0)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/open?limit=%d&offset=%d" % [_OPEN_PAGE_SIZE, offset]), _headers())


## "Load more" for the Open Challenges list — mirror of _add_load_more_if_needed
## but paging through _fetch_open (public rooms) instead of _fetch_mine.
func _add_open_load_more_if_needed(container: VBoxContainer, loaded_so_far: int, total: int, ref: float) -> void:
	if loaded_so_far >= total:
		return
	var more_btn := Button.new()
	more_btn.text = "Load more (%d of %d)" % [loaded_so_far, total]
	more_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	more_btn.custom_minimum_size.y = int(ref * 0.058)
	_load_more_btn_style(more_btn)
	more_btn.add_theme_font_size_override("font_size", int(ref * 0.024))
	container.add_child(more_btn)
	more_btn.pressed.connect(func():
		more_btn.disabled = true
		more_btn.text = "Loading..."
		_fetch_open(loaded_so_far, func(rooms: Array, total2: int):
			if not is_instance_valid(container): return
			more_btn.queue_free()
			for r in rooms:
				container.add_child(_make_room_row(r, ref))
			_add_open_load_more_if_needed(container, loaded_so_far + rooms.size(), total2, ref)
		)
	)


## Appends a "Load more" button to `container` if fewer than `total` rooms
## have been loaded so far. Pressing it fetches the next page, appends the
## new rows above the button, and re-evaluates whether another page remains.
func _add_load_more_if_needed(container: VBoxContainer, loaded_so_far: int, total: int, ref: float) -> void:
	if loaded_so_far >= total:
		return
	var more_btn := Button.new()
	more_btn.text = "Load more (%d of %d)" % [loaded_so_far, total]
	more_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	more_btn.custom_minimum_size.y = int(ref * 0.058)
	_load_more_btn_style(more_btn)
	more_btn.add_theme_font_size_override("font_size", int(ref * 0.024))
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
	# Weakref captures so a panel/view rebuilt by a ?vs= deeplink mid-request
	# doesn't trigger "Lambda capture ... was freed" — see _fetch_open above.
	var _alive : WeakRef = weakref(self)
	var _http_ref : WeakRef = weakref(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		var h = _http_ref.get_ref()
		if h == null or _alive.get_ref() == null: return
		h.queue_free()
		if not cb.is_valid(): return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				cb.call(_as_array(d.get("rooms", [])), int(d.get("total", 0)))
				return
		cb.call([], 0)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/mine?limit=%d&offset=%d" % [_MINE_PAGE_SIZE, offset]), _headers())


func _fetch_room(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	# Weakref captures — see _fetch_open. A ?vs= deeplink opens this room right as
	# the list view is torn down, which used to error "Lambda capture was freed".
	var _alive : WeakRef = weakref(self)
	var _http_ref : WeakRef = weakref(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		var h = _http_ref.get_ref()
		if h == null or _alive.get_ref() == null: return
		h.queue_free()
		if not cb.is_valid(): return
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
				if d.has("viewer_is_pending_opponent"): room["viewer_is_pending_opponent"] = d["viewer_is_pending_opponent"]
				cb.call(true, room)
				return
		cb.call(false, {})
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode()), _headers())


func _join_room(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	# BUG FIX: "Lambda capture at index 0 was freed" — VSPanel (self) or this
	# http node can be freed mid-flight (panel closed/queue_free'd, or a
	# window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				var room2 : Dictionary = d.get("room", {})
				if d.has("pay_to"):   room2["pay_to"]   = d["pay_to"]
				if d.has("pay_memo"): room2["pay_memo"] = d["pay_memo"]
				if d.has("viewer_is_pending_opponent"): room2["viewer_is_pending_opponent"] = d["viewer_is_pending_opponent"]
				cb.call(true, room2)
				return
		cb.call(false, {})
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/join"), _headers(true), HTTPClient.METHOD_POST, "{}")


## Claims this player's SINGLE play attempt on the server BEFORE the round starts
## — the network-safe lock. cb(ok, room, code, err): ok=true only on a real 200
## (round may start with room.seed). On failure ok=false and (code, err) tell the
## caller whether it was "already_played" (409 — show result/waiting) or a
## transport failure (no/!=200 — "check your connection", DON'T start the round).
func _start_play(room_id: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if not cb.is_valid(): return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				cb.call(true, d.get("room", {}), 200, "")
				return
			cb.call(false, {}, code, "bad_response")
			return
		# Non-200: pull the backend error code ("already_played", etc.) if present.
		var err_reason := ""
		if body != null:
			var j2 := JSON.new()
			if j2.parse(body.get_string_from_utf8()) == OK:
				var d2 = j2.get_data()
				if d2 is Dictionary: err_reason = str(d2.get("error", ""))
		cb.call(false, {}, code, err_reason)
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/start"), _headers(true), HTTPClient.METHOD_POST, "{}")


func _confirm_payment(room_id: String, tx_hash: String, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 20.0   # RPC lookup server-side can take a moment
	add_child(http)
	# BUG FIX: "Lambda capture at index 0 was freed" — VSPanel (self) or this
	# http node can be freed mid-flight (panel closed/queue_free'd, or a
	# window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		var ok : bool = result == HTTPRequest.RESULT_SUCCESS and code == 200
		var err_reason := ""
		if not ok and body != null:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d = j.get_data()
				if typeof(d) == TYPE_DICTIONARY:
					err_reason = str(d.get("error", ""))
		cb.call(ok, err_reason)
	)
	var body_str := JSON.stringify({"tx_hash": tx_hash})
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/pay"), _headers(true), HTTPClient.METHOD_POST, body_str)


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
	# BUG FIX: "Lambda capture at index 0 was freed" — VSPanel (self) or this
	# http node can be freed mid-flight (panel closed/queue_free'd, or a
	# window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				cb.call(true, j.get_data().get("room", {}))
				return
		cb.call(false, {})
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/vsroom/" + room_id.uri_encode() + "/forfeit"), _headers(true), HTTPClient.METHOD_POST, "{}")


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
	# BUG FIX: "Lambda capture at index 0 was freed" — VSPanel (self) or this
	# http node can be freed mid-flight (panel closed/queue_free'd, or a
	# window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if not is_instance_valid(btn): return
		btn.disabled = false
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			btn.text = "Replay"
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
		var gyro_active : bool = bool(d.get("gyro_active", false))
		var nickname : String = str(d.get("nickname", ""))
		var player_seed : int = int(str(d.get("player_seed", "0")))
		var address  : String = str(d.get("player_id", ""))
		if log_b64 == "" or seed == 0: return
		var log_bytes := Marshalls.base64_to_raw(log_b64)
		if log_bytes.is_empty(): return
		replay_requested.emit(seed, log_bytes, char_idx, nickname, player_seed, address, gyro_active)
		hide_panel.call_deferred()
		closed.emit.call_deferred()
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/replay/" + session_id_e), _headers())


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
	# If we've already loaded the real identicon for this address+size, use it
	# straight away — no fallback flash, no re-load. This is what stops the VS
	# detail's 4s poll re-render from briefly dropping every avatar back to the
	# colored placeholder before the async load swaps the real one back in.
	var real_key := address + "@" + str(size)
	if _nimiq_avatar_cache.has(real_key):
		tr.texture = _nimiq_avatar_cache[real_key]
		return tr
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
		var tex := _png_base64_to_tex(result)
		if tex != null:
			# Cache the real identicon so future re-renders (the 4s poll) reuse it
			# instantly instead of flashing the fallback and re-loading.
			_nimiq_avatar_cache[address + "@" + str(size)] = tex
			if is_instance_valid(target):
				(target as TextureRect).texture = tex
		return


func _png_base64_to_tex(data_url: String) -> ImageTexture:
	if DisplayServer.get_name() == "headless": return null
	if not data_url.begins_with("data:image/png;base64,"): return null
	var b64   := data_url.substr(len("data:image/png;base64,")).strip_edges()
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.is_empty(): return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK: return null
	return ImageTexture.create_from_image(img)
