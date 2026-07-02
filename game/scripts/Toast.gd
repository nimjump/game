extends CanvasLayer
class_name Toast
const UITheme := preload("res://scripts/UITheme.gd")

## Toast.gd — global toast/banner bildirim sistemi.
## Ekranın üst-ortasında, yatay dikdörtgen kart.
## GameConstants.VW x GameConstants.VH (600x800) referans alınır,
## tüm boyutlar/konumlar bu referansa göre oranlanır (vw/vh mantığı).
## Animasyon: yukarıdan kayarak girer, yukarı kayarak çıkar.
##
## NOT (üst üste binme / "ışınlanma" FIX):
## Eskiden kartlar bir VBoxContainer'a child olarak ekleniyordu ve animasyon
## kartın "position"unu elle değiştiriyordu. Ama VBoxContainer kendi
## çocuklarının pozisyonunu HER layout pass'inde kendisi hesaplayıp üzerine
## yazar — yani elle verdiğimiz offset bir sonraki frame'de container
## tarafından sıfırlanıyordu. İki toast aynı anda gelince bu çakışma daha da
## belirginleşip kartların önce üst üste binip sonra birden "ışınlanmasına"
## sebep oluyordu. Çözüm: container tabanlı dizilim tamamen kaldırıldı.
## Her toast artık bağımsız bir Control, kendi Y pozisyonu manuel olarak
## hesaplanıp tween ile animasyonlanıyor; sıradaki kartların yeri de her
## değişiklikte (ekleme/silme) elle yeniden hesaplanıp KENDİ tween'leriyle
## kaydırılıyor (layout sistemine hiç dokunulmuyor).

enum Kind { INFO, SUCCESS, ERROR, WARN }

# ── Warm bej palette ──────────────────────────────────────────────────
const _C_BG     := Color(0.957, 0.898, 0.800)
const _C_BORDER := Color(0.580, 0.380, 0.220)
const _C_BROWN  := Color(0.220, 0.130, 0.060)
const _C_ORANGE := Color(0.780, 0.380, 0.120)
const _C_GREEN  := Color(0.240, 0.620, 0.220)
const _C_RED    := Color(0.820, 0.180, 0.120)

static var _instance: Toast = null

static func get_instance() -> Toast:
	if is_instance_valid(_instance):
		return _instance
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root := tree.root
	for child in root.get_children():
		if child is Toast:
			_instance = child
			return _instance
	var t := Toast.new()
	root.add_child(t)
	_instance = t
	return _instance

const MAX_QUEUE := 4
const HOLD_SECONDS := 2.2
const SLIDE_SECONDS := 0.28
const REPOSITION_SECONDS := 0.20

var _layer_root : Control = null
var _stack_anchor : Control = null   # sadece pozisyon referansı (genişlik/üst boşluk), layout yapmaz

var _queue  : Array = []
# Şu an ekranda olan/animasyonda olan kartların sıralı listesi.
# Her eleman: { "card": PanelContainer, "entering": bool, "exiting": bool }
var _live_cards : Array = []


func _ready() -> void:
	layer = 999  # her zaman en üstte
	_build_ui()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_relayout()


# ── 600x800 referans sistemi ───────────────────────────────────────────
func _vw(ratio: float) -> float:
	var vp := get_viewport()
	var w := GameConstants.VW if vp == null else vp.get_visible_rect().size.x
	return w * ratio


func _vh(ratio: float) -> float:
	var vp := get_viewport()
	var h := GameConstants.VH if vp == null else vp.get_visible_rect().size.y
	return h * ratio


func _viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(GameConstants.VW, GameConstants.VH)
	return vp.get_visible_rect().size


func _safe_top_inset() -> float:
	var vp := get_viewport()
	if vp == null or DisplayServer.get_name() == "headless":
		return 0.0
	var screen_size := DisplayServer.screen_get_size()
	var safe := DisplayServer.get_display_safe_area()
	if screen_size.y <= 0 or safe.size == Vector2i.ZERO:
		return 0.0
	var view_size := vp.get_visible_rect().size
	var scale_y := view_size.y / float(screen_size.y)
	return maxf(float(safe.position.y) * scale_y, 0.0)


func _on_viewport_resized() -> void:
	_relayout()
	_reposition_all(false)


func _top_gap() -> float:
	return _safe_top_inset() + _vh(0.025)


func _stack_width() -> float:
	var vp_w := _viewport_size().x
	return minf(_vw(0.86), vp_w - _vw(0.06))


func _separation() -> float:
	return _vh(0.012)


func _relayout() -> void:
	if _stack_anchor == null:
		return
	var w := _stack_width()
	_stack_anchor.set_anchor_and_offset(SIDE_LEFT,  0.5, -w * 0.5)
	_stack_anchor.set_anchor_and_offset(SIDE_RIGHT, 0.5,  w * 0.5)
	_stack_anchor.set_anchor_and_offset(SIDE_TOP,   0.0,  0.0)
	_stack_anchor.set_anchor_and_offset(SIDE_BOTTOM, 0.0, 0.0)


func _build_ui() -> void:
	_layer_root = Control.new()
	_layer_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer_root)

	# _stack_anchor sadece genişlik/x-pozisyon referansı verir; içine child
	# eklenmez, layout yapmaz — kartlar doğrudan _layer_root'a eklenir ve
	# pozisyonları elle hesaplanır.
	_stack_anchor = Control.new()
	_stack_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer_root.add_child(_stack_anchor)


# ── Style helpers ─────────────────────────────────────────────────────

func _apply_warm_panel_style(panel: PanelContainer, corner: int = 14, border_w: int = 3) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color     = _C_BG
	s.border_color = _C_BORDER
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(corner)
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.25)
	s.shadow_size  = 10
	panel.add_theme_stylebox_override("panel", s)


func _kind_color(kind: int) -> Color:
	match kind:
		Kind.SUCCESS: return _C_GREEN
		Kind.ERROR:   return _C_RED
		Kind.WARN:    return _C_RED
		_:            return _C_ORANGE


func _kind_icon(kind: int) -> String:
	match kind:
		Kind.SUCCESS: return "check-circle"
		Kind.ERROR:   return "alert-triangle"
		Kind.WARN:    return "alert-triangle"
		_:            return "info"


# ── Public API ──────────────────────────────────────────────────────

func show_toast(msg: String, kind: int = Kind.INFO) -> void:
	if not is_inside_tree():
		await ready
	_relayout()
	_queue.append([msg, kind])
	if _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	_drain_queue()


# ── Network error helper ───────────────────────────────────────────────
## Tek noktadan çağrılan genel "bağlantı hatası" toast'ı.
## HTTPRequest sonucu RESULT_SUCCESS değilse (DNS/timeout/connection refused/
## 404 route bulunamadı vs.) her yerde aynı, kullanıcı dostu İngilizce mesajı
## göstermek için kullanılır. `context` opsiyonel — log/debug amaçlı, kullanıcıya
## gösterilmez.
static var _last_network_toast_ms : int = 0
const _NETWORK_TOAST_COOLDOWN_MS := 4000  # aynı anda birden fazla request patlarsa toast spam'ini engelle

static func network_error(context: String = "") -> void:
	var now := Time.get_ticks_msec()  # determinism-ok: toast spam-cooldown UI timer only
	if now - _last_network_toast_ms < _NETWORK_TOAST_COOLDOWN_MS:
		if context != "":
			print("[Toast] network_error suppressed (cooldown) ctx=%s" % context)
		return
	_last_network_toast_ms = now
	if context != "":
		print("[Toast] network_error ctx=%s" % context)
	var inst := get_instance()
	if inst != null:
		inst.show_toast("Failed to connect to server. Please check your connection.", Kind.ERROR)


# ── Internal: queue + tek toast yaşam döngüsü ─────────────────────────

func _drain_queue() -> void:
	if _queue.is_empty():
		return
	if _live_cards.size() >= MAX_QUEUE:
		return
	var pair: Array = _queue.pop_front()
	_spawn_toast(pair[0], pair[1])


## Bir "slot" indeksine (0 = en üstteki/en eski toast, artan sayı = daha
## aşağıdaki/daha yeni toast) karşılık gelen hedef Y pozisyonunu hesaplar.
## Her kartın gerçek (içerikten doğan) yüksekliğini kullanır, sabit bir
## satır yüksekliği varsaymaz — farklı uzunlukta mesajlar olabilir.
func _target_y_for_slot(slot: int) -> float:
	var y := _top_gap()
	var sep := _separation()
	for i in range(slot):
		if i < _live_cards.size():
			var c: Control = _live_cards[i]["card"]
			y += c.size.y + sep
	return y


## Tüm canlı kartları, listedeki sıralarına göre doğru Y konumuna kaydırır.
## Bir kart kapanıp listeden çıkınca diğerleri buradan yumuşakça kayar.
## Giriş/çıkış animasyonu kendi tween'ini yönettiği için buradan
## müdahale edilmiyor (çakışma olmasın diye).
func _reposition_all(animate: bool = true) -> void:
	for i in range(_live_cards.size()):
		var entry: Dictionary = _live_cards[i]
		var card: Control = entry["card"]
		if not is_instance_valid(card):
			continue
		if entry.get("entering", false) or entry.get("exiting", false):
			continue
		var target_y := _target_y_for_slot(i)
		if animate:
			var tw := create_tween()
			tw.tween_property(card, "position:y", target_y, REPOSITION_SECONDS)\
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		else:
			card.position.y = target_y


func _spawn_toast(msg: String, kind: int) -> void:
	var col := _kind_color(kind)

	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.top_level = true   # kendi pozisyonunu parent layout'undan bağımsız tutar
	_apply_warm_panel_style(card, 14, 2)

	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left",   int(_vw(0.045)))
	mc.add_theme_constant_override("margin_right",  int(_vw(0.045)))
	mc.add_theme_constant_override("margin_top",    int(_vh(0.014)))
	mc.add_theme_constant_override("margin_bottom", int(_vh(0.014)))
	card.add_child(mc)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(_vw(0.025)))
	mc.add_child(row)

	row.add_child(UITheme.lucide_icon(_kind_icon(kind), int(_vh(0.026)), col))

	var lbl := Label.new()
	lbl.text = msg
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.clip_text = false
	UITheme.apply_label(lbl, _C_BROWN, int(_vh(0.020)))
	row.add_child(lbl)

	_layer_root.add_child(card)

	# Genişliği biz veriyoruz (üst-ortada, sabit referans genişliği),
	# yüksekliği içerik belirliyor (PanelContainer kendi min-size'ına göre).
	var w := _stack_width()
	var vp_w := _viewport_size().x
	card.position.x = (vp_w - w) * 0.5
	card.size.x = w
	card.size.y = 0

	# top_level + manuel boyut olduğu için bir frame bekleyip gerçek
	# (içerikten doğan) yüksekliğin oturmasını sağlıyoruz; yoksa size.y
	# henüz 0 iken slot hesaplamaları yanlış çıkar ve kartlar üst üste biner.
	await get_tree().process_frame

	var entry := {"card": card, "entering": true, "exiting": false}
	_live_cards.append(entry)
	var slot := _live_cards.size() - 1
	var target_y := _target_y_for_slot(slot)
	var start_offset := card.size.y + _vh(0.04)

	card.modulate.a = 0.0
	card.position.y = target_y - start_offset

	var tw := create_tween()
	tw.tween_property(card, "position:y", target_y, SLIDE_SECONDS)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(card, "modulate:a", 1.0, SLIDE_SECONDS)

	tw.tween_interval(HOLD_SECONDS)

	tw.tween_callback(func():
		entry["entering"] = false
	)

	tw.tween_callback(func():
		entry["exiting"] = true
		var exit_target := target_y - start_offset
		var exit_tw := create_tween()
		exit_tw.tween_property(card, "position:y", exit_target, SLIDE_SECONDS)\
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		exit_tw.parallel().tween_property(card, "modulate:a", 0.0, SLIDE_SECONDS)
		exit_tw.tween_callback(func():
			if is_instance_valid(card):
				card.queue_free()
			_live_cards.erase(entry)
			_reposition_all(true)
			_drain_queue()
		)
	)
