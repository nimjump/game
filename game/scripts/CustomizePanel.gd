extends CanvasLayer
## CustomizePanel.gd — Character customization shop: buy/equip hats,
## glasses, outfits, shoes with NIM. Same visual language & panel-shell
## pattern as VSPanel/QuestPanel/StatsPanel (UITheme, warm-bej card).
##
## Payment flow mirrors VS room entry fees exactly: fetch catalog (server
## hands back pay_to + a per-item pay_memo so this client never constructs
## the memo string itself) -> NimiqJS.request_payment() pops the real wallet
## approval UI -> POST the resulting tx hash to /backend/cosmetics/buy for
## server-side verification -> equip via /backend/cosmetics/equip.
##
## Art note: until real PNGs exist at res://assets/cosmetics/<slot>/<id>.png,
## every item shows a generated pastel placeholder swatch here (and renders
## invisible on the actual character — see Player.gd's set_cosmetics()).
## Nothing else needs to change once the art is dropped in.

signal closed
signal cosmetics_changed(equipped: Dictionary)  # Main.gd pushes this straight to the live player preview

var BACKEND_URL : String = ApiConfig.base_url()
const UITheme := preload("res://scripts/UITheme.gd")
const _COL_ICON      := Color(0.780, 0.380, 0.120)
const _COL_TEXT_DARK := Color(0.220, 0.130, 0.060)
const _COL_TEXT_MID  := Color(0.480, 0.340, 0.200)

const SLOTS : Array[String] = ["hat", "glasses", "outfit", "shoes"]
const SLOT_LABELS := {"hat": "Hats", "glasses": "Glasses", "outfit": "Outfits", "shoes": "Shoes"}

var _player_id  : String = ""
var _auth_token : String = ""

var _panel_ctrl : Control
var _view_root  : VBoxContainer
var _anim_tween : Tween = null

var _catalog  : Array = []      # [{id,name,slot,price_nim,pay_memo}, ...]
var _pay_to   : String = ""
var _owned    : Array = []      # [item_id, ...]
var _equipped : Dictionary = {} # slot -> item_id
var _active_slot : String = "hat"
var _loaded   : bool = false

var _title_lbl    : Label
var _tab_buttons  : Dictionary = {}  # slot -> Button


func setup(player_id: String) -> void:
	_player_id = player_id
	_build_ui()
	hide()


func set_auth_token(token: String) -> void:
	_auth_token = token


## Fetch + apply equipped cosmetics WITHOUT opening the panel — called right
## after login so the player's saved hat/glasses/etc. show up immediately,
## not only the first time they open Customize.
func refresh() -> void:
	_fetch_catalog()


func _as_array(v) -> Array:
	return v if v is Array else []


# ── Panel open / close (same pattern as VSPanel) ────────────────────────────
func show_panel() -> void:
	if is_instance_valid(_anim_tween): _anim_tween.kill()
	show()
	if is_instance_valid(_panel_ctrl):
		# BUG FIX ("panel pops in from the top-left corner") — see VSPanel.gd's
		# show_panel() doc comment for the full explanation. Same fix here.
		_panel_ctrl.pivot_offset = _panel_ctrl.size * 0.5
		_panel_ctrl.modulate.a = 0.0
		_panel_ctrl.scale      = Vector2(0.92, 0.92)
		_anim_tween = create_tween()
		if _anim_tween:
			_anim_tween.set_parallel(true)
			_anim_tween.tween_property(_panel_ctrl, "modulate:a", 1.0,        0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_anim_tween.tween_property(_panel_ctrl, "scale",      Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_fetch_catalog()


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


func _ref() -> float:
	var vp := get_viewport()
	if not vp: return GameConstants.VW
	return minf(minf(vp.get_visible_rect().size.x, vp.get_visible_rect().size.y), GameConstants.VW)


func _mpad(h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   h)
	mc.add_theme_constant_override("margin_right",  h)
	mc.add_theme_constant_override("margin_top",    v)
	mc.add_theme_constant_override("margin_bottom", v)
	return mc


func _make_card() -> PanelContainer:
	var card := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(1.0, 0.97, 0.90, 0.9)
	st.set_corner_radius_all(12)
	st.content_margin_left   = 14
	st.content_margin_right  = 14
	st.content_margin_top    = 10
	st.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", st)
	return card


func _make_nim_icon(size: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load("res://assets/items/nimiq_hexagon_item.png") as Texture2D
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tr.custom_minimum_size = Vector2(size, size)
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return tr


func _close_btn_style(btn: Button, corner: int) -> void:
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new()
	for s in [sn, sh, sp]: s.set_corner_radius_all(corner)
	sn.bg_color = Color(0.780, 0.380, 0.120)
	sh.bg_color = Color(0.820, 0.450, 0.160)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	btn.add_theme_stylebox_override("normal",  sn)
	btn.add_theme_stylebox_override("hover",   sh)
	btn.add_theme_stylebox_override("pressed", sp)
	btn.flat = false


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

	hdr.add_child(UITheme.lucide_icon("sparkles", int(ref * 0.038), _COL_ICON))

	_title_lbl = Label.new()
	_title_lbl.text = "Customize"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_title_lbl, _COL_TEXT_DARK, int(ref * 0.048))
	hdr.add_child(_title_lbl)

	var close_sz := int(ref * 0.092)
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
	close_icon.custom_minimum_size = Vector2(int(close_sz * 0.72), int(close_sz * 0.72))
	close_center.add_child(close_icon)
	hdr.add_child(close_btn)

	var sep := ColorRect.new()
	sep.color = Color(0.4, 0.4, 0.4, 0.3)
	sep.custom_minimum_size.y = 1
	outer.add_child(sep)

	# ── Slot tabs ──
	var tabs_mc := _mpad(pad, int(pad * 0.5))
	outer.add_child(tabs_mc)
	var tabs := HBoxContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_theme_constant_override("separation", int(ref * 0.012))
	tabs_mc.add_child(tabs)
	for slot in SLOTS:
		var tb := Button.new()
		tb.text = str(SLOT_LABELS.get(slot, slot))
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.toggle_mode = true
		tb.pressed.connect(_select_slot.bind(slot))
		tabs.add_child(tb)
		_tab_buttons[slot] = tb

	var sep2 := ColorRect.new()
	sep2.color = Color(0.4, 0.4, 0.4, 0.3)
	sep2.custom_minimum_size.y = 1
	outer.add_child(sep2)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	outer.add_child(scroll)

	var content_mc := _mpad(pad, pad)
	content_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_mc)

	_view_root = VBoxContainer.new()
	_view_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_root.add_theme_constant_override("separation", int(ref * 0.016))
	content_mc.add_child(_view_root)

	_refresh_tab_styles()


func _select_slot(slot: String) -> void:
	_active_slot = slot
	_refresh_tab_styles()
	_render_list()


func _refresh_tab_styles() -> void:
	for slot in _tab_buttons.keys():
		var btn : Button = _tab_buttons[slot]
		btn.button_pressed = (slot == _active_slot)
		var st := StyleBoxFlat.new()
		st.set_corner_radius_all(8)
		st.bg_color = Color(0.780, 0.380, 0.120) if slot == _active_slot else Color(0.700, 0.520, 0.340, 0.20)
		btn.add_theme_stylebox_override("normal",  st)
		btn.add_theme_stylebox_override("pressed", st)
		btn.add_theme_color_override("font_color", Color.WHITE if slot == _active_slot else _COL_TEXT_DARK)


# ── Networking ───────────────────────────────────────────────────────────────
func _headers(json_body: bool = false) -> PackedStringArray:
	var h : PackedStringArray = []
	if json_body: h.append("Content-Type: application/json")
	if _auth_token != "": h.append("Authorization: Bearer " + _auth_token)
	return h


func _fetch_catalog() -> void:
	if not is_instance_valid(_view_root): return
	if _player_id == "":
		_render_list()
		return
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	# BUG FIX: "Lambda capture at index 0 was freed" — CustomizePanel (self)
	# or this http node can be freed mid-flight (panel closed/queue_free'd,
	# or a window-resize rebuild) before the response lands.
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
				_catalog  = _as_array(d.get("catalog", []))
				_pay_to   = str(d.get("pay_to", ""))
				_owned    = _as_array(d.get("owned", []))
				var eq = d.get("equipped", {})
				_equipped = eq if eq is Dictionary else {}
				_loaded = true
				cosmetics_changed.emit(_equipped)
		_render_list()
	)
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/cosmetics/catalog"), _headers())


# ── List view ────────────────────────────────────────────────────────────────
func _render_list() -> void:
	if not is_instance_valid(_view_root): return
	for c in _view_root.get_children():
		c.queue_free()
	var ref := _ref()

	if _player_id == "":
		var lbl := Label.new()
		lbl.text = "Connect your wallet to customize your character."
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(lbl, _COL_TEXT_MID, int(ref * 0.030))
		_view_root.add_child(lbl)
		return

	if not _loaded:
		var lbl2 := Label.new()
		lbl2.text = "Loading…"
		lbl2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(lbl2, _COL_TEXT_MID, int(ref * 0.030))
		_view_root.add_child(lbl2)
		return

	var items : Array = []
	for it in _catalog:
		if typeof(it) == TYPE_DICTIONARY and str(it.get("slot", "")) == _active_slot:
			items.append(it)

	if items.is_empty():
		var lbl3 := Label.new()
		lbl3.text = "No items yet — check back soon!"
		lbl3.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		UITheme.apply_label(lbl3, _COL_TEXT_MID, int(ref * 0.028))
		_view_root.add_child(lbl3)
		return

	for it in items:
		_view_root.add_child(_build_item_card(it, ref))


func _placeholder_swatch(name_str: String, size: int) -> ImageTexture:
	# Deterministic pastel color from the item name — stand-in art until the
	# real PNG exists at assets/cosmetics/<slot>/<id>.png.
	var h := 0
	for c in name_str: h = (h * 31 + c.unicode_at(0)) % 360
	var col := Color.from_hsv(float(h) / 360.0, 0.45, 0.92)
	var img := Image.create(maxi(1, size), maxi(1, size), false, Image.FORMAT_RGBA8)
	img.fill(col)
	return ImageTexture.create_from_image(img)


func _build_item_card(item: Dictionary, ref: float) -> Control:
	var item_id  : String = str(item.get("id", ""))
	var name_str : String = str(item.get("name", item_id))
	var price    : float  = float(item.get("price_nim", 0.0))
	var pay_memo : String = str(item.get("pay_memo", ""))
	var owned    : bool   = _owned.has(item_id)
	var equipped_here : bool = str(_equipped.get(_active_slot, "")) == item_id

	var card := _make_card()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(ref * 0.02))
	card.add_child(row)

	var swatch := TextureRect.new()
	swatch.custom_minimum_size = Vector2(int(ref * 0.11), int(ref * 0.11))
	var icon_path := "res://assets/cosmetics/%s/%s.png" % [_active_slot, item_id]
	if ResourceLoader.exists(icon_path):
		swatch.texture = load(icon_path)
		swatch.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	else:
		swatch.texture = _placeholder_swatch(name_str, int(ref * 0.11))
	row.add_child(swatch)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = name_str
	UITheme.apply_label(name_lbl, _COL_TEXT_DARK, int(ref * 0.034))
	info.add_child(name_lbl)

	var price_row := HBoxContainer.new()
	price_row.add_theme_constant_override("separation", int(ref * 0.01))
	info.add_child(price_row)
	if owned:
		var owned_lbl := Label.new()
		owned_lbl.text = "Equipped" if equipped_here else "Owned"
		UITheme.apply_label(owned_lbl, Color(0.2, 0.6, 0.25), int(ref * 0.026))
		price_row.add_child(owned_lbl)
	else:
		price_row.add_child(_make_nim_icon(int(ref * 0.03)))
		var price_lbl := Label.new()
		price_lbl.text = "%.0f NIM" % price
		UITheme.apply_label(price_lbl, _COL_TEXT_MID, int(ref * 0.030))
		price_row.add_child(price_lbl)

	var action_btn := Button.new()
	action_btn.custom_minimum_size = Vector2(int(ref * 0.26), int(ref * 0.08))
	if equipped_here:
		action_btn.text = "Unequip"
		UITheme.apply_button(action_btn)
		action_btn.pressed.connect(_do_equip.bind("", action_btn))
	elif owned:
		action_btn.text = "Equip"
		UITheme.apply_primary_button(action_btn)
		action_btn.pressed.connect(_do_equip.bind(item_id, action_btn))
	else:
		action_btn.text = "Buy"
		UITheme.apply_primary_button(action_btn)
		action_btn.pressed.connect(_do_buy.bind(item_id, price, pay_memo, action_btn))
	row.add_child(action_btn)

	return card


# ── Buy / equip actions ──────────────────────────────────────────────────────
func _do_buy(item_id: String, price_nim: float, pay_memo: String, btn: Button) -> void:
	if _pay_to == "":
		var t0 := Toast.get_instance()
		if t0: t0.show_toast("Payment info unavailable — reopen Customize and try again.", Toast.Kind.ERROR)
		return
	btn.disabled = true
	btn.text = "Waiting for wallet..."
	var value_luna := int(round(price_nim * 100000.0))  # NimLunaMultiplier
	var result : Dictionary = await NimiqJS.request_payment(_pay_to, value_luna, pay_memo)
	if not bool(result.get("ok", false)):
		var t1 := Toast.get_instance()
		if t1: t1.show_toast("Payment failed: " + str(result.get("err", "unknown")), Toast.Kind.ERROR)
		btn.disabled = false
		btn.text = "Buy"
		return
	btn.text = "Confirming..."
	var tx : String = str(result.get("tx", ""))
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	# BUG FIX: "Lambda capture at index 0 was freed" — CustomizePanel (self)
	# or this http node can be freed mid-flight (panel closed/queue_free'd,
	# or a window-resize rebuild) before the response lands.
	var _alive : WeakRef = weakref(self)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result2, code, _h, body):
		if not is_instance_valid(http): return
		http.queue_free()
		if _alive.get_ref() == null: return
		if result2 == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				_owned = _as_array(d.get("owned", []))
				var eq = d.get("equipped", {})
				_equipped = eq if eq is Dictionary else {}
			var t2 := Toast.get_instance()
			if t2: t2.show_toast("Purchased!", Toast.Kind.SUCCESS)
			cosmetics_changed.emit(_equipped)
			_render_list()
		else:
			# Same guarantee as VS room payments: the backend also reconciles
			# incoming wallet transactions on its own every ~90s, so a failed
			# confirm call here doesn't lose the purchase.
			var t3 := Toast.get_instance()
			if t3: t3.show_toast("Payment sent — confirming automatically, reopen Customize in a bit.", Toast.Kind.ERROR)
			btn.disabled = false
			btn.text = "Buy"
	)
	var body_str := JSON.stringify({"item_id": item_id, "tx_hash": tx})
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/cosmetics/buy"), _headers(true), HTTPClient.METHOD_POST, body_str)


func _do_equip(item_id: String, btn: Button) -> void:
	btn.disabled = true
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	# BUG FIX: "Lambda capture at index 0 was freed" — CustomizePanel (self)
	# or this http node can be freed mid-flight (panel closed/queue_free'd,
	# or a window-resize rebuild) before the response lands.
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
				var eq = d.get("equipped", {})
				_equipped = eq if eq is Dictionary else {}
			cosmetics_changed.emit(_equipped)
			_render_list()
		else:
			btn.disabled = false
			var t := Toast.get_instance()
			if t: t.show_toast("Could not update — try again.", Toast.Kind.ERROR)
	)
	var body_str := JSON.stringify({"slot": _active_slot, "item_id": item_id})
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/cosmetics/equip"), _headers(true), HTTPClient.METHOD_POST, body_str)
