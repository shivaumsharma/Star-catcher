extends Node
## Headless test suite. Run from the project folder:
##   godot --headless --path . res://tests/test_runner.tscn
## Exits non-zero if any check fails.

const Fake := preload("res://tests/fake_firebase.gd")
const GameScript := preload("res://scripts/game.gd")
const MainScene := preload("res://scenes/main.tscn")
const TEST_SAVE := "user://test_save.cfg"
const TEST_LOG := "user://test_playtest_log.jsonl"
const TEST_META := "user://test_playtest_meta.cfg"

var _checks := 0
var _failures := 0
var _real_save_path: String
var _real_telemetry := {}
var _clock := 1_000_000.0


func _ready() -> void:
	# Pessimistic default: a script error part-way through must not look like a pass.
	get_tree().quit(1)
	_real_save_path = Save.path
	_real_telemetry = {"enabled": Telemetry.enabled, "path": Telemetry.path,
		"meta_path": Telemetry.meta_path, "clock": Telemetry.clock}
	if Telemetry.enabled:
		print("(tip: run with `-- --no-telemetry` so tests don't add a line to your own playtest log)")
	for test in [
		_test_telemetry_writes_one_json_line_per_event,
		_test_telemetry_install_id_persists_and_sessions_count,
		_test_telemetry_rounds_are_numbered_per_install,
		_test_telemetry_ignores_the_firebase_consent_choice,
		_test_telemetry_can_be_switched_off,
		_test_events_dropped_without_consent,
		_test_events_queue_until_firebase_ready,
		_test_consent_denied_drops_events_and_queue,
		_test_core_failure_keeps_firebase_idle,
		_test_queue_is_capped,
		_test_consent_is_persisted,
		_test_catching_stars_scores,
		_test_missed_star_and_bombs_cost_lives,
		_test_round_ends_after_three_lives,
		_test_difficulty_curve,
		_test_basket_stays_in_field,
		_test_touch_input_moves_basket,
		_test_frame_hitch_cannot_tunnel,
		_test_spawner_and_restart,
		_test_full_flow_reports_expected_events,
		_test_full_flow_writes_the_funnel_to_the_local_log,
		_test_declined_players_are_still_logged_locally,
		_test_share_button_reports_how_many_lines_were_copied,
		_test_backgrounding_marks_whether_a_round_was_open,
	]:
		print("- ", String(test.get_method()).trim_prefix("_test_").replace("_", " "))
		_fresh_state()
		await test.call()
	_cleanup()
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


# --- helpers ------------------------------------------------------------------------------

func check(condition: bool, what: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("    FAIL: ", what)
	return condition


func eq(actual: Variant, expected: Variant, what: String) -> void:
	check(actual == expected, "%s (expected %s, got %s)" % [what, expected, actual])


func _fresh_state() -> void:
	Save.path = TEST_SAVE
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	Save.load_data()
	Analytics._core = null
	Analytics._firebase = null
	Analytics.firebase_ready = false
	Analytics._queue.clear()
	# Telemetry: a private log, a deterministic clock (1 s per event), and one fresh launch.
	for f in [TEST_LOG, TEST_META]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Telemetry.enabled = true
	Telemetry.path = TEST_LOG
	Telemetry.meta_path = TEST_META
	Telemetry.clock = func() -> float:
		_clock += 1.0
		return _clock
	Telemetry.start_session()


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	for f in [TEST_LOG, TEST_META]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Save.path = _real_save_path
	Save.load_data()
	Telemetry.enabled = _real_telemetry.enabled
	Telemetry.path = _real_telemetry.path
	Telemetry.meta_path = _real_telemetry.meta_path
	Telemetry.clock = _real_telemetry.clock


## Attaches fakes to the Analytics autoload. Returns [core, analytics, shared call log].
func _attach(auto_complete := true) -> Array:
	var log: Array[String] = []
	var core := Fake.FakeCore.new(log)
	var firebase := Fake.FakeAnalytics.new(log)
	firebase.auto_complete = auto_complete
	Analytics.attach_firebase(core, firebase)
	return [core, firebase, log]


func _new_game() -> Node2D:
	var game: Node2D = GameScript.new()
	add_child(game)  # runs _ready
	game.start()
	game._spawn_timer = INF  # no random spawns: tests place every item themselves
	return game


func _log_events() -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	for line in Telemetry.export_text().split("\n", false):
		var parsed: Variant = JSON.parse_string(line)
		if check(parsed is Dictionary, "every log line is a JSON object: %s" % line):
			events.append(_whole_numbers_as_ints(parsed))
	return events


## JSON has one number type, so Godot parses a logged 1 back as 1.0. Undo that so values
## compare equal to what the game logged.
func _whole_numbers_as_ints(value: Variant) -> Variant:
	if value is float and value == floorf(value):
		return int(value)
	if value is Dictionary:
		var converted := {}
		for key in value:
			converted[key] = _whole_numbers_as_ints(value[key])
		return converted
	if value is Array:
		return value.map(_whole_numbers_as_ints)
	return value


func _log_names() -> Array[String]:
	var names: Array[String] = []
	for e in _log_events():
		names.append(e.e)
	return names


## Last logged event with this name (empty dict if none).
func _last(event_name: String) -> Dictionary:
	var found := {}
	for e in _log_events():
		if e.e == event_name:
			found = e
	return found


# --- Local playtest log -------------------------------------------------------------------

func _test_telemetry_writes_one_json_line_per_event() -> void:
	Telemetry.event("x", {"n": 1, "f": 0.5, "s": "a"})
	var events := _log_events()
	eq(events.size(), 2, "app_open + x")
	eq(events[0].e, "app_open", "a launch is logged first")
	eq(events[0].p, {"first_launch": 1}, "the first launch is flagged")
	eq(events[1].e, "x", "event name")
	eq(events[1].p, {"n": 1, "f": 0.5, "s": "a"}, "params round-trip through JSON")
	eq(events[1].i, Telemetry.install_id, "install id on every line")
	check(str(events[1].i).length() == 8, "install id is 8 hex characters")
	check(events[1].t > events[0].t, "timestamps come from the clock and increase")
	eq(events[1].s, 1, "session number")


func _test_telemetry_install_id_persists_and_sessions_count() -> void:
	var first_id := Telemetry.install_id
	Telemetry.start_session()
	var launches := _log_events().filter(func(e): return e.e == "app_open")
	eq(launches.size(), 2, "two launches logged")
	eq(launches[1].i, first_id, "the install id survives a relaunch")
	eq(launches[1].s, 2, "the session number counts launches")
	eq(launches[1].p, {"first_launch": 0}, "only the very first launch is flagged")


func _test_telemetry_rounds_are_numbered_per_install() -> void:
	eq(Telemetry.next_round(), 1, "first round ever")
	eq(Telemetry.next_round(), 2, "second round")
	Telemetry.start_session()
	eq(Telemetry.next_round(), 3, "numbering continues after a relaunch")


func _test_telemetry_ignores_the_firebase_consent_choice() -> void:
	Save.consent = Save.CONSENT_DENIED
	Telemetry.event("tapped")
	check(_log_names().has("tapped"), "logged although Firebase analytics was declined")


func _test_telemetry_can_be_switched_off() -> void:
	var before := Telemetry.event_count()
	Telemetry.enabled = false
	Telemetry.event("nope")
	eq(Telemetry.event_count(), before, "a disabled logger writes nothing")


# --- Analytics wrapper --------------------------------------------------------------------

func _test_events_dropped_without_consent() -> void:
	var fb: Object = _attach()[1]
	Analytics.log_event("a")
	eq(fb.events.size(), 0, "nothing sent before the player answers")
	eq(Analytics._queue.size(), 0, "nothing queued before the player answers")


func _test_events_queue_until_firebase_ready() -> void:
	var parts := _attach(false)
	var core: Object = parts[0]
	var fb: Object = parts[1]
	var log: Array[String] = parts[2]
	eq(log, ["core.initialize", "analytics.initialize"] as Array[String], "Core initialises first, then Analytics")

	Analytics.set_consent(true)
	Analytics.log_event("a", {"n": 1})
	Analytics.log_event("b")
	eq(fb.events.size(), 0, "events wait while Analytics is initialising")

	fb.analytics_initialized.emit(true)
	eq(log.slice(2), ["set_consent", "collection:true", "log:a", "log:b"] as Array[String],
		"consent is applied, then the queue is flushed in order")
	if check(fb.consent_calls.size() == 1 and fb.events.size() == 2, "one consent call and two flushed events"):
		eq(fb.consent_calls[0], {
			"analytics_storage": "granted", "ad_storage": "granted",
			"ad_user_data": "granted", "ad_personalization": "granted"}, "all consent signals granted")
		eq(fb.events[0].params, {"n": 1}, "params are passed through untouched")

	Analytics.log_event("c")
	eq(fb.names(), ["a", "b", "c"] as Array[String], "once ready, events go straight through")
	check(core != null, "core fake alive")


func _test_consent_denied_drops_events_and_queue() -> void:
	var fb: Object = _attach(false)[1]
	Analytics.set_consent(true)
	Analytics.log_event("queued")
	Analytics.set_consent(false)
	eq(Analytics._queue.size(), 0, "revoking consent empties the queue")
	fb.analytics_initialized.emit(true)
	Analytics.log_event("after")
	eq(fb.events.size(), 0, "nothing is sent after consent is denied")
	if check(fb.consent_calls.size() == 1, "Firebase is told about the denial"):
		eq(fb.consent_calls[0]["analytics_storage"], "denied", "consent is denied")
	eq(fb.collection_enabled, false, "collection is switched off")


func _test_core_failure_keeps_firebase_idle() -> void:
	var log: Array[String] = []
	var core := Fake.FakeCore.new(log)
	core.succeed = false
	var fb := Fake.FakeAnalytics.new(log)
	Analytics.set_consent(true)
	Analytics.attach_firebase(core, fb)
	Analytics.log_event("a")
	eq(log, ["core.initialize"] as Array[String], "Analytics is never initialised when Core fails")
	eq(fb.events.size(), 0, "no events reach Firebase")
	check(not Analytics.firebase_ready, "wrapper stays not-ready")


func _test_queue_is_capped() -> void:
	var fb: Object = _attach(false)[1]
	Analytics.set_consent(true)
	for i in Analytics.MAX_QUEUED + 10:
		Analytics.log_event("e%d" % i)
	fb.analytics_initialized.emit(true)
	if check(fb.events.size() == Analytics.MAX_QUEUED, "only MAX_QUEUED events are kept"):
		eq(fb.events[0].name, "e0", "the oldest events are the ones kept")


func _test_consent_is_persisted() -> void:
	Analytics.set_consent(true)
	Save.load_data()
	eq(Save.consent, Save.CONSENT_GRANTED, "granted survives a reload")
	Analytics.set_consent(false)
	Save.load_data()
	eq(Save.consent, Save.CONSENT_DENIED, "denied survives a reload")


# --- Game simulation ----------------------------------------------------------------------

func _test_catching_stars_scores() -> void:
	var game := _new_game()
	var seen: Array[int] = []
	game.score_changed.connect(seen.append)
	game.spawn_item(game.ItemKind.STAR, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(game.score, 1, "catching a star scores a point")
	eq(game.stars_caught, 1, "stars_caught counts it")
	eq(seen, [1] as Array[int], "score_changed fired once with the new score")
	eq(game.item_count(), 0, "caught star is removed")

	# Catch zone: the basket's half-width plus half an item radius, either side of its centre.
	var reach: float = game.BASKET_SIZE.x / 2.0 + game.ITEM_RADIUS * 0.5
	game.spawn_item(game.ItemKind.STAR, game.basket_x + reach - 1.0, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(game.score, 2, "a star just inside the basket's edge is caught")
	game.spawn_item(game.ItemKind.STAR, game.basket_x - reach + 1.0, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(game.score, 3, "a star just inside the other edge is caught")
	game.spawn_item(game.ItemKind.STAR, game.basket_x + reach + 20.0, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(game.score, 3, "a star beside the basket is not caught")
	game.queue_free()


func _test_missed_star_and_bombs_cost_lives() -> void:
	var game := _new_game()
	var causes: Array[String] = []
	game.life_lost.connect(causes.append)

	game.spawn_item(game.ItemKind.STAR, 30.0, game.FIELD.y + game.ITEM_RADIUS)
	game.step(0.016)
	eq(game.lives, 2, "a missed star costs a life")
	eq(game.stars_missed, 1, "stars_missed counts it")

	game.spawn_item(game.ItemKind.BOMB, 30.0, game.FIELD.y + game.ITEM_RADIUS)
	game.step(0.016)
	eq(game.lives, 2, "a bomb that falls past is harmless")

	game.spawn_item(game.ItemKind.BOMB, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(game.lives, 1, "catching a bomb costs a life")
	eq(game.bombs_hit, 1, "bombs_hit counts it")
	eq(causes, ["missed_star", "bomb"] as Array[String], "life_lost reports the cause")

	game.spawn_item(game.ItemKind.STAR, 30.0, game.BASKET_Y + 80.0)
	game.step(0.016)
	check(game.item_count() == 1, "a star already below the basket is not caught")
	game.queue_free()


func _test_round_ends_after_three_lives() -> void:
	var game := _new_game()
	var results: Array[Dictionary] = []
	game.ended.connect(results.append)
	game.score = 7
	for i in 3:
		game.spawn_item(game.ItemKind.STAR, 30.0, game.FIELD.y + game.ITEM_RADIUS)
		game.step(0.016)
	eq(results.size(), 1, "ended fires exactly once")
	check(not game.running, "round stops")
	eq(results[0].score, 7, "result carries the score")
	eq(results[0].stars_missed, 3, "result carries stars_missed")
	check(results[0].duration > 0.0, "result carries the duration")
	game.step(0.016)
	eq(results.size(), 1, "stepping a finished round does nothing")
	game.queue_free()


func _test_difficulty_curve() -> void:
	var game := _new_game()
	var speeds: Array[float] = []
	var intervals: Array[float] = []
	for s in [0, 10, 30, 80, 500]:
		game.score = s
		speeds.append(game.fall_speed())
		intervals.append(game.spawn_interval())
	check(speeds[0] < speeds[1] and speeds[1] < speeds[2], "items fall faster as the score grows")
	check(intervals[0] > intervals[1] and intervals[1] > intervals[2], "items spawn more often as the score grows")
	eq(speeds[4], 620.0, "fall speed is capped")
	eq(intervals[4], 0.38, "spawn interval has a floor")
	game.score = 500
	eq(game.bomb_chance(), 0.40, "bomb chance is capped")
	game.queue_free()


func _test_basket_stays_in_field() -> void:
	var game := _new_game()
	game.set_target_x(-500.0)
	for i in 60:
		game.step(0.016)
	eq(game.basket_x, game.BASKET_SIZE.x / 2.0, "basket stops at the left edge")
	game.set_target_x(5000.0)
	for i in 60:
		game.step(0.016)
	eq(game.basket_x, game.FIELD.x - game.BASKET_SIZE.x / 2.0, "basket stops at the right edge")
	game.queue_free()


func _test_touch_input_moves_basket() -> void:
	var game := _new_game()
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = Vector2(100, 500)
	get_viewport().push_input(press, true)
	for i in 20:
		game.step(0.016)
	eq(game.basket_x, 100.0, "touching the screen moves the basket under the finger")

	var drag := InputEventScreenDrag.new()
	drag.position = Vector2(400, 500)
	get_viewport().push_input(drag, true)
	for i in 20:
		game.step(0.016)
	eq(game.basket_x, 400.0, "dragging follows the finger")

	var release := InputEventScreenTouch.new()
	release.pressed = false
	release.position = Vector2(50, 500)
	get_viewport().push_input(release, true)
	for i in 20:
		game.step(0.016)
	eq(game.basket_x, 400.0, "lifting a finger does not move the basket")

	check(ProjectSettings.get_setting("input_devices/pointing/emulate_touch_from_mouse"),
		"mouse is emulated as touch, so the game is playable on desktop")
	game.queue_free()


func _test_frame_hitch_cannot_tunnel() -> void:
	var game := _new_game()
	game.spawn_item(game.ItemKind.STAR, 30.0, 100.0)
	game.step(5.0)  # a 5-second hitch
	if check(game.item_count() == 1, "the item is still falling after a long frame"):
		var moved: float = game._items[0].pos.y - 100.0
		check(moved <= game.fall_speed() * game.MAX_STEP + 0.001, "a long frame only advances MAX_STEP of simulation (moved %s)" % moved)
	game.queue_free()


func _test_spawner_and_restart() -> void:
	var game := _new_game()
	game._spawn_timer = 0.0
	game.step(0.016)
	eq(game.item_count(), 1, "the spawner drops an item when its timer elapses")
	if game.item_count() == 1:
		var item = game._items[0]
		check(item.pos.x >= game.ITEM_RADIUS and item.pos.x <= game.FIELD.x - game.ITEM_RADIUS, "items spawn inside the field")
	game.score = 9
	game.lives = 1
	game.start()
	eq([game.score, game.lives, game.item_count()], [0, 3, 0], "start() resets the round")
	game.queue_free()


# --- Whole game through the real scene + UI ----------------------------------------------

func _event_names(fb: Object) -> Array[String]:
	return fb.names()


func _test_full_flow_reports_expected_events() -> void:
	var fb: Object = _attach()[1]
	var main: Node = MainScene.instantiate()
	add_child(main)
	var game: Node2D = main.get_node("Game")

	check(main.get_node("%ConsentPanel").visible, "first launch asks for consent")
	check(not main.get_node("%MenuPanel").visible, "menu waits for the answer")
	eq(fb.events.size(), 0, "no events before consent")

	main.get_node("%AllowButton").pressed.emit()
	check(main.get_node("%MenuPanel").visible, "menu shows after answering")
	eq(Save.consent, Save.CONSENT_GRANTED, "consent saved")
	if not check(fb.events.size() == 1, "the menu screen_view is the only event so far"):
		main.free()
		return
	eq(fb.events[0].params, {"screen_name": "menu", "screen_class": "Main"}, "screen_view params")

	main.get_node("%PlayButton").pressed.emit()
	check(game.running and main.get_node("%HUD").visible, "Play starts a round")
	if not check(fb.events.size() == 3, "Play reports game_start and the game screen"):
		main.free()
		return
	eq(fb.events[1].name, "game_start", "round start is reported")
	eq(fb.events[1].params, {"best_score": 0}, "game_start carries the best score")
	game._spawn_timer = INF

	# reach the first milestone, then lose all lives
	game.score = 9
	game.spawn_item(game.ItemKind.STAR, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(main.get_node("%ScoreLabel").text, "Score: 10", "HUD shows the score")
	for i in 3:
		game.spawn_item(game.ItemKind.STAR, 30.0, game.FIELD.y + game.ITEM_RADIUS)
		game.step(0.016)

	eq(_event_names(fb), [
		"screen_view", "game_start", "screen_view", "unlock_achievement",
		"life_lost", "life_lost", "life_lost", "game_over", "post_score", "screen_view",
	] as Array[String], "events for one round, in order")
	var by_name := {}
	for e in fb.events:
		by_name[e.name] = e.params
	eq(by_name["unlock_achievement"], {"achievement_id": "catcher_10"}, "milestone reported")
	eq(by_name["life_lost"], {"cause": "missed_star", "score": 10}, "life_lost params")
	eq(by_name["post_score"], {"score": 10}, "post_score params")
	eq(by_name["game_over"]["score"], 10, "game_over score")
	eq(by_name["game_over"]["stars_caught"], 1, "game_over stars_caught")
	eq(by_name["game_over"]["stars_missed"], 3, "game_over stars_missed")
	eq(by_name["game_over"]["bombs_hit"], 0, "game_over bombs_hit")
	eq(by_name["game_over"]["new_best"], 1, "first round is a new best")
	check(by_name["game_over"]["duration_s"] is float, "duration is numeric")
	check(main.get_node("%GameOverPanel").visible and main.get_node("%NewBestLabel").visible, "game over screen shows a new best")
	eq(Save.best_score, 10, "best score saved")

	# second round: worse score, milestone already unlocked -> not reported again
	fb.events.clear()
	main.get_node("%PlayAgainButton").pressed.emit()
	game._spawn_timer = INF
	if not check(fb.events.size() == 2, "Play again reports game_start and the game screen"):
		main.free()
		return
	eq(fb.events[0].params, {"best_score": 10}, "second round starts with the saved best")
	game.score = 9
	game.spawn_item(game.ItemKind.STAR, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	check(not _event_names(fb).has("unlock_achievement"), "an unlocked milestone is not reported twice")
	game.score = 0
	for i in 3:
		game.spawn_item(game.ItemKind.BOMB, game.basket_x, game.BASKET_Y - 5.0)
		game.step(0.016)
	var over: Dictionary = fb.events.filter(func(e): return e.name == "game_over")[0].params
	eq(over["new_best"], 0, "a lower score is not a new best")
	eq(over["bombs_hit"], 3, "bomb hits are counted")
	check(not main.get_node("%NewBestLabel").visible, "no 'new best' banner")
	eq(Save.best_score, 10, "best score is unchanged")

	# turning analytics off from the menu stops reporting immediately
	main.get_node("%MenuButton").pressed.emit()
	main.get_node("%AnalyticsToggle").pressed.emit()
	eq(main.get_node("%AnalyticsToggle").text, "Analytics: Off", "toggle label")
	eq(Save.consent, Save.CONSENT_DENIED, "denial saved")
	eq(fb.collection_enabled, false, "Firebase collection disabled")
	fb.events.clear()
	main.get_node("%PlayButton").pressed.emit()
	eq(fb.events.size(), 0, "no events while analytics is off")

	Save.load_data()
	eq([Save.best_score, Save.achievements, Save.consent],
		[10, ["catcher_10"] as Array[String], Save.CONSENT_DENIED], "state survives a reload")
	main.free()



func _new_main_with_fake_firebase() -> Array:
	var fb: Object = _attach()[1]
	var main: Node = MainScene.instantiate()
	add_child(main)
	main.get_node("Game")._spawn_timer = INF
	return [main, fb]


func _test_full_flow_writes_the_funnel_to_the_local_log() -> void:
	var main: Node = _new_main_with_fake_firebase()[0]
	var game: Node2D = main.get_node("Game")
	eq(_log_names(), ["app_open", "consent_shown"] as Array[String], "launch, then the consent screen is shown")

	main.get_node("%AllowButton").pressed.emit()
	eq(_last("consent_choice").p, {"granted": 1}, "the consent answer is logged")

	main.get_node("%PlayButton").pressed.emit()
	game._spawn_timer = INF
	eq(_last("round_start").p, {"round_number": 1, "source": "menu", "best_score": 0}, "round start")

	game.spawn_item(game.ItemKind.STAR, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(_last("round_first_star").p.round_number, 1, "first star is attributed to round 1")
	check(_last("round_first_star").p.seconds_in_round > 0.0, "and says how far into the round it came")

	game.score = 9
	game.spawn_item(game.ItemKind.STAR, game.basket_x, game.BASKET_Y - 5.0)
	game.step(0.016)
	eq(_last("unlock_milestone").p, {"id": "catcher_10", "round_number": 1}, "milestone is logged")

	for i in 3:
		game.spawn_item(game.ItemKind.STAR, 30.0, game.FIELD.y + game.ITEM_RADIUS)
		game.step(0.016)
	var lives_left: Array = _log_events().filter(func(e): return e.e == "life_lost").map(func(e): return e.p.lives_left)
	eq(lives_left, [2, 1, 0], "each life lost is logged with lives left")
	var end: Dictionary = _last("round_end").p
	eq([end.round_number, end.score, end.stars_caught, end.stars_missed, end.bombs_hit, end.new_best],
		[1, 10, 2, 3, 0, 1], "round_end summarises the round")

	main.get_node("%PlayAgainButton").pressed.emit()
	eq(_last("round_start").p, {"round_number": 2, "source": "game_over", "best_score": 10},
		"the second round says it came from the game-over screen")
	main.free()


func _test_declined_players_are_still_logged_locally() -> void:
	var parts := _new_main_with_fake_firebase()
	var main: Node = parts[0]
	var fb: Object = parts[1]
	var game: Node2D = main.get_node("Game")
	main.get_node("%DeclineButton").pressed.emit()
	main.get_node("%PlayButton").pressed.emit()
	game._spawn_timer = INF
	for i in 3:
		game.spawn_item(game.ItemKind.STAR, 30.0, game.FIELD.y + game.ITEM_RADIUS)
		game.step(0.016)
	eq(_last("consent_choice").p, {"granted": 0}, "the refusal itself is logged")
	check(_log_names().has("round_end"), "rounds are logged for a player who declined")
	eq(fb.events.size(), 0, "while Firebase receives nothing")
	main.free()


func _test_share_button_reports_how_many_lines_were_copied() -> void:
	var main: Node = _new_main_with_fake_firebase()[0]
	var before := Telemetry.event_count()
	main.get_node("%ShareLogButton").pressed.emit()
	var label: Label = main.get_node("%ShareStatusLabel")
	check(label.visible, "a status line appears")
	check(label.text.begins_with("Copied %d log lines" % before), "it states how many lines were copied (%s)" % label.text)
	eq(_last("share_log").p, {"lines": before}, "the share is itself logged, after the copy")
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		eq(DisplayServer.clipboard_get().strip_edges().count("\n") + 1, before, "the clipboard holds the log")
	else:
		print("    (this display server has no clipboard; copy itself not checked here)")
	main.free()


func _test_backgrounding_marks_whether_a_round_was_open() -> void:
	var main: Node = _new_main_with_fake_firebase()[0]
	main.get_node("%AllowButton").pressed.emit()
	main.notification(NOTIFICATION_APPLICATION_PAUSED)
	eq(_last("app_background").p, {"in_round": 0}, "backgrounded from the menu")
	main.notification(NOTIFICATION_APPLICATION_RESUMED)
	check(_log_names().has("app_foreground"), "coming back is logged")
	main.get_node("%PlayButton").pressed.emit()
	main.notification(NOTIFICATION_APPLICATION_PAUSED)
	eq(_last("app_background").p, {"in_round": 1}, "backgrounded mid-round")
	main.free()
