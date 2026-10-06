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
@onready var share_status_label: Label = %ShareStatusLabel


func _ready() -> void:
	game.score_changed.connect(_on_score_changed)
	game.lives_changed.connect(_on_lives_changed)
	game.life_lost.connect(_on_life_lost)
	game.ended.connect(_on_game_ended)
	%PlayButton.pressed.connect(_start_game.bind("menu"))
	%PlayAgainButton.pressed.connect(_start_game.bind("game_over"))
	%MenuButton.pressed.connect(_show_menu)
	%ShareLogButton.pressed.connect(_on_share_log)
	%AnalyticsToggle.pressed.connect(_on_analytics_toggle)
	%AllowButton.pressed.connect(_on_consent_chosen.bind(true))
	%DeclineButton.pressed.connect(_on_consent_chosen.bind(false))

	# Nothing is collected until the player answers, so ask before the first screen_view.
	if Save.consent == Save.CONSENT_UNKNOWN:
		_show_only(consent_panel)
		Telemetry.event("consent_shown")
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
	Telemetry.event("menu_shown")


## `source` is the screen whose button started the round (for the local playtest log).
func _start_game(source: String) -> void:
	_show_only(hud)
	game.start()
	Analytics.log_event("game_start", {"best_score": Save.best_score})
	Analytics.screen_view("game")
	Telemetry.event("round_start", {
		"round_number": Telemetry.next_round(),
		"source": source,
		"best_score": Save.best_score,
	})


func _on_consent_chosen(granted: bool) -> void:
	Telemetry.event("consent_choice", {"granted": int(granted)})
	Analytics.set_consent(granted)
	_show_menu()


func _on_analytics_toggle() -> void:
	Analytics.set_consent(not Analytics.has_consent())
	Telemetry.event("analytics_toggle", {"granted": int(Analytics.has_consent())})
	_refresh_analytics_toggle()


func _refresh_analytics_toggle() -> void:
	analytics_toggle.text = "Analytics: %s" % ("On" if Analytics.has_consent() else "Off")


func _on_score_changed(score: int) -> void:
	score_label.text = "Score: %d" % score
	if score == 1:
		Telemetry.event("round_first_star", {
			"round_number": Telemetry.round_number,
			"seconds_in_round": snappedf(game.elapsed, 0.01),
		})
	var id: String = MILESTONES.get(score, "")
	if id != "" and not Save.achievements.has(id):
		Save.achievements.append(id)
		Save.save_data()
		Analytics.log_event("unlock_achievement", {"achievement_id": id})
		Telemetry.event("unlock_milestone", {"id": id, "round_number": Telemetry.round_number})


func _on_lives_changed(lives: int) -> void:
	lives_label.text = "Lives: %d" % lives


func _on_life_lost(cause: String) -> void:
	Analytics.log_event("life_lost", {"cause": cause, "score": game.score})
	Telemetry.event("life_lost", {
		"round_number": Telemetry.round_number,
		"cause": cause,
		"score": game.score,
		"lives_left": game.lives,
		"seconds_in_round": snappedf(game.elapsed, 0.01),
	})


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
	Telemetry.event("round_end", {
		"round_number": Telemetry.round_number,
		"score": result.score,
		"seconds_in_round": snappedf(result.duration, 0.01),
		"stars_caught": result.stars_caught,
		"stars_missed": result.stars_missed,
		"bombs_hit": result.bombs_hit,
		"new_best": int(is_new_best),
	})

	over_score_label.text = "Score: %d" % result.score
	over_best_label.text = "Best: %d" % Save.best_score
	new_best_label.visible = is_new_best
	_show_only(over_panel)
	Analytics.screen_view("game_over")


## Copies the local playtest log to the clipboard for the tester to paste to the organiser.
func _on_share_log() -> void:
	DisplayServer.clipboard_set(Telemetry.export_text())
	var lines := Telemetry.event_count()
	Telemetry.event("share_log", {"lines": lines})
	share_status_label.text = "Copied %d log lines. Paste them into a message to the person who gave you this build." % lines
	share_status_label.visible = true


## Mobile only: lets the log show where sessions end, and whether a round was left unfinished.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		Telemetry.event("app_background", {"in_round": int(game != null and game.running)})
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		Telemetry.event("app_foreground")
