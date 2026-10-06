extends Node
## Wires gameplay, the UI screens, persistence and analytics together.

## Score milestones -> achievement ids, reported to Firebase once per install.
const MILESTONES := {10: "catcher_10", 25: "catcher_25", 50: "catcher_50"}

@onready var game: Node2D = $Game
@onready var hud: Control = %HUD
@onready var score_label: Label = %ScoreLabel
@onready var lives_label: Label = %LivesLabel
@onready var menu_panel: Control = %MenuPanel
@onready var menu_best_label: Label = %MenuBestLabel
@onready var analytics_toggle: Button = %AnalyticsToggle
@onready var over_panel: Control = %GameOverPanel
@onready var over_score_label: Label = %OverScoreLabel
@onready var new_best_label: Label = %NewBestLabel
@onready var over_best_label: Label = %OverBestLabel
@onready var consent_panel: Control = %ConsentPanel


func _ready() -> void:
	game.score_changed.connect(_on_score_changed)
	game.lives_changed.connect(_on_lives_changed)
	game.life_lost.connect(_on_life_lost)
	game.ended.connect(_on_game_ended)
	%PlayButton.pressed.connect(_start_game)
	%PlayAgainButton.pressed.connect(_start_game)
	%MenuButton.pressed.connect(_show_menu)
	%AnalyticsToggle.pressed.connect(_on_analytics_toggle)
	%AllowButton.pressed.connect(_on_consent_chosen.bind(true))
	%DeclineButton.pressed.connect(_on_consent_chosen.bind(false))

	# Nothing is collected until the player answers, so ask before the first screen_view.
	if Save.consent == Save.CONSENT_UNKNOWN:
		_show_only(consent_panel)
	else:
		_show_menu()


func _show_only(panel: Control) -> void:
	for p: Control in [hud, menu_panel, over_panel, consent_panel]:
		p.visible = p == panel


func _show_menu() -> void:
	game.stop()
	menu_best_label.text = "Best: %d" % Save.best_score
	_refresh_analytics_toggle()
	_show_only(menu_panel)
	Analytics.screen_view("menu")


func _start_game() -> void:
	_show_only(hud)
	game.start()
	Analytics.log_event("game_start", {"best_score": Save.best_score})
	Analytics.screen_view("game")


func _on_consent_chosen(granted: bool) -> void:
	Analytics.set_consent(granted)
	_show_menu()


func _on_analytics_toggle() -> void:
	Analytics.set_consent(not Analytics.has_consent())
	_refresh_analytics_toggle()


func _refresh_analytics_toggle() -> void:
	analytics_toggle.text = "Analytics: %s" % ("On" if Analytics.has_consent() else "Off")


func _on_score_changed(score: int) -> void:
	score_label.text = "Score: %d" % score
	var id: String = MILESTONES.get(score, "")
	if id != "" and not Save.achievements.has(id):
		Save.achievements.append(id)
		Save.save_data()
		Analytics.log_event("unlock_achievement", {"achievement_id": id})


func _on_lives_changed(lives: int) -> void:
	lives_label.text = "Lives: %d" % lives


func _on_life_lost(cause: String) -> void:
	Analytics.log_event("life_lost", {"cause": cause, "score": game.score})


func _on_game_ended(result: Dictionary) -> void:
	var is_new_best: bool = result.score > Save.best_score
	if is_new_best:
		Save.best_score = result.score
		Save.save_data()
	Analytics.log_event("game_over", {
		"score": result.score,
		"duration_s": snappedf(result.duration, 0.1),
		"stars_caught": result.stars_caught,
		"stars_missed": result.stars_missed,
		"bombs_hit": result.bombs_hit,
		"new_best": int(is_new_best),
	})
	# post_score is Firebase's standard event for leaderboard-style scores.
	Analytics.log_event("post_score", {"score": result.score})

	over_score_label.text = "Score: %d" % result.score
	over_best_label.text = "Best: %d" % Save.best_score
	new_best_label.visible = is_new_best
	_show_only(over_panel)
	Analytics.screen_view("game_over")
