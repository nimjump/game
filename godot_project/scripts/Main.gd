@tool
extends Node2D

# Ana sahne: editörde GameManager önizlemesi, oyunda init() + activate().


func _ready() -> void:
	if Engine.is_editor_hint():
		var player := get_node_or_null("Player")
		if player:
			player.visible = false
		return
	call_deferred("_start_game")


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		var gm := get_node_or_null("GameManager")
		if gm and gm.has_method("_cleanup_editor_preview"):
			gm.call("_cleanup_editor_preview")


func _start_game() -> void:
	var gm := get_node_or_null("GameManager")
	var cam := get_node_or_null("Camera2D") as Camera2D
	var player := get_node_or_null("Player") as CharacterBody2D

	if player:
		player.visible = true
	if gm and gm.has_method("init"):
		gm.init(cam, player, null, null, null, self)
	if player and player.has_method("activate"):
		player.activate()

	var restart := get_node_or_null("UI/GameOverPanel/GOVBox/RestartButton") as Button
	if restart and not restart.pressed.is_connected(_on_restart):
		restart.pressed.connect(_on_restart)


func _on_restart() -> void:
	get_tree().reload_current_scene()


func update_score_display(score: int) -> void:
	var lbl := get_node_or_null("UI/ScoreLabel") as Label
	if lbl:
		lbl.text = str(score)


func update_best_display(best: int) -> void:
	var lbl := get_node_or_null("UI/BestLabel") as Label
	if lbl:
		lbl.text = "BEST: %d" % best


func update_final_display(score: int) -> void:
	var lbl := get_node_or_null("UI/GameOverPanel/GOVBox/FinalScore") as Label
	if lbl:
		lbl.text = str(score)


func _show_go_panel() -> void:
	var panel := get_node_or_null("UI/GameOverPanel") as Control
	if panel:
		panel.visible = true
