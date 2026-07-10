extends CanvasLayer
## StreakPanel.gd — openable "Daily Streak" popup: current streak count,
## claimable NIM reward, Claim button. Opened by tapping the lobby streak
## badge (see Main.gd's _on_streak_badge_input) instead of claiming
## instantly on tap — same "open a panel, see the details, press the
## button" pattern as QuestPanel/LeaderboardPanel/StatsPanel.
##
## Talks directly to backend/handlers/streak.go (GET /backend/streak/status,
## POST /backend/streak/claim) — same self-contained HTTP-per-panel style
## QuestPanel.gd already uses, not routed through NimiqBridge.

signal closed

var BACKEND_URL : String = ApiConfig.base_url()   # resolved at runtime (same origin on web)
const UITheme := preload("res://scripts/UITheme.gd")

const _COL_ICON := Color(0.780, 0.380, 0.120)

var _auth_token : String = ""
var _panel_ctrl : Control
var _anim_tween : Tween = null

var _day_lbl        : Label
var _day_sub_lbl     : Label
var _amount_lbl     : Label
var _tomorrow_lbl   : Label
var _countdown_lbl  : Label
var _status_lbl     : Label
var _claim_btn      : Button
var _claiming       := false
var _calendar_row   : HBoxContainer
var _ref_px         := 0.0   # cached reference size from _build_ui, reused by _refresh_calendar's card-building
var _countdown_accum := 0.0  # _process accumulator — only recompute the countdown text once a second, not every frame

var _streak_day        := 0
var _claimable_nim     := 0.0
var _already_claimed   := false

# Reward formula params from the server (see backend/game/streak_reward.go's
# ComputeStreakReward: reward(day) = min(base + extra*(day-1), max)) — sent
# by GET /backend/streak/status alongside the per-day status so the panel can
# render a whole reward calendar, not just "today's number on a cold page".
# Defaults here match the backend's own hardcoded fallback (see
# defaultStreakRewardBaseNIM etc.) purely so the calendar isn't empty for the
# one frame before the first status response lands.
var _reward_base_nim  := 0.2
var _reward_extra_nim := 0.5
var _reward_max_nim   := 10.0


func setup() -> void:
	_build_ui()
	hide()


func set_auth_token(token: String) -> void:
	_auth_token = token


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
	# BUG FIX: this used to hide() only inside a tween.chain().tween_callback()
	# fired after the fade-out finished. If hide_panel() got called again
	# before that fade finished (e.g. a fast double-tap on the close button,
	# or the panel getting torn down/rebuilt while closing), the .kill() above
	# stops the tween WITHOUT running its chained callback — so hide() never
	# actually ran. This CanvasLayer (with its full-rect, input-blocking dim
	# ColorRect) was then left sitting on top of the lobby, invisibly eating
	# every tap and visually covering whatever's underneath (like the streak
	# badge), even though nothing looked obviously "open" anymore. Fix: hide
	# the layer immediately/synchronously first — never depend on a tween
	# finishing to actually leave the modal state — and treat the fade/scale
	# as a purely cosmetic animation on top of that, safe to interrupt.
	hide()
	if is_instance_valid(_panel_ctrl):
		_panel_ctrl.modulate.a = 1.0
		_panel_ctrl.scale      = Vector2.ONE


# ── UI ───────────────────────────────────────────────────────────
func _build_ui() -> void:
	var vp  := get_viewport()
	var vw  := vp.get_visible_rect().size.x if vp else GameConstants.VW
	var vh  := vp.get_visible_rect().size.y if vp else GameConstants.VH
	var ref := minf(minf(vw, vh), GameConstants.VW)
	_ref_px = ref
	var pad := int(ref * 0.025)
	var ic  := int(ref * 0.038)
	var pw  := ref * 0.85
	# BUG FIX: this stayed at 0.74 after the "current streak" subtitle and the
	# "Resets in HH:MM:SS" countdown rows were added below, so the body's
	# actual content needed more vertical space than the fixed-height
	# PanelContainer gave it — the panel's own rect is centered fine (the
	# anchor math never changed), but its content overflowed past the
	# bottom edge, which is exactly what reads as "the menu isn't centered
	# on screen" (everything visually bunched toward the top, spilling out
	# the bottom instead of sitting symmetrically inside the frame).
	var ph  := ref * 0.86

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
	outer.add_theme_constant_override("separation", int(ref * 0.018))
	pc.add_child(outer)

	# ── Header ──
	var hdr_mc := _mpad(pad, int(pad * 0.6))
	outer.add_child(hdr_mc)
	var hdr := HBoxContainer.new()
	hdr.alignment = BoxContainer.ALIGNMENT_CENTER
	hdr.add_theme_constant_override("separation", int(ref * 0.012))
	hdr_mc.add_child(hdr)

	hdr.add_child(UITheme.lucide_icon("calendar", ic, _COL_ICON))

	var title_lbl := Label.new()
	title_lbl.text = "DAILY STREAK"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title_lbl, Color(0.220, 0.130, 0.060), int(ref * 0.048))
	hdr.add_child(title_lbl)

	var close_sz    := int(ref * 0.092)
	var close_ic_sz := int(close_sz * 0.72)
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

	var sep := ColorRect.new()
	sep.color = Color(0.4, 0.4, 0.4, 0.3)
	sep.custom_minimum_size.y = 1
	outer.add_child(sep)

	# ── Body ──
	var body_mc := _mpad(pad, int(pad * 0.6))
	outer.add_child(body_mc)
	var body := VBoxContainer.new()
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", int(ref * 0.020))
	body_mc.add_child(body)

	# Big streak-day number — BUG FIX: no longer paired with a redundant
	# calendar icon (the header row above already has one right next to
	# "DAILY STREAK") — plain and centered on its own now, and toned down
	# from 0.060 to 0.052 so it doesn't dwarf the subtitle/countdown lines
	# below it (see their own size bumps a few lines down — the goal is a
	# readable size HIERARCHY, not one giant number next to unreadably tiny
	# captions).
	_day_lbl = Label.new()
	_day_lbl.text = "Day 0"
	_day_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_day_lbl, Color(0.220, 0.130, 0.060), int(ref * 0.052))
	body.add_child(_day_lbl)

	# "current streak" caption under the big "Day N" — echoes the same
	# "Day N" phrasing the calendar cards below already use (instead of a
	# separate "N day streak" sentence), so the whole panel reads as one
	# consistent day-counter idea instead of two different phrasings.
	_day_sub_lbl = Label.new()
	_day_sub_lbl.text = "current streak"
	_day_sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_day_sub_lbl, Color(0.460, 0.300, 0.160), int(ref * 0.034))
	body.add_child(_day_sub_lbl)

	# Claimable amount
	_amount_lbl = Label.new()
	_amount_lbl.text = ""
	_amount_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_amount_lbl, Color(0.240, 0.620, 0.220), int(ref * 0.042))
	body.add_child(_amount_lbl)

	# ── Reward calendar ── a horizontal strip of day-cards showing exactly
	# what each day pays, same "daily login calendar" language real games
	# use instead of a bare claim button with no context. Built/rebuilt by
	# _refresh_calendar() once we actually know the streak day + reward
	# formula from the server.
	#
	# BUG FIX: this used to be a ScrollContainer holding an 8-card window
	# (today ±2/+5) — at this panel's actual width, 8 cards never fit, so a
	# horizontal scrollbar always appeared, which looked like a UI bug
	# ("scroll çıktı, saçma") rather than an intentional feature. Swapped to
	# a plain CenterContainer (no scrolling at all) and _refresh_calendar()
	# below now only builds as many cards as comfortably fit the panel's
	# actual content width — see CALENDAR_DAYS_SHOWN's own comment.
	var cal_center := CenterContainer.new()
	cal_center.custom_minimum_size = Vector2(0, int(ref * 0.145))
	body.add_child(cal_center)
	_calendar_row = HBoxContainer.new()
	_calendar_row.add_theme_constant_override("separation", int(ref * 0.014))
	cal_center.add_child(_calendar_row)

	# Tomorrow preview — the explicit "what do I get if I come back tomorrow"
	# line, separate from _amount_lbl (which is specifically TODAY's claimable
	# amount) so both are visible at once instead of one overwriting the other.
	_tomorrow_lbl = Label.new()
	_tomorrow_lbl.text = ""
	_tomorrow_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(_tomorrow_lbl, Color(0.480, 0.340, 0.200), int(ref * 0.030))
	body.add_child(_tomorrow_lbl)

	# Live "resets in HH:MM:SS" countdown to the next UTC+3 day boundary —
	# ticked every second by _process() while the panel is open (see below).
	# Real daily-login-calendar UIs always show this alongside "come back
	# tomorrow" instead of leaving the player to guess when "tomorrow"
	# actually starts.
	_countdown_lbl = Label.new()
	_countdown_lbl.text = ""
	_countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Was 0.024 — noticeably smaller than the 0.030 "Tomorrow: +X NIM" line
	# right above it despite being equally important info; bumped closer to
	# match so the two read as a matched pair, not main-text/afterthought.
	UITheme.apply_label(_countdown_lbl, Color(0.500, 0.360, 0.220), int(ref * 0.028))
	body.add_child(_countdown_lbl)

	# Status / explanation line (also carries error/blocked messages)
	_status_lbl = Label.new()
	_status_lbl.text = "Come back every day to grow your streak."
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(_status_lbl, Color(0.440, 0.300, 0.180), int(ref * 0.026))
	body.add_child(_status_lbl)

	# Claim button
	_claim_btn = Button.new()
	_claim_btn.text = "Claim"
	_claim_btn.custom_minimum_size = Vector2(0, int(ref * 0.11))
	_claim_btn.disabled = true
	_warm_btn(_claim_btn, 10)
	_claim_btn.pressed.connect(_on_claim_pressed)
	body.add_child(_claim_btn)


# ── Backend ───────────────────────────────────────────────────────
func _refresh() -> void:
	if _auth_token == "":
		_status_lbl.text = "Connect your wallet to track your streak."
		_claim_btn.disabled = true
		return
	_status_lbl.text = "Loading..."
	_claim_btn.disabled = true

	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(ApiConfig.check_clock_skew)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var j := JSON.new()
			if j.parse(body.get_string_from_utf8()) == OK:
				var d : Dictionary = j.get_data()
				_streak_day      = int(d.get("streak_day", 0))
				_claimable_nim   = float(d.get("claimable_nim", 0.0))
				_already_claimed = bool(d.get("already_claimed", false))
				# Reward formula params — fall back to whatever we already had
				# (the hardcoded defaults on first load) if the server response
				# is missing a field for any reason, rather than zeroing them out.
				_reward_base_nim  = float(d.get("reward_base_nim", _reward_base_nim))
				_reward_extra_nim = float(d.get("reward_extra_per_day_nim", _reward_extra_nim))
				_reward_max_nim   = float(d.get("reward_max_nim", _reward_max_nim))
				_render_state()
				return
		_status_lbl.text = "Could not load streak status."
		Toast.network_error("streak_status code=%d" % code)
	)
	var headers : PackedStringArray = ["Authorization: Bearer " + _auth_token]
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/streak/status"), headers)


func _render_state() -> void:
	_day_lbl.text = "Day %d" % _streak_day
	_update_countdown()
	if _streak_day <= 0:
		_amount_lbl.text = ""
		_tomorrow_lbl.text = ""
		_status_lbl.text = "Play today to start a streak!"
		_claim_btn.disabled = true
		_claim_btn.text = "Claim"
		_refresh_calendar()
		return
	if _already_claimed:
		_amount_lbl.text = ""
		_status_lbl.text = "Already claimed today — come back tomorrow!"
		_claim_btn.disabled = true
		_claim_btn.text = "Claimed"
		_tomorrow_lbl.text = "Tomorrow: +%.2f NIM" % _reward_for_day(_streak_day + 1)
		_refresh_calendar()
		return
	if _claimable_nim > 0.0:
		_amount_lbl.text = "+%.2f NIM" % _claimable_nim
		_status_lbl.text = "Tap below to claim today's reward."
		_claim_btn.disabled = false
		_claim_btn.text = "Claim"
	else:
		_amount_lbl.text = ""
		_status_lbl.text = "Nothing to claim right now."
		_claim_btn.disabled = true
		_claim_btn.text = "Claim"
	# Not-yet-claimed-today branches (both the "something to claim" and the
	# rare "nothing to claim" fallback) still show tomorrow's number so the
	# player always has a reason to come back, not just today's.
	_tomorrow_lbl.text = "Tomorrow: +%.2f NIM" % _reward_for_day(_streak_day + 1)
	_refresh_calendar()


## Ticks the "resets in HH:MM:SS" countdown once a second while the panel
## is actually visible (no point recomputing 60x/sec for a label that only
## changes once a second, and no point at all while the panel is closed —
## _render_state() already calls _update_countdown() once immediately on
## every open/refresh so the label is never blank/stale when first shown).
func _process(delta: float) -> void:
	if not visible or not is_instance_valid(_countdown_lbl):
		return
	_countdown_accum += delta
	if _countdown_accum < 1.0:
		return
	_countdown_accum = 0.0
	_update_countdown()


## Time until the next UTC+3 day boundary — matches the backend's own day-
## rollover instant exactly (see game.UTC3 / RecordDailyActivity's "day"
## string format in backend/game/streak.go), so this never promises "resets
## in X" at a time that doesn't actually match when the streak really rolls
## over server-side.
func _update_countdown() -> void:
	if not is_instance_valid(_countdown_lbl):
		return
	var utc3_now := int(Time.get_unix_time_from_system()) + 3 * 3600
	var secs_left := 86400 - (utc3_now % 86400)
	var h := secs_left / 3600
	var m := (secs_left % 3600) / 60
	var s := secs_left % 60
	_countdown_lbl.text = "Resets in %02d:%02d:%02d" % [h, m, s]


## reward(day) = min(base + extra*(day-1), max) — mirrors the backend's
## ComputeStreakReward exactly (see backend/game/streak_reward.go). Computed
## client-side from the formula params the status endpoint now sends, so the
## panel can preview ANY day's reward, not just today's already-known amount.
func _reward_for_day(day: int) -> float:
	if day <= 0:
		return 0.0
	return minf(_reward_base_nim + _reward_extra_nim * float(day - 1), _reward_max_nim)


## Rebuilds the horizontal day-card strip: a window of days centered on
## today, each showing the day number and its NIM reward. Past days get a
## check mark (they're already "banked" into the streak count), today is
## highlighted with either a check (claimed) or the live claimable amount,
## future days show the projected amount, muted, so the player can see the
## payoff of coming back — the actual "real game daily login calendar" feel
## that was missing.
##
## BUG FIX: this used to always build an 8-card window (today -2/+5)
## regardless of how many actually fit the panel — the row lived in a
## ScrollContainer, so the overflow just became a horizontal scrollbar,
## which read as a UI bug rather than an intentional feature. The row is a
## plain non-scrolling CenterContainer now (see _build_ui), so this only
## ever builds CALENDAR_DAYS_SHOWN cards — tuned to comfortably fit this
## panel's actual content width at each card's current width (see card_w
## in _build_day_card) with real margin to spare, not scroll.
const CALENDAR_DAYS_SHOWN := 5   # e.g. today-2, today-1, today, today+1, today+2

func _refresh_calendar() -> void:
	if not is_instance_valid(_calendar_row):
		return
	for c in _calendar_row.get_children():
		c.queue_free()
	if _streak_day <= 0:
		return

	var ref := _ref_px if _ref_px > 0.0 else GameConstants.VW
	var back : int = (CALENDAR_DAYS_SHOWN - 1) / 2
	# Clamping start_day up to 1 on an early streak (day 1/2) and always
	# deriving end_day FROM start_day (not independently) keeps the card
	# count fixed at CALENDAR_DAYS_SHOWN in every case — the window just
	# shifts forward instead of shrinking to fewer, off-center cards.
	var start_day : int = maxi(1, _streak_day - back)
	var end_day   : int = start_day + CALENDAR_DAYS_SHOWN - 1

	for day in range(start_day, end_day + 1):
		_calendar_row.add_child(_build_day_card(day, ref))


func _build_day_card(day: int, ref: float) -> Control:
	var is_today  := day == _streak_day
	var is_past   := day < _streak_day
	var is_done   := is_past or (is_today and _already_claimed)   # already "banked"
	var reward    := _reward_for_day(day)

	# Widened slightly (was 0.115) to fit "NIM" on the amount line below —
	# see amt_lbl's own comment for why that unit was missing entirely.
	var card_w := int(ref * 0.128)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(card_w, int(ref * 0.130))

	var st := StyleBoxFlat.new()
	st.set_corner_radius_all(int(ref * 0.016))
	st.content_margin_left   = int(ref * 0.008)
	st.content_margin_right  = int(ref * 0.008)
	st.content_margin_top    = int(ref * 0.010)
	st.content_margin_bottom = int(ref * 0.010)
	if is_today:
		# Today (unclaimed) gets the loudest treatment — this is the card
		# that's actually actionable right now.
		st.bg_color     = Color(0.960, 0.780, 0.420, 0.9) if not is_done else Color(0.780, 0.870, 0.720, 0.9)
		st.border_color = Color(0.780, 0.380, 0.120)
		st.set_border_width_all(3)
	elif is_done:
		st.bg_color = Color(0.870, 0.900, 0.850, 0.75)   # soft green-grey — "done"
	else:
		st.bg_color = Color(0.900, 0.860, 0.780, 0.55)   # muted — future/locked
	card.add_theme_stylebox_override("panel", st)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", int(ref * 0.006))
	card.add_child(col)

	var day_lbl := Label.new()
	day_lbl.text = "Today" if is_today else ("Day %d" % day)
	day_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(day_lbl, Color(0.220, 0.130, 0.060), int(ref * 0.022))
	col.add_child(day_lbl)

	var icon_center := CenterContainer.new()
	col.add_child(icon_center)
	if is_done:
		icon_center.add_child(UITheme.lucide_icon("check", int(ref * 0.030), Color(0.240, 0.560, 0.220)))
	elif is_today:
		icon_center.add_child(UITheme.lucide_icon("coins", int(ref * 0.030), Color(0.780, 0.380, 0.120)))
	else:
		icon_center.add_child(UITheme.lucide_icon("circle", int(ref * 0.026), Color(0.560, 0.500, 0.440)))

	# BUG FIX: this used to just say "+0.20" with no unit at all — on its own,
	# out of context inside a small card, it's genuinely ambiguous what that
	# number even is. Every other amount on this panel (_amount_lbl,
	# _tomorrow_lbl) already says "NIM" explicitly; this was the one place
	# that didn't.
	var amt_lbl := Label.new()
	amt_lbl.text = "+%.2f NIM" % reward
	amt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var amt_col := Color(0.240, 0.560, 0.220) if is_done else (Color(0.560, 0.280, 0.080) if is_today else Color(0.560, 0.500, 0.440))
	UITheme.apply_label(amt_lbl, amt_col, int(ref * 0.019))
	col.add_child(amt_lbl)

	return card


func _on_claim_pressed() -> void:
	if _claiming or _auth_token == "":
		return
	_claiming = true
	_claim_btn.disabled = true
	_claim_btn.text = "Claiming..."

	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(result, code, _h, body):
		http.queue_free()
		_claiming = false
		if result != HTTPRequest.RESULT_SUCCESS:
			Toast.network_error("streak_claim result=%d" % result)
			_render_state()
			return
		var j := JSON.new()
		var d : Dictionary = {}
		if j.parse(body.get_string_from_utf8()) == OK:
			d = j.get_data()
		if code == 200 and bool(d.get("ok", false)):
			var reward : float = float(d.get("reward_nim", 0.0))
			_already_claimed = true
			_claimable_nim   = 0.0
			_render_state()
			_status_lbl.text = "Claimed +%.2f NIM!" % reward
			var inst := Toast.get_instance()
			if inst: inst.show_toast("Claimed +%.2f NIM!" % reward, Toast.Kind.SUCCESS)
			return
		var err_code : String = str(d.get("error", ""))
		if err_code == "already_claimed":
			_already_claimed = true
		# Restores the claim button's enabled/disabled state + default text
		# based on current known status FIRST, then any branch below
		# overrides _status_lbl with a more specific message.
		_render_state()
		match err_code:
			"no_active_streak":
				_status_lbl.text = "No active streak to claim yet."
			"ip_account_limit":
				_status_lbl.text = "Too many accounts have claimed from this connection today."
				var inst2 := Toast.get_instance()
				if inst2: inst2.show_toast("Too many accounts have claimed from this connection today.", Toast.Kind.WARN)
			"claim_in_progress":
				_status_lbl.text = "A claim is already in progress."
			"already_claimed":
				pass  # _render_state() already set the right "already claimed" message
			_:
				_status_lbl.text = "Could not claim right now. Code: %d" % code
	)
	var headers : PackedStringArray = ["Authorization: Bearer " + _auth_token]
	http.request(ApiConfig.sign_url(BACKEND_URL + "/backend/streak/claim"), headers, HTTPClient.METHOD_POST, "")


# ── Style helpers ────────────────────────────────────────────────
static func _warm_btn(btn: Button, r: float = 8.0) -> void:
	var ri := int(r)
	var sn := StyleBoxFlat.new(); var sh := StyleBoxFlat.new(); var sp := StyleBoxFlat.new(); var sd := StyleBoxFlat.new()
	for s in [sn, sh, sp, sd]:
		s.corner_radius_top_left = ri; s.corner_radius_top_right = ri
		s.corner_radius_bottom_left = ri; s.corner_radius_bottom_right = ri
	sn.bg_color = Color(0.780, 0.380, 0.120)
	sh.bg_color = Color(0.820, 0.450, 0.160)
	sp.bg_color = Color(0.640, 0.300, 0.080)
	# BUG FIX: no "disabled" stylebox was ever set here — only normal/hover/
	# pressed — so a disabled Button (the Claim button before there's anything
	# to claim) fell all the way back to Godot's raw ENGINE-DEFAULT disabled
	# panel, a flat grey box that doesn't match this warm bej/orange theme at
	# all (looks broken/ugly next to everything else — the "korkunç" report).
	# Same shape as the other three states, just muted so it still reads as
	# "not tappable" without looking like a rendering bug.
	sd.bg_color = Color(0.720, 0.660, 0.580)
	btn.add_theme_stylebox_override("normal",   sn)
	btn.add_theme_stylebox_override("hover",    sh)
	btn.add_theme_stylebox_override("pressed",  sp)
	btn.add_theme_stylebox_override("disabled", sd)
	btn.add_theme_color_override("font_color",         Color(0.957, 0.898, 0.800))
	btn.add_theme_color_override("font_hover_color",   Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.957, 0.898, 0.800))
	btn.add_theme_color_override("font_disabled_color", Color(0.480, 0.420, 0.360))


func _mpad(h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   h)
	mc.add_theme_constant_override("margin_right",  h)
	mc.add_theme_constant_override("margin_top",    v)
	mc.add_theme_constant_override("margin_bottom", v)
	return mc
