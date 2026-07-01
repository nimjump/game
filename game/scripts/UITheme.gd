extends RefCounted
# class_name UITheme — loaded via preload, removed to prevent class_name conflicts

# ═══════════════════════════════════════════════════════
#  UITheme.gd — Bubble v1.0 Complete UI Styling Template
#  Only sets pixel ratios and visuals of the interface.
# ═══════════════════════════════════════════════════════

# ── UT-01: Static caches — allocated once, reused forever ──
static var _cached_assets    : Dictionary = {}
static var _cached_font      : FontFile   = null
static var _font_loaded      : bool       = false
static var _bg_tex_cache     : Dictionary = {}   # index → Texture2D
static var _bg_id_to_index   : Dictionary = {}   # id string → int (UT-05)
static var _cached_empty_box : StyleBoxEmpty = null

# ── Active Theme Selection ───────────────────────────────
const ACTIVE_THEME := "Yellow"

# ── Color Palette (kept for compatibility with other code) ──
const COL_BG          := Color(0.067, 0.082, 0.149)
const COL_SURFACE     := Color(0.110, 0.133, 0.220)
const COL_SURFACE2    := Color(0.149, 0.176, 0.275)
const COL_GOLD        := Color(0.000, 0.000, 0.000)
const COL_GOLD_DARK   := Color(0.000, 0.000, 0.000)
const COL_BLUE        := Color(0.129, 0.588, 0.953)
const COL_BLUE_DARK   := Color(0.063, 0.400, 0.780)
const COL_GREEN       := Color(0.122, 0.878, 0.529)
const COL_GREEN_DARK  := Color(0.059, 0.671, 0.388)
const COL_RED         := Color(0.996, 0.275, 0.275)
const COL_RED_DARK    := Color(0.780, 0.118, 0.118)
const COL_ORANGE      := Color(1.000, 0.518, 0.094)
const COL_ORANGE_DARK := Color(0.820, 0.369, 0.031)
const COL_TEXT        := Color(0.961, 0.965, 0.988)
const COL_TEXT_DIM    := Color(0.620, 0.643, 0.737)
const COL_TEXT_DARK   := Color(0.067, 0.082, 0.149)

# ── Font ─────────────────────────────────────────────────
const PIXEL_FONT_PATH := "res://assets/fonts/KartwoFilled.ttf"

# ── ASSET YOLLARI ────────────────────────────────────────
const UI := "res://assets/NewUI/"

# ── ARKA PLAN (BACKGROUND) TEMALARI ───────────────────────
# 8 independent themes — NOT RANDOM, selected manually by index or id.
# The order below is the order displayed/selectable in-game.
const BG_PATH := "res://assets/backgrounds/"

const BACKGROUNDS := [
	{"id": "fall",       "name": "Autumn",       "file": "backgroundColorFall.png"},
	{"id": "forest",     "name": "Forest",       "file": "backgroundColorForest.png"},
	{"id": "grass",      "name": "Meadow",       "file": "backgroundColorGrass.png"},
	{"id": "desert",     "name": "Desert",       "file": "backgroundColorDesert.png"},
	{"id": "sky",        "name": "Open Sky",     "file": "backgroundEmpty.png"},
	{"id": "ice_forest", "name": "Snow Forest",  "file": "backgroundForest.png"},
	{"id": "castle",     "name": "Castle",       "file": "backgroundCastles.png"},
	{"id": "ice_desert", "name": "Glacial Desert","file": "backgroundDesert.png"},
	{"id": "candy",      "name": "Candy Land",   "file": "backgroundColorFall.png"},
]

static func get_theme_assets(_theme_name: String = ACTIVE_THEME) -> Dictionary:
	if not _cached_assets.is_empty(): return _cached_assets
	var u := UI
	_cached_assets = {
		# ── Paneller ──
		"panel_1":          u + "panel_lg_normal.png",
		"panel_2":          u + "panel_lg_normal.png",
		"panel_3":          u + "panel_md_normal.png",
		"popup_1":          u + "panel_sm_normal.png",
		# ── All buttons — same beige sprite, hover=pressed (no ►PLAY text) ──
		"btn_1_normal":     u + "btn_wide_normal.png",
		"btn_1_hover":      u + "btn_wide_normal.png",
		"btn_1_pressed":    u + "btn_wide_pressed.png",
		"btn_2_normal":     u + "btn_wide_normal.png",
		"btn_2_hover":      u + "btn_wide_normal.png",
		"btn_2_pressed":    u + "btn_wide_pressed.png",
		"btn_3_normal":     u + "btn_wide_normal.png",
		"btn_3_hover":      u + "btn_wide_normal.png",
		"btn_3_pressed":    u + "btn_wide_pressed.png",
		# ── Kare butonlar (pause) ──
		"sq_pause_n":       u + "btn_wide_normal.png",
		"sq_pause_h":       u + "btn_wide_normal.png",
		"sq_play_n":        u + "btn_wide_normal.png",
		"sq_play_h":        u + "btn_wide_normal.png",
		# ── Selector ◄► ──
		"selector_left":    u + "btn_sm_right_normal.png",
		"selector_left_h":  u + "btn_sm_right_hover.png",
		"selector_right":   u + "btn_sm_normal.png",
		"selector_right_h": u + "btn_sm_normal_hover.png",
		# ── Toggle ──
		"toggle_off":       u + "toggle_off.png",
		"toggle_on":        u + "toggle_on.png",
		# ── Slider ──
		"slider_bg":        u + "slider_track_1.png",
		"slider_fill":      u + "slider_track_2.png",
		"slider_grabber":   u + "slider.png",
		# ── Sound icons (lucide) ──
		"icon_sound_on":    "res://assets/icons/lucide/volume-2.png",
		"icon_sound_mid":   "res://assets/icons/lucide/volume-1.png",
		"icon_sound_off":   "res://assets/icons/lucide/volume-x.png",
		"icon_music":       "res://assets/icons/lucide/music.png",
		"icon_play":        "res://assets/icons/lucide/play.png",
		"icon_pause":       "res://assets/icons/lucide/pause.png",
		"icon_arrow_left":  "res://assets/icons/lucide/arrow-left.png",
		"icon_arrow_right": "res://assets/icons/lucide/arrow-right.png",
		# ── Cursor ──
		"cursor_hand":      u + "cursor_hand.png",
	}
	return _cached_assets

# ── PROPORTION SETTING: Constructor That Prevents Edge Distortion While Stretching ──
static func _nine_patch(
		path: String,
		margin_l: int = 6, margin_r: int = 6,
		margin_t: int = 6, margin_b: int = 6) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	if ResourceLoader.exists(path):
		s.texture = load(path)
	s.region_rect             = Rect2()
	# Margins equalized so edges (roundings) don't stretch and distort
	s.texture_margin_left     = margin_l
	s.texture_margin_right    = margin_r
	s.texture_margin_top      = margin_t
	s.texture_margin_bottom   = margin_b
	s.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	s.axis_stretch_vertical   = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return s

# ── PROPORTION SETTING: Function to Reset Inner Padding ──
# Values zeroed so button size is entirely determined by what you manually set in Godot.
static func _with_no_padding(s: StyleBoxTexture) -> StyleBoxTexture:
	s.content_margin_left   = 0
	s.content_margin_right  = 0
	s.content_margin_top    = 0
	s.content_margin_bottom = 0
	return s

## Returns ImageTexture from a solid-color Image (for HSlider grabber icon)
static func _solid_texture(color: Color, w: int, h: int) -> ImageTexture:
	if DisplayServer.get_name() == "headless": return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

# ── PANELS (Visual Proportioning) ─────────────────────────
static func apply_panel(panel: Control, _color: Color = Color.WHITE) -> void:
	var assets := get_theme_assets()
	var s := _with_no_padding(_nine_patch(assets["panel_1"], 8, 8, 8, 8))
	panel.add_theme_stylebox_override("panel", s)

static func apply_panel_grey(panel: Control) -> void:
	var assets := get_theme_assets()
	var s := _with_no_padding(_nine_patch(assets["panel_2"], 8, 8, 8, 8))
	panel.add_theme_stylebox_override("panel", s)

static func apply_panel_dark(panel: Control) -> void:
	var assets := get_theme_assets()
	var s := _with_no_padding(_nine_patch(assets["popup_1"], 8, 8, 8, 8))
	panel.add_theme_stylebox_override("panel", s)

static func apply_bottom_bar(panel: Control) -> void:
	var s := _with_no_padding(_nine_patch(UI + "panel_bar_horizontal.png", 16, 16, 16, 16))
	panel.add_theme_stylebox_override("panel", s)

# ── BUTTONS (Size and Layout Proportioning) ────────────────
static func _apply_hand_cursor(btn: Control) -> void:
	var assets := get_theme_assets()
	var cp : String = assets.get("cursor_hand", "")
	if ResourceLoader.exists(cp):
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func apply_button(btn: Button, _color: Color = COL_GOLD, _text_color: Color = COL_TEXT) -> void:
	var assets   := get_theme_assets()
	var normal   := _with_no_padding(_nine_patch(assets["btn_1_normal"], 6, 6, 6, 6))
	var hover    := _with_no_padding(_nine_patch(assets["btn_1_hover"],  6, 6, 6, 6))
	var pressed  := _with_no_padding(_nine_patch(assets["btn_1_pressed"],6, 6, 6, 6))
	var disabled := _with_no_padding(_nine_patch(assets["btn_1_normal"], 6, 6, 6, 6))
	var focus    := _with_no_padding(_nine_patch(assets["btn_1_normal"], 6, 6, 6, 6))

	btn.add_theme_stylebox_override("normal",   normal)
	btn.add_theme_stylebox_override("hover",    hover)
	btn.add_theme_stylebox_override("pressed",  pressed)
	btn.add_theme_stylebox_override("focus",    focus)
	btn.add_theme_stylebox_override("disabled", disabled)

	# Hover'da hafif karartma
	hover.modulate_color = Color(0.88, 0.80, 0.70, 1.0)

	btn.add_theme_color_override("font_color",          COL_TEXT_DARK)
	btn.add_theme_color_override("font_hover_color",    COL_TEXT_DARK)
	btn.add_theme_color_override("font_pressed_color",  COL_TEXT_DARK)
	_apply_pixel_font(btn)
	_apply_hand_cursor(btn)

static func apply_play_button(btn: Button) -> void:
	var assets  := get_theme_assets()
	var normal  := _with_no_padding(_nine_patch(assets["btn_2_normal"],  6, 6, 6, 6))
	var hover   := _with_no_padding(_nine_patch(assets["btn_2_hover"],   6, 6, 6, 6))
	var pressed := _with_no_padding(_nine_patch(assets["btn_2_pressed"], 6, 6, 6, 6))

	btn.add_theme_stylebox_override("normal",  normal)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color", COL_TEXT_DARK)
	_apply_pixel_font(btn)
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_hand_cursor(btn)

static func apply_ghost_button(btn: Button, _color: Color = COL_GOLD) -> void:
	var assets  := get_theme_assets()
	var normal  := _with_no_padding(_nine_patch(assets["btn_3_normal"],  6, 6, 6, 6))
	var hover   := _with_no_padding(_nine_patch(assets["btn_3_hover"],   6, 6, 6, 6))
	var pressed := _with_no_padding(_nine_patch(assets["btn_3_pressed"], 6, 6, 6, 6))

	btn.add_theme_stylebox_override("normal",  normal)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color", COL_TEXT_DARK)
	_apply_pixel_font(btn)
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_hand_cursor(btn)

static func apply_primary_button(btn: Button) -> void:
	apply_button(btn)

# ── SLIDERS (Volume Bar Proportioning) ─────────────────────
static func apply_slider(slider: HSlider) -> void:
	var assets := get_theme_assets()

	# Track arka plan — ince çizgi
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.580, 0.380, 0.220, 0.5)
	bg.set_corner_radius_all(3)
	bg.content_margin_top    = 3
	bg.content_margin_bottom = 3

	# Fill (dolu kısım)
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = Color(0.318, 0.576, 0.224)
	fill_sb.set_corner_radius_all(3)
	fill_sb.content_margin_top    = 3
	fill_sb.content_margin_bottom = 3

	slider.add_theme_stylebox_override("slider",                  bg)
	slider.add_theme_stylebox_override("grabber_area",           fill_sb)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_sb)

	# Grabber — slider.png asset'ini kullan, 1/5 oraninda kucult
	var grabber_path : String = assets["slider_grabber"]
	if ResourceLoader.exists(grabber_path):
		var grabber_tex := load(grabber_path) as Texture2D
		var img := grabber_tex.get_image()
		var new_w : int = max(1, img.get_width() / 5)
		var new_h : int = max(1, img.get_height() / 5)
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
		var small_tex := ImageTexture.create_from_image(img)
		slider.add_theme_icon_override("grabber",           small_tex)
		slider.add_theme_icon_override("grabber_highlight", small_tex)
		slider.add_theme_icon_override("grabber_disabled",  small_tex)
	slider.add_theme_constant_override("grabber_offset", 0)

# ── SELECTORS (Character Left/Right Selection Buttons) ─────
# Use TextureButton — texture covers full size, no overflow
static func make_selector_button(is_left: bool, size: int) -> TextureButton:
	var assets  := get_theme_assets()
	var key_n   := "selector_left"   if is_left else "selector_right"
	var key_h   := "selector_left_h" if is_left else "selector_right_h"
	var btn     := TextureButton.new()
	btn.custom_minimum_size = Vector2(size, size)
	btn.stretch_mode        = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.ignore_texture_size = true
	if ResourceLoader.exists(assets[key_n]):
		btn.texture_normal  = load(assets[key_n])
		btn.texture_pressed = load(assets[key_n])
	if ResourceLoader.exists(assets[key_h]):
		btn.texture_hover = load(assets[key_h])
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return btn

static func _get_empty_box() -> StyleBoxEmpty:
	if not _cached_empty_box:
		_cached_empty_box = StyleBoxEmpty.new()
	return _cached_empty_box

static func apply_selector_left_button(btn: Button) -> void:
	var assets := get_theme_assets()
	if ResourceLoader.exists(assets["selector_left"]):
		btn.icon = load(assets["selector_left"])
		btn.flat = true
		btn.expand_icon = true
		btn.text = ""
		var eb := _get_empty_box()
		for s in ["normal","hover","pressed","focus","disabled"]:
			btn.add_theme_stylebox_override(s, eb)
	_apply_hand_cursor(btn)

static func apply_selector_right_button(btn: Button) -> void:
	var assets := get_theme_assets()
	if ResourceLoader.exists(assets["selector_right"]):
		btn.icon = load(assets["selector_right"])
		btn.flat = true
		btn.expand_icon = true
		btn.text = ""
		var eb := _get_empty_box()
		for s in ["normal","hover","pressed","focus","disabled"]:
			btn.add_theme_stylebox_override(s, eb)
	_apply_hand_cursor(btn)

# ── TOGGLES (On / Off Button) ───────────────────────────────
static func apply_toggle_button(btn: CheckButton, icon_height: int = 36) -> void:
	var assets := get_theme_assets()
	if ResourceLoader.exists(assets["toggle_off"]) and ResourceLoader.exists(assets["toggle_on"]):
		var tex_on  := load(assets["toggle_on"])  as Texture2D
		var tex_off := load(assets["toggle_off"]) as Texture2D
		btn.add_theme_icon_override("checked",               tex_on)
		btn.add_theme_icon_override("checked_mirrored",      tex_on)
		btn.add_theme_icon_override("checked_disabled",      tex_on)
		btn.add_theme_icon_override("unchecked",             tex_off)
		btn.add_theme_icon_override("unchecked_mirrored",    tex_off)
		btn.add_theme_icon_override("unchecked_disabled",    tex_off)
		btn.add_theme_constant_override("icon_max_width", icon_height * 2)
		var eb := _get_empty_box()
		btn.add_theme_stylebox_override("normal",   eb)
		btn.add_theme_stylebox_override("hover",    eb)
		btn.add_theme_stylebox_override("pressed",  eb)
		btn.add_theme_stylebox_override("disabled", eb)
		btn.add_theme_stylebox_override("focus",    eb)
		btn.text = ""

# ── BACKGROUND SELECTOR FUNCTIONS ───────────────────────────
# These functions do NOT make random selections.
# Calling code specifies which theme it wants via index (0-7) or id ("forest" etc.).

static func get_background_count() -> int:
	return BACKGROUNDS.size()

# if index is out of bounds it is clamped to the nearest valid value (no crash)
static func get_background_data(index: int) -> Dictionary:
	var idx := clampi(index, 0, BACKGROUNDS.size() - 1)
	return BACKGROUNDS[idx]

static func get_background_texture(index: int) -> Texture2D:
	if _bg_tex_cache.has(index): return _bg_tex_cache[index]
	var data := get_background_data(index)
	var path: String = BG_PATH + String(data["file"])
	var tex : Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	else:
		push_warning("[UITheme] Background file NOT FOUND: " + path)
	_bg_tex_cache[index] = tex
	return tex

# search by id: returns the matching theme from the BACKGROUNDS array by "id" field
static func get_background_index_by_id(id: String) -> int:
	if _bg_id_to_index.is_empty():
		for i in BACKGROUNDS.size():
			_bg_id_to_index[BACKGROUNDS[i]["id"]] = i
	return _bg_id_to_index.get(id, 0)

static func get_background_texture_by_id(id: String) -> Texture2D:
	return get_background_texture(get_background_index_by_id(id))

# Calculates background index based on score.
# 4 biomes cycle every 500 pts: grass → desert → fall → sky → repeat (candy devre dışı)
static func get_background_index_for_score(score: int) -> int:
	const BIOME_INDICES := [0, 3, 4, 2]  # grass, desert, fall, sky
	var slot := (maxi(score, 0) / 500) % BIOME_INDICES.size()
	return BIOME_INDICES[slot]

# Applies the selected background to a TextureRect and scales it to cover the screen
static func apply_background(rect: TextureRect, index: int) -> void:
	var tex := get_background_texture(index)
	if tex:
		rect.texture = tex
		rect.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		print("[UITheme] apply_background SUCCESS index=", index, " rect_size=", rect.size, " tex_size=", tex.get_size())
	else:
		push_warning("[UITheme] apply_background: texture could not be loaded, index=" + str(index))

# ── LABEL & FONT ──────────────────────────────────────────
static func apply_label(lbl: Label, color: Color = COL_TEXT, size: int = 0) -> void:
	lbl.add_theme_color_override("font_color", color)
	var font_size := size
	if font_size <= 0:
		var vp := lbl.get_viewport() if lbl.is_inside_tree() else null
		var ref := minf(minf(vp.get_visible_rect().size.x, vp.get_visible_rect().size.y), GameConstants.VW) if vp else GameConstants.VW
		font_size = int(ref * 0.032)
	lbl.add_theme_font_size_override("font_size", font_size)
	_apply_pixel_font(lbl)

static func _apply_pixel_font(ctrl: Control) -> void:
	if not _font_loaded:
		_font_loaded = true
		if ResourceLoader.exists(PIXEL_FONT_PATH):
			_cached_font = load(PIXEL_FONT_PATH) as FontFile
	if _cached_font:
		ctrl.add_theme_font_override("font", _cached_font)

# ── FALLBACK FLAT VARIANTS ────────────────────────────────
static func make_flat_style(bg: Color, border: Color = Color.TRANSPARENT, corner: int = 10, border_w: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	return s

static func make_lifted_style(bg: Color, shadow: Color, corner: int = 10) -> StyleBoxFlat:
	return make_flat_style(bg)

# ── Lucide Icon helper ───────────────────────────────────
const LUCIDE_PATH := "res://assets/icons/lucide/"

# Returns a TextureRect for the given icon name (64x64 white PNG)
static func lucide_icon(name: String, size: int, color: Color = Color.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	var path := LUCIDE_PATH + name + ".png"
	if ResourceLoader.exists(path):
		tr.texture = load(path)
	tr.custom_minimum_size = Vector2(size, size)
	tr.size                = Vector2(size, size)
	tr.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.expand_mode         = TextureRect.EXPAND_IGNORE_SIZE
	tr.modulate            = color
	tr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tr.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	return tr
